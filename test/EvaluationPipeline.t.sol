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
    event EvaluationMarketCreated(
        uint256 indexed proposalId,
        uint256 indexed futarchyProposalId,
        address indexed futarchyProposal
    );
    event EvaluationResolved(
        uint256 indexed proposalId, address indexed futarchyProposal, bool accepted
    );

    MockFutarchyArbitrationLike arb;
    MockEvaluationOrchestrator orch;
    MockAlgebraFactoryLike factory;
    MockTWAPOracle twapOracle;
    EvaluationPipeline pipeline;
    address manager = makeAddr("manager");
    address proposalSource = makeAddr("proposal-source");

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
            address(arb),
            address(orch),
            address(twapOracle),
            address(factory),
            manager,
            proposalSource,
            1e18,
            0
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

    function testConstructorWiresOrchestratorFromPipeline() public view {
        assertEq(orch.manager(), manager);
        assertEq(orch.proposalSource(), proposalSource);
        assertEq(orch.wiringCaller(), address(pipeline));
    }

    function testConstructorRevertsIfEvaluationMinBondIsZero() public {
        vm.expectRevert(EvaluationPipeline.InvalidEvaluationConfig.selector);
        new EvaluationPipeline(
            address(arb),
            address(orch),
            address(twapOracle),
            address(factory),
            manager,
            proposalSource,
            0,
            0
        );
    }

    // ═══════════════════════════════════════════════════════
    //  startEvaluation
    // ═══════════════════════════════════════════════════════

    function testStartEvaluationRevertsIfNoActiveEvaluation() public {
        arb.setActive(0);

        vm.expectRevert(EvaluationPipeline.NoActiveEvaluation.selector);
        pipeline.startEvaluation(1, "test", "cat", "en");
    }

    function testStartEvaluationRevertsIfWrongProposalId() public {
        arb.setActive(7);

        vm.expectRevert(abi.encodeWithSelector(EvaluationPipeline.WrongProposalId.selector, 7, 99));
        pipeline.startEvaluation(99, "test", "cat", "en");
    }

    function testStartEvaluationSucceeds() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        pipeline.startEvaluation(5, "test market", "cat", "en");

        assertEq(pipeline.futarchyProposalOf(5), address(prop));
        assertEq(orch.createCallCount(), 1);
        // Verify TWAP oracle was bound.
        assertEq(twapOracle.bindCallCount(), 1);
    }

    function testStartEvaluationBindsCorrectPools() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        pipeline.startEvaluation(5, "test", "cat", "en");

        // Verify the TWAP oracle received correct binding.
        (
            address boundYesPool,
            address boundNoPool,
            address boundYesBase,
            address boundNoBase,
            uint48 boundStartTime
        ) = twapOracle.bindings(address(prop));
        assertEq(boundYesPool, yesPool);
        assertEq(boundNoPool, noPool);
        assertEq(boundYesBase, yesCompany);
        assertEq(boundNoBase, noCompany);
        assertEq(boundStartTime, uint48(block.timestamp));
    }

    function testStartEvaluationUsesPinnedMarketConfig() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);
        EvaluationPipeline delayedPipeline = new EvaluationPipeline(
            address(arb),
            address(orch),
            address(twapOracle),
            address(factory),
            manager,
            proposalSource,
            2e18,
            2 days
        );

        delayedPipeline.startEvaluation(5, "test", "cat", "en");

        (,,,, uint48 boundStartTime) = twapOracle.bindings(address(prop));
        assertEq(boundStartTime, uint48(block.timestamp + 2 days));
        assertEq(orch.lastMinBond(), 2e18);
        assertEq(orch.lastOpeningTime(), uint32(block.timestamp + 2 days));
    }

    function testStartEvaluationRevertsIfAlreadyStarted() public {
        arb.setActive(5);
        _setupProposal(42);

        pipeline.startEvaluation(5, "test", "cat", "en");

        vm.expectRevert(
            abi.encodeWithSelector(EvaluationPipeline.EvaluationAlreadyStarted.selector, 5)
        );
        pipeline.startEvaluation(5, "test", "cat", "en");
    }

    function testStartEvaluationEmitsEvent() public {
        arb.setActive(5);
        MockFutarchyProposalLike prop = _setupProposal(42);

        vm.expectEmit(true, true, true, true);
        emit EvaluationMarketCreated(5, 42, address(prop));

        pipeline.startEvaluation(5, "test", "cat", "en");
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
        pipeline.startEvaluation(5, "test", "cat", "en");
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
        pipeline.startEvaluation(7, "test", "cat", "en");

        // Decision not set → resolved = false.
        vm.expectRevert(
            abi.encodeWithSelector(EvaluationPipeline.FutarchyNotResolved.selector, address(prop))
        );
        pipeline.resolve(7);
    }

    function testResolveAcceptedWhenYesWins() public {
        arb.setActive(7);
        MockFutarchyProposalLike prop = _setupProposal(42);
        pipeline.startEvaluation(7, "test", "cat", "en");

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
        pipeline.startEvaluation(7, "test", "cat", "en");

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
        pipeline.startEvaluation(7, "test", "cat", "en");

        twapOracle.setDecision(address(prop), true, true);

        vm.expectEmit(true, true, false, true);
        emit EvaluationResolved(7, address(prop), true);

        pipeline.resolve(7);
    }
}
