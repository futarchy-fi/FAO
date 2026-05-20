// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FAOToken} from "../src/FAOToken.sol";

/// @notice Minimal FAO token deploy for Sepolia phase-4. Mints 10_000 FAO to the
/// deployer (used to seed spot pool + agent wallets) — no FAOSale, no incentive
/// contract. Production launch uses script/DeployFAO.s.sol.
contract DeployFAOTestnet is Script {
    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPK);

        vm.startBroadcast(deployerPK);
        FAOToken token = new FAOToken(admin);
        token.grantRole(token.MINTER_ROLE(), admin);
        token.mint(admin, 10_000 ether);
        vm.stopBroadcast();

        console2.log("FAO_TOKEN=", address(token));
        console2.log("admin=", admin);
        console2.log("initial supply (FAO)=", uint256(10_000));
    }
}
