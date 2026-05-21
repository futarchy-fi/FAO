// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {UniswapV3LiquidityAdapter} from "../src/UniswapV3LiquidityAdapter.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";

/// @title DeployUniswapV3LiquidityAdapter
/// @notice Deploys the v0 UniswapV3LiquidityAdapter wired to (CTF,
/// Wrapped1155Factory, orchestrator, COMPANY, CURRENCY). The operator must run
/// `orchestrator.setAdapter(<addr>)` separately after deploy (one-shot, immutable).
///
/// Required env:
///   PRIVATE_KEY    — deployer EOA
///
/// Optional env (defaults match the FAO bootstrap Sepolia v0 stack):
///   CTF            — Gnosis ConditionalTokens deployment
///   W1155          — Gnosis Wrapped1155Factory deployment
///   ORCHESTRATOR   — FAOOfficialProposalOrchestrator address (sole caller of migrate)
///   COMPANY        — collateral token 1 (FAO on bootstrap)
///   CURRENCY       — collateral token 2 (WETH on bootstrap)
///
/// Usage:
///   forge script script/DeployUniswapV3LiquidityAdapter.s.sol \
///     --rpc-url $SEPOLIA_RPC \
///     --broadcast \
///     --legacy --gas-price 1100000000 \
///     -vvvv
///
/// After deploy, the operator runs:
///   cast send $ORCHESTRATOR "setAdapter(address)" <ADAPTER_ADDR> \
///     --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
contract DeployUniswapV3LiquidityAdapter is Script {
    // ─── Sepolia v0 defaults (docs/sepolia-deployment-v0.md) ─────────────────

    /// @dev Seer ConditionalTokens deployment on Sepolia (see docs/sepolia-deployment-v0.md).
    address internal constant DEFAULT_CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;

    /// @dev Seer Wrapped1155Factory deployment on Sepolia.
    address internal constant DEFAULT_W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;

    /// @dev FAOOfficialProposalOrchestrator deployed for the FAO bootstrap instance.
    address internal constant DEFAULT_ORCHESTRATOR = 0x7DF66Fd816c09bb534136C5688B55BBA9398d262;

    /// @dev FAOToken (collateralToken1 / COMPANY) on Sepolia.
    address internal constant DEFAULT_COMPANY = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;

    /// @dev Sepolia WETH (collateralToken2 / CURRENCY).
    address internal constant DEFAULT_CURRENCY = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);

        address ctf = vm.envOr("CTF", DEFAULT_CTF);
        address w1155 = vm.envOr("W1155", DEFAULT_W1155);
        address orch = vm.envOr("ORCHESTRATOR", DEFAULT_ORCHESTRATOR);
        address company = vm.envOr("COMPANY", DEFAULT_COMPANY);
        address currency = vm.envOr("CURRENCY", DEFAULT_CURRENCY);

        console2.log("=== Deployer ===");
        console2.log("deployer:", deployer);
        console2.log("=== Adapter constructor args ===");
        console2.log("CTF:         ", ctf);
        console2.log("W1155:       ", w1155);
        console2.log("ORCHESTRATOR:", orch);
        console2.log("COMPANY:     ", company);
        console2.log("CURRENCY:    ", currency);

        vm.startBroadcast(deployerPK);
        UniswapV3LiquidityAdapter adapter = new UniswapV3LiquidityAdapter(
            IConditionalTokensLike(ctf),
            IWrapped1155FactoryLike(w1155),
            orch,
            company,
            currency
        );
        vm.stopBroadcast();

        console2.log("=== Deployed ===");
        console2.log("UNISWAPV3_LIQUIDITY_ADAPTER=", address(adapter));
        console2.log("");
        console2.log("Next step (operator runs separately):");
        console2.log(
            "  cast send",
            orch,
            "'setAdapter(address)'",
            address(adapter)
        );
    }
}
