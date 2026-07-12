// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FaoToken} from "../src/FaoToken.sol";

contract FaoTokenTest is Test {
    address internal vault = makeAddr("vault");
    address internal holder = makeAddr("holder");

    FaoToken internal token;

    function setUp() public {
        token = new FaoToken("Example FAO", "EFAO", vault, 100 ether);
    }

    function testConfiguration() public view {
        assertEq(token.name(), "Example FAO");
        assertEq(token.symbol(), "EFAO");
        assertEq(token.vault(), vault);
        assertEq(token.maxSupply(), 100 ether);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.mintingFinished());
    }

    function testRejectsInvalidConfiguration() public {
        vm.expectRevert(FaoToken.InvalidVault.selector);
        new FaoToken("Example FAO", "EFAO", address(0), 100 ether);

        vm.expectRevert(FaoToken.InvalidMaxSupply.selector);
        new FaoToken("Example FAO", "EFAO", vault, 0);
    }

    function testOnlyVaultCanMintAndBurn() public {
        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.mint(holder, 1 ether);

        vm.prank(vault);
        token.mint(holder, 1 ether);

        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.burnFromVault(holder, 1 ether);

        vm.expectRevert(FaoToken.OnlyVault.selector);
        token.finishMinting();
    }

    function testSupplyCanNeverExceedCap() public {
        vm.prank(vault);
        token.mint(holder, 100 ether);

        vm.expectRevert(FaoToken.MaxSupplyExceeded.selector);
        vm.prank(vault);
        token.mint(holder, 1);

        assertEq(token.totalSupply(), token.maxSupply());
    }

    function testFinishedMintingCannotReopenAfterBurn() public {
        vm.prank(vault);
        token.mint(holder, 100 ether);
        assertEq(token.allowance(holder, vault), 0);

        vm.prank(vault);
        token.finishMinting();

        vm.prank(vault);
        token.burnFromVault(holder, 40 ether);

        vm.expectRevert(FaoToken.MintingFinished.selector);
        vm.prank(vault);
        token.mint(holder, 40 ether);

        assertTrue(token.mintingFinished());
        assertEq(token.balanceOf(holder), 60 ether);
        assertEq(token.totalSupply(), 60 ether);
        assertEq(token.allowance(holder, vault), 0);
    }
}
