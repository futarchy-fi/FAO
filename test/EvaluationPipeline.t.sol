// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EvaluationPipeline} from "../src/EvaluationPipeline.sol";

import {MockFutarchyArbitrationLike} from "./mocks/MockFutarchyArbitrationLike.sol";
import {MockEvaluationOrchestrator} from "./mocks/MockEvaluationOrchestrator.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockTWAPOracle} from "./mocks/MockTWAPOracle.sol";

contract EvaluationPipelineTest is Test {
    MockFutarchyArbitrationLike arb;
    MockEvaluationOrchestrator orch;
    MockAlgebraFactoryLike factory;
    MockTWAPOracle twapOracle;
    EvaluationPipeline pipeline;

    // Outcome tokens.
    address yesCompany = address(0x10);
    address noCompany = address(0x20);
    address yesCurrency = address(0x30);
    address noCurrency = address(0x40);

    // Pool addresses.
    address yesPool = address(0x50);
    address noPool = address(0x60);

    function setUp() public {
        arb = new MockFutarchyArbitrationLike();
        orch = new MockEvaluationOrchestrator();
        factory = new MockAlgebraFactoryLike();
        twapOracle = new MockTWAPOracle();

        pipeline = new EvaluationPipeline(
            address(arb), address(orch), address(twapOracle), address(factory)
        );

        // Register pools in factory.
        factory.setPool(yesCompany, yesCurrency, yesPool);
        factory.setPool(noCompany, noCurrency, noPool);
    }

    /// @dev Create a MockFutarchyProposalLike with the standard outcome
    /// tokens and register it as the next return from the orchestrator.
    function _setupProposal(uint256 futarchyId) internal returns (MockFutarchyProposalLike prop) {
        prop = new MockFutarchyProposalLike(
            address(0), address(0), bytes32(0), yesCompany, noCompany, yesCurrency, noCurrency
        );
        orch.setNextReturn(futarchyId, address(prop));
    }

    // ═══════════════════════════════════════════════════════
    //  arbitration()
    // ═══════════════════════════════════════════════════════

    function testArbitrationReturnsCorrectAddress() public view {
        assertEq(pipeline.arbitration(), address(arb));
    }

    // ═══════════════════════════════════════════════════════
    //  startEvaluation
    // ═══════════════════════════════════════════════════════

    function testStartEvaluationRevertsIfNoActiveEvaluation() public {
        arb.setActive(0);

        vm.expectRevert(EvaluationPipeline.NoActiveEvaluation.selector);
        pipeline.startEvaluation(1, "test", "cat", "en", 1e18, uint32(block.timestamp));
    }

    function testStartEvaluationRevertsIfWrongProposalId() public {
        arb.setActive(7);

        vm.expectRevert(abi.encodeWithSelector(EvaluationPipeline.WrongProposalId.selector, 7, 99));
        pipeline.startEvaluation(99, "test", "cat", "en", 1e18, uint32(block.timestamp));
    }

    function testStartEvaluationSucceeds() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        pipeline.startEvaluation(5, "test market", "cat", "en", 1e18, uint32(block.timestamp));

        assertEq(pipeline.futarchyProposalOf(5), address(prop));
        assertEq(orch.createCallCount(), 1);
        // Verify TWAP oracle was bound.
        assertEq(twapOracle.bindCallCount(), 1);
    }

    function testStartEvaluationBindsCorrectPools() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        pipeline.startEvaluation(5, "test", "cat", "en", 1e18, uint32(block.timestamp));

        // Verify the TWAP oracle received correct binding.
        (address boundYesPool, address boundNoPool, address boundYesBase, address boundNoBase) =
            twapOracle.bindings(address(prop));
        assertEq(boundYesPool, yesPool);
        assertEq(boundNoPool, noPool);
        assertEq(boundYesBase, yesCompany);
        assertEq(boundNoBase, noCompany);
    }

    function testStartEvaluationRevertsIfAlreadyStarted() public {
        arb.setActive(5);
        _setupProposal(42);

        pipeline.startEvaluation(5, "test", "cat", "en", 1e18, uint32(block.timestamp));

        vm.expectRevert(
            abi.encodeWithSelector(EvaluationPipeline.EvaluationAlreadyStarted.selector, 5)
        );
        pipeline.startEvaluation(5, "test", "cat", "en", 1e18, uint32(block.timestamp));
    }

    function testStartEvaluationEmitsEvent() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        vm.expectEmit(true, true, true, true);
        emit EvaluationPipeline.EvaluationMarketCreated(5, 42, address(prop));

        pipeline.startEvaluation(5, "test", "cat", "en", 1e18, uint32(block.timestamp));
    }

    function testStartEvaluationRevertsIfPoolNotFound() public {
        arb.setActive(5);

        // Create proposal with tokens that have no pools registered.
        MockFutarchyProposalLike prop = new MockFutarchyProposalLike(
            address(0),
            address(0),
            bytes32(0),
            address(0xAA),
            address(0xBB),
            address(0xCC),
            address(0xDD)
        );
        orch.setNextReturn(42, address(prop));

        vm.expectRevert(EvaluationPipeline.PoolNotFound.selector);
        pipeline.startEvaluation(5, "test", "cat", "en", 1e18, uint32(block.timestamp));
    }

    // ═══════════════════════════════════════════════════════
    //  resolve
    // ═══════════════════════════════════════════════════════

    function testResolveRevertsIfNoActiveEvaluation() public {
        arb.setActive(0);

        vm.expectRevert(EvaluationPipeline.NoActiveEvaluation.selector);
        pipeline.resolve(1);
    }

    function testResolveRevertsIfWrongProposalId() public {
        arb.setActive(7);

        vm.expectRevert(abi.encodeWithSelector(EvaluationPipeline.WrongProposalId.selector, 7, 8));
        pipeline.resolve(8);
    }

    function testResolveRevertsIfEvaluationNotStarted() public {
        arb.setActive(7);

        vm.expectRevert(abi.encodeWithSelector(EvaluationPipeline.EvaluationNotStarted.selector, 7));
        pipeline.resolve(7);
    }

    function testResolveRevertsIfFutarchyNotResolved() public {
        arb.setActive(7);
        MockFutarchyProposalLike prop = _setupProposal(42);
        pipeline.startEvaluation(7, "test", "cat", "en", 1e18, uint32(block.timestamp));

        // Decision not set → resolved = false.
        vm.expectRevert(
            abi.encodeWithSelector(EvaluationPipeline.FutarchyNotResolved.selector, address(prop))
        );
        pipeline.resolve(7);
    }

    function testResolveAcceptedWhenYesWins() public {
        arb.setActive(7);
        MockFutarchyProposalLike prop = _setupProposal(42);
        pipeline.startEvaluation(7, "test", "cat", "en", 1e18, uint32(block.timestamp));

        twapOracle.setDecision(address(prop), true, true);

        bool accepted = pipeline.resolve(7);
        assertTrue(accepted);
        assertEq(arb.resolveCalls(), 1);
        assertTrue(arb.lastAccepted());
        assertEq(arb.activeEvaluationProposalId(), 0);
    }

    function testResolveRejectedWhenNoWins() public {
        arb.setActive(7);
        MockFutarchyProposalLike prop = _setupProposal(42);
        pipeline.startEvaluation(7, "test", "cat", "en", 1e18, uint32(block.timestamp));

        twapOracle.setDecision(address(prop), true, false);

        bool accepted = pipeline.resolve(7);
        assertFalse(accepted);
        assertEq(arb.resolveCalls(), 1);
        assertFalse(arb.lastAccepted());
        assertEq(arb.activeEvaluationProposalId(), 0);
    }

    function testResolveEmitsEvent() public {
        arb.setActive(7);
        MockFutarchyProposalLike prop = _setupProposal(42);
        pipeline.startEvaluation(7, "test", "cat", "en", 1e18, uint32(block.timestamp));

        twapOracle.setDecision(address(prop), true, true);

        vm.expectEmit(true, true, false, true);
        emit EvaluationPipeline.EvaluationResolved(7, address(prop), true);

        pipeline.resolve(7);
    }
}
