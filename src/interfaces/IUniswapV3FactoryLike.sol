// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of UniswapV3Factory used by the FAO stack.
interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}
