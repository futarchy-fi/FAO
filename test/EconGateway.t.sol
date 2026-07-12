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

contract EconGatewayTest is Test {
    event TreasuryActionProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes32 dataHash,
        bytes32 salt
    );

    uint256 internal constant SITE_BOND = 1 ether;
    uint256 internal constant TREASURY_BOND = 7 ether;
    address internal constant EXECUTION_STRATEGY = address(0xE1);
    address internal constant VAULT = address(0xA11CE);
    address internal constant TARGET = address(0xBEEF);

    EconGatewayArbitrationMock internal arbitration;
    EconGatewaySpaceMock internal space;
    EconGateway internal gateway;

    function setUp() public {
        arbitration = new EconGatewayArbitrationMock();
        space = new EconGatewaySpaceMock();
        gateway = new EconGateway(
            address(space),
            EXECUTION_STRATEGY,
            address(arbitration),
            VAULT,
            SITE_BOND,
            TREASURY_BOND
        );
    }

    function testConstructorPinsOneArbitrationAndBothRoutes() public view {
        assertEq(address(gateway.space()), address(space));
        assertEq(address(gateway.executionStrategy()), EXECUTION_STRATEGY);
        assertEq(address(gateway.arbitration()), address(arbitration));
        assertEq(gateway.vault(), VAULT);
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
        assertEq(arbitration.lastCaller(), address(gateway));
        assertTrue(arbitration.exists(expectedId));
        assertEq(space.calls(), 1);
        assertEq(space.author(), proposer);
        assertEq(space.metadataURI(), "ipfs://proposal");
        assertEq(space.executionStrategy(), EXECUTION_STRATEGY);
        assertEq(space.executionPayload(), payload);
        assertEq(space.proposalValidationParams(), validationParams);
    }

    function testTreasuryRouteUsesExactDomainHashAndDoesNotTouchSnapshot() public {
        FAOTreasuryActions.TreasuryAction memory action = _treasuryAction(bytes32(uint256(123)));
        bytes32 dataHash = keccak256(action.data);
        bytes32 expectedHash = keccak256(
            abi.encode(
                gateway.KIND_TREASURY(),
                block.chainid,
                VAULT,
                action.target,
                action.value,
                dataHash,
                action.salt
            )
        );
        address proposer = makeAddr("treasury-proposer");

        vm.expectEmit(true, true, true, true, address(gateway));
        emit TreasuryActionProposed(
            uint256(expectedHash), proposer, action.target, action.value, dataHash, action.salt
        );
        vm.prank(proposer);
        uint256 proposalId = gateway.proposeTreasuryAction(action);

        assertEq(gateway.treasuryActionHash(action), expectedHash);
        assertEq(gateway.treasuryProposalId(action), uint256(expectedHash));
        assertEq(
            gateway.treasuryEvaluationPayload(action),
            abi.encode(
                gateway.KIND_TREASURY(),
                block.chainid,
                VAULT,
                action.target,
                action.value,
                dataHash,
                action.salt
            )
        );
        assertEq(proposalId, uint256(expectedHash));
        assertEq(arbitration.lastProposalId(), proposalId);
        assertEq(arbitration.lastMinActivationBond(), TREASURY_BOND);
        assertEq(arbitration.lastCaller(), address(gateway));
        assertEq(space.calls(), 0);
    }

    function testTreasuryDomainPreventsCrossVaultAndCrossChainReplay() public {
        FAOTreasuryActions.TreasuryAction memory action = _treasuryAction(bytes32(uint256(1)));
        bytes32 original = gateway.treasuryActionHash(action);

        EconGateway otherVault = new EconGateway(
            address(space),
            EXECUTION_STRATEGY,
            address(arbitration),
            address(0xB0B),
            SITE_BOND,
            TREASURY_BOND
        );
        assertNotEq(otherVault.treasuryActionHash(action), original);

        vm.chainId(block.chainid + 1);
        assertNotEq(gateway.treasuryActionHash(action), original);
    }

    function testTreasurySaltMakesRepeatIntentDistinctButExactReplayFails() public {
        FAOTreasuryActions.TreasuryAction memory first = _treasuryAction(bytes32(uint256(1)));
        FAOTreasuryActions.TreasuryAction memory second = _treasuryAction(bytes32(uint256(2)));

        assertNotEq(gateway.treasuryActionHash(first), gateway.treasuryActionHash(second));
        gateway.proposeTreasuryAction(first);

        vm.expectRevert(EconGatewayArbitrationMock.ProposalAlreadyExists.selector);
        gateway.proposeTreasuryAction(first);

        gateway.proposeTreasuryAction(second);
        assertEq(arbitration.calls(), 2);
    }

    function testTreasuryHashCommitsEveryActionField() public view {
        FAOTreasuryActions.TreasuryAction memory base = _treasuryAction(bytes32(uint256(1)));
        bytes32 expected = gateway.treasuryActionHash(base);

        FAOTreasuryActions.TreasuryAction memory changed = _treasuryAction(bytes32(uint256(1)));
        changed.target = address(0xDEAD);
        assertNotEq(gateway.treasuryActionHash(changed), expected);

        changed = _treasuryAction(bytes32(uint256(1)));
        changed.value += 1;
        assertNotEq(gateway.treasuryActionHash(changed), expected);

        changed = _treasuryAction(bytes32(uint256(1)));
        changed.data = abi.encodePacked(base.data, bytes1(0x01));
        assertNotEq(gateway.treasuryActionHash(changed), expected);

        changed = _treasuryAction(bytes32(uint256(1)));
        changed.salt = bytes32(uint256(2));
        assertNotEq(gateway.treasuryActionHash(changed), expected);
    }

    function testSiteReleaseRejectsMalformedPayloadsBeforeEitherExternalCall() public {
        _expectInvalidSite(_siteRelease(0, keccak256("release"), "ipfs://release"));
        _expectInvalidSite(_siteRelease(1, bytes32(0), "ipfs://release"));
        _expectInvalidSite(_siteRelease(1, keccak256("release"), ""));
        _expectInvalidSite(_siteRelease(1, keccak256("release"), string(new bytes(257))));

        assertEq(arbitration.calls(), 0);
        assertEq(space.calls(), 0);
    }

    function testConstructorRejectsNewRouteWithoutVaultOrBond() public {
        vm.expectRevert(SXProposalGateway.ZeroAddress.selector);
        new EconGateway(
            address(space),
            EXECUTION_STRATEGY,
            address(arbitration),
            address(0),
            SITE_BOND,
            TREASURY_BOND
        );

        vm.expectRevert(SXProposalGateway.InvalidMinActivationBond.selector);
        new EconGateway(
            address(space), EXECUTION_STRATEGY, address(arbitration), VAULT, SITE_BOND, 0
        );
    }

    function _expectInvalidSite(bytes memory payload) internal {
        vm.expectRevert(SXProposalGateway.InvalidExecutionPayload.selector);
        gateway.propose("ipfs://proposal", payload, "");
    }

    function _siteRelease(uint256 nonce, bytes32 digest, string memory uri)
        internal
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

    function _treasuryAction(bytes32 salt)
        internal
        pure
        returns (FAOTreasuryActions.TreasuryAction memory)
    {
        return FAOTreasuryActions.TreasuryAction({
            target: TARGET,
            value: 2 ether,
            data: abi.encodeWithSignature("transfer(address,uint256)", address(0xCAFE), 4 ether),
            salt: salt
        });
    }
}
