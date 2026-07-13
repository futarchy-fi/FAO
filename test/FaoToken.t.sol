// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FaoToken} from "../src/FaoToken.sol";

contract FaoTokenVaultMock {
    error UnauthorizedBurn();

    FaoToken public immutable token;
    address private authorizedAccount;
    uint256 private authorizedAmount;

    constructor() {
        token = new FaoToken("Example FAO", "EFAO", address(this), 100 ether);
    }

    function mint(address account, uint256 amount) external {
        token.mint(account, amount);
    }

    function finishMinting() external {
        token.finishMinting();
    }

    function burn(address account, uint256 amount) external {
        authorizedAccount = account;
        authorizedAmount = amount;
        token.burnFromVault(account, amount);
    }

    function burnWithoutAuthorization(address account, uint256 amount) external {
        token.burnFromVault(account, amount);
    }

    function consumeTokenBurnAuthorization(address account, uint256 amount) external {
        if (
            msg.sender != address(token) || account != authorizedAccount
                || amount != authorizedAmount || amount == 0
        ) revert UnauthorizedBurn();
        delete authorizedAccount;
        delete authorizedAmount;
    }
}

contract FaoTokenTest is Test {
    address internal holder = makeAddr("holder");

    FaoTokenVaultMock internal vault;
    FaoToken internal token;

    function setUp() public {
        vault = new FaoTokenVaultMock();
        token = vault.token();
    }

    function testConfiguration() public view {
        assertEq(token.name(), "Example FAO");
        assertEq(token.symbol(), "EFAO");
        assertEq(token.vault(), address(vault));
        assertEq(token.maxSupply(), 100 ether);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.mintingFinished());
    }

    function testRejectsInvalidConfiguration() public {
        vm.expectRevert(FaoToken.InvalidVault.selector);
        new FaoToken("Example FAO", "EFAO", address(0), 100 ether);

        vm.expectRevert(FaoToken.InvalidMaxSupply.selector);
        new FaoToken("Example FAO", "EFAO", address(vault), 0);
    }

    function testOnlyVaultCanMintAndBurn() public {
        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.mint(holder, 1 ether);

        vault.mint(holder, 1 ether);

        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.burnFromVault(holder, 1 ether);

        vm.expectRevert(FaoTokenVaultMock.UnauthorizedBurn.selector);
        vault.burnWithoutAuthorization(holder, 1 ether);

        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.finishMinting();
    }

    function testSupplyCanNeverExceedCap() public {
        vault.mint(holder, 100 ether);

        vm.expectRevert(FaoToken.MaxSupplyExceeded.selector);
        vm.prank(address(vault));
        token.mint(holder, 1);

        assertEq(token.totalSupply(), token.maxSupply());
    }

    function testFinishedMintingCannotReopenAfterBurn() public {
        vm.prank(address(vault));
        token.mint(holder, 100 ether);
        assertEq(token.allowance(holder, address(vault)), 0);

        vault.finishMinting();

        vault.burn(holder, 40 ether);

        vm.expectRevert(FaoToken.MintingFinished.selector);
        vm.prank(address(vault));
        token.mint(holder, 40 ether);

        assertTrue(token.mintingFinished());
        assertEq(token.balanceOf(holder), 60 ether);
        assertEq(token.totalSupply(), 60 ether);
        assertEq(token.allowance(holder, address(vault)), 0);
    }
}
