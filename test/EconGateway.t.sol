// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EconGateway} from "../src/EconGateway.sol";
import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";
import {SXProposalGateway} from "../src/SXProposalGateway.sol";
import {Strategy} from "../src/types.sol";

contract EconGatewayArbitrationMock {
    error ProposalAlreadyExists();

    mapping(uint256 proposalId => bool) public exists;
    uint256 public lastProposalId;
    uint256 public lastMinActivationBond;
    address public lastCaller;
    uint256 public calls;

    function createProposalWithId(uint256 proposalId, uint256 minActivationBond)
        external
        returns (uint256)
    {
        if (exists[proposalId]) revert ProposalAlreadyExists();
        exists[proposalId] = true;
        lastProposalId = proposalId;
        lastMinActivationBond = minActivationBond;
        lastCaller = msg.sender;
        ++calls;
        return proposalId;
    }
}

contract EconGatewaySpaceMock {
    address public author;
    string public metadataURI;
    address public executionStrategy;
    bytes public executionPayload;
    bytes public proposalValidationParams;
    uint256 public calls;

    function propose(
        address author_,
        string calldata metadataURI_,
        Strategy calldata strategy_,
        bytes calldata proposalValidationParams_
    ) external {
        author = author_;
        metadataURI = metadataURI_;
        executionStrategy = strategy_.addr;
        executionPayload = strategy_.params;
        proposalValidationParams = proposalValidationParams_;
        ++calls;
    }
}

contract CriticalWindowMock {
    mapping(bytes32 baseHash => uint256 opensAt) public opens;
    mapping(bytes32 baseHash => uint256 closesAt) public closes;
    mapping(bytes32 baseHash => bool queued) public isQueued;

    function set(bytes32 baseHash, uint256 opensAt, uint256 closesAt, bool queued) external {
        opens[baseHash] = opensAt;
        closes[baseHash] = closesAt;
        isQueued[baseHash] = queued;
    }

    function criticalRoundTwoWindow(bytes32 baseHash)
        external
        view
        returns (uint256 opensAt, uint256 closesAt, bool queued)
    {
        return (opens[baseHash], closes[baseHash], isQueued[baseHash]);
    }
}

contract EconGatewayTest is Test {
    event TransferProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed asset,
        address recipient,
        uint256 amount,
        bytes32 salt
    );
    event ParamProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 indexed key,
        address asset,
        uint256 value,
        bytes32 salt
    );
    event CriticalRoundProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 indexed baseHash,
        address target,
        uint256 value,
        bytes32 dataHash,
        bytes32 salt,
        uint256 round
    );

    uint256 internal constant SITE_BOND = 1 ether;
    uint256 internal constant TREASURY_BOND = 7 ether;
    address internal constant EXECUTION_STRATEGY = address(0xE1);

    EconGatewayArbitrationMock internal arbitration;
    EconGatewaySpaceMock internal space;
    CriticalWindowMock internal vault;
    EconGateway internal gateway;

    function setUp() public {
        arbitration = new EconGatewayArbitrationMock();
        space = new EconGatewaySpaceMock();
        vault = new CriticalWindowMock();
        gateway = new EconGateway(
            address(space),
            EXECUTION_STRATEGY,
            address(arbitration),
            address(vault),
            SITE_BOND,
            TREASURY_BOND
        );
    }

    function testConstructorPinsOneArbitrationAndBothRoutes() public view {
        assertEq(address(gateway.space()), address(space));
        assertEq(address(gateway.executionStrategy()), EXECUTION_STRATEGY);
        assertEq(address(gateway.arbitration()), address(arbitration));
        assertEq(gateway.vault(), address(vault));
        assertEq(gateway.minActivationBond(), SITE_BOND);
        assertEq(gateway.treasuryMinActivationBond(), TREASURY_BOND);
    }

    function testSiteReleasePreservesExistingSnapshotRouteAndIdentity() public {
        address proposer = makeAddr("site-proposer");
        bytes memory payload = _siteRelease(1, keccak256("release"), "ipfs://release");
        bytes memory validationParams = hex"cafe";

        vm.prank(proposer);
        gateway.propose("ipfs://proposal", payload, validationParams);

        uint256 expectedId = uint256(keccak256(payload));
        assertEq(arbitration.lastProposalId(), expectedId);
        assertEq(arbitration.lastMinActivationBond(), SITE_BOND);
        assertEq(space.author(), proposer);
        assertEq(space.executionPayload(), payload);
        assertEq(space.proposalValidationParams(), validationParams);
    }

    function testTypedTransferAndParamUseExactPayloadsWithoutSnapshot() public {
        address proposer = makeAddr("proposer");
        FAOTreasuryActions.TransferAction memory transfer = _transfer(bytes32(uint256(1)));
        bytes memory transferPayload =
            FAOTreasuryActions.transferEvaluationPayload(block.chainid, address(vault), transfer);
        uint256 transferId = uint256(keccak256(transferPayload));

        vm.expectEmit(true, true, true, true, address(gateway));
        emit TransferProposed(
            transferId, proposer, transfer.asset, transfer.recipient, transfer.amount, transfer.salt
        );
        vm.prank(proposer);
        assertEq(gateway.proposeTransfer(transfer), transferId);
        assertEq(gateway.transferProposalId(transfer), transferId);
        assertEq(gateway.transferEvaluationPayload(transfer), transferPayload);

        FAOTreasuryActions.ParamAction memory param = _param(bytes32(uint256(2)));
        bytes memory paramPayload =
            FAOTreasuryActions.paramEvaluationPayload(block.chainid, address(vault), param);
        uint256 paramId = uint256(keccak256(paramPayload));
        vm.expectEmit(true, true, true, true, address(gateway));
        emit ParamProposed(paramId, proposer, param.key, param.asset, param.value, param.salt);
        vm.prank(proposer);
        assertEq(gateway.proposeParam(param), paramId);

        assertEq(gateway.paramProposalId(param), paramId);
        assertEq(gateway.paramEvaluationPayload(param), paramPayload);
        assertEq(arbitration.lastMinActivationBond(), TREASURY_BOND);
        assertEq(arbitration.lastCaller(), address(gateway));
        assertEq(arbitration.calls(), 2);
        assertEq(space.calls(), 0);
    }

    function testTypedRoutesRejectSameInvalidSemanticsAsEvaluator() public {
        FAOTreasuryActions.TransferAction memory transfer = _transfer(bytes32(0));
        transfer.recipient = address(0);
        vm.expectRevert(EconGateway.InvalidTransferAction.selector);
        gateway.proposeTransfer(transfer);

        transfer = _transfer(bytes32(0));
        transfer.amount = 0;
        vm.expectRevert(EconGateway.InvalidTransferAction.selector);
        gateway.proposeTransfer(transfer);

        FAOTreasuryActions.ParamAction memory param = _param(bytes32(0));
        param.key = bytes32(0);
        vm.expectRevert(EconGateway.InvalidParamAction.selector);
        gateway.proposeParam(param);

        FAOTreasuryActions.CriticalAction memory critical = _critical(bytes32(0));
        critical.target = address(0);
        vm.expectRevert(SXProposalGateway.ZeroAddress.selector);
        gateway.proposeCriticalRound(critical, 1);
        assertEq(arbitration.calls(), 0);
    }

    function testCriticalRoundOneUsesTypedIdWithoutConsultingWindow() public {
        FAOTreasuryActions.CriticalAction memory action = _critical(bytes32(uint256(3)));
        bytes32 baseHash =
            FAOTreasuryActions.criticalBaseHash(block.chainid, address(vault), action);
        uint256 proposalId =
            uint256(FAOTreasuryActions.criticalHash(block.chainid, address(vault), action, 1));

        vm.expectEmit(true, true, true, true, address(gateway));
        emit CriticalRoundProposed(
            proposalId,
            address(this),
            baseHash,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt,
            1
        );
        assertEq(gateway.proposeCriticalRound(action, 1), proposalId);
        assertEq(gateway.criticalBaseHash(action), baseHash);
        assertEq(gateway.criticalProposalId(action, 1), proposalId);
        assertEq(
            gateway.criticalEvaluationPayload(action, 1),
            FAOTreasuryActions.criticalEvaluationPayload(block.chainid, address(vault), action, 1)
        );
    }

    function testCriticalRoundTwoRequiresVaultStagingWindowAndNotQueued() public {
        vm.warp(100);
        FAOTreasuryActions.CriticalAction memory action = _critical(bytes32(uint256(4)));
        bytes32 baseHash = gateway.criticalBaseHash(action);

        vm.expectRevert(abi.encodeWithSelector(EconGateway.CriticalNotStaged.selector, baseHash));
        gateway.proposeCriticalRound(action, 2);

        vault.set(baseHash, block.timestamp + 1, block.timestamp + 10, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                EconGateway.CriticalRoundTwoTooEarly.selector, block.timestamp + 1
            )
        );
        gateway.proposeCriticalRound(action, 2);

        vault.set(baseHash, block.timestamp, block.timestamp + 10, true);
        vm.expectRevert(
            abi.encodeWithSelector(EconGateway.CriticalAlreadyQueued.selector, baseHash)
        );
        gateway.proposeCriticalRound(action, 2);

        vault.set(baseHash, block.timestamp - 10, block.timestamp - 1, false);
        vm.expectRevert(
            abi.encodeWithSelector(EconGateway.CriticalRoundTwoClosed.selector, block.timestamp - 1)
        );
        gateway.proposeCriticalRound(action, 2);

        vault.set(baseHash, block.timestamp, block.timestamp, false);
        uint256 expected = gateway.criticalProposalId(action, 2);
        assertEq(gateway.proposeCriticalRound(action, 2), expected);
        assertEq(arbitration.lastProposalId(), expected);
    }

    function testCriticalRejectsNonexistentRounds() public {
        FAOTreasuryActions.CriticalAction memory action = _critical(bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(FAOTreasuryActions.InvalidCriticalRound.selector, uint256(0))
        );
        gateway.proposeCriticalRound(action, 0);
        vm.expectRevert(
            abi.encodeWithSelector(FAOTreasuryActions.InvalidCriticalRound.selector, uint256(3))
        );
        gateway.proposeCriticalRound(action, 3);
    }

    function testTypedDomainPreventsCrossVaultAndCrossChainReplay() public {
        FAOTreasuryActions.TransferAction memory action = _transfer(bytes32(uint256(1)));
        uint256 original = gateway.transferProposalId(action);

        CriticalWindowMock otherVault = new CriticalWindowMock();
        EconGateway other = new EconGateway(
            address(space),
            EXECUTION_STRATEGY,
            address(arbitration),
            address(otherVault),
            SITE_BOND,
            TREASURY_BOND
        );
        assertNotEq(other.transferProposalId(action), original);

        vm.chainId(block.chainid + 1);
        assertNotEq(gateway.transferProposalId(action), original);
    }

    function _siteRelease(uint256 nonce, bytes32 digest, string memory uri)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            SXProposalGateway.SiteRelease({
                nonce: nonce,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: digest,
                artifactURI: uri
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
}
