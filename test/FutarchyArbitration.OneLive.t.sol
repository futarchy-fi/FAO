// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {IFutarchyArbitrationEvaluator} from "../src/IFutarchyArbitrationEvaluator.sol";

contract OneLiveEvaluator is IFutarchyArbitrationEvaluator {
    address public immutable arbitration;

    constructor(address arbitration_) {
        arbitration = arbitration_;
    }

    function resolve(uint256) external returns (bool accepted) {
        accepted = true;
        FutarchyArbitration(arbitration).resolveActiveEvaluation(accepted);
    }

    function resolveWith(bool accepted) external {
        FutarchyArbitration(arbitration).resolveActiveEvaluation(accepted);
    }
}

/// @notice Kelvin 2026-11-12: at most one graduated proposal may be in market evaluation.
contract FutarchyArbitrationOneLiveTest is Test {
    FutarchyArbitration arb;
    OneLiveEvaluator evaluator;

    address internal constant TOKEN = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    uint256 internal constant BASE_X = 100e18;
    uint256 internal constant TIMEOUT = 72 hours;
    uint256 internal constant M = 1e18;

    uint256[] ids;

    function setUp() public {
        vm.etch(TOKEN, hex"00");
        arb = new FutarchyArbitration(IERC20(TOKEN), BASE_X, TIMEOUT);
        arb.setProposalGateway(address(this));
        evaluator = new OneLiveEvaluator(address(arb));
        arb.setEvaluator(address(evaluator));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(TOKEN, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
    }

    function _state(uint256 id) internal view returns (FutarchyArbitration.ProposalState) {
        return arb.getProposal(id).state;
    }

    function _countEvaluating() internal view returns (uint256 n) {
        for (uint256 i; i < ids.length; i++) {
            if (_state(ids[i]) == FutarchyArbitration.ProposalState.EVALUATING) n++;
        }
    }

    function _assertAtMostOneLive() internal view {
        uint256 n = _countEvaluating();
        assertLe(n, 1, "more than one EVALUATING");
        uint256 active = arb.activeEvaluationProposalId();
        if (n == 1) {
            assertTrue(active != 0, "evaluating but no active id");
            assertEq(uint256(_state(active)), uint256(FutarchyArbitration.ProposalState.EVALUATING));
        } else {
            assertEq(active, 0, "active id without EVALUATING proposal");
        }
    }

    /// Activate, contest (NO), flip YES at exactly the current graduation threshold.
    function _contestAndGraduate(uint256 id) internal {
        address yes = makeAddr(string.concat("yes", vm.toString(id)));
        address no = makeAddr(string.concat("no", vm.toString(id)));
        vm.prank(yes);
        arb.placeYesBond(id, M);
        _assertAtMostOneLive();
        vm.prank(no);
        arb.placeNoBond(id);
        _assertAtMostOneLive();
        // A non-graduating escalation step first (2x NO), then NO matches again.
        vm.prank(yes);
        arb.placeYesBond(id, 2 * M);
        vm.prank(no);
        arb.placeNoBond(id);
        _assertAtMostOneLive();
        uint256 req = arb.requiredYes(_queued());
        vm.prank(yes);
        arb.placeYesBond(id, req);
        assertEq(uint256(_state(id)), uint256(FutarchyArbitration.ProposalState.QUEUED));
        _assertAtMostOneLive();
    }

    function _queued() internal view returns (uint256 n) {
        for (uint256 i; i < ids.length; i++) {
            if (_state(ids[i]) == FutarchyArbitration.ProposalState.QUEUED) n++;
        }
    }

    function testThreeControversialProposalsOnlyOneLive() public {
        for (uint256 i = 1; i <= 3; i++) {
            ids.push(arb.createProposal(M));
        }

        // Graduation thresholds grow 100, 200, 400 with queue length 0, 1, 2.
        _contestAndGraduate(ids[0]);
        _contestAndGraduate(ids[1]);
        _contestAndGraduate(ids[2]);
        assertEq(arb.getProposal(ids[0]).yesBond.amount, BASE_X);
        assertEq(arb.getProposal(ids[1]).yesBond.amount, 2 * BASE_X);
        assertEq(arb.getProposal(ids[2]).yesBond.amount, 4 * BASE_X);
        assertEq(arb.getProposal(ids[0]).queuePosition, 1);
        assertEq(arb.getProposal(ids[1]).queuePosition, 2);
        assertEq(arb.getProposal(ids[2]).queuePosition, 3);

        // Queued proposals cannot time out, nor be bid on.
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.finalizeByTimeout(ids[1]);
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.placeNoBond(ids[1]);

        // FIFO, one at a time.
        for (uint256 k; k < 3; k++) {
            vm.prank(makeAddr("anyone")); // permissionless
            arb.startNextEvaluation();
            assertEq(arb.activeEvaluationProposalId(), ids[k], "not FIFO");
            _assertAtMostOneLive();
            for (uint256 j = k + 1; j < 3; j++) {
                assertEq(uint256(_state(ids[j])), uint256(FutarchyArbitration.ProposalState.QUEUED));
            }

            // Second start (also in the same block) must fail while one is live,
            // even after the market window has long ended.
            vm.expectRevert(FutarchyArbitration.InvalidState.selector);
            arb.startNextEvaluation();
            vm.warp(block.timestamp + 30 days);
            vm.expectRevert(FutarchyArbitration.InvalidState.selector);
            arb.startNextEvaluation();
            vm.expectRevert(FutarchyArbitration.InvalidState.selector);
            arb.finalizeByTimeout(ids[k]);
            _assertAtMostOneLive();

            // Only the evaluator can settle.
            vm.expectRevert(FutarchyArbitration.NotEvaluator.selector);
            arb.resolveActiveEvaluation(true);

            evaluator.resolveWith(k % 2 == 0);
            assertEq(uint256(_state(ids[k])), uint256(FutarchyArbitration.ProposalState.SETTLED));
            assertEq(arb.activeEvaluationProposalId(), 0);
            _assertAtMostOneLive();
        }

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.startNextEvaluation();
    }

    /// An evaluation nobody resolves can be aborted after MAX_EVALUATION; both bonds are returned
    /// and the next queued proposal can start. Still at most one is ever live.
    function testStaleEvaluationCanBeAbortedAndQueueAdvances() public {
        ids.push(arb.createProposal(M));
        ids.push(arb.createProposal(M));
        _contestAndGraduate(ids[0]);
        _contestAndGraduate(ids[1]);
        arb.startNextEvaluation();

        address yes = makeAddr(string.concat("yes", vm.toString(ids[0])));
        address no = makeAddr(string.concat("no", vm.toString(ids[0])));
        uint256 yesBefore = arb.withdrawable(yes);
        uint256 noBefore = arb.withdrawable(no);
        FutarchyArbitration.Proposal memory live = arb.getProposal(ids[0]);

        vm.warp(block.timestamp + arb.MAX_EVALUATION() - 1);
        vm.expectRevert(FutarchyArbitration.TimeoutNotReached.selector);
        arb.abortStaleEvaluation();
        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.startNextEvaluation();

        vm.warp(block.timestamp + 1);
        vm.prank(makeAddr("anyone"));
        arb.abortStaleEvaluation();

        assertEq(uint256(_state(ids[0])), uint256(FutarchyArbitration.ProposalState.SETTLED));
        assertFalse(arb.isAccepted(ids[0]));
        assertEq(arb.withdrawable(yes) - yesBefore, live.yesBond.amount);
        assertEq(arb.withdrawable(no) - noBefore, live.noBond.amount);
        assertEq(arb.activeEvaluationProposalId(), 0);
        _assertAtMostOneLive();

        vm.expectRevert(FutarchyArbitration.InvalidState.selector);
        arb.abortStaleEvaluation();

        arb.startNextEvaluation();
        assertEq(arb.activeEvaluationProposalId(), ids[1]);
        _assertAtMostOneLive();
    }

    /// A full queue no longer kills a contested proposal: the YES flip is accepted, the proposal
    /// waits in YES, and it graduates once a slot frees.
    function testFullQueueDefersGraduationInsteadOfKillingProposal() public {
        for (uint256 i; i < 16; i++) {
            ids.push(arb.createProposal(M));
            _contestAndGraduate(ids[i]);
        }
        uint256 victim = arb.createProposal(M);
        ids.push(victim);
        address y = makeAddr("vy");
        address n = makeAddr("vn");
        uint256 req = arb.requiredYes(16);
        vm.prank(y);
        arb.placeYesBond(victim, req);
        vm.prank(n);
        arb.placeNoBond(victim);
        vm.prank(y);
        arb.placeYesBond(victim, 2 * req);
        assertEq(uint256(_state(victim)), uint256(FutarchyArbitration.ProposalState.YES));
        _assertAtMostOneLive();

        // While it waits for a slot it cannot be settled by timeout: it must be evaluated.
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.expectRevert(FutarchyArbitration.MustBeEvaluated.selector);
        arb.finalizeByTimeout(victim);

        // One evaluation completes, freeing a slot.
        arb.startNextEvaluation();
        evaluator.resolveWith(true);
        arb.tryGraduate(victim);
        assertEq(uint256(_state(victim)), uint256(FutarchyArbitration.ProposalState.QUEUED));
        _assertAtMostOneLive();
    }
}
