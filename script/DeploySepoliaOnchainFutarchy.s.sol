// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {FutarchyEvaluator} from "../src/FutarchyEvaluator.sol";
import {FutarchyCtfSettlementOracle} from "../src/FutarchyCtfSettlementOracle.sol";
import {CtfRouter} from "../src/CtfRouter.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";

/// @title DeploySepoliaOnchainFutarchy
/// @notice Deploys the FAO v0 on-chain futarchy stack to Sepolia testnet on top of
/// the Seer-deployed CTF and the canonical UniV3 / Wrapped1155Factory.
///
/// Required env vars:
///   PRIVATE_KEY            — deployer EOA
///   FAO_TOKEN              — already-deployed FAO token (use DeployFAO.s.sol first)
///   WETH                   — Sepolia WETH (default: 0xfFf9...676B14)
///   CTF                    — Sepolia ConditionalTokens (default: 0x8bdC...7B93 Seer)
///   WRAPPED_1155_FACTORY   — Wrapped1155Factory on Sepolia
///   UNIV3_FACTORY          — Sepolia UniV3 factory (default: 0x0227...DaC1c)
///   SPOT_POOL              — pre-created FAO/WETH UniV3 pool address (see README)
///   FEE_TIER               — UniV3 fee tier in hundredths of bps (default: 500)
///   OBSERVATION_CARDINALITY — observations buffer size (default: 1000)
///   TIMEOUT_SECONDS        — TwapResolver TIMEOUT (default: 7200 = 2h)
///   TWAP_WINDOW_SECONDS    — TwapResolver TWAP_WINDOW (default: 3600 = 1h)
///
/// Usage:
///   forge script script/DeploySepoliaOnchainFutarchy.s.sol \
///     --rpc-url $SEPOLIA_RPC --broadcast -vvvv
contract DeploySepoliaOnchainFutarchy is Script {
    // Defaults for Sepolia (sourced from lib/seer-demo/contracts/deployments/sepolia/).
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant DEFAULT_WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant DEFAULT_UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    uint24 internal constant DEFAULT_FEE_TIER = 500;
    uint16 internal constant DEFAULT_OBSERVATION_CARDINALITY = 1_000;
    uint32 internal constant DEFAULT_TIMEOUT = 2 hours;
    uint32 internal constant DEFAULT_TWAP_WINDOW = 1 hours;

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPK);

        address fao = vm.envAddress("FAO_TOKEN");
        address weth = vm.envOr("WETH", DEFAULT_WETH);
        address ctfAddr = vm.envOr("CTF", DEFAULT_CTF);
        address wrappedFactoryAddr = vm.envOr("WRAPPED_1155_FACTORY", DEFAULT_WRAPPED_1155_FACTORY);
        address univ3FactoryAddr = vm.envOr("UNIV3_FACTORY", DEFAULT_UNIV3_FACTORY);
        address spotPool = vm.envAddress("SPOT_POOL");
        uint24 feeTier = uint24(vm.envOr("FEE_TIER", uint256(DEFAULT_FEE_TIER)));
        uint16 observationCardinality =
            uint16(vm.envOr("OBSERVATION_CARDINALITY", uint256(DEFAULT_OBSERVATION_CARDINALITY)));
        uint32 timeoutSecs = uint32(vm.envOr("TIMEOUT_SECONDS", uint256(DEFAULT_TIMEOUT)));
        uint32 twapWindowSecs = uint32(vm.envOr("TWAP_WINDOW_SECONDS", uint256(DEFAULT_TWAP_WINDOW)));

        console2.log("=== Deployer ===");
        console2.log("admin:", admin);
        console2.log("=== External deps ===");
        console2.log("FAO:", fao);
        console2.log("WETH:", weth);
        console2.log("CTF:", ctfAddr);
        console2.log("Wrapped1155Factory:", wrappedFactoryAddr);
        console2.log("UniV3 Factory:", univ3FactoryAddr);
        console2.log("SpotPool:", spotPool);
        console2.log("FeeTier:", feeTier);
        console2.log("ObservationCardinality:", observationCardinality);
        console2.log("Timeout (s):", timeoutSecs);
        console2.log("TwapWindow (s):", twapWindowSecs);

        vm.startBroadcast(deployerPK);

        // 1. FAOFutarchyProposal implementation (cloneable template).
        FAOFutarchyProposal proposalImpl = new FAOFutarchyProposal();
        console2.log("proposalImpl:", address(proposalImpl));

        // 2. TwapResolver (CTF reporter). Bind address set later once orchestrator exists.
        FAOTwapResolver resolver =
            new FAOTwapResolver(timeoutSecs, twapWindowSecs, IConditionalTokensLike(ctfAddr));
        console2.log("resolver:", address(resolver));

        // 3. Factory referencing the resolver as the CTF oracle.
        FAOFutarchyFactory factory = new FAOFutarchyFactory(
            address(proposalImpl),
            IConditionalTokensLike(ctfAddr),
            IWrapped1155FactoryLike(wrappedFactoryAddr),
            address(resolver)
        );
        console2.log("factory:", address(factory));

        // 4. Orchestrator (atomic promote w/ prevrandao sanity check + TIP).
        FAOOfficialProposalOrchestrator orchestrator = new FAOOfficialProposalOrchestrator(
            admin,
            factory,
            IUniswapV3FactoryLike(univ3FactoryAddr),
            spotPool,
            fao,
            weth,
            feeTier,
            observationCardinality,
            resolver
        );
        console2.log("orchestrator:", address(orchestrator));

        // 5. Lock orchestrator into the resolver (one-shot).
        resolver.setOrchestrator(address(orchestrator));

        // 6. FutarchyArbitration is self-contained (constructor reads WETH + sets baseX).
        FutarchyArbitration arb = new FutarchyArbitration();
        console2.log("arbitration:", address(arb));

        // 7. CtfRouter wraps CTF and exposes IFutarchyConditionalRouter for the
        //    settlement oracle to read winning outcomes from.
        CtfRouter router = new CtfRouter(IConditionalTokensLike(ctfAddr));
        console2.log("ctfRouter:", address(router));

        FutarchyCtfSettlementOracle ctfOracle =
            new FutarchyCtfSettlementOracle(IFutarchyConditionalRouter(address(router)));
        console2.log("ctfSettlementOracle:", address(ctfOracle));

        FutarchyEvaluator evaluator = new FutarchyEvaluator(address(arb), ctfAddr, admin);
        console2.log("evaluator:", address(evaluator));
        arb.setEvaluator(address(evaluator));

        vm.stopBroadcast();

        console2.log("=== Deployed ===");
        console2.log("Save these in your env / docs:");
        console2.log("PROPOSAL_IMPL=", address(proposalImpl));
        console2.log("FUTARCHY_FACTORY=", address(factory));
        console2.log("TWAP_RESOLVER=", address(resolver));
        console2.log("ORCHESTRATOR=", address(orchestrator));
        console2.log("ARBITRATION=", address(arb));
        console2.log("EVALUATOR=", address(evaluator));
        console2.log("CTF_SETTLEMENT_ORACLE=", address(ctfOracle));
        console2.log("CTF_ROUTER=", address(router));
    }
}
