// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {GenericFutarchyToken} from "./GenericFutarchyToken.sol";
import {InstanceSale} from "./InstanceSale.sol";
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

    /// @notice Deploy a fresh token + sale atomically: token starts at 0 supply,
    /// sale is granted `MINTER_ROLE`, then this deployer renounces its admin
    /// roles so only `creator` retains DEFAULT_ADMIN_ROLE on the token.
    function deployTokenAndSale(
        string calldata name,
        string calldata symbol,
        address creator,
        uint256 initialPriceWeiPerToken,
        uint256 minInitialPhaseSold,
        uint256 initialPhaseDuration
    ) external returns (address tokenAddr, address saleAddr) {
        // 1. Deploy the token with THIS contract as the initial admin so we can
        //    grant MINTER_ROLE to the sale below. `initialSupply` is 0 — all
        //    supply must come from the sale.
        GenericFutarchyToken token = new GenericFutarchyToken(name, symbol, address(this), 0);
        tokenAddr = address(token);

        // 2. Deploy the sale, then grant it MINTER_ROLE on the token.
        InstanceSale sale = new InstanceSale(
            tokenAddr, creator, initialPriceWeiPerToken, minInitialPhaseSold, initialPhaseDuration
        );
        saleAddr = address(sale);
        token.grantRole(token.MINTER_ROLE(), saleAddr);

        // 3. Hand DEFAULT_ADMIN_ROLE to the creator, then renounce our own
        //    privileges. The deployer keeps nothing.
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), creator);
        token.renounceRole(token.MINTER_ROLE(), address(this));
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), address(this));
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
