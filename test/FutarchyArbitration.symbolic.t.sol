// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";

/// @custom:spec INV-ARB-001 — proposal id monotonicity.
/// Halmos-checkable symbolic tests for the invariants listed in
/// `audit/specs/INVARIANTS.md`.
contract FutarchyArbitrationSymbolic is Test {
    FutarchyArbitration internal arb;

    address internal constant CREATOR_ONE = address(0xA11CE);
    address internal constant CREATOR_TWO = address(0xB0B);
    address internal constant CREATOR_THREE = address(0xCAFE);

    function setUp() public {
        arb = new FutarchyArbitration();
    }

    /// @custom:spec INV-ARB-001 — See audit/specs/INVARIANTS.md.
    /// `nextProposalId` is monotone and auto ids below it exist.
    function check_INV_ARB_001_idMonotone(
        uint16 firstMinBond,
        uint16 secondMinBond,
        uint16 explicitIdDelta
    ) public {
        vm.assume(firstMinBond >= 1 && firstMinBond <= 100);
        vm.assume(secondMinBond >= 1 && secondMinBond <= 100);
        vm.assume(explicitIdDelta >= 1 && explicitIdDelta <= 100);

        uint256 initialNext = arb.nextProposalId();

        vm.prank(CREATOR_ONE);
        uint256 firstId = arb.createProposal(uint256(firstMinBond));
        uint256 afterFirst = arb.nextProposalId();

        assertEq(firstId, initialNext);
        assertEq(afterFirst, initialNext + 1);
        assertGt(afterFirst, initialNext);

        FutarchyArbitration.Proposal memory first = arb.getProposal(firstId);
        assertTrue(first.exists);
        assertLt(firstId, afterFirst);

        vm.prank(CREATOR_TWO);
        uint256 secondId = arb.createProposal(uint256(secondMinBond));
        uint256 afterSecond = arb.nextProposalId();

        assertEq(secondId, afterFirst);
        assertEq(afterSecond, afterFirst + 1);
        assertGt(afterSecond, afterFirst);

        first = arb.getProposal(firstId);
        FutarchyArbitration.Proposal memory second = arb.getProposal(secondId);
        assertTrue(first.exists);
        assertTrue(second.exists);
        assertLt(firstId, afterSecond);
        assertLt(secondId, afterSecond);

        uint256 explicitId = afterSecond + uint256(explicitIdDelta);
        vm.prank(CREATOR_THREE);
        uint256 returnedId = arb.createProposalWithId(explicitId, uint256(firstMinBond));
        uint256 afterExplicit = arb.nextProposalId();

        assertEq(returnedId, explicitId);
        assertEq(afterExplicit, afterSecond);
        assertGe(afterExplicit, afterSecond);
        FutarchyArbitration.Proposal memory explicit = arb.getProposal(explicitId);
        assertTrue(explicit.exists);
    }
}
