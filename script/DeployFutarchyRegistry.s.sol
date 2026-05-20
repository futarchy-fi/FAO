// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FutarchyRegistry} from "../src/FutarchyRegistry.sol";
import {
    FutarchyStackDeployer,
    TokenAndArbitrationDeployer
} from "../src/FutarchyRegistryDeployers.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";

/// @title DeployFutarchyRegistry
/// @notice Deploys the FAO v0 meta-factory (FutarchyRegistry) wired to the
/// shared Sepolia infrastructure.
///
/// Required env vars:
///   PRIVATE_KEY            — deployer EOA
///
/// Optional env vars (defaults shown below match the live Sepolia stack):
///   PROPOSAL_IMPL          — existing FAOFutarchyProposal clone target
///                            (default: 0x098990c0e1a4a84f03b236f16cd34ed140803555)
///                            Pass 0x0 or set DEPLOY_PROPOSAL_IMPL=1 to deploy a fresh impl.
///   WETH                   — Sepolia WETH (default: 0xfFf9...676B14)
///   CTF                    — Seer ConditionalTokens (default: 0x8bdC...7B93)
///   WRAPPED_1155_FACTORY   — Seer Wrapped1155Factory (default: 0xD194...0B79f)
///   UNIV3_FACTORY          — canonical UniV3 Factory (default: 0x0227...DaC1c)
///   FEE_TIER               — UniV3 fee tier hundredths of bps (default: 500)
///   OBSERVATION_CARDINALITY — observation buffer warmup size (default: 100)
///   DEPLOY_PROPOSAL_IMPL   — if "1", deploy a new proposal impl too (default: 0)
///
/// Usage:
///   forge script script/DeployFutarchyRegistry.s.sol \
///     --rpc-url $SEPOLIA_RPC \
///     --broadcast \
///     --legacy --gas-price 1100000000 \
///     -vvvv
///
/// (Do NOT execute this from agents — broadcast only when you mean it.)
contract DeployFutarchyRegistry is Script {
    address internal constant DEFAULT_PROPOSAL_IMPL = 0x098990C0E1a4A84F03B236F16cd34eD140803555;
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant DEFAULT_W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant DEFAULT_UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    uint24 internal constant DEFAULT_FEE_TIER = 500;
    uint16 internal constant DEFAULT_OBSERVATION_CARDINALITY = 100;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address proposalImpl = vm.envOr("PROPOSAL_IMPL", DEFAULT_PROPOSAL_IMPL);
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address ctfAddr = vm.envOr("CTF", DEFAULT_CTF);
        address w1155Addr = vm.envOr("WRAPPED_1155_FACTORY", DEFAULT_W1155);
        address uniFactoryAddr = vm.envOr("UNIV3_FACTORY", DEFAULT_UNIV3_FACTORY);
        uint24 feeTier = uint24(vm.envOr("FEE_TIER", uint256(DEFAULT_FEE_TIER)));
        uint16 cardinality =
            uint16(vm.envOr("OBSERVATION_CARDINALITY", uint256(DEFAULT_OBSERVATION_CARDINALITY)));
        bool deployFreshImpl = vm.envOr("DEPLOY_PROPOSAL_IMPL", uint256(0)) == 1;

        console2.log("=== Deployer ===");
        console2.log("deployer:", deployer);
        console2.log("=== Shared dependencies ===");
        console2.log("WETH:", weth);
        console2.log("CTF:", ctfAddr);
        console2.log("Wrapped1155Factory:", w1155Addr);
        console2.log("UniV3 Factory:", uniFactoryAddr);
        console2.log("FeeTier:", feeTier);
        console2.log("ObservationCardinality:", cardinality);

        vm.startBroadcast(pk);

        if (deployFreshImpl || proposalImpl == address(0)) {
            FAOFutarchyProposal impl = new FAOFutarchyProposal();
            proposalImpl = address(impl);
            console2.log("Fresh FAOFutarchyProposal impl deployed:", proposalImpl);
        } else {
            console2.log("Reusing FAOFutarchyProposal impl:", proposalImpl);
        }

        TokenAndArbitrationDeployer tokenArbDeployer = new TokenAndArbitrationDeployer();
        console2.log("TokenAndArbitrationDeployer:", address(tokenArbDeployer));

        FutarchyStackDeployer stackDeployer = new FutarchyStackDeployer();
        console2.log("FutarchyStackDeployer:", address(stackDeployer));

        FutarchyRegistry registry = new FutarchyRegistry(
            proposalImpl,
            IConditionalTokensLike(ctfAddr),
            IWrapped1155FactoryLike(w1155Addr),
            IUniswapV3FactoryLike(uniFactoryAddr),
            weth,
            feeTier,
            cardinality,
            tokenArbDeployer,
            stackDeployer
        );

        vm.stopBroadcast();

        console2.log("=== Deployed ===");
        console2.log("FUTARCHY_REGISTRY=", address(registry));
        console2.log("Save above in your .env / site config.");
    }
}
