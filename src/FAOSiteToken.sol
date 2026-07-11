// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply company token for the first FAO-controlled site market.
contract FAOSiteToken is ERC20 {
    error InvalidInitialHolder();
    error InvalidInitialSupply();

    constructor(address initialHolder, uint256 initialSupply) ERC20("FAO Site", "FAOS") {
        if (initialHolder == address(0)) revert InvalidInitialHolder();
        if (initialSupply == 0) revert InvalidInitialSupply();
        _mint(initialHolder, initialSupply);
    }
}
