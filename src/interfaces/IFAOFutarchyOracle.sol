// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Oracle interface used by FAOFutarchyProposal.resolve().
/// @dev The concrete oracle in v0 is FutarchyTwapResolver, which reads UniV3 TWAP and
/// reports payouts to the Conditional Tokens Framework.
interface IFAOFutarchyOracle {
    /// @notice Resolve a proposal by computing the futarchy signal and reporting payouts to CTF.
    /// @param proposal The address of the FAOFutarchyProposal to resolve.
    function resolve(address proposal) external;
}
