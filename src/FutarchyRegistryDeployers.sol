// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {GenericFutarchyToken} from "./GenericFutarchyToken.sol";
import {ParameterizedArbitration} from "./ParameterizedArbitration.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IFAOFutarchyTwapResolver} from "./interfaces/IFAOFutarchyOracle.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";

/// @title TokenAndArbitrationDeployer
/// @notice Sub-factory used by FutarchyRegistry to keep its deployed bytecode
/// under the 24KB EIP-170 limit. Owns the bytecode for GenericFutarchyToken
/// and ParameterizedArbitration so the registry doesn't have to.
/// @dev This contract is permissionless and stateless — it simply forwards
/// constructor arguments. Anyone could call it directly to spin up a token
/// or a parameterized arbitration; in practice it's only invoked by the
/// registry inside `createFutarchy`.
contract TokenAndArbitrationDeployer {
    function deployToken(string calldata name, string calldata symbol, address admin, uint256 initialSupply)
        external
        returns (address)
    {
        return address(new GenericFutarchyToken(name, symbol, admin, initialSupply));
    }

    function deployArbitration(
        address admin,
        address weth,
        uint256 baseBondX,
        uint256 maxQueue,
        uint256 timeout
    ) external returns (address) {
        return address(new ParameterizedArbitration(admin, weth, baseBondX, maxQueue, timeout));
    }
}

/// @title FutarchyStackDeployer
/// @notice Sub-factory used by FutarchyRegistry to keep its deployed bytecode
/// under the 24KB EIP-170 limit. Owns the bytecode for FAOTwapResolver,
/// FAOFutarchyFactory and FAOOfficialProposalOrchestrator.
/// @dev Stateless. The registry calls this once per `createFutarchy`.
/// Returned addresses are wired together in the registry (it sets the
/// orchestrator on the resolver).
contract FutarchyStackDeployer {
    struct Deployed {
        address resolver;
        address factory;
        address orchestrator;
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
            IFAOFutarchyTwapResolver(address(resolver))
        );

        out.resolver = address(resolver);
        out.factory = address(factory);
        out.orchestrator = address(orchestrator);
    }
}
