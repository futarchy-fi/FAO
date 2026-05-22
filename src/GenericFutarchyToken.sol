// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title GenericFutarchyToken
/// @notice ERC20 governance token deployed per-instance by FutarchyRegistry.
///         Mirrors the FAOToken pattern (ERC20 + Burnable + AccessControl) but
///         lets the registry pick name, symbol, admin, and initial supply at
///         creation time.
/// @dev    The constructor grants both DEFAULT_ADMIN_ROLE and MINTER_ROLE to
///         `admin`, then mints `initialSupply` to `admin` so the creator has
///         full custody of the genesis allocation. Admin can grant MINTER_ROLE
///         to additional accounts later (or renounce both roles to lock supply).
contract GenericFutarchyToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(string memory name_, string memory symbol_, address admin, uint256 initialSupply)
        ERC20(name_, symbol_)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        if (initialSupply != 0) {
            _mint(admin, initialSupply);
        }
    }

    /// @notice Mint new tokens.
    /// @dev Caller must have the MINTER_ROLE.
    /// @custom:spec INV-TOKEN-001 — totalSupply changes only via mint/burn. See audit/specs/INVARIANTS.md.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
