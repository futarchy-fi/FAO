// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";

interface IFutarchyArbitrationLike {
    function activeEvaluationProposalId() external view returns (uint256);
    function resolveActiveEvaluation(bool accepted) external;
}

interface IFutarchyProposalLike {
    function conditionId() external view returns (bytes32);
}

interface IConditionalTokens {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
}

/// @notice Evaluator that resolves FutarchyArbitration evaluations using CTF condition payouts.
///
/// Design:
/// - Maintains an owner-controlled mapping from arbitration `proposalId` -> futarchy proposal contract.
/// - Reads the futarchy proposal's `conditionId()` and consults ConditionalTokens payouts.
/// - If resolved, calls `FutarchyArbitration.resolveActiveEvaluation(accepted)`.
///
/// Assumptions (must match the futarchy proposal implementation):
/// - Outcome index 0 corresponds to "YES/accepted" and index 1 to "NO/rejected".
///   Evidence (Gnosis, DEFAULT_TEST_PROPOSAL 0x81829a8e...): `wrappedOutcome(0)` bytes start with ASCII `YES_FAO`,
///   and `wrappedOutcome(1)` bytes start with ASCII `NO_FAO`.
/// - Condition is resolved when payoutDenominator(conditionId) > 0.
contract FutarchyEvaluator is Ownable, IFutarchyArbitrationEvaluator {
    error NoActiveEvaluation();
    error WrongProposalId(uint256 expectedActive, uint256 got);
    error MissingFutarchyProposal(uint256 proposalId);
    error FutarchyNotResolved(bytes32 conditionId);
    error InvalidPayout(uint256 yesNumerator, uint256 noNumerator, uint256 denom);

    address public immutable arbitrationContract;
    IConditionalTokens public immutable conditionalTokens;

    mapping(uint256 proposalId => address futarchyProposal) public futarchyProposalOf;

    event FutarchyProposalBound(uint256 indexed proposalId, address indexed futarchyProposal);
    event EvaluationResolved(uint256 indexed proposalId, bytes32 indexed conditionId, bool accepted, uint256 yesNumerator, uint256 noNumerator, uint256 denom);

    constructor(address _arbitration, address _conditionalTokens, address _owner) Ownable(_owner) {
        arbitrationContract = _arbitration;
        conditionalTokens = IConditionalTokens(_conditionalTokens);
    }

    function arbitration() external view returns (address) {
        return arbitrationContract;
    }

    /// @notice Bind an arbitration proposal id to a futarchy proposal contract.
    /// @dev Owner-only because an incorrect binding could resolve the wrong evaluation.
    function setFutarchyProposal(uint256 proposalId, address futarchyProposal) external onlyOwner {
        futarchyProposalOf[proposalId] = futarchyProposal;
        emit FutarchyProposalBound(proposalId, futarchyProposal);
    }

    /// @notice Resolve `proposalId` (must be the current active evaluation) using the bound futarchy proposal + CTF payouts.
    /// Reverts if there is no active evaluation, mapping is missing, or futarchy is not resolved.
    function resolve(uint256 proposalId) external returns (bool accepted) {
        uint256 active = IFutarchyArbitrationLike(arbitrationContract).activeEvaluationProposalId();
        if (active == 0) revert NoActiveEvaluation();
        if (proposalId != active) revert WrongProposalId(active, proposalId);

        address futarchyProposal = futarchyProposalOf[proposalId];
        if (futarchyProposal == address(0)) revert MissingFutarchyProposal(proposalId);

        bytes32 conditionId = IFutarchyProposalLike(futarchyProposal).conditionId();

        uint256 denom = conditionalTokens.payoutDenominator(conditionId);
        if (denom == 0) revert FutarchyNotResolved(conditionId);

        uint256 yesNum = conditionalTokens.payoutNumerators(conditionId, 0);
        uint256 noNum = conditionalTokens.payoutNumerators(conditionId, 1);

        // Expected for binary CTF conditions: yesNum + noNum == denom.
        // We also require a strict winner (no tie).
        if (yesNum + noNum != denom) revert InvalidPayout(yesNum, noNum, denom);
        if (yesNum == noNum) revert InvalidPayout(yesNum, noNum, denom);

        accepted = yesNum > noNum;
        IFutarchyArbitrationLike(arbitrationContract).resolveActiveEvaluation(accepted);

        emit EvaluationResolved(proposalId, conditionId, accepted, yesNum, noNum, denom);
    }
}
