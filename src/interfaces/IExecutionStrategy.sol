// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/// @notice Compatibility shim for Snapshot X's `src/types.sol`, which imports
///         `src/interfaces/IExecutionStrategy.sol`.
/// @dev Snapshot X's canonical interface lives at `sx/interfaces/IExecutionStrategy.sol`.
///      We intentionally keep this interface empty/minimal to avoid import cycles.
interface IExecutionStrategy {}
