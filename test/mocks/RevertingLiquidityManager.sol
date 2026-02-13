// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityManager} from "../../src/interfaces/IFutarchyLiquidityManager.sol";

contract RevertingLiquidityManager is IFutarchyLiquidityManager {
    function initializeFromSale(uint256, bytes calldata)
        external
        payable
        returns (uint128 liquidityMinted)
    {
        liquidityMinted = 0;
        revert("LP init failed");
    }
}
