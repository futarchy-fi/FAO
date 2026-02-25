// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockAlgebraFactoryLike} from "./MockAlgebraFactoryLike.sol";
import {MockAlgebraPoolLike} from "./MockAlgebraPoolLike.sol";

/// @notice Minimal position manager mock supporting pool creation/initialization.
contract MockSwaprAlgebraPositionManager {
    MockAlgebraFactoryLike public immutable factory;

    constructor(MockAlgebraFactoryLike factory_) {
        factory = factory_;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint160 sqrtPriceX96
    ) external returns (address pool) {
        pool = factory.poolByPair(token0, token1);
        if (pool != address(0)) return pool;

        pool = address(new MockAlgebraPoolLike(token0, token1));
        MockAlgebraPoolLike(pool).setSqrtPriceX96(sqrtPriceX96);
        // Tick is left at its default (0) which matches SQRT_PRICE_1_1 in tests.
        factory.setPool(token0, token1, pool);
    }
}

