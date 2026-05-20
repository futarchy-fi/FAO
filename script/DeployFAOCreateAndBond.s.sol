// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOCreateAndBond} from "../src/FAOCreateAndBond.sol";

/// @title DeployFAOCreateAndBond
/// @notice Deploys the FAOCreateAndBond bridge wired to the existing Sepolia v0
/// deployment (see docs/sepolia-deployment-v0.md).
///
/// Required env:
///   PRIVATE_KEY    — deployer EOA
///
/// Optional env (defaults match the live Sepolia v0 stack):
///   FACTORY        — FAOFutarchyFactory address
///   ARBITRATION    — FutarchyArbitration address
///   WETH           — Sepolia WETH
///   FAO_TOKEN      — FAOToken address (collateralToken1)
///
/// Usage:
///   forge script script/DeployFAOCreateAndBond.s.sol \
///     --rpc-url $SEPOLIA_RPC \
///     --broadcast \
///     --legacy --gas-price 1100000000 \
///     -vvvv
contract DeployFAOCreateAndBond is Script {
    // ─── Sepolia v0 defaults (docs/sepolia-deployment-v0.md) ─────────────────

    /// @dev FAOFutarchyFactory deployed on Sepolia.
    address internal constant DEFAULT_FACTORY = 0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0;

    /// @dev FutarchyArbitration deployed on Sepolia.
    address internal constant DEFAULT_ARBITRATION = 0x9D7692738a4d323338b9007d65d7F79e013B3476;

    /// @dev Sepolia WETH (also baked into FutarchyArbitration as immutable).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    /// @dev FAOToken on Sepolia (used as collateralToken1).
    address internal constant DEFAULT_FAO_TOKEN = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);

        address factory = vm.envOr("FACTORY", DEFAULT_FACTORY);
        address arbitration = vm.envOr("ARBITRATION", DEFAULT_ARBITRATION);
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address fao = vm.envOr("FAO_TOKEN", DEFAULT_FAO_TOKEN);

        console2.log("=== Deployer ===");
        console2.log("deployer:", deployer);
        console2.log("=== Bridge constructor args ===");
        console2.log("factory:         ", factory);
        console2.log("arbitration:     ", arbitration);
        console2.log("weth:            ", weth);
        console2.log("collateralToken1:", fao);
        console2.log("collateralToken2:", weth);

        vm.startBroadcast(deployerPK);
        FAOCreateAndBond bridge = new FAOCreateAndBond(
            factory,
            arbitration,
            weth,
            fao,  // collateralToken1 = FAO
            weth  // collateralToken2 = WETH
        );
        vm.stopBroadcast();

        console2.log("=== Deployed ===");
        console2.log("FAO_CREATE_AND_BOND=", address(bridge));
    }
}
