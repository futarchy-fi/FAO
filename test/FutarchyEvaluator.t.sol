// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyEvaluator} from "../src/FutarchyEvaluator.sol";

import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyProposalWithCondition} from "./mocks/MockFutarchyProposalWithCondition.sol";
import {MockFutarchyArbitrationLike} from "./mocks/MockFutarchyArbitrationLike.sol";

contract FutarchyEvaluatorTest is Test {
    MockFutarchyArbitrationLike arb;
    MockConditionalTokens ctf;
    FutarchyEvaluator eval;

    address owner = address(0xBEEF);

    function setUp() public {
        arb = new MockFutarchyArbitrationLike();
        ctf = new MockConditionalTokens();
        eval = new FutarchyEvaluator(address(arb), address(ctf), owner);
    }

    function testResolveRevertsIfNoActiveEvaluation() public {
        arb.setActive(0);

        vm.expectRevert(FutarchyEvaluator.NoActiveEvaluation.selector);
        eval.resolve(1);
    }

    function testResolveRevertsIfWrongProposalId() public {
        arb.setActive(7);

        vm.expectRevert(abi.encodeWithSelector(FutarchyEvaluator.WrongProposalId.selector, 7, 8));
        eval.resolve(8);
    }

    function testResolveRevertsIfMissingMapping() public {
        arb.setActive(7);

        vm.expectRevert(
            abi.encodeWithSelector(FutarchyEvaluator.MissingFutarchyProposal.selector, 7)
        );
        eval.resolve(7);
    }

    function testResolveRevertsIfFutarchyNotResolved() public {
        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        arb.setActive(7);
        vm.prank(owner);
        eval.setFutarchyProposal(7, address(prop));

        // denom==0 => unresolved
        ctf.setPayout(conditionId, 0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(FutarchyEvaluator.FutarchyNotResolved.selector, conditionId)
        );
        eval.resolve(7);
    }

    function testResolveRevertsIfInvalidPayoutTie() public {
        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        arb.setActive(7);
        vm.prank(owner);
        eval.setFutarchyProposal(7, address(prop));

        ctf.setPayout(conditionId, 2, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(FutarchyEvaluator.InvalidPayout.selector, 1, 1, 2));
        eval.resolve(7);
    }

    function testResolveRevertsIfInvalidPayoutSumMismatch() public {
        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        arb.setActive(7);
        vm.prank(owner);
        eval.setFutarchyProposal(7, address(prop));

        // denom=10 but yes+no=9
        ctf.setPayout(conditionId, 10, 9, 0);

        vm.expectRevert(abi.encodeWithSelector(FutarchyEvaluator.InvalidPayout.selector, 9, 0, 10));
        eval.resolve(7);
    }

    function testResolveAcceptedTrueWhenYesNumeratorGreater() public {
        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        arb.setActive(7);
        vm.prank(owner);
        eval.setFutarchyProposal(7, address(prop));

        ctf.setPayout(conditionId, 10, 10, 0);

        bool accepted = eval.resolve(7);
        assertTrue(accepted);
        assertEq(arb.resolveCalls(), 1);
        assertTrue(arb.lastAccepted());
        assertEq(arb.activeEvaluationProposalId(), 0);
    }

    function testResolveAcceptedFalseWhenNoNumeratorGreater() public {
        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        arb.setActive(7);
        vm.prank(owner);
        eval.setFutarchyProposal(7, address(prop));

        ctf.setPayout(conditionId, 10, 0, 10);

        bool accepted = eval.resolve(7);
        assertFalse(accepted);
        assertEq(arb.resolveCalls(), 1);
        assertFalse(arb.lastAccepted());
        assertEq(arb.activeEvaluationProposalId(), 0);
    }
}
