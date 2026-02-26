// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";
import {IAlgebraFactoryLike} from "./interfaces/IAlgebraFactoryLike.sol";

interface IFutarchyArbitrationForPipeline {
    function activeEvaluationProposalId() external view returns (uint256);
    function resolveActiveEvaluation(bool accepted) external;
}

interface IFutarchyProposalOutcomes {
    function wrappedOutcome(uint256 index) external view returns (address token, bytes memory data);
}

interface IOrchestratorLike {
    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata category,
        string calldata lang,
        uint256 minBond,
        uint32 openingTime
    ) external returns (uint256 proposalId, address proposal);
}

interface ITWAPOracleLike {
    function bind(
        address proposal,
        address yesPool,
        address noPool,
        address yesBase,
        address noBase
    ) external;
    function getDecision(address proposal) external view returns (bool resolved, bool accepted);
}

/// @title EvaluationPipeline
/// @notice Automated evaluator for FutarchyArbitration that creates futarchy
/// markets for graduated proposals and resolves the arbitration based on TWAP
/// oracle outcomes.
///
/// Implements IFutarchyArbitrationEvaluator so it can be registered on a
/// FutarchyArbitration instance via setEvaluator().
///
/// Lifecycle:
///   1. FutarchyArbitration graduates a proposal to EVALUATING via
///      startNextEvaluation().
///   2. Anyone calls startEvaluation(proposalId, ...) on this contract. The
///      orchestrator atomically creates a futarchy proposal, initializes
///      YES/NO conditional pools at the current spot price, sets it as
///      official, and migrates liquidity. The pipeline then binds the pools
///      to the TWAP oracle.
///   3. The futarchy market runs for the configured trading period.
///   4. Anyone calls resolve(proposalId) which reads the TWAP oracle
///      decision and calls arbitration.resolveActiveEvaluation(accepted).
contract EvaluationPipeline is IFutarchyArbitrationEvaluator {
    // ═══════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════

    error NoActiveEvaluation();
    error WrongProposalId(uint256 expectedActive, uint256 got);
    error EvaluationAlreadyStarted(uint256 proposalId);
    error EvaluationNotStarted(uint256 proposalId);
    error FutarchyNotResolved(address futarchyProposal);
    error PoolNotFound();

    // ═══════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════

    /// @notice The FutarchyArbitration contract this evaluator is bound to.
    address public immutable arbitrationContract;

    /// @notice Orchestrator that atomically creates futarchy proposals,
    /// initializes pools, and migrates liquidity.
    IOrchestratorLike public immutable orchestrator;

    /// @notice TWAP oracle for comparing YES/NO pool prices.
    ITWAPOracleLike public immutable twapOracle;

    /// @notice Algebra DEX factory for looking up conditional pools.
    IAlgebraFactoryLike public immutable algebraFactory;

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    /// @notice Maps arbitration proposalId to the futarchy proposal contract
    /// created for its evaluation market.
    mapping(uint256 proposalId => address futarchyProposal) public futarchyProposalOf;

    // ═══════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════

    event EvaluationMarketCreated(
        uint256 indexed proposalId,
        uint256 indexed futarchyProposalId,
        address indexed futarchyProposal
    );

    event EvaluationResolved(
        uint256 indexed proposalId, address indexed futarchyProposal, bool accepted
    );

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor(
        address _arbitration,
        address _orchestrator,
        address _twapOracle,
        address _algebraFactory
    ) {
        arbitrationContract = _arbitration;
        orchestrator = IOrchestratorLike(_orchestrator);
        twapOracle = ITWAPOracleLike(_twapOracle);
        algebraFactory = IAlgebraFactoryLike(_algebraFactory);
    }

    // ═══════════════════════════════════════════════════════
    //  IFutarchyArbitrationEvaluator
    // ═══════════════════════════════════════════════════════

    /// @inheritdoc IFutarchyArbitrationEvaluator
    function arbitration() external view returns (address) {
        return arbitrationContract;
    }

    /// @inheritdoc IFutarchyArbitrationEvaluator
    /// @notice Resolve a proposal using the TWAP oracle. Permissionless —
    /// anyone can call once the TWAP oracle has resolved.
    function resolve(uint256 proposalId) external returns (bool accepted) {
        uint256 active =
            IFutarchyArbitrationForPipeline(arbitrationContract).activeEvaluationProposalId();
        if (active == 0) revert NoActiveEvaluation();
        if (proposalId != active) {
            revert WrongProposalId(active, proposalId);
        }

        address futarchyProposal = futarchyProposalOf[proposalId];
        if (futarchyProposal == address(0)) {
            revert EvaluationNotStarted(proposalId);
        }

        (bool resolved, bool result) = twapOracle.getDecision(futarchyProposal);
        if (!resolved) revert FutarchyNotResolved(futarchyProposal);

        accepted = result;
        IFutarchyArbitrationForPipeline(arbitrationContract).resolveActiveEvaluation(accepted);

        emit EvaluationResolved(proposalId, futarchyProposal, accepted);
    }

    // ═══════════════════════════════════════════════════════
    //  Evaluation Market Creation
    // ═══════════════════════════════════════════════════════

    /// @notice Create a futarchy market for a proposal currently in
    /// EVALUATING state, then bind its YES/NO pools to the TWAP oracle.
    /// @dev Permissionless: anyone can trigger once a proposal is the
    /// active evaluation. The orchestrator atomically creates the proposal,
    /// initializes YES/NO pools at spot, makes it official, and migrates
    /// 80% of spot liquidity. Then this function looks up the newly created
    /// pools and binds them to the TWAP oracle for later resolution.
    function startEvaluation(
        uint256 proposalId,
        string calldata marketName,
        string calldata category,
        string calldata lang,
        uint256 minBond,
        uint32 openingTime
    ) external {
        uint256 active = IFutarchyArbitrationForPipeline(arbitrationContract)
            .activeEvaluationProposalId();
        if (active == 0) revert NoActiveEvaluation();
        if (proposalId != active) {
            revert WrongProposalId(active, proposalId);
        }
        if (futarchyProposalOf[proposalId] != address(0)) {
            revert EvaluationAlreadyStarted(proposalId);
        }

        (uint256 futarchyProposalId, address futarchyProposal) = orchestrator.createOfficialProposalAndMigrate(
            marketName, category, lang, minBond, openingTime
        );

        futarchyProposalOf[proposalId] = futarchyProposal;

        _bindToTWAPOracle(futarchyProposal);

        emit EvaluationMarketCreated(proposalId, futarchyProposalId, futarchyProposal);
    }

    /// @dev Look up YES/NO pools from the Algebra factory using the
    /// proposal's wrapped outcome tokens and bind them to the TWAP
    /// oracle. Extracted to avoid stack-too-deep in startEvaluation.
    function _bindToTWAPOracle(address futarchyProposal) internal {
        IFutarchyProposalOutcomes fp = IFutarchyProposalOutcomes(futarchyProposal);
        (address yesCompany,) = fp.wrappedOutcome(0);
        (address noCompany,) = fp.wrappedOutcome(1);
        (address yesCurrency,) = fp.wrappedOutcome(2);
        (address noCurrency,) = fp.wrappedOutcome(3);

        address yesPool = algebraFactory.poolByPair(yesCompany, yesCurrency);
        address noPool = algebraFactory.poolByPair(noCompany, noCurrency);
        if (yesPool == address(0) || noPool == address(0)) {
            revert PoolNotFound();
        }

        twapOracle.bind(futarchyProposal, yesPool, noPool, yesCompany, noCompany);
    }
}
