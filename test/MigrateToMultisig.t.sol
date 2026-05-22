// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MigrateToMultisig} from "../script/MigrateToMultisig.s.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";

contract MigrateToMultisigTest is Test {
    uint256 internal constant DEPLOYER_PK = 0xA11CE;
    address internal deployer;
    address internal constant MULTISIG = address(0x51AFE);

    GenericFutarchyToken internal tokenA;
    GenericFutarchyToken internal tokenB;
    MigrateToMultisig internal migration;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        tokenA = new GenericFutarchyToken("Org A", "ORGA", deployer, 0);
        tokenB = new GenericFutarchyToken("Org B", "ORGB", deployer, 0);
        migration = new MigrateToMultisig();
    }

    function test_run_dryRunMigratesDefaultAdminForEveryTarget() public {
        _setMigrationEnv(_targetList(address(tokenA), address(tokenB)), MULTISIG);

        migration.run();

        bytes32 role = tokenA.DEFAULT_ADMIN_ROLE();
        assertTrue(tokenA.hasRole(role, MULTISIG), "tokenA multisig admin");
        assertFalse(tokenA.hasRole(role, deployer), "tokenA deployer renounced");
        assertTrue(tokenB.hasRole(role, MULTISIG), "tokenB multisig admin");
        assertFalse(tokenB.hasRole(role, deployer), "tokenB deployer renounced");
    }

    function _setMigrationEnv(string memory targets, address multisig) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.setEnv("MULTISIG", vm.toString(multisig));
        vm.setEnv("PER_INSTANCE_ACCESS_CONTROL_CONTRACTS", targets);
    }

    function _targetList(address first, address second) internal view returns (string memory) {
        if (second == address(0)) {
            return vm.toString(first);
        }
        return string.concat(vm.toString(first), ",", vm.toString(second));
    }
}
