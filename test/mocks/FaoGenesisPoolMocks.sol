// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

interface IFaoGenesisCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external;
}

contract FaoGenesisFactoryMock is IUniswapV3FactoryLike {
    mapping(bytes32 key => address pool) private pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(address, address, uint24) external pure returns (address) {
        revert("test config must install the predicted pool");
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

/// @dev Storage-backed so its runtime can be etched at the canonical CREATE2 address.
contract FaoGenesisPoolMock is IUniswapV3PoolLike {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    uint16 public observationCardinalityNext;
    bool public hostileLiquidity;

    function configure(
        address tokenA,
        address tokenB,
        uint24 fee_,
        uint160 sqrtPriceX96_,
        bool hostileLiquidity_
    ) external {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        sqrtPriceX96 = sqrtPriceX96_;
        hostileLiquidity = hostileLiquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, observationCardinalityNext, 0, true);
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "initialized");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function increaseObservationCardinalityNext(uint16 requested) external {
        if (requested > observationCardinalityNext) observationCardinalityNext = requested;
    }

    function swap(address recipient, bool, int256, uint160 limit, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(recipient == msg.sender, "receipt recipient");
        if (hostileLiquidity) {
            IFaoGenesisCallback(msg.sender).uniswapV3SwapCallback(1, -1, "");
            return (1, -1);
        }
        IFaoGenesisCallback(msg.sender).uniswapV3SwapCallback(0, 0, "");
        sqrtPriceX96 = limit;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (int56[] memory ticks, uint160[] memory secondsPerLiquidity)
    {
        ticks = new int56[](secondsAgos.length);
        secondsPerLiquidity = new uint160[](secondsAgos.length);
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}
