// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockERC20Symbol {
    string internal _symbol;

    constructor(string memory sym) {
        _symbol = sym;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }
}
