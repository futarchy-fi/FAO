// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {ManualEvaluator} from "../src/ManualEvaluator.sol";

contract FutarchyArbitrationTest is Test {
    FutarchyArbitration arb;

    // Canonical Gnosis WXDAI address hardcoded into contract.
    address internal constant WXDAI =
        0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    function setUp() public {
        arb = new FutarchyArbitration();

        // We don't need a full ERC20 implementation for most tests; SafeERC20 only
        // requires transfer/transferFrom to return true (or return no data).
        vm.mockCall(
            WXDAI,
            abi.encodeWithSelector(IERC20.transferFrom.selector),
            abi.encode(true)
        );
        vm.mockCall(
            WXDAI,
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(true)
        );
    }

    function testDeploy() public view {
        assertTrue(address(arb) != address(0));

        // sanity: immutable WXDAI address is set to canonical Gnosis WXDAI
        assertEq(address(arb.WXDAI()), WXDAI);
    }

    function testCreateProposalWithExplicitId() public {
        uint256 explicitId = uint256(keccak256("arbId"));

        uint256 returned = arb.createProposalWithId(
            explicitId,
            FutarchyArbitration.ProposalType.A,
            1e18
        );
        assertEq(returned, explicitId);

        FutarchyArbitration.Proposal memory p = arb.getProposal(explicitId);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.INACTIVE));

        // cannot reuse id
        vm.expectRevert(FutarchyArbitration.ProposalAlreadyExists.selector);
        arb.createProposalWithId(explicitId, FutarchyArbitration.ProposalType.A, 1e18);
    }

    function testCannotNoBidInactive() public {
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            1e18
        );

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId, 1e18);
    }

    function testFirstYesRequiresAtLeastM() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        vm.expectRevert(FutarchyArbitration.BondTooSmall.selector);
        arb.placeYesBond(proposalId, m - 1);

        // sanity: equal to m should succeed
        arb.placeYesBond(proposalId, m);
    }

    function testYesToNoRequiresAtLeast2xYes() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        uint256 yes = m;
        arb.placeYesBond(proposalId, yes);

        // must be >= 2x current YES
        vm.expectRevert(FutarchyArbitration.BondTooSmall.selector);
        arb.placeNoBond(proposalId, (yes * 2) - 1);

        arb.placeNoBond(proposalId, yes * 2);
    }

    function testNoToYesRequiresAtLeastMaxMOr2xNo() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        // Drive state to NO with an initial YES then a flipping NO.
        uint256 yes = m;
        arb.placeYesBond(proposalId, yes);

        uint256 noBond = yes * 2;
        arb.placeNoBond(proposalId, noBond);

        // NO -> YES must be >= max(m, 2x current NO)
        uint256 minFlip = noBond * 2;
        vm.expectRevert(FutarchyArbitration.BondTooSmall.selector);
        arb.placeYesBond(proposalId, minFlip - 1);

        arb.placeYesBond(proposalId, minFlip);
    }

    function testNoNonFlippingBidsAllowed() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        // INACTIVE -> YES
        arb.placeYesBond(proposalId, m);

        // YES -> YES should revert (flip-only)
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, m + 1);

        // YES -> NO
        arb.placeNoBond(proposalId, m * 2);

        // NO -> NO should revert (flip-only)
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId, (m * 2) + 1);
    }

    function testReplacingYesAfterInterveningFlipRefundsPreviousYesBond() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        address yesBidder1 = vm.addr(1);
        address noBidder = vm.addr(2);
        address yesBidder2 = vm.addr(3);

        // First YES activates the proposal.
        vm.prank(yesBidder1);
        arb.placeYesBond(proposalId, m);

        // Flip to NO (requires >= 2x YES)
        vm.prank(noBidder);
        arb.placeNoBond(proposalId, m * 2);

        // No refunds yet: YES bond not replaced, only NO bond set.
        assertEq(arb.withdrawable(yesBidder1), 0);

        // Flip back to YES with a new bidder (requires >= max(m, 2x current NO) = 4m)
        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, m * 4);

        // The replaced YES bond (from yesBidder1) should now be withdrawable.
        assertEq(arb.withdrawable(yesBidder1), m);
    }

    function testReplacingNoAfterInterveningFlipRefundsPreviousNoBond() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        address yesBidder = vm.addr(1);
        address noBidder1 = vm.addr(2);
        address yesBidder2 = vm.addr(3);
        address noBidder2 = vm.addr(4);

        // INACTIVE -> YES
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO (requires >= 2x YES)
        vm.prank(noBidder1);
        arb.placeNoBond(proposalId, m * 2);

        // NO bond not replaced yet.
        assertEq(arb.withdrawable(noBidder1), 0);

        // NO -> YES (requires >= max(m, 2x NO) = 4m)
        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, m * 4);

        // Still no refund: NO bond not replaced, only YES bond set.
        assertEq(arb.withdrawable(noBidder1), 0);

        // YES -> NO with a new bidder (requires >= 2x current YES = 8m)
        vm.prank(noBidder2);
        arb.placeNoBond(proposalId, m * 8);

        // The replaced NO bond (from noBidder1) should now be withdrawable.
        assertEq(arb.withdrawable(noBidder1), m * 2);
    }

    function testTimeoutSettlementAfter72hCreditsWinnerWithBothBonds() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO (requires >= 2x YES)
        vm.prank(noBidder);
        arb.placeNoBond(proposalId, m * 2);

        // Cannot finalize before 72h since last flip
        vm.warp(block.timestamp + 72 hours - 1);
        vm.expectRevert(FutarchyArbitration.TimeoutNotReached.selector);
        arb.finalizeByTimeout(proposalId);

        // After 72h elapsed, current side (NO) wins and gets both bonds
        vm.warp(block.timestamp + 1);
        arb.finalizeByTimeout(proposalId);

        assertEq(arb.withdrawable(noBidder), m + (m * 2));
        assertEq(arb.withdrawable(yesBidder), 0);

        assertTrue(arb.isSettled(proposalId));
        assertFalse(arb.isAccepted(proposalId));
    }

    function testSettlementIdempotenceAndPostSettlementBiddingReverts() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO
        vm.prank(noBidder);
        arb.placeNoBond(proposalId, m * 2);

        // settle by timeout
        vm.warp(block.timestamp + 72 hours);
        arb.finalizeByTimeout(proposalId);

        uint256 winnerPayout = arb.withdrawable(noBidder);
        assertEq(winnerPayout, m + (m * 2));

        // idempotence: cannot finalize again
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.finalizeByTimeout(proposalId);

        // ensure payout did not change
        assertEq(arb.withdrawable(noBidder), winnerPayout);

        // post-settlement bids revert
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, m * 4);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId, m * 8);
    }

    function testWithdrawWorksAndCannotDoubleWithdraw() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        address yesBidder = vm.addr(1);
        address noBidder = vm.addr(2);

        // INACTIVE -> YES
        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        // YES -> NO
        vm.prank(noBidder);
        arb.placeNoBond(proposalId, m * 2);

        // Settle by timeout; NO wins and gets both bonds
        vm.warp(block.timestamp + 72 hours);
        arb.finalizeByTimeout(proposalId);

        uint256 payout = m + (m * 2);
        assertEq(arb.withdrawable(noBidder), payout);

        // First withdraw transfers WXDAI and clears withdrawable balance
        bytes memory transferCalldata =
            abi.encodeWithSelector(IERC20.transfer.selector, noBidder, payout);
        vm.expectCall(WXDAI, transferCalldata, 1);

        vm.prank(noBidder);
        arb.withdraw();

        assertEq(arb.withdrawable(noBidder), 0);

        // Second withdraw should be a no-op (and must not call transfer again).
        vm.mockCallRevert(WXDAI, transferCalldata, "unexpected-transfer");

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

    function testGraduationTriggersOnlyOnNoToYesFlip() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        // Even if first activation is huge, it should NOT graduate (only flips).
        arb.placeYesBond(proposalId, 200e18);
        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.YES));
            assertEq(p.queuePosition, 0);
        }

        // Flip YES -> NO.
        arb.placeNoBond(proposalId, 400e18);

        // Flip NO -> YES. Flip rule requires >= max(m, 2x current NO)=800e18.
        // This is also above requiredYes(0)=100e18, so it should graduate into QUEUED.
        arb.placeYesBond(proposalId, 800e18);

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        assertEq(p2.queuePosition, 1);
    }

    function testYesFlipAboveThresholdGraduates() public {
        // Make the NO->YES flip amount exactly equal to requiredYes(0)=100e18,
        // while still satisfying the flip-only rule (>= 2x current NO).
        uint256 proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // YES -> NO where NO=50e18 is valid if YES was <= 25e18.
        arb.placeYesBond(proposalId, 25e18);
        arb.placeNoBond(proposalId, 50e18);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.NO));
        }

        // NO -> YES flip requires >= max(m, 2x NO)=100e18.
        // This meets the graduation threshold requiredYes(0)=100e18, so it should enqueue.
        arb.placeYesBond(proposalId, arb.requiredYes(0));

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(uint256(p2.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        assertEq(p2.queuePosition, 1);
    }

    function testGraduationRevertsIfQueueFull() public {
        uint256 maxQ = arb.MAX_QUEUE();

        // Fill the queue to MAX_QUEUE with graduated proposals.
        for (uint256 i = 0; i < maxQ; i++) {
            uint256 req = arb.requiredYes(i);

            uint256 pid = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

            // YES -> NO -> YES, where the NO->YES flip amount meets the graduation threshold.
            // Ensure flip constraints are satisfied:
            // - YES->NO requires NO >= 2x YES
            // - NO->YES requires YES >= max(m, 2x NO)
            arb.placeYesBond(pid, req / 4);
            arb.placeNoBond(pid, req / 2);
            arb.placeYesBond(pid, req);

            FutarchyArbitration.Proposal memory p = arb.getProposal(pid);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
            assertEq(p.queuePosition, i + 1);
        }

        // Next graduation attempt should revert with QueueFull.
        uint256 reqFull = arb.requiredYes(maxQ);
        uint256 pid2 = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);
        arb.placeYesBond(pid2, reqFull / 4);
        arb.placeNoBond(pid2, reqFull / 2);

        vm.expectRevert(FutarchyArbitration.QueueFull.selector);
        arb.placeYesBond(pid2, reqFull);
    }

    function testQueuedAndEvaluatingProposalsCannotBeBidOn() public {
        uint256 proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // Drive into QUEUED via NO -> YES graduation.
        arb.placeYesBond(proposalId, 200e18);
        arb.placeNoBond(proposalId, 400e18);
        arb.placeYesBond(proposalId, 800e18);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        }

        // Any bids while QUEUED should revert.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId, 1600e18);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, 1600e18);

        // Move head to EVALUATING.
        arb.startNextEvaluation();

        {
            FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
            assertEq(
                uint256(p2.state),
                uint256(FutarchyArbitration.ProposalState.EVALUATING)
            );
        }

        // Any bids while EVALUATING should revert.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(proposalId, 1600e18);

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeYesBond(proposalId, 1600e18);
    }

    function testStartNextEvaluationMovesHeadToEvaluating() public {
        uint256 m = 1e18;
        uint256 proposalId = arb.createProposal(
            FutarchyArbitration.ProposalType.A,
            m
        );

        // Drive into QUEUED via NO -> YES graduation.
        arb.placeYesBond(proposalId, 200e18);
        arb.placeNoBond(proposalId, 400e18);
        arb.placeYesBond(proposalId, 800e18);

        {
            FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
            assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.QUEUED));
        }

        arb.startNextEvaluation();

        assertEq(arb.activeEvaluationProposalId(), proposalId);

        FutarchyArbitration.Proposal memory p2 = arb.getProposal(proposalId);
        assertEq(
            uint256(p2.state),
            uint256(FutarchyArbitration.ProposalState.EVALUATING)
        );

        // Cannot start another while one is active.
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.startNextEvaluation();
    }

    function testEvaluatorCanResolveActiveEvaluationAndSettles() public {
        // Deploy evaluator and wire it.
        ManualEvaluator eval = new ManualEvaluator(address(arb), address(this));
        arb.setEvaluator(address(eval));

        uint256 proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // Drive into QUEUED via NO -> YES graduation.
        arb.placeYesBond(proposalId, 200e18);
        arb.placeNoBond(proposalId, 400e18);
        arb.placeYesBond(proposalId, 800e18);
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

        // Payout should be credited to YES bidder (winner receives both bonds).
        // Note: withdrawable also includes the replaced YES bond from the first flip.
        assertEq(arb.withdrawable(address(this)), 200e18 + 400e18 + 800e18);
    }

    function testEvaluationResolvesAndPaysCorrectWinner() public {
        // Deploy evaluator and wire it.
        ManualEvaluator eval = new ManualEvaluator(address(arb), address(this));
        arb.setEvaluator(address(eval));

        uint256 proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        address yesBidder1 = vm.addr(1);
        address noBidder = vm.addr(2);
        address yesBidder2 = vm.addr(3);

        // Drive into QUEUED via NO -> YES graduation.
        vm.prank(yesBidder1);
        arb.placeYesBond(proposalId, 200e18);

        vm.prank(noBidder);
        arb.placeNoBond(proposalId, 400e18);

        vm.prank(yesBidder2);
        arb.placeYesBond(proposalId, 800e18);

        arb.startNextEvaluation();

        // Decision: reject -> NO bond bidder should win (receives current YES+NO bond amounts).
        eval.setDecision(proposalId, false);
        bool accepted = eval.resolve(proposalId);
        assertFalse(accepted);

        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertFalse(p.accepted);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.SETTLED));

        // Winner payout = current YES bond (800e18) + current NO bond (400e18)
        assertEq(arb.withdrawable(noBidder), 1200e18);

        // Replaced YES bond from yesBidder1 should be withdrawable as well.
        assertEq(arb.withdrawable(yesBidder1), 200e18);

        // The winning NO bidder was not replaced; no extra credits.
        // The final YES bidder lost; no withdrawable balance.
        assertEq(arb.withdrawable(yesBidder2), 0);
    }

    function testQueueAdvancesAfterResolution() public {
        // Deploy evaluator and wire it.
        ManualEvaluator eval = new ManualEvaluator(address(arb), address(this));
        arb.setEvaluator(address(eval));

        // Create two proposals and graduate both into the queue.
        uint256 pid1 = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);
        uint256 pid2 = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // Graduate pid1 into QUEUED.
        arb.placeYesBond(pid1, 200e18);
        arb.placeNoBond(pid1, 400e18);
        arb.placeYesBond(pid1, 800e18);

        // Graduate pid2 into QUEUED.
        arb.placeYesBond(pid2, 200e18);
        arb.placeNoBond(pid2, 400e18);
        arb.placeYesBond(pid2, 800e18);

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
        uint256 proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // Drive into EVALUATING.
        arb.placeYesBond(proposalId, 200e18);
        arb.placeNoBond(proposalId, 400e18);
        arb.placeYesBond(proposalId, 800e18);
        arb.startNextEvaluation();

        // No evaluator set, so any caller should revert NotEvaluator.
        vm.expectRevert(FutarchyArbitration.NotEvaluator.selector);
        arb.resolveActiveEvaluation(true);
    }

    function testTotalActiveNoBondsTracksActiveNoStateOnly() public {
        uint256 pid = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);

        // INACTIVE -> YES
        arb.placeYesBond(pid, 10e18);
        assertEq(arb.totalActiveNoBonds(), 0);

        // YES -> NO, amount becomes active
        arb.placeNoBond(pid, 20e18);
        assertEq(arb.totalActiveNoBonds(), 20e18);

        // NO -> YES, NO amount no longer active
        arb.placeYesBond(pid, 40e18);
        assertEq(arb.totalActiveNoBonds(), 0);

        // YES -> NO again: new NO amount becomes active
        arb.placeNoBond(pid, 80e18);
        assertEq(arb.totalActiveNoBonds(), 80e18);

        // Settle by timeout while NO: should decrement
        vm.warp(block.timestamp + 72 hours);
        arb.finalizeByTimeout(pid);
        assertEq(arb.totalActiveNoBonds(), 0);
    }

    function testSafetyModeActiveWhenTotalActiveNoBondsAtOrAboveThreshold() public {
        assertEq(arb.safetyNoBondThreshold(), arb.baseX());
        assertFalse(arb.safetyModeActive());

        // Drive a proposal into NO with a NO bond >= threshold.
        uint256 pid = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);
        arb.placeYesBond(pid, 50e18);
        arb.placeNoBond(pid, 100e18);

        assertEq(arb.totalActiveNoBonds(), 100e18);
        assertTrue(arb.safetyModeActive());
    }

    function testSafetyModeBlocksYesTimeoutFinalizeButAllowsNoFinalize() public {
        // Proposal 1: create large NO exposure so safety mode is active.
        uint256 noPid = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);
        arb.placeYesBond(noPid, 50e18);
        arb.placeNoBond(noPid, 100e18);
        assertTrue(arb.safetyModeActive());

        // Proposal 2: left in YES state.
        uint256 yesPid = arb.createProposal(FutarchyArbitration.ProposalType.A, 1e18);
        arb.placeYesBond(yesPid, 1e18);

        // Advance beyond TIMEOUT for both proposals.
        vm.warp(block.timestamp + 72 hours + 1);

        // While in safety mode, YES-by-timeout must be disabled.
        vm.expectRevert(FutarchyArbitration.SafetyModeActive.selector);
        arb.finalizeByTimeout(yesPid);

        // NO-by-timeout is still allowed, and should decrement accounting.
        arb.finalizeByTimeout(noPid);
        assertEq(arb.totalActiveNoBonds(), 0);
        assertFalse(arb.safetyModeActive());
    }

    function testEnumHasEvaluatingState() public {
        // Compile-time guard: ensure the enum includes EVALUATING for Phase 3+.
        FutarchyArbitration.ProposalState s = FutarchyArbitration.ProposalState.EVALUATING;
        assertEq(uint256(s), uint256(FutarchyArbitration.ProposalState.EVALUATING));
    }
}
