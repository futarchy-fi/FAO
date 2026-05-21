// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {UniswapV3LiquidityAdapter, IConditionalTokensLike as AdapterCTF, IWrapped1155FactoryLike as AdapterW1155}
    from "../src/UniswapV3LiquidityAdapter.sol";
import {FAOOfficialProposalOrchestrator, IFAOLiquidityAdapter} from "../src/FAOOfficialProposalOrchestrator.sol";

/// @notice Deploy the patched adapter and wire it into the live orchestrator.
contract DeployAndSetAdapter is Script {
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant FAO = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant ORCH = 0xa7D281ED62283f29c44A863D5CbB1B53023244b3;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        UniswapV3LiquidityAdapter adapter = new UniswapV3LiquidityAdapter(
            AdapterCTF(CTF), AdapterW1155(W1155), ORCH, FAO, WETH
        );
        console2.log("adapter:", address(adapter));

        FAOOfficialProposalOrchestrator(ORCH).setAdapter(IFAOLiquidityAdapter(address(adapter)));

        vm.stopBroadcast();

        console2.log("ADAPTER=", address(adapter));
    }
}
