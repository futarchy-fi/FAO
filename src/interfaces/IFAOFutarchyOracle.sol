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

/// @notice Extension of IFAOFutarchyOracle for resolvers that need pool/anchor binding
/// at proposal promotion time (e.g. UniV3 TWAP resolver).
interface IFAOFutarchyTwapResolver is IFAOFutarchyOracle {
    /// @notice Bind a proposal to its conditional pools and anchor timestamp.
    /// Called by the orchestrator atomically inside createOfficialProposalAndMigrate.
    /// @param proposal Address of the FAOFutarchyProposal.
    /// @param yesPool YES_company / YES_currency UniV3 pool.
    /// @param noPool NO_company / NO_currency UniV3 pool.
    /// @param companyToken Address of the company-side base token (FAO).
    /// @param currencyToken Address of the currency-side quote token (WETH).
    /// @param anchorTimestamp t_promote; the TWAP window is anchored relative to this.
    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp
    ) external;
}
