// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

interface IDefaultAdminAccessControl {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
}

/// @title MigrateToMultisig
/// @notice Hands DEFAULT_ADMIN_ROLE from the deployer EOA to a multisig for every supplied
/// AccessControl per-instance contract.
/// @dev // pragma: TODO step B - InstanceSale, ParameterizedArbitration, and
/// FAOOfficialProposalOrchestrator still use immutable/admin or Ownable surfaces in the current
/// v5 stack. See audit/specs/SECURITY.md Step B before treating this as full-stack migration.
///
/// Required env:
///   PRIVATE_KEY                            deployer/admin EOA key
///   MULTISIG                               Safe/multisig recipient
///   PER_INSTANCE_ACCESS_CONTROL_CONTRACTS  comma-separated AccessControl contract addresses
///
/// Dry-run:
///   forge script script/MigrateToMultisig.s.sol --fork-url $RPC -vvvv
///
/// Broadcast only after reviewing the dry-run trace:
///   forge script script/MigrateToMultisig.s.sol --rpc-url $RPC --broadcast -vvvv
contract MigrateToMultisig is Script {
    error ZeroMultisig();
    error MultisigIsDeployer();
    error NoContracts();
    error ZeroContract(uint256 index);
    error DeployerNotAdmin(address target, address deployer);
    error MultisigGrantFailed(address target, address multisig);
    error DeployerStillAdmin(address target, address deployer);

    event DefaultAdminMigrated(
        address indexed target, address indexed deployer, address indexed multisig
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address multisig = vm.envAddress("MULTISIG");
        address[] memory targets = vm.envAddress("PER_INSTANCE_ACCESS_CONTROL_CONTRACTS", ",");

        _validateInputs(multisig, deployer, targets);

        console2.log("=== Migrate DEFAULT_ADMIN_ROLE to multisig ===");
        console2.log("deployer:", deployer);
        console2.log("multisig:", multisig);
        console2.log("targets:", targets.length);

        vm.startBroadcast(deployerPrivateKey);
        _migrate(multisig, deployer, targets);
        vm.stopBroadcast();
    }

    function _migrate(address multisig, address deployer, address[] memory targets) internal {
        bytes32 role;
        IDefaultAdminAccessControl target;

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert ZeroContract(i);

            target = IDefaultAdminAccessControl(targets[i]);
            role = target.DEFAULT_ADMIN_ROLE();

            if (!target.hasRole(role, deployer)) {
                revert DeployerNotAdmin(targets[i], deployer);
            }

            target.grantRole(role, multisig);
            if (!target.hasRole(role, multisig)) {
                revert MultisigGrantFailed(targets[i], multisig);
            }

            target.renounceRole(role, deployer);
            if (target.hasRole(role, deployer)) {
                revert DeployerStillAdmin(targets[i], deployer);
            }

            console2.log("migrated:", targets[i]);
            emit DefaultAdminMigrated(targets[i], deployer, multisig);
        }
    }

    function _validateInputs(address multisig, address deployer, address[] memory targets)
        internal
        pure
    {
        if (multisig == address(0)) revert ZeroMultisig();
        if (multisig == deployer) revert MultisigIsDeployer();
        if (targets.length == 0) revert NoContracts();
    }
}
