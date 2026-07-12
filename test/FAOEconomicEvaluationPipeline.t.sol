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
    uint256 public resolveCalls;

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
        ++resolveCalls;
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
    address internal constant TARGET = address(0xBEEF);

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
        assertEq(address(pipeline), expectedPipeline);

        gateway = new EconGateway(
            address(space), address(0xE1), address(arbitration), VAULT, SITE_BOND, TREASURY_BOND
        );
    }

    function testSiteGatewayRouteRetainsPayloadIdentityMarketTextAndResolution() public {
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
        assertTrue(arbitration.resolved());
        assertTrue(arbitration.accepted());
    }

    function testTreasuryGatewayRouteUsesExactStaticCommitmentAndCanResolveNo() public {
        FAOTreasuryActions.TreasuryAction memory action = _action(bytes32(uint256(17)));
        bytes memory payload = gateway.treasuryEvaluationPayload(action);
        uint256 proposalId = uint256(keccak256(payload));
        bytes32 dataHash = keccak256(action.data);

        assertEq(payload.length, 7 * 32);
        assertEq(gateway.treasuryActionHash(action), keccak256(payload));
        assertEq(gateway.proposeTreasuryAction(action), proposalId);
        assertEq(arbitration.lastCreatedProposalId(), proposalId);
        arbitration.setActive(proposalId);

        vm.expectEmit(true, true, true, true, address(pipeline));
        emit EvaluationMarketCreated(
            proposalId, 0, address(proposal), gateway.KIND_TREASURY(), dataHash
        );
        pipeline.startEvaluation(proposalId, payload);

        assertEq(
            orchestrator.lastMarketName(),
            string.concat("FAO treasury action to ", Strings.toHexString(action.target))
        );
        assertEq(orchestrator.lastDescription(), _treasuryDescription(action, dataHash));

        resolver.setDecision(1, 0, 1);
        assertFalse(pipeline.resolve(proposalId));
        assertTrue(arbitration.resolved());
        assertFalse(arbitration.accepted());
    }

    function testTreasuryPayloadRejectsWrongDomainOrTarget() public {
        FAOTreasuryActions.TreasuryAction memory action = _action(bytes32(uint256(1)));

        bytes memory payload = _treasuryPayload(block.chainid + 1, VAULT, action);
        _activate(payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.WrongTreasuryChain.selector,
                block.chainid,
                block.chainid + 1
            )
        );
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);

        payload = _treasuryPayload(block.chainid, address(0xBAD), action);
        _activate(payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOEconomicEvaluationPipeline.WrongTreasuryVault.selector, VAULT, address(0xBAD)
            )
        );
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);

        action.target = address(0);
        payload = _treasuryPayload(block.chainid, VAULT, action);
        _activate(payload);
        vm.expectRevert(FAOEconomicEvaluationPipeline.InvalidTreasuryPayload.selector);
        pipeline.startEvaluation(uint256(keccak256(payload)), payload);
    }

    function testTreasuryKindWithTrailingWordCannotFallThroughToSiteDecoder() public {
        bytes memory payload = bytes.concat(
            _treasuryPayload(block.chainid, VAULT, _action(bytes32(uint256(2)))), bytes32(0)
        );
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);

        vm.expectRevert(FAOEconomicEvaluationPipeline.InvalidTreasuryPayload.selector);
        pipeline.startEvaluation(proposalId, payload);
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

    function _action(bytes32 salt) private pure returns (FAOTreasuryActions.TreasuryAction memory) {
        return FAOTreasuryActions.TreasuryAction({
            target: TARGET,
            value: 2 ether,
            data: abi.encodeWithSignature("transfer(address,uint256)", address(0xCAFE), 4 ether),
            salt: salt
        });
    }

    function _treasuryPayload(
        uint256 chainId,
        address vault,
        FAOTreasuryActions.TreasuryAction memory action
    ) private view returns (bytes memory) {
        return abi.encode(
            gateway.KIND_TREASURY(),
            chainId,
            vault,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt
        );
    }

    function _treasuryDescription(FAOTreasuryActions.TreasuryAction memory action, bytes32 dataHash)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "chain=",
            block.chainid.toString(),
            "; vault=",
            Strings.toHexString(VAULT),
            "; target=",
            Strings.toHexString(action.target),
            "; value=",
            action.value.toString(),
            "; data-hash=",
            Strings.toHexString(uint256(dataHash), 32),
            "; salt=",
            Strings.toHexString(uint256(action.salt), 32)
        );
    }
}
