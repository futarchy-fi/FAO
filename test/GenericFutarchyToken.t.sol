// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";

contract GenericFutarchyTokenTest is Test {
    GenericFutarchyToken internal token;
    address internal constant ADMIN = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    address internal constant MINTEE = address(0xCAFE);
    uint256 internal constant INITIAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new GenericFutarchyToken("MyOrg Token", "MOT", ADMIN, INITIAL_SUPPLY);
    }

    function test_constructor_mintsSupplyToAdmin() public view {
        assertEq(token.name(), "MyOrg Token");
        assertEq(token.symbol(), "MOT");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(ADMIN), INITIAL_SUPPLY);
    }

    function test_constructor_grantsBothRolesToAdmin() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(token.hasRole(token.MINTER_ROLE(), ADMIN));
    }

    function test_constructor_zeroSupply_mintsNothing() public {
        GenericFutarchyToken t = new GenericFutarchyToken("Zero", "Z", ADMIN, 0);
        assertEq(t.totalSupply(), 0);
        assertEq(t.balanceOf(ADMIN), 0);
        // Admin still has both roles even if supply is zero.
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertTrue(t.hasRole(t.MINTER_ROLE(), ADMIN));
    }

    function test_admin_canMintMore() public {
        uint256 extra = 500 ether;
        vm.prank(ADMIN);
        token.mint(MINTEE, extra);

        assertEq(token.balanceOf(MINTEE), extra);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + extra);
    }

    function test_nonAdmin_cannotMint() public {
        // OZ v4 AccessControl reverts with a string error message.
        vm.expectRevert();
        vm.prank(ALICE);
        token.mint(MINTEE, 1 ether);
    }

    function test_admin_canGrantMinterRoleToOther() public {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(ADMIN);
        token.grantRole(minterRole, ALICE);

        vm.prank(ALICE);
        token.mint(MINTEE, 42 ether);
        assertEq(token.balanceOf(MINTEE), 42 ether);
    }

    function test_burnable_holderCanBurn() public {
        // Admin holds INITIAL_SUPPLY; burn half.
        uint256 burnAmt = INITIAL_SUPPLY / 2;
        vm.prank(ADMIN);
        token.burn(burnAmt);
        assertEq(token.balanceOf(ADMIN), INITIAL_SUPPLY - burnAmt);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmt);
    }
}
