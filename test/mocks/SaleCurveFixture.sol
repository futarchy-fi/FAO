// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FaoSaleCurve} from "../../src/FaoSaleCurve.sol";

/// @dev Deploys a curve and binds it to `vault`, as a deployer does before genesis.
function newBoundCurve(
    address vault,
    uint256 initialPrice,
    uint256 slope,
    uint64 fixedPriceEnd,
    uint256 fixedMinimum
) returns (FaoSaleCurve curve) {
    curve = new FaoSaleCurve(initialPrice, slope, fixedPriceEnd, fixedMinimum);
    curve.bind(vault);
}

abstract contract SaleCurveFixture is Test {
    /// @dev Deploys a plain linear curve for the vault this contract creates next.
    function _newSaleCurve(uint256 initialPrice, uint256 slope) internal returns (address) {
        address vault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        return address(newBoundCurve(vault, initialPrice, slope, 0, 0));
    }
}
