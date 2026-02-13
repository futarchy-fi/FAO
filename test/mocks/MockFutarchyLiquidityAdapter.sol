// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

/// @notice Minimal deterministic adapter for high-level tests.
///         Liquidity units are modeled as min(token0, token1) amounts.
contract MockFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

    uint128 public totalLiquidity;
    mapping(bytes32 => uint128) public liquidityByPair;
    uint128 public nextCompoundLiquidity;

    function setNextCompoundLiquidity(uint128 value) external {
        nextCompoundLiquidity = value;
    }

    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata
    ) external returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used) {
        bytes32 pairKey = keccak256(abi.encode(token0, token1));
        uint256 liq = amount0Desired < amount1Desired ? amount0Desired : amount1Desired;
        liquidityMinted = uint128(liq);
        amount0Used = liq;
        amount1Used = liq;

        if (amount0Used > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Used);
        }
        if (amount1Used > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Used);
        }

        liquidityByPair[pairKey] += liquidityMinted;
        totalLiquidity += liquidityMinted;
    }

    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        bytes32 pairKey = keccak256(abi.encode(token0, token1));
        require(liquidity <= liquidityByPair[pairKey], "insufficient liquidity");
        liquidityByPair[pairKey] -= liquidity;
        totalLiquidity -= liquidity;

        amount0Out = liquidity;
        amount1Out = liquidity;
        if (amount0Out > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0Out);
        }
        if (amount1Out > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1Out);
        }
    }

    function compoundPosition(address, address, bytes calldata)
        external
        returns (uint128 liquidityAdded)
    {
        liquidityAdded = nextCompoundLiquidity;
        if (liquidityAdded > 0) {
            totalLiquidity += liquidityAdded;
            nextCompoundLiquidity = 0;
        }
    }
}
