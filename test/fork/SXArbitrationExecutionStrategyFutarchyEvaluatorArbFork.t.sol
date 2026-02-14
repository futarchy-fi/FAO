// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {FutarchyEvaluator} from "../../src/FutarchyEvaluator.sol";

interface IConditionalTokensLike {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
}

interface IFutarchyProposalWithConditionLike {
    function conditionId() external view returns (bytes32);
}

/// @notice Fork test proving FutarchyArbitration evaluation can be resolved via FutarchyEvaluator
///         using real ConditionalTokens payouts on Gnosis, when/if the referenced futarchy proposal is resolved.
///
/// Env:
/// - RUN_GNOSIS_FORK_TESTS=true
/// - Optional: TEST_FAO_PROPOSAL=<address> (must expose conditionId())
contract SXArbitrationExecutionStrategyFutarchyEvaluatorArbForkTest is Test {
    address internal constant DEFAULT_TEST_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;
    address internal constant GNOSIS_CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;

    function testFork_futarchyEvaluatorCanResolveArbitrationWhenCTFResolved() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        // Deploy arbitration + evaluator.
        FutarchyArbitration arb = new FutarchyArbitration();
        FutarchyEvaluator eval = new FutarchyEvaluator(address(arb), GNOSIS_CTF, address(this));
        arb.setEvaluator(address(eval));

        // Use a real futarchy proposal (needs conditionId()).
        address proposalAddress = vm.envOr("TEST_FAO_PROPOSAL", DEFAULT_TEST_PROPOSAL);
        bytes32 conditionId = IFutarchyProposalWithConditionLike(proposalAddress).conditionId();

        // Create arbitration proposal with deterministic id to match Snapshot X-style arbId alignment.
        uint256 proposalId = uint256(conditionId);
        uint256 m = 100e18;
        arb.createProposalWithId(proposalId, FutarchyArbitration.ProposalType.A, m);

        // Drive INACTIVE -> YES -> NO -> YES flip with enough YES to trigger graduation
        // (requiredYes(0)=baseX=100e18).
        address yesBidder = makeAddr("yesBidder");
        address noBidder = makeAddr("noBidder");

        // bonds: m, 2m, 4m
        uint256 noBond = 2 * m;
        uint256 yesFlipBond = 4 * m; // must be >= max(m, 2x current NO)

        // Fund and approve WXDAI.
        address wxdai = address(arb.WXDAI());
        deal(wxdai, yesBidder, m + yesFlipBond);
        deal(wxdai, noBidder, noBond);

        vm.prank(yesBidder);
        _approveAll(wxdai, address(arb));
        vm.prank(noBidder);
        _approveAll(wxdai, address(arb));

        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, m);

        vm.prank(noBidder);
        arb.placeNoBond(proposalId, noBond);

        vm.prank(yesBidder);
        arb.placeYesBond(proposalId, yesFlipBond);

        // Start evaluation.
        arb.startNextEvaluation();
        assertEq(arb.activeEvaluationProposalId(), proposalId, "active evaluation id mismatch");

        // Bind proposalId -> futarchy proposal.
        eval.setFutarchyProposal(proposalId, proposalAddress);

        // If unresolved, evaluator must revert (no flaky assertions).
        bool expectedAccepted;
        {
            IConditionalTokensLike ctf = IConditionalTokensLike(GNOSIS_CTF);
            uint256 denom = ctf.payoutDenominator(conditionId);
            if (denom == 0) {
                vm.expectRevert();
                eval.resolve(proposalId);
                return;
            }

            uint256 yesNum = ctf.payoutNumerators(conditionId, 0);
            uint256 noNum = ctf.payoutNumerators(conditionId, 1);
            assertEq(yesNum + noNum, denom, "payout numerators != denom");
            assertTrue(yesNum != noNum, "binary condition should not tie");
            expectedAccepted = yesNum > noNum;
        }

        bool accepted = eval.resolve(proposalId);
        assertEq(accepted, expectedAccepted, "accepted != CTF winner");
        assertTrue(arb.isSettled(proposalId), "proposal not settled");
        assertEq(arb.isAccepted(proposalId), accepted, "arb accepted mismatch");
    }

    function _approveAll(address token, address spender) internal {
        // We keep it interface-free here to reduce imports; use low-level call.
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve failed");
    }
}
