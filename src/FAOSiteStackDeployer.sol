// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {
    IFAOFutarchyTwapResolver,
    IFutarchyRandomnessSource
} from "./interfaces/IFAOFutarchyOracle.sol";
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

    function randomnessSource() public view virtual returns (IFutarchyRandomnessSource) {
        return IFutarchyRandomnessSource(address(0));
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
        IFutarchyRandomnessSource vrf = randomnessSource();
        if (address(vrf) != address(0)) {
            resolver.initRandomnessSource(vrf);
        }
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

/// @notice Stack helper variant whose runtime bytecode immutably pins an
/// `IFutarchyRandomnessSource` (committed via `CoreConfig.stackDeployer.codehash` in
/// `FaoGenesisDeployment`).
contract FAOVrfStackDeployer is FAOSiteStackDeployer {
    IFutarchyRandomnessSource internal immutable RANDOMNESS_SOURCE;

    error InvalidRandomnessSource();

    constructor(bool adapterReplaceable, IFutarchyRandomnessSource randomnessSource_)
        FAOSiteStackDeployer(adapterReplaceable)
    {
        if (address(randomnessSource_) == address(0) || address(randomnessSource_).code.length == 0)
        {
            revert InvalidRandomnessSource();
        }
        RANDOMNESS_SOURCE = randomnessSource_;
    }

    function randomnessSource() public view override returns (IFutarchyRandomnessSource) {
        return RANDOMNESS_SOURCE;
    }
}
