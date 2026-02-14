// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IFutarchyProposalWithConditionLike {
    function conditionId() external view returns (bytes32);
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

interface IConditionalTokensLike {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
}

contract FutarchyEvaluatorForkTest is Test {
    address internal constant DEFAULT_TEST_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;

    // Canonical ConditionalTokens on Gnosis (also documented in docs/futarchy-evaluator-integration.md).
    address internal constant GNOSIS_CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;

    function testFork_outcomeIndexMapping_yesIs0_noIs1_andPayoutsConsistentIfResolved() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        address proposalAddress = vm.envOr("TEST_FAO_PROPOSAL", DEFAULT_TEST_PROPOSAL);
        IFutarchyProposalWithConditionLike proposal = IFutarchyProposalWithConditionLike(proposalAddress);

        // Outcome-data bytes observed on-chain begin with ASCII YES_/NO_ prefixes for indices 0/1.
        (, bytes memory yesData) = proposal.wrappedOutcome(0);
        (, bytes memory noData) = proposal.wrappedOutcome(1);
        assertTrue(_startsWith(yesData, bytes("YES_")), "wrappedOutcome(0) not YES_");
        assertTrue(_startsWith(noData, bytes("NO_")), "wrappedOutcome(1) not NO_");

        // If the underlying CTF condition is already resolved, verify payout invariants.
        bytes32 conditionId = proposal.conditionId();
        IConditionalTokensLike ctf = IConditionalTokensLike(GNOSIS_CTF);

        uint256 denom = ctf.payoutDenominator(conditionId);
        if (denom == 0) return; // unresolved at fork time; nothing further to assert

        uint256 yesNum = ctf.payoutNumerators(conditionId, 0);
        uint256 noNum = ctf.payoutNumerators(conditionId, 1);

        // Binary CTF condition invariant: payouts sum to denominator.
        assertEq(yesNum + noNum, denom, "CTF payout numerators != denom");

        // Sanity: no ties for a binary resolved condition.
        assertTrue(yesNum == 0 || noNum == 0, "CTF binary condition should have single winner");
    }

    function _startsWith(bytes memory value, bytes memory prefix) internal pure returns (bool) {
        if (prefix.length > value.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) return false;
        }
        return true;
    }
}
