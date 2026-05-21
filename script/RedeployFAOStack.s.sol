// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {UniswapV3LiquidityAdapter, IConditionalTokensLike as AdapterCTF, IWrapped1155FactoryLike as AdapterW1155}
    from "../src/UniswapV3LiquidityAdapter.sol";
import {IFAOLiquidityAdapter} from "../src/FAOOfficialProposalOrchestrator.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";

/// @notice Redeploy resolver + factory + orchestrator + adapter, wired to the
/// existing FAO token + WETH + spot pool. Used to swap out a broken adapter when
/// the orchestrator's previous setAdapter has already been called and locked.
contract RedeployFAOStack is Script {
    address internal constant FAO = 0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant SPOT_POOL = 0x5Dac596a38A294C03D7fAC840D031708c970dA79;

    uint24 internal constant FEE_TIER = 500;
    uint16 internal constant OBS_CARDINALITY = 30;
    uint32 internal constant TIMEOUT = 7200;       // 2h
    uint32 internal constant TWAP_WINDOW = 3600;   // 1h

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        console2.log("admin:", admin);

        vm.startBroadcast(pk);

        FAOFutarchyProposal proposalImpl = new FAOFutarchyProposal();
        console2.log("proposalImpl:", address(proposalImpl));

        FAOTwapResolver resolver =
            new FAOTwapResolver(TIMEOUT, TWAP_WINDOW, IConditionalTokensLike(CTF));
        console2.log("resolver:", address(resolver));

        FAOFutarchyFactory factory = new FAOFutarchyFactory(
            address(proposalImpl),
            IConditionalTokensLike(CTF),
            IWrapped1155FactoryLike(W1155),
            address(resolver)
        );
        console2.log("factory:", address(factory));

        FAOOfficialProposalOrchestrator orchestrator = new FAOOfficialProposalOrchestrator(
            admin,
            factory,
            IUniswapV3FactoryLike(UNIV3_FACTORY),
            SPOT_POOL,
            FAO,
            WETH,
            FEE_TIER,
            OBS_CARDINALITY,
            resolver
        );
        console2.log("orchestrator:", address(orchestrator));

        resolver.setOrchestrator(address(orchestrator));

        UniswapV3LiquidityAdapter adapter = new UniswapV3LiquidityAdapter(
            AdapterCTF(CTF),
            AdapterW1155(W1155),
            address(orchestrator),
            FAO,
            WETH
        );
        console2.log("adapter:", address(adapter));

        orchestrator.setAdapter(IFAOLiquidityAdapter(address(adapter)));

        vm.stopBroadcast();

        console2.log("=== Redeploy complete ===");
        console2.log("PROPOSAL_IMPL=", address(proposalImpl));
        console2.log("FUTARCHY_FACTORY=", address(factory));
        console2.log("TWAP_RESOLVER=", address(resolver));
        console2.log("ORCHESTRATOR=", address(orchestrator));
        console2.log("ADAPTER=", address(adapter));
    }
}
