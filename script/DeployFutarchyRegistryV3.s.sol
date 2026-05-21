// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FutarchyRegistry} from "../src/FutarchyRegistry.sol";
import {TokenAndArbitrationDeployer, FutarchyStackDeployer} from "../src/FutarchyRegistryDeployers.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";

/// @notice FutarchyRegistry v3 — token+sale+arbitration in Part1, no initial mint.
contract DeployFutarchyRegistryV3 is Script {
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;

    uint24  internal constant FEE_TIER = 500;
    uint16  internal constant OBS_CARDINALITY = 30;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        FAOFutarchyProposal proposalImpl = new FAOFutarchyProposal();
        console2.log("proposalImpl:", address(proposalImpl));

        TokenAndArbitrationDeployer tokArb = new TokenAndArbitrationDeployer();
        console2.log("tokArbDeployer:", address(tokArb));

        FutarchyStackDeployer stack = new FutarchyStackDeployer();
        console2.log("stackDeployer:", address(stack));

        FutarchyRegistry registry = new FutarchyRegistry(
            address(proposalImpl),
            IConditionalTokensLike(CTF),
            IWrapped1155FactoryLike(W1155),
            IUniswapV3FactoryLike(UNIV3_FACTORY),
            WETH,
            FEE_TIER,
            OBS_CARDINALITY,
            tokArb,
            stack
        );
        console2.log("REGISTRY_V3:", address(registry));

        vm.stopBroadcast();
    }
}
