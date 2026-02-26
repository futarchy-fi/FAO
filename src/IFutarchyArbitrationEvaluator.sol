// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFutarchyArbitrationEvaluator
/// @notice Minimal interface for evaluator modules that can resolve arbitration proposals.
/// @dev Phase 4 introduces a ManualEvaluator that implements this interface.
interface IFutarchyArbitrationEvaluator {
    /// @notice The arbitration contract this evaluator is bound to.
    function arbitration() external view returns (address);

    /// @notice Resolve a proposal currently in evaluation.
    /// @dev Implementations should enforce authorization (e.g., owner-only) and/or
    /// evaluator-only hooks as appropriate.
    function resolve(uint256 proposalId) external returns (bool accepted);
}
