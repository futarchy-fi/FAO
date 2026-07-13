// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FaoGenesisRegistrar} from "../src/FaoGenesisRegistrar.sol";
import {EconomicDeploymentCodeHashes} from "../src/generated/EconomicDeploymentCodeHashes.sol";

/// @notice Deploys the ownerless singleton registrar for self-serve economic FAOs.
contract DeployFaoGenesisRegistrar is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;

    error DeploymentFailed();
    error InvalidChain(uint256 chainId);
    error InvalidConfig();

    function run() external returns (FaoGenesisRegistrar registrar) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        if (privateKey == 0) revert InvalidConfig();

        bytes memory baseCode = vm.readFileBinary("metadata/economic-creation-code/registrar.bin");
        if (keccak256(baseCode) != EconomicDeploymentCodeHashes.REGISTRAR) {
            revert InvalidConfig();
        }

        bytes memory initcode =
            abi.encodePacked(baseCode, abi.encode(EconomicDeploymentCodeHashes.RECEIPT));
        vm.broadcast(privateKey);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
        registrar = FaoGenesisRegistrar(deployed);
        if (registrar.RECEIPT_CREATION_CODE_HASH() != EconomicDeploymentCodeHashes.RECEIPT) {
            revert InvalidConfig();
        }

        console2.log("FAO_GENESIS_REGISTRAR=", deployed);
        console2.log("DEPLOYER=", vm.addr(privateKey));
    }
}
