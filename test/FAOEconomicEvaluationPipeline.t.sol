// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test} from "forge-std/Test.sol";

import {EconGateway} from "../src/EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "../src/FAOEconomicEvaluationPipeline.sol";
import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {Strategy} from "../src/types.sol";

contract EconomicEvaluationArbitrationMock {
    uint256 public activeEvaluationProposalId;
    uint256 public lastCreatedProposalId;
    bool public resolved;
    bool public accepted;

    function createProposalWithId(uint256 proposalId, uint256) external returns (uint256) {
        lastCreatedProposalId = proposalId;
        return proposalId;
    }

    function setActive(uint256 proposalId) external {
        activeEvaluationProposalId = proposalId;
    }

    function resolveActiveEvaluation(bool accepted_) external {
        resolved = true;
        accepted = accepted_;
        activeEvaluationProposalId = 0;
    }
}

contract EconomicEvaluationSpaceMock {
    bytes public lastPayload;

    function propose(address, string calldata, Strategy calldata strategy, bytes calldata)
        external
    {
        lastPayload = strategy.params;
    }
}

contract EconomicEvaluationConditionalTokensMock {
    uint256 public denominator;
    uint256 public yes;
    uint256 public no;

    function setPayout(uint256 denominator_, uint256 yes_, uint256 no_) external {
        denominator = denominator_;
        yes = yes_;
        no = no_;
    }

    function payoutDenominator(bytes32) external view returns (uint256) {
        return denominator;
    }

    function payoutNumerators(bytes32, uint256 index) external view returns (uint256) {
        return index == 0 ? yes : no;
    }
}

contract EconomicEvaluationProposalMock {
    bytes32 public immutable conditionId;

    constructor(bytes32 conditionId_) {
        conditionId = conditionId_;
    }
}

contract EconomicEvaluationResolverMock {
    address public immutable CTF;
    EconomicEvaluationConditionalTokensMock internal immutable ctf;
    uint256 public denominator = 1;
    uint256 public yes = 1;
    uint256 public no;

    constructor(EconomicEvaluationConditionalTokensMock ctf_) {
        CTF = address(ctf_);
        ctf = ctf_;
    }

    function setDecision(uint256 denominator_, uint256 yes_, uint256 no_) external {
        denominator = denominator_;
        yes = yes_;
        no = no_;
    }

    function resolve(address) external {
        ctf.setPayout(denominator, yes, no);
    }
}

contract EconomicEvaluationOrchestratorMock {
    address public immutable ADMIN;
    address public immutable RESOLVER;
    address public immutable proposal;

    uint256 public createCalls;
    string public lastMarketName;
    string public lastDescription;

    constructor(address admin_, address resolver_, address proposal_) {
        ADMIN = admin_;
        RESOLVER = resolver_;
        proposal = proposal_;
    }

    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata description,
        uint256
    ) external payable returns (uint256 proposalId, address proposal_) {
        lastMarketName = marketName;
        lastDescription = description;
        proposalId = createCalls++;
        proposal_ = proposal;
    }
}

contract FAOEconomicEvaluationPipelineTest is Test {
    using Strings for uint256;

    event EvaluationMarketCreated(
        uint256 indexed proposalId,
        uint256 indexed futarchyProposalId,
        address indexed futarchyProposal,
        bytes32 payloadKind,
        bytes32 payloadCommitment
    );

    bytes32 internal constant CONDITION_ID = keccak256("economic-evaluation-condition");
    uint256 internal constant SITE_BOND = 1 ether;
    uint256 internal constant TREASURY_BOND = 7 ether;
    address internal constant VAULT = address(0xA11CE);

    EconomicEvaluationArbitrationMock internal arbitration;
    EconomicEvaluationSpaceMock internal space;
    EconomicEvaluationConditionalTokensMock internal ctf;
    EconomicEvaluationProposalMock internal proposal;
    EconomicEvaluationResolverMock internal resolver;
    EconomicEvaluationOrchestratorMock internal orchestrator;
    FAOEconomicEvaluationPipeline internal pipeline;
    EconGateway internal gateway;

    function setUp() public {
        arbitration = new EconomicEvaluationArbitrationMock();
        space = new EconomicEvaluationSpaceMock();
        ctf = new EconomicEvaluationConditionalTokensMock();
        proposal = new EconomicEvaluationProposalMock(CONDITION_ID);
        resolver = new EconomicEvaluationResolverMock(ctf);

        address expectedPipeline =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        orchestrator = new EconomicEvaluationOrchestratorMock(
            expectedPipeline, address(resolver), address(proposal)
        );
        pipeline = new FAOEconomicEvaluationPipeline(
            address(arbitration), address(orchestrator), address(resolver), address(ctf), VAULT
        );
        gateway = new EconGateway(
            address(space), address(0xE1), address(arbitration), VAULT, SITE_BOND, TREASURY_BOND
        );
    }

    function testSiteRouteRetainsPayloadIdentityTextAndResolution() public {
        bytes32 currentDigest = keccak256("current");
        bytes32 artifactDigest = keccak256("artifact");
        string memory uri = "ipfs://site-artifact";
        bytes memory payload = _sitePayload(7, currentDigest, artifactDigest, uri);
        uint256 proposalId = uint256(keccak256(payload));

        gateway.propose("ipfs://metadata", payload, "");
        assertEq(arbitration.lastCreatedProposalId(), proposalId);
        assertEq(space.lastPayload(), payload);
        arbitration.setActive(proposalId);

        vm.expectEmit(true, true, true, true, address(pipeline));
        emit EvaluationMarketCreated(
            proposalId, 0, address(proposal), pipeline.KIND_SITE_RELEASE(), artifactDigest
        );
        pipeline.startEvaluation(proposalId, payload);

        assertEq(orchestrator.lastMarketName(), "FAO site release #7");
        assertEq(
            orchestrator.lastDescription(),
            string.concat(
                "expected-current=",
                Strings.toHexString(uint256(currentDigest), 32),
                "; artifact=",
                Strings.toHexString(uint256(artifactDigest), 32),
                "; uri=",
                uri
            )
        );
        assertTrue(pipeline.resolve(proposalId));
        assertTrue(arbitration.accepted());
    }

    function testTransferUsesExactTextAndFullPayloadCommitment() public {
        FAOTreasuryActions.TransferAction memory action = _transfer(bytes32(uint256(17)));
        bytes memory payload = gateway.transferEvaluationPayload(action);
        uint256 proposalId = uint256(keccak256(payload));
        assertEq(payload.length, 224);
        assertEq(gateway.proposeTransfer(action), proposalId);
        arbitration.setActive(proposalId);

        vm.expectEmit(true, true, true, true, address(pipeline));
        emit EvaluationMarketCreated(
            proposalId, 0, address(proposal), pipeline.KIND_TRANSFER(), keccak256(payload)
        );
        pipeline.startEvaluation(proposalId, payload);

        assertEq(
            orchestrator.lastMarketName(),
            string.concat("FAO treasury transfer to ", Strings.toHexString(action.recipient))
        );
        assertEq(orchestrator.lastDescription(), _transferDescription(action));
    }

    function testParamUsesExactTextAndFullPayloadCommitment() public {
        FAOTreasuryActions.ParamAction memory action = _param(bytes32(uint256(18)));
        bytes memory payload = gateway.paramEvaluationPayload(action);
        uint256 proposalId = uint256(keccak256(payload));
        assertEq(payload.length, 224);
        assertEq(gateway.proposeParam(action), proposalId);
        arbitration.setActive(proposalId);

        vm.expectEmit(true, true, true, true, address(pipeline));
        emit EvaluationMarketCreated(
            proposalId, 0, address(proposal), pipeline.KIND_PARAM(), keccak256(payload)
        );
        pipeline.startEvaluation(proposalId, payload);

        assertEq(
            orchestrator.lastMarketName(),
            string.concat("FAO treasury parameter ", Strings.toHexString(uint256(action.key), 32))
        );
        assertEq(orchestrator.lastDescription(), _paramDescription(action));
    }

    function testCriticalRoundsCommitToSameBaseAndRenderRound() public {
        FAOTreasuryActions.CriticalAction memory action = _critical(bytes32(uint256(19)));
        bytes32 baseHash = gateway.criticalBaseHash(action);

        for (uint256 round = 1; round <= 2; ++round) {
            bytes memory payload = gateway.criticalEvaluationPayload(action, round);
            uint256 proposalId = uint256(keccak256(payload));
            assertEq(payload.length, 256);
            arbitration.setActive(proposalId);

            vm.expectEmit(true, true, true, true, address(pipeline));
            emit EvaluationMarketCreated(
                proposalId, round - 1, address(proposal), pipeline.KIND_CRITICAL(), baseHash
            );
            pipeline.startEvaluation(proposalId, payload);

            assertEq(
                orchestrator.lastMarketName(),
                string.concat("FAO critical action round ", round.toString(), "/2")
            );
            assertEq(orchestrator.lastDescription(), _criticalDescription(action, baseHash, round));
        }
    }

    function testTypedPayloadLengthsAreExactAndCannotFallThroughToSiteDecoder() public {
        bytes memory transfer = gateway.transferEvaluationPayload(_transfer(bytes32(0)));
        _expectInvalidTreasury(bytes.concat(transfer, bytes32(0)));
        _expectInvalidTreasury(bytes.concat(bytes32(pipeline.KIND_TRANSFER()), bytes32(0)));

        bytes memory param = gateway.paramEvaluationPayload(_param(bytes32(0)));
        _expectInvalidTreasury(bytes.concat(param, bytes32(0)));

        bytes memory criticalBase =
            FAOTreasuryActions.criticalBasePayload(block.chainid, VAULT, _critical(bytes32(0)));
        assertEq(criticalBase.length, 224);
        _expectInvalidTreasury(criticalBase);
        _expectInvalidTreasury(
            bytes.concat(gateway.criticalEvaluationPayload(_critical(bytes32(0)), 1), bytes32(0))
        );
    }

    function testTypedPayloadsRejectWrongDomainAndInvalidSemantics() public {
        FAOTreasuryActions.TransferAction memory transfer = _transfer(bytes32(0));
        bytes memory payload =
            FAOTreasuryActions.transferEvaluationPayload(block.chainid + 1, VAULT, transfer);
        _activate(payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.WrongTreasuryChain.selector,
                block.chainid,
                block.chainid + 1
            )
        );
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);

        payload =
            FAOTreasuryActions.transferEvaluationPayload(block.chainid, address(0xBAD), transfer);
        _activate(payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.WrongTreasuryVault.selector, VAULT, address(0xBAD)
            )
        );
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);

        transfer.recipient = address(0);
        _expectInvalidTreasury(
            FAOTreasuryActions.transferEvaluationPayload(block.chainid, VAULT, transfer)
        );
        transfer = _transfer(bytes32(0));
        transfer.amount = 0;
        _expectInvalidTreasury(
            FAOTreasuryActions.transferEvaluationPayload(block.chainid, VAULT, transfer)
        );

        FAOTreasuryActions.ParamAction memory param = _param(bytes32(0));
        param.key = bytes32(0);
        _expectInvalidTreasury(
            FAOTreasuryActions.paramEvaluationPayload(block.chainid, VAULT, param)
        );

        FAOTreasuryActions.CriticalAction memory critical = _critical(bytes32(0));
        critical.target = address(0);
        _expectInvalidTreasury(
            FAOTreasuryActions.criticalEvaluationPayload(block.chainid, VAULT, critical, 1)
        );
        critical = _critical(bytes32(0));
        _expectInvalidTreasury(_criticalPayload(critical, 0));
        _expectInvalidTreasury(_criticalPayload(critical, 3));
    }

    function testPayloadMustMatchActiveIdAndEvaluationIsOneShot() public {
        bytes memory payload = _sitePayload(1, bytes32(0), keccak256("one"), "ipfs://one");
        bytes memory substitute = _sitePayload(1, bytes32(0), keccak256("two"), "ipfs://two");
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.PayloadHashMismatch.selector,
                proposalId,
                keccak256(substitute)
            )
        );
        pipeline.startEvaluation(proposalId, substitute);

        pipeline.startEvaluation(proposalId, payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.EvaluationAlreadyStarted.selector, proposalId
            )
        );
        pipeline.startEvaluation(proposalId, payload);
    }

    function _expectInvalidTreasury(bytes memory payload) private {
        _activate(payload);
        vm.expectRevert(FAOEconomicEvaluationPipeline.InvalidTreasuryPayload.selector);
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);
    }

    function _activate(bytes memory payload) private {
        arbitration.setActive(uint256(keccak256(payload)));
    }

    function _sitePayload(
        uint256 nonce,
        bytes32 expectedCurrentDigest,
        bytes32 artifactDigest,
        string memory artifactURI
    ) private pure returns (bytes memory) {
        return abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: nonce,
                expectedCurrentDigest: expectedCurrentDigest,
                artifactDigest: artifactDigest,
                artifactURI: artifactURI
            })
        );
    }

    function _transfer(bytes32 salt)
        private
        pure
        returns (FAOTreasuryActions.TransferAction memory)
    {
        return FAOTreasuryActions.TransferAction({
            asset: address(0xA55E7), recipient: address(0xB0B), amount: 2 ether, salt: salt
        });
    }

    function _param(bytes32 salt) private pure returns (FAOTreasuryActions.ParamAction memory) {
        return FAOTreasuryActions.ParamAction({
            key: keccak256("monthly-tap"), asset: address(0xA55E7), value: 3 ether, salt: salt
        });
    }

    function _critical(bytes32 salt)
        private
        pure
        returns (FAOTreasuryActions.CriticalAction memory)
    {
        return FAOTreasuryActions.CriticalAction({
            target: address(0xBEEF), value: 4 ether, data: hex"12345678aabb", salt: salt
        });
    }

    function _criticalPayload(FAOTreasuryActions.CriticalAction memory action, uint256 round)
        private
        view
        returns (bytes memory)
    {
        return abi.encode(
            pipeline.KIND_CRITICAL(),
            block.chainid,
            VAULT,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt,
            round
        );
    }

    function _transferDescription(FAOTreasuryActions.TransferAction memory action)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "chain=",
            block.chainid.toString(),
            "; vault=",
            Strings.toHexString(VAULT),
            "; asset=",
            Strings.toHexString(action.asset),
            "; recipient=",
            Strings.toHexString(action.recipient),
            "; amount=",
            action.amount.toString(),
            "; salt=",
            Strings.toHexString(uint256(action.salt), 32)
        );
    }

    function _paramDescription(FAOTreasuryActions.ParamAction memory action)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "chain=",
            block.chainid.toString(),
            "; vault=",
            Strings.toHexString(VAULT),
            "; key=",
            Strings.toHexString(uint256(action.key), 32),
            "; asset=",
            Strings.toHexString(action.asset),
            "; value=",
            action.value.toString(),
            "; salt=",
            Strings.toHexString(uint256(action.salt), 32)
        );
    }

    function _criticalDescription(
        FAOTreasuryActions.CriticalAction memory action,
        bytes32 baseHash,
        uint256 round
    ) private view returns (string memory) {
        return string.concat(
            "chain=",
            block.chainid.toString(),
            "; vault=",
            Strings.toHexString(VAULT),
            "; action-hash=",
            Strings.toHexString(uint256(baseHash), 32),
            "; target=",
            Strings.toHexString(action.target),
            "; value=",
            action.value.toString(),
            "; data-hash=",
            Strings.toHexString(uint256(keccak256(action.data)), 32),
            "; salt=",
            Strings.toHexString(uint256(action.salt), 32),
            "; round=",
            round.toString(),
            " of 2"
        );
    }
}
