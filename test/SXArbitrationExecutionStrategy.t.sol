// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Space} from "lib/sx-evm/src/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "lib/sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {AlwaysZeroVotingStrategy} from "../src/AlwaysZeroVotingStrategy.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {IFutarchyArbitrationEvaluator} from "../src/IFutarchyArbitrationEvaluator.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "../src/SXProposalGateway.sol";
import {IExecutionStrategy} from "src/interfaces/IExecutionStrategy.sol";
import {ISpaceErrors} from "src/interfaces/space/ISpaceErrors.sol";
import {
    Choice,
    FinalizationStatus,
    IndexedStrategy,
    InitializeCalldata,
    Proposal,
    ProposalStatus,
    Strategy
} from "src/types.sol";

contract ArbitrationMock {
    error NotProposalGateway();
    error ProposalAlreadyExists();
    error ProposalGatewayAlreadySet();

    mapping(uint256 => bool) public accepted;
    mapping(uint256 => bool) public settled;
    mapping(uint256 => bool) public exists;
    mapping(uint256 => uint256) public activationBond;
    mapping(uint256 => address) public creator;
    address public proposalGateway;

    function setProposalGateway(address proposalGateway_) external {
        if (proposalGateway != address(0)) revert ProposalGatewayAlreadySet();
        proposalGateway = proposalGateway_;
    }

    function createProposalWithId(uint256 arbId, uint256 minActivationBond)
        external
        returns (uint256)
    {
        if (msg.sender != proposalGateway) revert NotProposalGateway();
        if (exists[arbId]) revert ProposalAlreadyExists();
        exists[arbId] = true;
        activationBond[arbId] = minActivationBond;
        creator[arbId] = msg.sender;
        return arbId;
    }

    function settle(uint256 arbId, bool accepted_) external {
        settled[arbId] = true;
        accepted[arbId] = accepted_;
    }

    function setAccepted(uint256 arbId, bool accepted_) external {
        accepted[arbId] = accepted_;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }

    function isSettled(uint256 arbId) external view returns (bool) {
        return settled[arbId];
    }
}

contract AcceptingEvaluator is IFutarchyArbitrationEvaluator {
    address public immutable arbitration;

    constructor(address arbitration_) {
        arbitration = arbitration_;
    }

    function resolve(uint256) external returns (bool accepted) {
        accepted = true;
        FutarchyArbitration(arbitration).resolveActiveEvaluation(accepted);
    }
}

contract SXArbitrationExecutionStrategyTest is Test {
    uint256 internal constant MIN_ACTIVATION_BOND = 1e18;
    address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    event SiteReleaseSelected(
        uint256 indexed sxProposalId,
        uint256 indexed arbitrationId,
        bytes32 indexed artifactDigest,
        uint256 nonce,
        bytes32 previousDigest,
        string artifactURI
    );

    address internal proposer = makeAddr("proposer");
    address internal voter = makeAddr("voter");

    Space internal space;
    ArbitrationMock internal arbitration;
    SXArbitrationExecutionStrategy internal strategy;
    AlwaysZeroVotingStrategy internal zeroVoting;
    SXProposalGateway internal gateway;

    function setUp() public {
        Space implementation = new Space();
        space = Space(address(new ERC1967Proxy(address(implementation), "")));

        arbitration = new ArbitrationMock();
        strategy = new SXArbitrationExecutionStrategy(address(space), address(arbitration));
        zeroVoting = new AlwaysZeroVotingStrategy();
        gateway = new SXProposalGateway(
            address(space), address(strategy), address(arbitration), MIN_ACTIVATION_BOND
        );
        arbitration.setProposalGateway(address(gateway));

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: address(zeroVoting), params: ""});

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "AlwaysZeroVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(gateway);

        VanillaProposalValidationStrategy proposalValidation =
            new VanillaProposalValidationStrategy();

        space.initialize(
            InitializeCalldata({
                owner: address(this),
                votingDelay: 0,
                minVotingDuration: 0,
                maxVotingDuration: 0,
                proposalValidationStrategy: Strategy({
                    addr: address(proposalValidation), params: ""
                }),
                proposalValidationStrategyMetadataURI: "VanillaProposalValidationStrategy",
                daoURI: "",
                metadataURI: "",
                votingStrategies: votingStrategies,
                votingStrategyMetadataURIs: votingStrategyMetadataURIs,
                authenticators: authenticators
            })
        );

        space.renounceOwnership();
        assertEq(space.owner(), address(0));
    }

    function testAlwaysZeroVotingStrategyReturnsZero() public view {
        assertEq(zeroVoting.getVotingPower(42, voter, hex"1234", hex"5678"), 0);
    }

    function testZeroDurationVoteAlwaysRevertsWithoutState() public {
        uint256 proposalId = _propose(_validPayload("zero-duration"));
        IndexedStrategy[] memory userStrategies = _userStrategies();

        vm.expectRevert(ISpaceErrors.AuthenticatorNotWhitelisted.selector);
        vm.prank(voter);
        space.vote(voter, proposalId, Choice.For, userStrategies, "");

        _expectEndedVote(proposalId, userStrategies);
        vm.roll(block.number + 10);
        _expectEndedVote(proposalId, userStrategies);

        assertEq(space.voteRegistry(proposalId, voter), 0);
        assertEq(space.votePower(proposalId, Choice.For), 0);
        assertEq(space.votePower(proposalId, Choice.Against), 0);
        assertEq(space.votePower(proposalId, Choice.Abstain), 0);
    }

    function testProposalCreationAtomicallyCreatesArbitrationRecord() public {
        bytes memory payload = _validPayload("atomic-record");
        _propose(payload);

        uint256 arbId = _arbId(payload);
        assertTrue(arbitration.exists(arbId));
        assertEq(arbitration.activationBond(arbId), MIN_ACTIVATION_BOND);
        assertEq(arbitration.creator(arbId), address(gateway));
    }

    function testDuplicatePayloadCannotCreateAnotherSpaceProposal() public {
        bytes memory payload = _validPayload("duplicate-payload");
        _propose(payload);
        uint256 nextProposalId = space.nextProposalId();

        vm.expectRevert(ArbitrationMock.ProposalAlreadyExists.selector);
        vm.prank(makeAddr("second-proposer"));
        gateway.propose("ipfs://duplicate", payload, "");

        assertEq(space.nextProposalId(), nextProposalId);
        assertEq(arbitration.creator(_arbId(payload)), address(gateway));
    }

    function testSpaceFailureRollsBackArbitrationRecord() public {
        ArbitrationMock rollbackArbitration = new ArbitrationMock();
        SXProposalGateway unlistedGateway = new SXProposalGateway(
            address(space), address(strategy), address(rollbackArbitration), MIN_ACTIVATION_BOND
        );
        rollbackArbitration.setProposalGateway(address(unlistedGateway));
        bytes memory payload = _validPayload("rollback-record");
        uint256 nextProposalId = space.nextProposalId();

        vm.expectRevert(ISpaceErrors.AuthenticatorNotWhitelisted.selector);
        vm.prank(proposer);
        unlistedGateway.propose("ipfs://rollback", payload, "");

        assertFalse(rollbackArbitration.exists(_arbId(payload)));
        assertEq(space.nextProposalId(), nextProposalId);
    }

    function testAcceptedArbitrationSelectsArbitrarySiteReleaseWithZeroVotes() public {
        bytes32 digest = keccak256("arbitrary-site-artifact");
        string memory uri =
            "git+ssh://git@example.invalid/any/repo.git#refs/heads/release?manifest=site/**";
        bytes memory payload = _releasePayload(1, bytes32(0), digest, uri);
        uint256 proposalId = _propose(payload);
        arbitration.settle(_arbId(payload), true);

        assertEq(uint256(space.getProposalStatus(proposalId)), uint256(ProposalStatus.Accepted));
        assertEq(space.votePower(proposalId, Choice.For), 0);
        assertEq(space.votePower(proposalId, Choice.Against), 0);
        assertEq(space.votePower(proposalId, Choice.Abstain), 0);

        vm.expectEmit(true, true, true, true);
        emit SiteReleaseSelected(proposalId, _arbId(payload), digest, 1, bytes32(0), uri);
        space.execute(proposalId, payload);

        assertEq(strategy.releaseNonce(), 1);
        assertEq(strategy.releaseDigest(), digest);
        assertEq(strategy.releaseURI(), uri);
        assertEq(uint256(_finalizationStatus(proposalId)), uint256(FinalizationStatus.Executed));
        assertEq(uint256(space.getProposalStatus(proposalId)), uint256(ProposalStatus.Executed));
    }

    function testUnsettledArbitrationCannotExecute() public {
        bytes memory payload = _validPayload("unsettled-payload");
        uint256 proposalId = _propose(payload);
        arbitration.setAccepted(_arbId(payload), true);

        assertEq(uint256(space.getProposalStatus(proposalId)), uint256(ProposalStatus.VotingPeriod));
        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, _arbId(payload)
            )
        );
        space.execute(proposalId, payload);

        _assertNotExecuted(proposalId);
    }

    function testRejectedArbitrationCannotExecute() public {
        bytes memory payload = _validPayload("rejected-payload");
        uint256 proposalId = _propose(payload);
        arbitration.settle(_arbId(payload), false);

        assertEq(uint256(space.getProposalStatus(proposalId)), uint256(ProposalStatus.Rejected));
        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, _arbId(payload)
            )
        );
        space.execute(proposalId, payload);

        _assertNotExecuted(proposalId);
    }

    function testReleasePayloadCannotBeReplayed() public {
        bytes memory payload =
            _releasePayload(1, bytes32(0), keccak256("release-one"), "ipfs://release-one");
        uint256 proposalId = _propose(payload);
        arbitration.settle(_arbId(payload), true);
        space.execute(proposalId, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.InvalidReleaseNonce.selector, 2, 1
            )
        );
        vm.prank(address(space));
        strategy.execute(proposalId, _proposal(address(strategy), payload), 0, 0, 0, payload);

        assertEq(strategy.releaseNonce(), 1);
    }

    function testStaleExpectedDigestCannotOverwriteNewerRelease() public {
        bytes32 firstDigest = keccak256("release-one");
        bytes memory first = _releasePayload(1, bytes32(0), firstDigest, "ipfs://release-one");
        bytes memory stale =
            _releasePayload(2, bytes32(0), keccak256("stale-release"), "ipfs://stale");

        uint256 firstProposalId = _propose(first);
        uint256 staleProposalId = _propose(stale);
        arbitration.settle(_arbId(first), true);
        arbitration.settle(_arbId(stale), true);
        space.execute(firstProposalId, first);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.UnexpectedCurrentRelease.selector,
                bytes32(0),
                firstDigest
            )
        );
        space.execute(staleProposalId, stale);

        assertEq(strategy.releaseNonce(), 1);
        assertEq(strategy.releaseDigest(), firstDigest);
        assertEq(uint256(_finalizationStatus(staleProposalId)), uint256(FinalizationStatus.Pending));
    }

    function testReleaseURILengthIsBounded() public {
        string memory uri = string(new bytes(strategy.MAX_RELEASE_URI_BYTES() + 1));
        bytes memory payload = _releasePayload(1, bytes32(0), keccak256("too-long-uri"), uri);
        arbitration.settle(_arbId(payload), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.InvalidReleaseURI.selector,
                strategy.MAX_RELEASE_URI_BYTES() + 1
            )
        );
        vm.prank(address(space));
        strategy.execute(1, _proposal(address(strategy), payload), 0, 0, 0, payload);

        assertEq(strategy.releaseNonce(), 0);
    }

    function testUnrelatedLargeNoProposalCannotBlockYesTimeoutSiteRelease() public {
        FutarchyArbitration realArbitration = _realArbitration();
        SXArbitrationExecutionStrategy realStrategy =
            new SXArbitrationExecutionStrategy(address(this), address(realArbitration));

        uint256 unrelatedId = uint256(keccak256("unrelated-no"));
        realArbitration.createProposalWithId(unrelatedId, MIN_ACTIVATION_BOND);
        realArbitration.placeYesBond(unrelatedId, realArbitration.baseX());
        realArbitration.placeNoBond(unrelatedId);

        bytes32 digest = keccak256("timeout-release");
        bytes memory payload = _releasePayload(1, bytes32(0), digest, "ipfs://timeout-release");
        uint256 arbId = _arbId(payload);

        realArbitration.createProposalWithId(arbId, MIN_ACTIVATION_BOND);
        realArbitration.placeYesBond(arbId, MIN_ACTIVATION_BOND);
        vm.warp(block.timestamp + 72 hours);
        realArbitration.finalizeByTimeout(arbId);

        assertFalse(realArbitration.isSettled(unrelatedId));
        realStrategy.execute(1, _proposal(address(realStrategy), payload), 0, 0, 0, payload);
        assertTrue(realArbitration.isAccepted(arbId));
        assertEq(realStrategy.releaseDigest(), digest);
    }

    function testEvaluatedAcceptanceSelectsRelease() public {
        FutarchyArbitration realArbitration = _realArbitration();
        AcceptingEvaluator evaluator = new AcceptingEvaluator(address(realArbitration));
        realArbitration.setEvaluator(address(evaluator));
        SXArbitrationExecutionStrategy realStrategy =
            new SXArbitrationExecutionStrategy(address(this), address(realArbitration));
        bytes32 digest = keccak256("evaluated-release");
        bytes memory payload = _releasePayload(1, bytes32(0), digest, "ar://evaluated-release");
        uint256 arbId = _arbId(payload);

        realArbitration.createProposalWithId(arbId, MIN_ACTIVATION_BOND);
        realArbitration.placeYesBond(arbId, MIN_ACTIVATION_BOND);
        realArbitration.placeNoBond(arbId);
        realArbitration.placeYesBond(arbId, realArbitration.baseX());
        realArbitration.startNextEvaluation();
        evaluator.resolve(arbId);

        realStrategy.execute(1, _proposal(address(realStrategy), payload), 0, 0, 0, payload);
        assertTrue(realArbitration.isAccepted(arbId));
        assertEq(realStrategy.releaseDigest(), digest);
    }

    function testDirectStrategyCallCannotExecute() public {
        bytes memory payload =
            _releasePayload(1, bytes32(0), keccak256("direct-call"), "ipfs://direct-call");
        arbitration.settle(_arbId(payload), true);

        Proposal memory proposal = _proposal(address(strategy), payload);

        vm.expectRevert(
            abi.encodeWithSelector(SXArbitrationExecutionStrategy.OnlySpace.selector, address(this))
        );
        strategy.execute(1, proposal, 0, 0, 0, payload);

        assertEq(strategy.releaseNonce(), 0);
    }

    function testPayloadMismatchCannotExecute() public {
        bytes memory payload = _validPayload("committed-payload");
        uint256 proposalId = _propose(payload);
        arbitration.settle(_arbId(payload), true);

        vm.expectRevert(ISpaceErrors.InvalidPayload.selector);
        space.execute(proposalId, _validPayload("different-payload"));

        _assertNotExecuted(proposalId);
    }

    function _propose(bytes memory payload) internal returns (uint256 proposalId) {
        proposalId = space.nextProposalId();
        vm.prank(proposer);
        gateway.propose("ipfs://proposal", payload, "");

        (address author,, IExecutionStrategy storedStrategy,,,, bytes32 payloadHash,) =
            space.proposals(proposalId);
        assertEq(author, proposer);
        assertEq(address(storedStrategy), address(strategy));
        assertEq(payloadHash, keccak256(payload));

        uint256 arbId = _arbId(payload);
        assertTrue(arbitration.exists(arbId));
        assertEq(arbitration.activationBond(arbId), MIN_ACTIVATION_BOND);
        assertEq(arbitration.creator(arbId), address(gateway));
    }

    function _expectEndedVote(uint256 proposalId, IndexedStrategy[] memory userStrategies)
        internal
    {
        vm.expectRevert(ISpaceErrors.VotingPeriodHasEnded.selector);
        vm.prank(address(gateway));
        space.vote(voter, proposalId, Choice.For, userStrategies, "");
    }

    function _userStrategies() internal pure returns (IndexedStrategy[] memory strategies) {
        strategies = new IndexedStrategy[](1);
        strategies[0] = IndexedStrategy({index: 0, params: ""});
    }

    function _arbId(bytes memory payload) internal pure returns (uint256) {
        return uint256(keccak256(payload));
    }

    function _releasePayload(
        uint256 nonce,
        bytes32 currentDigest,
        bytes32 digest,
        string memory uri
    ) internal pure returns (bytes memory) {
        return abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: nonce,
                expectedCurrentDigest: currentDigest,
                artifactDigest: digest,
                artifactURI: uri
            })
        );
    }

    function _validPayload(string memory seed) internal pure returns (bytes memory) {
        return
            _releasePayload(1, bytes32(0), keccak256(bytes(seed)), string.concat("ipfs://", seed));
    }

    function _proposal(address executionStrategy, bytes memory payload)
        internal
        view
        returns (Proposal memory)
    {
        return Proposal({
            author: proposer,
            startBlockNumber: uint32(block.number),
            executionStrategy: IExecutionStrategy(executionStrategy),
            minEndBlockNumber: uint32(block.number),
            maxEndBlockNumber: uint32(block.number),
            finalizationStatus: FinalizationStatus.Pending,
            executionPayloadHash: keccak256(payload),
            activeVotingStrategies: 1
        });
    }

    function _realArbitration() internal returns (FutarchyArbitration realArbitration) {
        vm.etch(WXDAI, hex"00");
        vm.mockCall(WXDAI, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        realArbitration = new FutarchyArbitration(IERC20(WXDAI), 100e18, 72 hours);
        realArbitration.setProposalGateway(address(this));
    }

    function _finalizationStatus(uint256 proposalId)
        internal
        view
        returns (FinalizationStatus status)
    {
        (,,,,, status,,) = space.proposals(proposalId);
    }

    function _assertNotExecuted(uint256 proposalId) internal view {
        assertEq(strategy.releaseNonce(), 0);
        assertEq(uint256(_finalizationStatus(proposalId)), uint256(FinalizationStatus.Pending));
    }
}
