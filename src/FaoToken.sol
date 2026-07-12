// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Capped FAO token whose immutable genesis vault controls issuance and ragequit burns.
contract FaoToken is ERC20 {
    error InvalidVault();
    error InvalidMaxSupply();
    error OnlyVault();
    error MintingFinished();
    error MaxSupplyExceeded();

    address public immutable vault;
    uint256 public immutable maxSupply;
    bool public mintingFinished;

    constructor(string memory name_, string memory symbol_, address vault_, uint256 maxSupply_)
        ERC20(name_, symbol_)
    {
        if (vault_ == address(0)) revert InvalidVault();
        if (maxSupply_ == 0) revert InvalidMaxSupply();

        vault = vault_;
        maxSupply = maxSupply_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        if (mintingFinished) revert MintingFinished();
        if (amount > maxSupply - totalSupply()) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    function finishMinting() external {
        if (msg.sender != vault) revert OnlyVault();
        mintingFinished = true;
    }

    /// @dev The immutable vault burns only the ragequitting caller's tokens.
    function burnFromVault(address account, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        _burn(account, amount);
    }
}
