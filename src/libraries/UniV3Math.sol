// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title UniV3Math
/// @notice Minimal inlined slices of Uniswap v3 core/periphery math used by the FAO
/// `UniswapV3LiquidityAdapter`. Only the helpers required to (a) clamp full-range
/// ticks to a pool's tick spacing, (b) translate ticks <-> sqrtPriceX96, and (c)
/// derive the liquidity to mint given desired (amount0, amount1) at the current
/// price are included.
///
/// Sources (verbatim formulas, lightly re-typed for Solidity 0.8 unchecked
/// semantics):
///   * `TickMath.getSqrtRatioAtTick` and the `MIN_TICK`/`MAX_TICK` constants are
///     adapted from Uniswap v3-core TickMath library.
///   * `FullMath.mulDiv` is adapted from Uniswap v3-core FullMath library.
///   * `LiquidityAmounts.getLiquidityForAmount0/1/Amounts` is adapted from
///     Uniswap v3-periphery LiquidityAmounts library.
///
/// We deliberately do NOT pull the full periphery package as a dependency — the
/// adapter only needs <300 LoC of math and the periphery has heavy transitive
/// dependencies that conflict with our pinned OpenZeppelin v4.x stack.
library UniV3Math {
    // ─── constants ─────────────────────────────────────────────────────────

    /// @dev Minimum tick supported by UniV3 (== -887272 in canonical core).
    int24 internal constant MIN_TICK = -887272;
    /// @dev Maximum tick supported by UniV3 (== 887272 in canonical core).
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev getSqrtRatioAtTick(MIN_TICK).
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    /// @dev getSqrtRatioAtTick(MAX_TICK).
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    // ─── full-range tick helpers ───────────────────────────────────────────

    /// @notice Snap MIN_TICK upward to the next valid initialized tick for the
    /// given tick-spacing. (UniV3 pools require ticks to be multiples of their
    /// `tickSpacing`.)
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MIN_TICK / tickSpacing) * tickSpacing;
    }

    /// @notice Snap MAX_TICK downward to the previous valid initialized tick.
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MAX_TICK / tickSpacing) * tickSpacing;
    }

    // ─── FullMath.mulDiv (no-overflow 512-bit multiplication then divide) ──

    /// @dev mulDiv(a, b, denominator) = floor(a*b/denominator), full precision,
    /// reverts on overflow or division by zero.
    /// Verbatim from Uniswap v3-core, with Solidity 0.8 unchecked blocks where
    /// the original used Solidity 0.7 implicit overflow semantics.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(denominator > 0, "FullMath: division by zero");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }
            require(denominator > prod1, "FullMath: overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
            return result;
        }
    }

    // ─── TickMath.getSqrtRatioAtTick (Q64.96 sqrt prices) ──────────────────

    /// @dev Calculates sqrt(1.0001^tick) * 2^96.
    /// Verbatim from Uniswap v3-core, adapted to 0.8.x where shifts may differ.
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= uint256(int256(MAX_TICK)), "T");

            uint256 ratio = absTick & 0x1 != 0
                ? 0xfffcb933bd6fad37aa2d162d1a594001
                : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // The shift converts from 128-bit Q128.128 to Q64.96; rounding-up
            // the next bit ensures `getTickAtSqrtRatio(getSqrtRatioAtTick(t)) == t`.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    // ─── LiquidityAmounts helpers ──────────────────────────────────────────

    /// @notice Liquidity producible by `amount0` deposited between sqrtA and sqrtB.
    function getLiquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = mulDiv(uint256(sqrtA), uint256(sqrtB), 1 << 96);
        return _toUint128(mulDiv(amount0, intermediate, uint256(sqrtB) - uint256(sqrtA)));
    }

    /// @notice Liquidity producible by `amount1` deposited between sqrtA and sqrtB.
    function getLiquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _toUint128(mulDiv(amount1, 1 << 96, uint256(sqrtB) - uint256(sqrtA)));
    }

    /// @notice Compute liquidity for a position given amounts and current price.
    /// Behaviour matches `LiquidityAmounts.getLiquidityForAmounts`:
    ///   - if current < lower → 100% token0 → use amount0
    ///   - if current > upper → 100% token1 → use amount1
    ///   - in range → liquidity is the MIN of the two single-sided computations
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtLowerX96 > sqrtUpperX96) {
            (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        }
        if (sqrtPriceX96 <= sqrtLowerX96) {
            liquidity = getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0);
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            uint128 l0 = getLiquidityForAmount0(sqrtPriceX96, sqrtUpperX96, amount0);
            uint128 l1 = getLiquidityForAmount1(sqrtLowerX96, sqrtPriceX96, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount1);
        }
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        require(x <= type(uint128).max, "uint128 overflow");
        return uint128(x);
    }
}
