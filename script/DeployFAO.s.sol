// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { FAOToken } from "../src/FAOToken.sol";
import { FAOSale } from "../src/FAOSale.sol";

contract DeployFAO is Script {
    function run() external {
        // Read private key from env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the FAO token with the EOA as admin for now
        FAOToken token = new FAOToken(admin);

        // 2. Deploy the sale contract
        FAOSale sale = new FAOSale(
            token,
            1000000,
            admin,      // admin (later this will be your Timelock)
            address(0), // incentive contract (can be set later)
            address(0)  // insider vesting contract (can be set later)
        );

        // 3. Grant minter role to sale so it can mint FAO on buys
        token.grantRole(token.MINTER_ROLE(), address(sale));

        // 4. Start the sale
        sale.startSale();

        vm.stopBroadcast();

        console2.log("FAOToken deployed at", address(token));
        console2.log("FAOSale deployed at", address(sale));
        console2.log("Admin address", admin);
    }
}
