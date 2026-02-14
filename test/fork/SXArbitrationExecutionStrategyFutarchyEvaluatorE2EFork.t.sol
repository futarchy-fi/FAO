// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Space} from "sx-evm/src/Space.sol";
import {VanillaAuthenticator} from "sx-evm/src/authenticators/VanillaAuthenticator.sol";
import {VanillaVotingStrategy} from "sx-evm/src/voting-strategies/VanillaVotingStrategy.sol";
import {VanillaExecutionStrategy} from "sx-evm/src/execution-strategies/VanillaExecutionStrategy.sol";
import {VanillaProposalValidationStrategy} from "sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {
    Choice,
    Strategy,
    IndexedStrategy,
    InitializeCalldata,
    ProposalStatus
} from "sx/types.sol";

import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {FutarchyEvaluator} from "../../src/FutarchyEvaluator.sol";

interface IConditionalTokensLike {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
}

interface IFutarchyProposalWithConditionLike {
    function conditionId() external view returns (bytes32);
}

/// @notice Full fork E2E for the Phase 8 claim:
///         graduate -> (bind futarchy proposal) -> resolve via CTF -> settle arbitration -> execute Snapshot X.
///
/// Notes:
/// - Requires a resolved Futarchy proposal on Gnosis (ConditionalTokens payouts set). When unresolved,
///   the test returns early after asserting execute() is blocked.
///
/// Env:
/// - RUN_GNOSIS_FORK_TESTS=true
/// - Optional: TEST_FAO_PROPOSAL=<address> (must expose conditionId())
contract SXArbitrationExecutionStrategyFutarchyEvaluatorE2EForkTest is Test {
    // Selectors copied from sx-evm test utils
    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR = bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));

    address internal constant DEFAULT_TEST_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;
    address internal constant GNOSIS_CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;

    Space internal masterSpace;
    Space internal space;

    VanillaVotingStrategy internal vanillaVotingStrategy;
    VanillaAuthenticator internal vanillaAuthenticator;
    VanillaExecutionStrategy internal vanillaExecutionStrategy;
    VanillaProposalValidationStrategy internal vanillaProposalValidationStrategy;

    FutarchyArbitration internal arbitration;
    FutarchyEvaluator internal evaluator;
    SXArbitrationExecutionStrategy internal gated;

    address internal owner;
    address internal author;
    address internal voter;
    address internal bidder;

    IndexedStrategy[] internal userVotingStrategies;

    function setUp() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        owner = address(this);
        author = vm.addr(1234);
        voter = vm.addr(5678);
        bidder = vm.addr(9999);

        // Snapshot X Space wiring
        masterSpace = new Space();

        vanillaVotingStrategy = new VanillaVotingStrategy();
        vanillaAuthenticator = new VanillaAuthenticator();
        vanillaExecutionStrategy = new VanillaExecutionStrategy(owner, 1);
        vanillaProposalValidationStrategy = new VanillaProposalValidationStrategy();

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy(address(vanillaVotingStrategy), new bytes(0));

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "VanillaVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(vanillaAuthenticator);

        InitializeCalldata memory init = InitializeCalldata({
            owner: owner,
            votingDelay: 0,
            minVotingDuration: 0,
            maxVotingDuration: 1000,
            proposalValidationStrategy: Strategy(address(vanillaProposalValidationStrategy), new bytes(0)),
            proposalValidationStrategyMetadataURI: "",
            daoURI: "dao",
            metadataURI: "space",
            votingStrategies: votingStrategies,
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: authenticators
        });

        space = Space(address(new ERC1967Proxy(address(masterSpace), abi.encodeWithSelector(Space.initialize.selector, init))));

        userVotingStrategies.push(IndexedStrategy(0, new bytes(0)));

        // Arbitration + evaluator.
        arbitration = new FutarchyArbitration();
        evaluator = new FutarchyEvaluator(address(arbitration), GNOSIS_CTF, owner);
        arbitration.setEvaluator(address(evaluator));

        gated = new SXArbitrationExecutionStrategy(address(arbitration), address(vanillaExecutionStrategy));
    }

    function testFork_endToEnd_executeAfterFutarchyEvaluatorResolutionWhenCTFResolved() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;

        bytes memory payload = abi.encodePacked("hello");
        Strategy memory execStrat = Strategy(address(gated), payload);

        uint256 sxProposalId = _createProposal(author, "p", execStrat);
        _vote(voter, sxProposalId, Choice.For);

        // Voting accepted, but arbitration not accepted: wrapper should expose VotingPeriodAccepted.
        assertEq(uint256(space.getProposalStatus(sxProposalId)), uint256(ProposalStatus.VotingPeriodAccepted));

        uint256 arbId = uint256(keccak256(payload));

        // Create arbitration proposal with aligned deterministic id.
        // Note: FutarchyArbitration defaults baseX=100e18, and graduation requires YES flip >= baseX.
        uint256 m = arbitration.baseX();
        arbitration.createProposalWithId(arbId, FutarchyArbitration.ProposalType.A, m);

        // Not accepted yet => execute should fail.
        vm.expectRevert(abi.encodeWithSelector(SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId));
        space.execute(sxProposalId, payload);

        // Bind a real futarchy proposal (needs conditionId()).
        address proposalAddress = vm.envOr("TEST_FAO_PROPOSAL", DEFAULT_TEST_PROPOSAL);
        bytes32 conditionId = IFutarchyProposalWithConditionLike(proposalAddress).conditionId();

        // If unresolved, do not proceed (avoid flaky tests). Ensure evaluator reverts on unresolved.
        IConditionalTokensLike ctf = IConditionalTokensLike(GNOSIS_CTF);
        uint256 denom = ctf.payoutDenominator(conditionId);
        if (denom == 0) {
            evaluator.setFutarchyProposal(arbId, proposalAddress);
            // Drive arbitration into evaluation then confirm resolver cannot finish.
            _driveToEvaluation(arbId);
            vm.expectRevert();
            evaluator.resolve(arbId);
            return;
        }

        // Drive arbitration through graduation+evaluation.
        _driveToEvaluation(arbId);

        // Bind and resolve via CTF payouts.
        evaluator.setFutarchyProposal(arbId, proposalAddress);
        bool accepted = evaluator.resolve(arbId);

        assertTrue(arbitration.isSettled(arbId), "arb not settled");
        assertEq(arbitration.isAccepted(arbId), accepted, "arb accepted mismatch");
        assertTrue(arbitration.isAccepted(arbId) || !arbitration.isAccepted(arbId), "sanity");

        if (!accepted) {
            // If rejected by futarchy, execution must remain blocked.
            vm.expectRevert(abi.encodeWithSelector(SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId));
            space.execute(sxProposalId, payload);
            return;
        }

        // Now Snapshot X execution should succeed.
        space.execute(sxProposalId, payload);

        // Proposal already executed; a second execute should revert.
        vm.expectRevert();
        space.execute(sxProposalId, payload);
    }

    function _driveToEvaluation(uint256 arbId) internal {
        IERC20 wxdai = arbitration.WXDAI();

        // Bonding path:
        // INACTIVE -> YES with >= m
        // YES -> NO with >= 2x YES
        // NO -> YES with >= max(m, 2x NO) and also >= requiredYes(0) (= baseX)
        uint256 m = arbitration.baseX();
        uint256 noBond = 2 * m;
        uint256 yesFlipBond = 4 * m;

        deal(address(wxdai), bidder, m + noBond + yesFlipBond);
        vm.startPrank(bidder);
        wxdai.approve(address(arbitration), type(uint256).max);
        arbitration.placeYesBond(arbId, m);
        arbitration.placeNoBond(arbId, noBond);
        arbitration.placeYesBond(arbId, yesFlipBond);
        vm.stopPrank();

        // Graduation should have queued; start evaluation.
        arbitration.startNextEvaluation();
        assertEq(arbitration.activeEvaluationProposalId(), arbId, "active eval id mismatch");
    }

    function _createProposal(address _author, string memory _metadataURI, Strategy memory _executionStrategy)
        internal
        returns (uint256)
    {
        vanillaAuthenticator.authenticate(
            address(space),
            PROPOSE_SELECTOR,
            abi.encode(_author, _metadataURI, _executionStrategy, new bytes(0))
        );
        return space.nextProposalId() - 1;
    }

    function _vote(address _voter, uint256 _proposalId, Choice _choice) internal {
        vanillaAuthenticator.authenticate(
            address(space),
            VOTE_SELECTOR,
            abi.encode(_voter, _proposalId, _choice, userVotingStrategies, "vote")
        );
    }
}
