// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Futarchy Autonomous Optimizer Token (FAO)
/// @notice Standard ERC20 with burn support and controlled minting role.
contract FAOToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("Futarchy Autonomous Optimizer", "FAO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint new FAO tokens.
    /// @dev Caller must have the MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
