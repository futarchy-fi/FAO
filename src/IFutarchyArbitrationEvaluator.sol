// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFutarchyArbitrationEvaluator
/// @notice Minimal interface for evaluator modules that can resolve arbitration proposals.
interface IFutarchyArbitrationEvaluator {
    /// @notice The arbitration contract this evaluator is bound to.
    function arbitration() external view returns (address);

    /// @notice Resolve a proposal currently in evaluation.
    /// @dev Implementations should resolve from the configured automated market pipeline.
    function resolve(uint256 proposalId) external returns (bool accepted);
}
