// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOTimelock} from "../src/FAOTimelock.sol";

contract TimelockTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract FAOTimelockTest is Test {
    address internal constant MULTISIG = address(0x51AFE);
    address internal constant EXECUTOR = address(0xE11EC);
    bytes32 internal constant PREDECESSOR = bytes32(0);
    bytes32 internal constant SALT = keccak256("FAO_TIMELOCK_TEST");

    FAOTimelock internal timelock;
    TimelockTarget internal target;

    function setUp() public {
        timelock = new FAOTimelock(MULTISIG);
        target = new TimelockTarget();
        vm.warp(100);
    }

    function test_constructor_usesMainnetDelayAndMultisigRoles() public view {
        assertEq(timelock.getMinDelay(), timelock.MIN_DELAY_MAINNET());
        assertEq(timelock.MIN_DELAY_MAINNET(), 1 days);
        assertEq(timelock.MIN_DELAY_STAGING(), 1 hours);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), MULTISIG));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), MULTISIG));
        assertTrue(timelock.hasRole(timelock.TIMELOCK_ADMIN_ROLE(), MULTISIG));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    function test_constructor_revertsOnZeroMultisig() public {
        vm.expectRevert(FAOTimelock.ZeroMultisig.selector);
        new FAOTimelock(address(0));
    }

    function test_scheduleRejectsDelayBelowMainnetMinimum() public {
        bytes memory payload = abi.encodeCall(TimelockTarget.setValue, (1));
        uint256 delay = timelock.MIN_DELAY_MAINNET();

        vm.expectRevert("TimelockController: insufficient delay");
        vm.prank(MULTISIG);
        timelock.schedule(address(target), 0, payload, PREDECESSOR, SALT, delay - 1);
    }

    function test_executeRequiresQueuedDelayToPass() public {
        bytes memory payload = abi.encodeCall(TimelockTarget.setValue, (42));
        uint256 delay = timelock.MIN_DELAY_MAINNET();

        vm.prank(MULTISIG);
        timelock.schedule(address(target), 0, payload, PREDECESSOR, SALT, delay);

        vm.expectRevert("TimelockController: operation is not ready");
        vm.prank(EXECUTOR);
        timelock.execute(address(target), 0, payload, PREDECESSOR, SALT);

        vm.warp(block.timestamp + delay - 1);
        vm.expectRevert("TimelockController: operation is not ready");
        vm.prank(EXECUTOR);
        timelock.execute(address(target), 0, payload, PREDECESSOR, SALT);

        vm.warp(block.timestamp + 1);
        vm.prank(EXECUTOR);
        timelock.execute(address(target), 0, payload, PREDECESSOR, SALT);

        assertEq(target.value(), 42);
    }
}
