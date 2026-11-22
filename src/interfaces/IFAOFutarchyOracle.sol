// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice External verifiable randomness oracle for two-step randomized execution draws.
interface IFutarchyRandomnessSource {
    /// @notice Request a fresh verifiable random word bound to `context`.
    /// @param context Domain-separated commitment (`keccak256(abi.encode(resolver, proposal,
    /// questionId))`). @return requestId Non-zero identifier used to read fulfillment in Step 2.
    function requestRandomness(bytes32 context) external returns (bytes32 requestId);

    /// @notice Read whether `requestId` has been fulfilled and its verifiable random word.
    function readRandomness(bytes32 requestId)
        external
        view
        returns (bool fulfilled, bytes32 randomWord);
}

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
    /// @param marginTicks The proposal passes only if the YES average tick exceeds the NO average
    /// tick by more than this. One tick is 0.01% in price; 0 means YES only has to be above NO.
    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp,
        int24 marginTicks
    ) external;

    /// @notice Configure the Floor + 1/spread randomized NOOP policy for a bound proposal:
    ///         `p(NOOP)(s) = 1` for `s <= margin`, and `max(floor, scale / (scale + s - margin))`
    ///         for `s > margin`. Must be called in the same block as `bindProposal`, and requires
    ///         a configured `IFutarchyRandomnessSource` on the resolver.
    /// @param proposal Address of the bound FAOFutarchyProposal.
    /// @param noopFloorBps Minimum NOOP probability in bps (`1000` = 10%, `< 10000`).
    /// @param noopScaleTicks Hyperbolic scale `sigma` in UniV3 ticks (`100` ~= 1% price spread).
    function setNoopPolicy(address proposal, uint16 noopFloorBps, int24 noopScaleTicks) external;
}
