// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IFaoTokenBurnAuthorizer {
    function consumeTokenBurnAuthorization(address account, uint256 amount) external;
}

/// @notice FAO token. The immutable genesis vault controls sale issuance and ragequit burns.
/// Two further issuers are fixed at construction and can never be changed or removed:
/// - `optionIssuer` mints when a team option is exercised (the strike is paid to the treasury);
/// - `shortIssuer` mints against locked collateral and burns on close.
/// Tokens minted by the short issuer and not yet closed or forfeited are tracked in
/// `shortOutstanding`, which the vault excludes from the ragequit denominator.
contract FaoToken is ERC20 {
    error InvalidVault();
    error InvalidMaxSupply();
    error OnlyVault();
    error OnlyOptionIssuer();
    error OnlyShortIssuer();
    error MintingFinished();
    error MaxSupplyExceeded();

    address public immutable vault;
    /// @notice Cap on vault (genesis) issuance only. Option and short issuance is bounded by the
    /// issuers' own immutable rules.
    uint256 public immutable maxSupply;
    address public immutable optionIssuer;
    address public immutable shortIssuer;

    bool public mintingFinished;
    uint256 public vaultMinted;
    uint256 public optionMinted;
    uint256 public shortOutstanding;

    constructor(
        string memory name_,
        string memory symbol_,
        address vault_,
        uint256 maxSupply_,
        address optionIssuer_,
        address shortIssuer_
    ) ERC20(name_, symbol_) {
        if (vault_ == address(0)) revert InvalidVault();
        if (maxSupply_ == 0) revert InvalidMaxSupply();

        vault = vault_;
        maxSupply = maxSupply_;
        optionIssuer = optionIssuer_;
        shortIssuer = shortIssuer_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        if (mintingFinished) revert MintingFinished();
        if (amount > maxSupply - vaultMinted) revert MaxSupplyExceeded();
        vaultMinted += amount;
        _mint(to, amount);
    }

    function finishMinting() external {
        if (msg.sender != vault) revert OnlyVault();
        mintingFinished = true;
    }

    /// @dev The immutable vault burns only the ragequitting caller's tokens.
    function burnFromVault(address account, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        IFaoTokenBurnAuthorizer(vault).consumeTokenBurnAuthorization(account, amount);
        _burn(account, amount);
    }

    function issueOption(address to, uint256 amount) external {
        if (msg.sender != optionIssuer) revert OnlyOptionIssuer();
        optionMinted += amount;
        _mint(to, amount);
    }

    function issueShort(address to, uint256 amount) external {
        if (msg.sender != shortIssuer) revert OnlyShortIssuer();
        shortOutstanding += amount;
        _mint(to, amount);
    }

    /// @dev Burns returned tokens held by the short issuer itself.
    function closeShort(uint256 amount) external {
        if (msg.sender != shortIssuer) revert OnlyShortIssuer();
        shortOutstanding -= amount;
        _burn(msg.sender, amount);
    }

    /// @dev The position was abandoned: its tokens stay in circulation as ordinary supply.
    function forfeitShort(uint256 amount) external {
        if (msg.sender != shortIssuer) revert OnlyShortIssuer();
        shortOutstanding -= amount;
    }
}
