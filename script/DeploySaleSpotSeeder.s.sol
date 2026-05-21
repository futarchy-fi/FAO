// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SaleSpotSeeder} from "../src/SaleSpotSeeder.sol";

/// @notice Deploys the SaleSpotSeeder for the live FAOSale on Sepolia.
contract DeploySaleSpotSeeder is Script {
    address internal constant SALE = 0x011F6e57DEfEca4d5Ea633DAf6Dc0e3c5DF45678;
    address internal constant FAO = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address internal constant SPOT_POOL = 0x5Dac596a38A294C03D7fAC840D031708c970dA79;
    uint24  internal constant FEE = 500;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        vm.startBroadcast(pk);
        SaleSpotSeeder seeder = new SaleSpotSeeder(SALE, admin, FAO, WETH, NPM, SPOT_POOL, FEE);
        console2.log("SaleSpotSeeder:", address(seeder));
        vm.stopBroadcast();
    }
}
