// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal subset of FAOFutarchyFactory used by FAOCreateAndBond.
/// @dev Mirrors the on-chain ABI exposed by src/FAOFutarchyFactory.sol so the bridge
/// can call it without depending on the full implementation (and so tests can mock it).
interface IFAOFutarchyFactoryLike {
    struct CreateProposalParams {
        string marketName;
        string description;
        address collateralToken1;
        address collateralToken2;
    }

    function createProposal(CreateProposalParams memory params) external returns (address);

    function marketsCount() external view returns (uint256);
}
