// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyConditionalRouter {
    function getWinningOutcomes(bytes32 conditionId) external view returns (bool[] memory);

    function splitPosition(address proposal, address collateralToken, uint256 amount) external;

    function mergePositions(address proposal, address collateralToken, uint256 amount) external;

    function redeemPositions(address proposal, address collateralToken, uint256 amount) external;
}
