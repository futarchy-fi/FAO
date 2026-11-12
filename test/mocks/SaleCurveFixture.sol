// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FaoSaleCurve} from "../../src/FaoSaleCurve.sol";

abstract contract SaleCurveFixture is Test {
    /// @dev Deploys a plain linear curve for the vault this contract creates next.
    function _newSaleCurve(uint256 initialPrice, uint256 slope) internal returns (address) {
        address vault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        return address(new FaoSaleCurve(vault, initialPrice, slope, 0, 0));
    }
}
