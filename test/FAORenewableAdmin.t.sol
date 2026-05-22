// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAORenewableAdmin} from "../src/FAORenewableAdmin.sol";

contract RenewableAdminHarness is FAORenewableAdmin {
    constructor(address admin, uint256 gracePeriod) FAORenewableAdmin(gracePeriod) {
        _grantRenewableDefaultAdmin(admin);
    }

    function adminOnlyPing() external view onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        return 1;
    }
}

contract FAORenewableAdminTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant CALLER = address(0xB0B);
    uint256 internal constant GRACE_PERIOD = 7 days;

    RenewableAdminHarness internal target;

    function setUp() public {
        target = new RenewableAdminHarness(ADMIN, GRACE_PERIOD);
    }

    function test_constructorGrantsRenewableDefaultAdmin() public {
        assertTrue(target.hasRole(target.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertEq(target.defaultAdminRenewedAt(ADMIN), block.timestamp);
        assertEq(target.ADMIN_RENEWAL_GRACE_PERIOD(), GRACE_PERIOD);
    }

    function test_renounceIfStaleRejectsFreshAdmin() public {
        uint256 staleAt = target.defaultAdminRenewedAt(ADMIN) + GRACE_PERIOD;

        vm.warp(staleAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FAORenewableAdmin.DefaultAdminFresh.selector, ADMIN, staleAt)
        );
        target.renounceIfStale(ADMIN);

        assertTrue(target.hasRole(target.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_anyoneCanRenounceStaleDefaultAdmin() public {
        vm.warp(target.defaultAdminRenewedAt(ADMIN) + GRACE_PERIOD);

        vm.prank(CALLER);
        target.renounceIfStale(ADMIN);

        assertFalse(target.hasRole(target.DEFAULT_ADMIN_ROLE(), ADMIN));
    }

    function test_adminRenewalExtendsGraceDeadline() public {
        vm.warp(target.defaultAdminRenewedAt(ADMIN) + GRACE_PERIOD - 1);

        vm.prank(ADMIN);
        target.renewDefaultAdmin();
        uint256 staleAt = target.defaultAdminRenewedAt(ADMIN) + GRACE_PERIOD;

        vm.warp(staleAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(FAORenewableAdmin.DefaultAdminFresh.selector, ADMIN, staleAt)
        );
        target.renounceIfStale(ADMIN);

        vm.warp(staleAt);
        vm.prank(CALLER);
        target.renounceIfStale(ADMIN);

        assertFalse(target.hasRole(target.DEFAULT_ADMIN_ROLE(), ADMIN));
    }
}
