// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyLiquidityManager {
    function initializeFromSale(uint256 faoAmount, bytes calldata spotAddData)
        external
        payable
        returns (uint128 liquidityMinted);
}
