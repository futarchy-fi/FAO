// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {FutarchyEvaluator} from "../src/FutarchyEvaluator.sol";

import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyProposalWithCondition} from "./mocks/MockFutarchyProposalWithCondition.sol";

contract FutarchyEvaluatorIntegrationTest is Test {
    FutarchyArbitration arb;
    MockConditionalTokens ctf;
    FutarchyEvaluator eval;

    // Canonical Gnosis WXDAI address hardcoded into contract.
    address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    address owner = address(0xBEEF);

    function setUp() public {
        arb = new FutarchyArbitration();
        ctf = new MockConditionalTokens();
        eval = new FutarchyEvaluator(address(arb), address(ctf), owner);

        // Mock ERC20 behaviors used by SafeERC20.
        vm.mockCall(WXDAI, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        vm.mockCall(WXDAI, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

        // Wire evaluator (arb.DEPLOYER == this test contract).
        arb.setEvaluator(address(eval));
    }

    function _createQueuedAndEvaluatingProposal() internal returns (uint256 proposalId) {
        uint256 m = 1e18;
        proposalId = arb.createProposal(FutarchyArbitration.ProposalType.A, m);

        // Drive state: INACTIVE -> YES -> NO -> (NO->YES flip) => QUEUED
        arb.placeYesBond(proposalId, 100e18);
        arb.placeNoBond(proposalId, 200e18);

        // Must be >= max(m, 2x current NO)=400e18 and also >= requiredYes(queueLen=0)=baseX=100e18.
        arb.placeYesBond(proposalId, 400e18);

        // QUEUED head -> EVALUATING
        arb.startNextEvaluation();
    }

    function testResolveViaFutarchyEvaluatorSettlesAccepted() public {
        uint256 proposalId = _createQueuedAndEvaluatingProposal();
        assertEq(arb.activeEvaluationProposalId(), proposalId);

        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        vm.prank(owner);
        eval.setFutarchyProposal(proposalId, address(prop));

        // resolved, YES wins (index 0)
        ctf.setPayout(conditionId, 10, 10, 0);

        bool accepted = eval.resolve(proposalId);
        assertTrue(accepted);
        assertEq(arb.activeEvaluationProposalId(), 0);
        assertTrue(arb.isAccepted(proposalId));

        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertTrue(p.accepted);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.SETTLED));
    }

    function testResolveViaFutarchyEvaluatorSettlesRejected() public {
        uint256 proposalId = _createQueuedAndEvaluatingProposal();
        assertEq(arb.activeEvaluationProposalId(), proposalId);

        bytes32 conditionId = keccak256("cond");
        MockFutarchyProposalWithCondition prop = new MockFutarchyProposalWithCondition(conditionId);

        vm.prank(owner);
        eval.setFutarchyProposal(proposalId, address(prop));

        // resolved, NO wins (index 1)
        ctf.setPayout(conditionId, 10, 0, 10);

        bool accepted = eval.resolve(proposalId);
        assertFalse(accepted);
        assertEq(arb.activeEvaluationProposalId(), 0);
        assertFalse(arb.isAccepted(proposalId));

        FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertFalse(p.accepted);
        assertEq(uint256(p.state), uint256(FutarchyArbitration.ProposalState.SETTLED));
    }
}
