// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";

/// @custom:spec INV-TOKEN-001 — totalSupply changes only via mint/burn.
/// Halmos-checkable symbolic tests for the invariants listed in
/// `audit/specs/INVARIANTS.md`.
contract GenericFutarchyTokenSymbolic is Test {
    GenericFutarchyToken internal token;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant HOLDER = address(0xB0B);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        token = new GenericFutarchyToken("Sym", "SYM", ADMIN, 0);
    }

    /// @custom:spec INV-TOKEN-001 — totalSupply tracks mint minus burn. See
    /// audit/specs/INVARIANTS.md. `transfer` is included to prove ordinary ERC20 movement leaves
    /// supply unchanged.
    function check_INV_TOKEN_001_supplyTracksHandlerOps(
        uint16 mintUnits,
        uint16 transferUnits,
        uint16 burnUnits
    ) public {
        vm.assume(mintUnits >= 1 && mintUnits <= 100);
        vm.assume(transferUnits >= 1 && transferUnits <= 100);
        vm.assume(burnUnits >= 1 && burnUnits <= 100);
        vm.assume(transferUnits <= mintUnits);
        vm.assume(burnUnits <= transferUnits);

        uint256 minted = uint256(mintUnits) * 1e18;
        uint256 transferred = uint256(transferUnits) * 1e18;
        uint256 burned = uint256(burnUnits) * 1e18;

        uint256 expectedSupply;
        assertEq(token.totalSupply(), expectedSupply);

        vm.prank(ADMIN);
        token.mint(HOLDER, minted);
        expectedSupply += minted;
        assertEq(token.totalSupply(), expectedSupply);

        vm.prank(HOLDER);
        token.transfer(RECIPIENT, transferred);
        assertEq(token.totalSupply(), expectedSupply);

        vm.prank(RECIPIENT);
        token.burn(burned);
        expectedSupply -= burned;
        assertEq(token.totalSupply(), expectedSupply);
    }
}
