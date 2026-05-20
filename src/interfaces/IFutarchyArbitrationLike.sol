// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal subset of FutarchyArbitration used by FAOCreateAndBond.
/// @dev Only exposes the methods the bridge actually calls. Full ABI lives in
/// src/FutarchyArbitration.sol.
interface IFutarchyArbitrationLike {
    /// @notice Returns the base graduation threshold (WETH, 18 decimals).
    function baseX() external view returns (uint256);

    /// @notice Create an arbitration proposal with an explicit id.
    /// @dev Reverts if `proposalId` already exists or `minActivationBond == 0`.
    function createProposalWithId(uint256 proposalId, uint256 minActivationBond)
        external
        returns (uint256);
}
