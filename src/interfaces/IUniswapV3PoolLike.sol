// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of IUniswapV3Pool used by the FAO stack.
interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);

    /// @notice slot0 packs (sqrtPriceX96, tick, observationIndex, ..., unlocked).
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function initialize(uint160 sqrtPriceX96) external;

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    /// @notice Returns cumulative observations over the given seconds-ago points.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    /// @notice Mint a position. Caller (typically the orchestrator's adapter) must
    /// have implemented IUniswapV3MintCallback to transfer the required token amounts.
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);
}
