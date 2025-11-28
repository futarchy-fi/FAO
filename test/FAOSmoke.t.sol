// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { FAOToken } from "../src/FAOToken.sol";
import { FAOSale } from "../src/FAOSale.sol";

contract FAOSmokeTest is Test {
    FAOToken token;
    FAOSale sale;

    function setUp() public {
        // for tests, this contract is admin
        token = new FAOToken(address(this));
        sale  = new FAOSale(
            token,
            address(this),   // admin
            address(0),
            address(0)
        );

        token.grantRole(token.MINTER_ROLE(), address(sale));
    }

    function test_buy_one_token() public {
        sale.startSale();

        address buyer = address(0xBEEF);

        // Give the buyer enough ETH to pay for 1 token (and more, just to be safe)
        vm.deal(buyer, 1 ether);

        vm.prank(buyer);
        sale.buy{value: 1e14}(1); // 1 FAO @ 0.0001 ETH

        assertEq(token.balanceOf(buyer), 1e18);
    }
}
