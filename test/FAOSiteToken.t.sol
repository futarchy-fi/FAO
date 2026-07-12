// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOSiteToken} from "../src/FAOSiteToken.sol";

contract FAOSiteTokenTest is Test {
    function testFixedSupplyIsMintedOnce() public {
        address holder = makeAddr("holder");
        FAOSiteToken token = new FAOSiteToken(holder, 1_000_000 ether);

        assertEq(token.name(), "FAO Site");
        assertEq(token.symbol(), "FAOS");
        assertEq(token.totalSupply(), 1_000_000 ether);
        assertEq(token.balanceOf(holder), 1_000_000 ether);
    }

    function testRejectsInvalidGenesis() public {
        vm.expectRevert(FAOSiteToken.InvalidInitialHolder.selector);
        new FAOSiteToken(address(0), 1 ether);

        vm.expectRevert(FAOSiteToken.InvalidInitialSupply.selector);
        new FAOSiteToken(address(this), 0);
    }
}
