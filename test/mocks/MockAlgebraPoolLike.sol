// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraPoolLike} from "../../src/interfaces/IAlgebraPoolLike.sol";

/// @notice Minimal mock Algebra pool for unit tests (tick + token order).
contract MockAlgebraPoolLike is IAlgebraPoolLike {
    address public immutable override token0;
    address public immutable override token1;

    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public fee;
    uint16 public timepointIndex;
    uint8 public communityFeeToken0;
    uint8 public communityFeeToken1;
    bool public unlocked;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
        unlocked = true;
    }

    function setTick(int24 newTick) external {
        tick = newTick;
    }

    function setSqrtPriceX96(uint160 newSqrtPriceX96) external {
        sqrtPriceX96 = newSqrtPriceX96;
    }

    function globalState()
        external
        view
        returns (
            uint160 _sqrtPriceX96,
            int24 _tick,
            uint16 _fee,
            uint16 _timepointIndex,
            uint8 _communityFeeToken0,
            uint8 _communityFeeToken1,
            bool _unlocked
        )
    {
        return (
            sqrtPriceX96,
            tick,
            fee,
            timepointIndex,
            communityFeeToken0,
            communityFeeToken1,
            unlocked
        );
    }
}

