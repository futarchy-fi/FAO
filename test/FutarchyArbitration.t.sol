// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {IFutarchyArbitrationEvaluator} from "../src/IFutarchyArbitrationEvaluator.sol";

contract TestEvaluator is IFutarchyArbitrationEvaluator {
    address public immutable arbitration;
    mapping(uint256 proposalId => bool accepted) public decision;

    constructor(address arbitration_) {
        arbitration = arbitration_;
    }

    function setDecision(uint256 proposalId, bool accepted) external {
        decision[proposalId] = accepted;
    }

    function resolve(uint256 proposalId) external returns (bool accepted) {
        accepted = decision[proposalId];
        FutarchyArbitration(arbitration).resolveActiveEvaluation(accepted);
    }
}

contract FutarchyArbitrationTest is Test {
    FutarchyArbitration arb;

    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    uint256 internal constant GNOSIS_BASE_X = 100e18;
    uint256 internal constant GNOSIS_TIMEOUT = 72 hours;

    function setUp() public {
        vm.etch(GNOSIS_WXDAI, hex"00");
        arb = new FutarchyArbitration(IERC20(GNOSIS_WXDAI), GNOSIS_BASE_X, GNOSIS_TIMEOUT);
        arb.setProposalGateway(address(this));

        // We don't need a full ERC20 implementation for most tests; SafeERC20 only
        // requires transfer/transferFrom to return true (or return no data).
        vm.mockCall(
            GNOSIS_WXDAI, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true)
        );
        vm.mockCall(
            GNOSIS_WXDAI, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true)
        );
    }

    function testDeploy() public view {
        assertTrue(address(arb) != address(0));

        assertEq(address(arb.bondToken()), GNOSIS_WXDAI);
        assertEq(arb.baseX(), GNOSIS_BASE_X);
        assertEq(arb.timeout(), GNOSIS_TIMEOUT);
    }

    function testConstructorRejectsInvalidConfig() public {
        vm.expectRevert(FutarchyArbitration.InvalidConfig.selector);
        new FutarchyArbitration(IERC20(address(0)), GNOSIS_BASE_X, GNOSIS_TIMEOUT);

        vm.expectRevert(FutarchyArbitration.InvalidConfig.selector);
        new FutarchyArbitration(IERC20(GNOSIS_WXDAI), 0, GNOSIS_TIMEOUT);

        vm.expectRevert(FutarchyArbitration.InvalidConfig.selector);
        new FutarchyArbitration(IERC20(GNOSIS_WXDAI), GNOSIS_BASE_X, 0);
    }

    function testCreateProposalWithExplicitId() public {
        uint256 explicitId = uint256(keccak256("arbId"));

        uint256 returned = arb.createProposalWithId(explicitId, 1e18);
        assertEq(returned, explicitId);

        FutarchyArbitration.Proposal memory p = arb.getProposal(explicitId);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.INACTIVE));

        // cannot reuse id
        vm.expectRevert(FutarchyArbitration.ProposalAlreadyExists.selector);
        arb.createProposalWithId(explicitId, 1e18);
    }

    function testOnlyProposalGatewayCanCreateWithExplicitId() public {
        vm.expectRevert(FutarchyArbitration.NotProposalGateway.selector);
        vm.prank(makeAddr("id-squatter"));
        arb.createProposalWithId(uint256(keccak256("squatted-id")), 1e18);
    }

    function testOnlyProposalGatewayCanCreateAutoIdOnceConfigured() public {
        vm.expectRevert(FutarchyArbitration.NotProposalGateway.selector);
        vm.prank(makeAddr("queue-squatter"));
        arb.createProposal(1e18);
    }

    function testProposalGatewayCanOnlyBeSetOnce() public {
        vm.expectRevert(FutarchyArbitration.ProposalGatewayAlreadySet.selector);
        arb.setProposalGateway(makeAddr("replacement-gateway"));
    }

    function testEvaluatorCanOnlyBeSetOnce() public {
        TestEvaluator evaluator = new TestEvaluator(address(arb));
        arb.setEvaluator(address(evaluator));
        TestEvaluator replacement = new TestEvaluator(address(arb));

        vm.expectRevert(FutarchyArbitration.EvaluatorAlreadySet.selector);
        arb.setEvaluator(address(replacement));
    }

    function testCannotNoBidInactive() public {
        uint256 proposalId = arb.createProposal(1e18);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId);
    }

    function testFirstYesRequiresAtLeastM() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        vm.expectRevert(FutarchyArbitration.BondTooSmall.selector);
        arb.placeYesBond(proposalId, m - 1);

        // sanity: equal to m should succeed
        arb.placeYesBond(proposalId, m);
    }

    function testNoBondMatchesYesExactly() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        arb.placeYesBond(proposalId, m);

        // NO always matches YES — no amount parameter.
        arb.placeNoBond(proposalId);

        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertEq(p.noBond.amount, m);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.NO));
    }

    function testNoToYesRequiresAtLeast2xNo() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        // YES(m) → NO matches(m) → YES must be >= 2m
        arb.placeYesBond(proposalId, m);
        arb.placeNoBond(proposalId);

        uint256 minFlip = m * 2; // 2x NO bond (= 2x YES since NO matches)
        vm.expectRevert(FutarchyArbitration.BondTooSmall.selector);
        arb.placeYesBond(proposalId, minFlip - 1);

        arb.placeYesBond(proposalId, minFlip);
    }

    function testNoNonFlippingBidsAllowed() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        // INACTIVE -> YES
        arb.placeYesBond(proposalId, m);

        // YES -> YES should revert (flip-only)
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, m + 1);

        // YES -> NO
        arb.placeNoBond(proposalId);

        // NO -> NO should revert (flip-only)
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId);
    }

    function testReplacingYesAfterInterveningFlipRefundsPreviousYesBond() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        address yesBidder1 = vm.addr(1);
        address noBidder = vm.addr(2);
        address yesBidder2 = vm.addr(3);

        // First YES activates the proposal.
        vm.prank(yesBidder1);
        arb.placeYesBond(proposalId, m);

        // Flip to NO (matches YES = m)
        vm.prank(noBidder);
        arb.placeNoBond(proposalId);

        // No refunds yet: YES bond not replaced, only NO bond set.
        assertEq(arb.withdrawable(yesBidder1), 0);

        // Flip back to YES with a new bidder (requires >= 2x NO = 2m)
        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, m * 2);

        // The replaced YES bond (from yesBidder1) should now be withdrawable.
        assertEq(arb.withdrawable(yesBidder1), m);
    }

    function testReplacingNoAfterInterveningFlipRefundsPreviousNoBond() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        address yesBidder = vm.addr(1);
        address noBidder1 = vm.addr(2);
        address yesBidder2 = vm.addr(3);
        address noBidder2 = vm.addr(4);

        // INACTIVE -> YES(m)
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO: matches m
        vm.prank(noBidder1);
        arb.placeNoBond(proposalId);

        // NO bond not replaced yet.
        assertEq(arb.withdrawable(noBidder1), 0);

        // NO -> YES (requires >= 2x NO = 2m)
        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, m * 2);

        // Still no refund: NO bond not replaced, only YES bond set.
        assertEq(arb.withdrawable(noBidder1), 0);

        // YES -> NO: matches 2m
        vm.prank(noBidder2);
        arb.placeNoBond(proposalId);

        // The replaced NO bond (from noBidder1, amount=m) should now be withdrawable.
        assertEq(arb.withdrawable(noBidder1), m);
    }

    function testTimeoutSettlementAfter72hCreditsWinnerWithBothBonds() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES(m)
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO: matches m
        vm.prank(noBidder);
        arb.placeNoBond(proposalId);

        // Cannot finalize before 72h since last flip
        vm.warp(block.timestamp + 72 hours - 1);
        vm.expectRevert(FutarchyArbitration.TimeoutNotReached.selector);
        arb.finalizeByTimeout(proposalId);

        // After 72h elapsed, current side (NO) wins and gets both bonds
        vm.warp(block.timestamp + 1);
        arb.finalizeByTimeout(proposalId);

        // Winner gets YES(m) + NO(m) = 2m
        assertEq(arb.withdrawable(noBidder), 2 * m);
        assertEq(arb.withdrawable(yesBidder), 0);

        assertTrue(arb.isSettled(proposalId));
        assertFalse(arb.isAccepted(proposalId));
    }

    function testSettlementIdempotenceAndPostSettlementBiddingReverts() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES(m)
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO: matches m
        vm.prank(noBidder);
        arb.placeNoBond(proposalId);

        // settle by timeout
        vm.warp(block.timestamp + 72 hours);
        arb.finalizeByTimeout(proposalId);

        uint256 winnerPayout = arb.withdrawable(noBidder);
        assertEq(winnerPayout, 2 * m);

        // idempotence: cannot finalize again
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.finalizeByTimeout(proposalId);

        // ensure payout did not change
        assertEq(arb.withdrawable(noBidder), winnerPayout);

        // post-settlement bids revert
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, m * 4);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId);
    }

    function testWithdrawWorksAndCannotDoubleWithdraw() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES(m)
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO: matches m
        vm.prank(noBidder);
        arb.placeNoBond(proposalId);

        // Settle by timeout; NO wins and gets both bonds
        vm.warp(block.timestamp + 72 hours);
        arb.finalizeByTimeout(proposalId);

        uint256 payout = 2 * m;
        assertEq(arb.withdrawable(noBidder), payout);

        // First withdraw transfers WXDAI and clears withdrawable balance
        bytes memory transferCalldata =
            abi.encodeWithSelector(IERC20.transfer.selector, noBidder, payout);
        vm.expectCall(GNOSIS_WXDAI, transferCalldata, 1);

        vm.prank(noBidder);
        arb.withdraw();

        assertEq(arb.withdrawable(noBidder), 0);

        // Second withdraw should be a no-op (and must not call transfer again).
        vm.mockCallRevert(GNOSIS_WXDAI, transferCalldata, "unexpected-transfer");

        vm.prank(noBidder);
        arb.withdraw();

        assertEq(arb.withdrawable(noBidder), 0);
    }

    function testRequiredYesThresholdDoublesPerQueueLen() public {
        // baseX defaults to 100e18 in the constructor.
        assertEq(arb.requiredYes(0), 100e18);
        assertEq(arb.requiredYes(1), 200e18);
        assertEq(arb.requiredYes(2), 400e18);
        assertEq(arb.requiredYes(4), 1600e18);
    }

    // ── Helper: drive proposal from INACTIVE to QUEUED ──

    function _graduateProposal(uint256 proposalId) internal {
        arb.placeYesBond(proposalId, 25e18);
        arb.placeNoBond(proposalId);
        // YES >= graduation threshold is always accepted.
        arb.placeYesBond(proposalId, 100e18);
    }

    function testGraduationTriggersOnlyOnNoToYesFlip() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        // Even if first activation is huge, it should NOT graduate (only flips).
        arb.placeYesBond(proposalId, 25e18);
        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.YES));
            assertEq(p.queuePosition, 0);
        }

        // Flip YES -> NO: matches 25e18.
        arb.placeNoBond(proposalId);

        // Flip NO -> YES. YES >= graduation threshold always accepted.
        // This meets requiredYes(0)=100e18, so it should graduate into QUEUED.
        arb.placeYesBond(proposalId, 100e18);

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        assertEq(p2.queuePosition, 1);
    }

    function testYesFlipAboveThresholdGraduates() public {
        uint256 proposalId = arb.createProposal(1e18);

        // YES(25e18) -> NO matches(25e18)
        arb.placeYesBond(proposalId, 25e18);
        arb.placeNoBond(proposalId);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.NO));
        }

        // NO -> YES: 100e18 >= graduation threshold, always accepted.
        arb.placeYesBond(proposalId, arb.requiredYes(0));

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        assertEq(p2.queuePosition, 1);
    }

    function testTryGraduateWorksAfterQueueDrains() public {
        TestEvaluator eval = new TestEvaluator(address(arb));
        arb.setEvaluator(address(eval));

        // Graduate pid1 into queue (queueLen becomes 1, threshold = 200e18).
        uint256 pid1 = arb.createProposal(1e18);
        _graduateProposal(pid1);

        // pid2: YES(50e18) -> NO matches(50e18) -> YES(100e18)
        // 100e18 < requiredYes(1)=200e18, so it stays in YES state, doesn't graduate.
        uint256 pid2 = arb.createProposal(1e18);
        arb.placeYesBond(pid2, 50e18);
        arb.placeNoBond(pid2);
        arb.placeYesBond(pid2, 100e18);

        FutarchyArbitration.Proposal memory p = arb.getProposal(pid2);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.YES));

        // tryGraduate should be a no-op because threshold is still 200e18.
        arb.tryGraduate(pid2);
        assertEq(
            uint256(arb.getProposal(pid2).state), uint256(FutarchyArbitration.ProposalState.YES)
        );

        // Resolve pid1 — queue drains, threshold drops to 100e18.
        arb.startNextEvaluation();
        eval.setDecision(pid1, true);
        eval.resolve(pid1);

        // Now tryGraduate should succeed: 100e18 >= requiredYes(0)=100e18.
        arb.tryGraduate(pid2);

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(pid2);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
    }

    function testTryGraduateCannotConvertUnchallengedYesTimeoutRoute() public {
        uint256 proposalId = arb.createProposal(1e18);
        arb.placeYesBond(proposalId, arb.requiredYes(0));

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.tryGraduate(proposalId);

        vm.warp(block.timestamp + GNOSIS_TIMEOUT);
        arb.finalizeByTimeout(proposalId);
        assertTrue(arb.isAccepted(proposalId));
    }

    function testGraduationRevertsIfQueueFull() public {
        uint256 maxQ = arb.MAX_QUEUE();

        // Fill the queue to MAX_QUEUE with graduated proposals.
        for (uint256 i = 0; i < maxQ; i++) {
            uint256 req = arb.requiredYes(i);

            uint256 pid = arb.createProposal(1e18);

            arb.placeYesBond(pid, 25e18);
            arb.placeNoBond(pid);
            arb.placeYesBond(pid, req);

            FutarchyArbitration.Proposal memory p = arb.getProposal(pid);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
            assertEq(p.queuePosition, i + 1);
        }

        // Next graduation attempt should revert with QueueFull.
        uint256 reqFull = arb.requiredYes(maxQ);
        uint256 pid2 = arb.createProposal(1e18);
        arb.placeYesBond(pid2, 25e18);
        arb.placeNoBond(pid2);

        vm.expectRevert(FutarchyArbitration.QueueFull.selector);
        arb.placeYesBond(pid2, reqFull);
    }

    function testQueuedAndEvaluatingProposalsCannotBeBidOn() public {
        uint256 proposalId = arb.createProposal(1e18);

        // Drive into QUEUED via NO -> YES graduation.
        _graduateProposal(proposalId);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        }

        // Any bids while QUEUED should revert.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, 100e18);

        // Move head to EVALUATING.
        arb.startNextEvaluation();

        {
            FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
            assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.EVALUATING));
        }

        // Any bids while EVALUATING should revert.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, 100e18);
    }

    function testStartNextEvaluationMovesHeadToEvaluating() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(m);

        // Drive into QUEUED via NO -> YES graduation.
        _graduateProposal(proposalId);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        }

        arb.startNextEvaluation();

        assertEq(arb.activeEvaluationProposalId(), proposalId);

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.EVALUATING));

        // Cannot start another while one is active.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.startNextEvaluation();
    }

    function testEvaluatorCanResolveActiveEvaluationAndSettles() public {
        // Deploy evaluator and wire it.
        TestEvaluator eval = new TestEvaluator(address(arb));
        arb.setEvaluator(address(eval));

        uint256 proposalId = arb.createProposal(1e18);

        // Drive into EVALUATING: YES(25) -> NO(25) -> YES(100) -> QUEUED -> EVALUATING
        _graduateProposal(proposalId);
        arb.startNextEvaluation();

        eval.setDecision(proposalId, true);
        bool accepted = eval.resolve(proposalId);
        assertTrue(accepted);

        // Proposal should now be settled and the evaluation slot cleared.
        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertTrue(p.accepted);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.SETTLED));
        assertEq(arb.activeEvaluationProposalId(), 0);

        // Payout: replaced YES(25e18) + winner gets YES(100e18) + NO(25e18)
        assertEq(arb.withdrawable(address(this)), 25e18 + 100e18 + 25e18);
    }

    function testEvaluationResolvesAndPaysCorrectWinner() public {
        // Deploy evaluator and wire it.
        TestEvaluator eval = new TestEvaluator(address(arb));
        arb.setEvaluator(address(eval));

        uint256 proposalId = arb.createProposal(1e18);

        address yesBidder1 = vm.addr(1);
        address noBidder = vm.addr(2);
        address yesBidder2 = vm.addr(3);

        // YES(25e18) -> NO matches(25e18) -> YES(100e18) -> graduates
        vm.prank(yesBidder1);
        arb.placeYesBond(proposalId, 25e18);

        vm.prank(noBidder);
        arb.placeNoBond(proposalId);

        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, 100e18);

        arb.startNextEvaluation();

        // Decision: reject -> NO bond bidder should win (receives current YES+NO bond amounts).
        eval.setDecision(proposalId, false);
        bool accepted = eval.resolve(proposalId);
        assertFalse(accepted);

        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertFalse(p.accepted);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.SETTLED));

        // Winner payout = current YES bond (100e18) + current NO bond (25e18)
        assertEq(arb.withdrawable(noBidder), 125e18);

        // Replaced YES bond from yesBidder1 should be withdrawable as well.
        assertEq(arb.withdrawable(yesBidder1), 25e18);

        // The winning NO bidder was not replaced; no extra credits.
        // The final YES bidder lost; no withdrawable balance.
        assertEq(arb.withdrawable(yesBidder2), 0);
    }

    function testQueueAdvancesAfterResolution() public {
        // Deploy evaluator and wire it.
        TestEvaluator eval = new TestEvaluator(address(arb));
        arb.setEvaluator(address(eval));

        // Create two proposals and graduate both into the queue.
        uint256 pid1 = arb.createProposal(1e18);
        uint256 pid2 = arb.createProposal(1e18);

        // Graduate pid1 into QUEUED.
        _graduateProposal(pid1);

        // Graduate pid2 into QUEUED (requires requiredYes(1)=200e18).
        arb.placeYesBond(pid2, 25e18);
        arb.placeNoBond(pid2);
        arb.placeYesBond(pid2, 200e18);

        // Evaluate and resolve the first queued item.
        arb.startNextEvaluation();
        assertEq(arb.activeEvaluationProposalId(), pid1);

        eval.setDecision(pid1, true);
        bool accepted1 = eval.resolve(pid1);
        assertTrue(accepted1);
        assertEq(arb.activeEvaluationProposalId(), 0);

        // Next evaluation should pick the next queued proposal.
        arb.startNextEvaluation();
        assertEq(arb.activeEvaluationProposalId(), pid2);
    }

    function testResolveActiveEvaluationRevertsForNonEvaluator() public {
        uint256 proposalId = arb.createProposal(1e18);

        // Drive into EVALUATING.
        _graduateProposal(proposalId);
        arb.startNextEvaluation();

        // No evaluator set, so any caller should revert NotEvaluator.
        vm.expectRevert(FutarchyArbitration.NotEvaluator.selector);
        arb.resolveActiveEvaluation(true);
    }

    function testUnrelatedLargeNoProposalCannotBlockYesTimeout() public {
        uint256 noPid = arb.createProposal(1e18);
        arb.placeYesBond(noPid, 100e18);
        arb.placeNoBond(noPid);

        uint256 yesPid = arb.createProposal(1e18);
        arb.placeYesBond(yesPid, 1e18);

        vm.warp(block.timestamp + 72 hours + 1);

        arb.finalizeByTimeout(yesPid);
        assertTrue(arb.isAccepted(yesPid));
        assertEq(arb.withdrawable(address(this)), 1e18);

        arb.finalizeByTimeout(noPid);
        assertFalse(arb.isAccepted(noPid));
        assertEq(arb.withdrawable(address(this)), 201e18);
    }

    function testEnumHasEvaluatingState() public {
        // Compile-time guard: ensure the enum includes EVALUATING.
        FutarchyArbitration.ProposalState s = FutarchyArbitration.ProposalState.EVALUATING;
        assertEq(uint256(s), uint256(FutarchyArbitration.ProposalState.EVALUATING));
    }
}
