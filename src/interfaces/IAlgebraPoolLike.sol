// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Algebra pool interface for reading token order + current tick.
interface IAlgebraPoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function globalState()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 fee,
            uint16 timepointIndex,
            uint8 communityFeeToken0,
            uint8 communityFeeToken1,
            bool unlocked
        );
}

