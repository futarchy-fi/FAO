// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IFAOFutarchyTwapResolver} from "./interfaces/IFAOFutarchyOracle.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";

/// @notice Stateless helper that deploys the immutable resolver/factory/orchestrator stack.
contract FAOSiteStackDeployer {
    bool public immutable ADAPTER_REPLACEABLE;

    struct Deployed {
        address resolver;
        address factory;
        address orchestrator;
    }

    constructor(bool adapterReplaceable) {
        ADAPTER_REPLACEABLE = adapterReplaceable;
    }

    function deployStack(
        address proposalImpl,
        IConditionalTokensLike ctf,
        IWrapped1155FactoryLike w1155,
        IUniswapV3FactoryLike univ3Factory,
        address admin,
        address token,
        address weth,
        address spotPool,
        uint24 feeTier,
        uint16 observationCardinality,
        uint32 timeout,
        uint32 twapWindow
    ) external returns (Deployed memory out) {
        FAOTwapResolver resolver = new FAOTwapResolver(timeout, twapWindow, ctf);
        FAOFutarchyFactory factory =
            new FAOFutarchyFactory(proposalImpl, ctf, w1155, address(resolver));
        FAOOfficialProposalOrchestrator orchestrator = new FAOOfficialProposalOrchestrator(
            admin,
            factory,
            univ3Factory,
            spotPool,
            token,
            weth,
            feeTier,
            observationCardinality,
            IFAOFutarchyTwapResolver(address(resolver)),
            ADAPTER_REPLACEABLE
        );

        out.resolver = address(resolver);
        out.factory = address(factory);
        out.orchestrator = address(orchestrator);
    }
}
