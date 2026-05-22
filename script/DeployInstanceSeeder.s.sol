// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SaleSpotSeeder} from "../src/SaleSpotSeeder.sol";

interface ISaleR {
    function addRagequitToken(address erc20) external;
    function isRagequitToken(address) external view returns (bool);
}

/// @notice Deploy a `SaleSpotSeeder` (the fLP-issuing one) for a specific
/// instance and register it in that instance's sale `ragequitTokens[]`.
/// Run by the instance admin after `createFutarchyPart2`.
contract DeployInstanceSeeder is Script {
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant NPM  = 0x1238536071E1c677A632429e3655c799b22cDA52;
    uint24  internal constant FEE  = 500;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        address sale  = vm.envAddress("SALE");
        address token = vm.envAddress("TOKEN");
        address pool  = vm.envAddress("SPOT_POOL");

        vm.startBroadcast(pk);
        SaleSpotSeeder seeder = new SaleSpotSeeder(sale, admin, token, WETH, NPM, pool, FEE);
        console2.log("seeder:", address(seeder));
        if (!ISaleR(sale).isRagequitToken(address(seeder))) {
            ISaleR(sale).addRagequitToken(address(seeder));
        }
        vm.stopBroadcast();
    }
}
