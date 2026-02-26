// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {EvaluationPipeline} from "../src/EvaluationPipeline.sol";

import {MockEvaluationOrchestrator} from
    "./mocks/MockEvaluationOrchestrator.sol";
import {MockFutarchyProposalLike} from
    "./mocks/MockFutarchyProposalLike.sol";
import {MockAlgebraFactoryLike} from
    "./mocks/MockAlgebraFactoryLike.sol";
import {MockTWAPOracle} from "./mocks/MockTWAPOracle.sol";

/// @notice Integration test: EvaluationPipeline + real FutarchyArbitration.
/// Exercises the full lifecycle: create proposal, escalate bonds, graduate
/// to EVALUATING, start evaluation market (with TWAP oracle binding), and
/// resolve via TWAP oracle decision.
contract EvaluationPipelineIntegrationTest is Test {
    FutarchyArbitration arb;
    MockEvaluationOrchestrator orch;
    MockAlgebraFactoryLike factory;
    MockTWAPOracle twapOracle;
    EvaluationPipeline pipeline;

    address internal constant WXDAI =
        0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    // Outcome tokens.
    address yesCompany = address(0x10);
    address noCompany = address(0x20);
    address yesCurrency = address(0x30);
    address noCurrency = address(0x40);

    // Pool addresses.
    address yesPool = address(0x50);
    address noPool = address(0x60);

    function setUp() public {
        arb = new FutarchyArbitration();
        orch = new MockEvaluationOrchestrator();
        factory = new MockAlgebraFactoryLike();
        twapOracle = new MockTWAPOracle();

        pipeline = new EvaluationPipeline(
            address(arb),
            address(orch),
            address(twapOracle),
            address(factory)
        );

        // Mock ERC20 behaviors used by SafeERC20 in FutarchyArbitration.
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

        // Register pipeline as the evaluator.
        arb.setEvaluator(address(pipeline));

        // Register pools in factory.
        factory.setPool(yesCompany, yesCurrency, yesPool);
        factory.setPool(noCompany, noCurrency, noPool);
    }

    /// @dev Create a MockFutarchyProposalLike with the standard outcome
    /// tokens.
    function _makeProposal()
        internal
        returns (MockFutarchyProposalLike)
    {
        return new MockFutarchyProposalLike(
            address(0),
            address(0),
            bytes32(0),
            yesCompany,
            noCompany,
            yesCurrency,
            noCurrency
        );
    }

    /// @dev Drive a proposal through INACTIVE -> YES -> NO -> YES
    /// (graduation) -> QUEUED -> EVALUATING.
    function _createEvaluatingProposal()
        internal
        returns (uint256 proposalId)
    {
        uint256 m = 1e18;
        proposalId = arb.createProposal(m);

        // INACTIVE -> YES
        arb.placeYesBond(proposalId, 25e18);
        // YES -> NO (match)
        arb.placeNoBond(proposalId);
        // NO -> YES with graduation threshold (requiredYes(0) = 100e18)
        arb.placeYesBond(proposalId, 100e18);

        // QUEUED -> EVALUATING
        arb.startNextEvaluation();
    }

    function testFullLifecycleAccepted() public {
        uint256 proposalId = _createEvaluatingProposal();
        assertEq(arb.activeEvaluationProposalId(), proposalId);

        FutarchyArbitration.Proposal memory p =
            arb.getProposal(proposalId);
        assertEq(
            uint256(p.state),
            uint256(FutarchyArbitration.ProposalState.EVALUATING)
        );

        // Step 1: Start evaluation — create futarchy market + bind TWAP.
        MockFutarchyProposalLike futarchyProp = _makeProposal();
        orch.setNextReturn(10, address(futarchyProp));

        pipeline.startEvaluation(
            proposalId,
            "FAO Eval",
            "governance",
            "en",
            1e18,
            uint32(block.timestamp)
        );

        assertEq(
            pipeline.futarchyProposalOf(proposalId),
            address(futarchyProp)
        );
        assertEq(twapOracle.bindCallCount(), 1);

        // Step 2: TWAP oracle resolves — YES wins.
        twapOracle.setDecision(address(futarchyProp), true, true);

        bool accepted = pipeline.resolve(proposalId);
        assertTrue(accepted);

        // Verify arbitration state.
        assertEq(arb.activeEvaluationProposalId(), 0);
        assertTrue(arb.isAccepted(proposalId));
        assertTrue(arb.isSettled(proposalId));

        p = arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertTrue(p.accepted);
        assertEq(
            uint256(p.state),
            uint256(FutarchyArbitration.ProposalState.SETTLED)
        );
    }

    function testFullLifecycleRejected() public {
        uint256 proposalId = _createEvaluatingProposal();

        MockFutarchyProposalLike futarchyProp = _makeProposal();
        orch.setNextReturn(10, address(futarchyProp));

        pipeline.startEvaluation(
            proposalId,
            "FAO Eval",
            "governance",
            "en",
            1e18,
            uint32(block.timestamp)
        );

        // NO wins.
        twapOracle.setDecision(address(futarchyProp), true, false);

        bool accepted = pipeline.resolve(proposalId);
        assertFalse(accepted);

        assertEq(arb.activeEvaluationProposalId(), 0);
        assertFalse(arb.isAccepted(proposalId));
        assertTrue(arb.isSettled(proposalId));

        FutarchyArbitration.Proposal memory p =
            arb.getProposal(proposalId);
        assertTrue(p.settled);
        assertFalse(p.accepted);
    }

    function testResolveRevertsIfFutarchyNotYetResolved() public {
        uint256 proposalId = _createEvaluatingProposal();

        MockFutarchyProposalLike futarchyProp = _makeProposal();
        orch.setNextReturn(10, address(futarchyProp));

        pipeline.startEvaluation(
            proposalId,
            "FAO Eval",
            "governance",
            "en",
            1e18,
            uint32(block.timestamp)
        );

        // TWAP oracle not resolved.
        vm.expectRevert(
            abi.encodeWithSelector(
                EvaluationPipeline.FutarchyNotResolved.selector,
                address(futarchyProp)
            )
        );
        pipeline.resolve(proposalId);
    }

    function testSecondEvaluationAfterFirstResolves() public {
        // First proposal lifecycle.
        uint256 pid1 = _createEvaluatingProposal();

        MockFutarchyProposalLike prop1 = _makeProposal();
        orch.setNextReturn(10, address(prop1));

        pipeline.startEvaluation(
            pid1, "First", "gov", "en", 1e18, uint32(block.timestamp)
        );
        twapOracle.setDecision(address(prop1), true, true);
        pipeline.resolve(pid1);

        assertTrue(arb.isSettled(pid1));
        assertEq(arb.activeEvaluationProposalId(), 0);

        // Second proposal lifecycle.
        uint256 m = 1e18;
        uint256 pid2 = arb.createProposal(m);
        arb.placeYesBond(pid2, 25e18);
        arb.placeNoBond(pid2);
        arb.placeYesBond(pid2, 100e18);
        arb.startNextEvaluation();

        assertEq(arb.activeEvaluationProposalId(), pid2);

        MockFutarchyProposalLike prop2 = _makeProposal();
        orch.setNextReturn(11, address(prop2));

        pipeline.startEvaluation(
            pid2, "Second", "gov", "en", 1e18, uint32(block.timestamp)
        );
        twapOracle.setDecision(address(prop2), true, false);

        bool accepted = pipeline.resolve(pid2);
        assertFalse(accepted);

        assertTrue(arb.isSettled(pid2));
        assertFalse(arb.isAccepted(pid2));
    }
}
