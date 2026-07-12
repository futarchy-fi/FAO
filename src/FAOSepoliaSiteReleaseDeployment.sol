// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {IProxyFactory} from "src/interfaces/IProxyFactory.sol";
import {InitializeCalldata, Strategy} from "src/types.sol";

import {AlwaysZeroVotingStrategy} from "./AlwaysZeroVotingStrategy.sol";
import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOSiteEvaluationPipeline} from "./FAOSiteEvaluationPipeline.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {FutarchyArbitration} from "./FutarchyArbitration.sol";
import {FAOSiteStackDeployer} from "./FAOSiteStackDeployer.sol";
import {SXArbitrationExecutionStrategy} from "./SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "./SXProposalGateway.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";

/// @notice One-transaction receipt for a stock-Snapshot-X, ownerless FAO site-release stack.
contract FAOSepoliaSiteReleaseDeployment {
    struct Dependency {
        address target;
        bytes32 codehash;
    }

    struct Config {
        Dependency proxyFactory;
        Dependency spaceImplementation;
        Dependency proposalValidationStrategy;
        Dependency stackDeployer;
        Dependency proposalImplementation;
        Dependency bondToken;
        Dependency conditionalTokens;
        Dependency wrapped1155Factory;
        Dependency uniswapV3Factory;
        Dependency companyToken;
        Dependency spotPool;
        uint256 graduationThreshold;
        uint256 arbitrationTimeout;
        uint256 minActivationBond;
        uint24 feeTier;
        uint16 observationCardinality;
        uint32 twapTimeout;
        uint32 twapWindow;
        uint256 spaceSaltNonce;
        string daoURI;
        string metadataURI;
        string votingStrategyMetadataURI;
        string proposalValidationStrategyMetadataURI;
    }

    error InvalidCodehash(address target, bytes32 expected, bytes32 actual);
    error InvalidConfig();
    error InvalidDependency(address target);
    error InvalidMetadataURI();
    error InvalidWiring();
    error UnexpectedDeploymentAddress(address expected, address actual);

    event SiteReleaseStackDeployed(
        address indexed space,
        address indexed arbitration,
        address indexed proposalGateway,
        address releaseStrategy,
        address votingStrategy,
        address evaluator,
        address orchestrator,
        address resolver,
        address futarchyFactory
    );

    address public immutable space;
    address public immutable arbitration;
    address public immutable proposalGateway;
    address public immutable releaseStrategy;
    address public immutable votingStrategy;
    address public immutable evaluator;
    address public immutable orchestrator;
    address public immutable resolver;
    address public immutable futarchyFactory;

    constructor(Config memory config) {
        _validateDependencies(config);
        _validateMetadata(config);
        _validateSpot(config);

        bytes32 proxySalt = keccak256(abi.encodePacked(address(this), config.spaceSaltNonce));
        address predictedSpace = IProxyFactory(config.proxyFactory.target)
            .predictProxyAddress(config.spaceImplementation.target, proxySalt);
        if (predictedSpace == address(0) || predictedSpace.code.length != 0) {
            revert InvalidConfig();
        }

        FutarchyArbitration arbitration_ = new FutarchyArbitration(
            IERC20(config.bondToken.target), config.graduationThreshold, config.arbitrationTimeout
        );
        SXArbitrationExecutionStrategy releaseStrategy_ =
            new SXArbitrationExecutionStrategy(predictedSpace, address(arbitration_));
        AlwaysZeroVotingStrategy votingStrategy_ = new AlwaysZeroVotingStrategy();
        SXProposalGateway proposalGateway_ = new SXProposalGateway(
            predictedSpace,
            address(releaseStrategy_),
            address(arbitration_),
            config.minActivationBond
        );

        address expectedEvaluator = _createAddress(5);
        FAOSiteStackDeployer.Deployed memory market = _deployMarket(config, expectedEvaluator);

        FAOSiteEvaluationPipeline evaluator_ = new FAOSiteEvaluationPipeline(
            address(arbitration_),
            market.orchestrator,
            market.resolver,
            config.conditionalTokens.target
        );
        if (address(evaluator_) != expectedEvaluator) {
            revert UnexpectedDeploymentAddress(expectedEvaluator, address(evaluator_));
        }

        FAOTwapResolver(market.resolver).setOrchestrator(market.orchestrator);
        _validateMarketWiring(config, market, arbitration_, evaluator_);

        arbitration_.setProposalGateway(address(proposalGateway_));
        arbitration_.setEvaluator(address(evaluator_));

        Space space_ = _deploySpace(
            config, predictedSpace, address(proposalGateway_), address(votingStrategy_)
        );
        space_.renounceOwnership();
        arbitration_.renounceOwnership();
        if (
            space_.owner() != address(0) || arbitration_.owner() != address(0)
                || arbitration_.pendingOwner() != address(0)
        ) revert InvalidWiring();

        space = predictedSpace;
        arbitration = address(arbitration_);
        proposalGateway = address(proposalGateway_);
        releaseStrategy = address(releaseStrategy_);
        votingStrategy = address(votingStrategy_);
        evaluator = address(evaluator_);
        orchestrator = market.orchestrator;
        resolver = market.resolver;
        futarchyFactory = market.factory;

        emit SiteReleaseStackDeployed(
            predictedSpace,
            address(arbitration_),
            address(proposalGateway_),
            address(releaseStrategy_),
            address(votingStrategy_),
            address(evaluator_),
            market.orchestrator,
            market.resolver,
            market.factory
        );
    }

    function _deploySpace(
        Config memory config,
        address predictedSpace,
        address proposalGateway_,
        address votingStrategy_
    ) private returns (Space space_) {
        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: votingStrategy_, params: ""});
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = config.votingStrategyMetadataURI;
        address[] memory authenticators = new address[](1);
        authenticators[0] = proposalGateway_;

        bytes memory initializer = abi.encodeWithSelector(
            Space.initialize.selector,
            InitializeCalldata({
                owner: address(this),
                votingDelay: 0,
                minVotingDuration: 0,
                maxVotingDuration: 0,
                proposalValidationStrategy: Strategy({
                    addr: config.proposalValidationStrategy.target, params: ""
                }),
                proposalValidationStrategyMetadataURI: config.proposalValidationStrategyMetadataURI,
                daoURI: config.daoURI,
                metadataURI: config.metadataURI,
                votingStrategies: votingStrategies,
                votingStrategyMetadataURIs: votingStrategyMetadataURIs,
                authenticators: authenticators
            })
        );
        IProxyFactory(config.proxyFactory.target)
            .deployProxy(config.spaceImplementation.target, initializer, config.spaceSaltNonce);
        if (predictedSpace.code.length == 0) revert InvalidWiring();

        space_ = Space(predictedSpace);
        if (
            space_.owner() != address(this) || space_.authenticators(proposalGateway_) != 1
                || space_.activeVotingStrategies() != 1
        ) revert InvalidWiring();
    }

    function _validateDependencies(Config memory config) private view {
        _requireDependency(config.proxyFactory);
        _requireDependency(config.spaceImplementation);
        _requireDependency(config.proposalValidationStrategy);
        _requireDependency(config.stackDeployer);
        _requireDependency(config.proposalImplementation);
        _requireDependency(config.bondToken);
        _requireDependency(config.conditionalTokens);
        _requireDependency(config.wrapped1155Factory);
        _requireDependency(config.uniswapV3Factory);
        _requireDependency(config.companyToken);
        _requireDependency(config.spotPool);

        if (
            config.graduationThreshold == 0 || config.arbitrationTimeout == 0
                || config.minActivationBond == 0 || config.observationCardinality == 0
                || config.twapWindow == 0 || config.twapWindow > config.twapTimeout
                || FAOSiteStackDeployer(config.stackDeployer.target).ADAPTER_REPLACEABLE()
        ) revert InvalidConfig();
    }

    function _validateMetadata(Config memory config) private pure {
        _requireMetadataURI(config.daoURI);
        _requireMetadataURI(config.metadataURI);
        _requireMetadataURI(config.votingStrategyMetadataURI);
        _requireMetadataURI(config.proposalValidationStrategyMetadataURI);
    }

    function _requireMetadataURI(string memory uri) private pure {
        bytes memory value = bytes(uri);
        bytes memory prefix = bytes("ipfs://");
        if (value.length != 66) revert InvalidMetadataURI();
        for (uint256 i; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) revert InvalidMetadataURI();
        }
        if (value[prefix.length] != "b") revert InvalidMetadataURI();
        for (uint256 i = prefix.length; i < value.length; ++i) {
            bytes1 char = value[i];
            if (!((char >= "a" && char <= "z") || (char >= "2" && char <= "7"))) {
                revert InvalidMetadataURI();
            }
        }
    }

    function _deployMarket(Config memory config, address expectedEvaluator)
        private
        returns (FAOSiteStackDeployer.Deployed memory)
    {
        return FAOSiteStackDeployer(config.stackDeployer.target)
            .deployStack(
                config.proposalImplementation.target,
                IConditionalTokensLike(config.conditionalTokens.target),
                IWrapped1155FactoryLike(config.wrapped1155Factory.target),
                IUniswapV3FactoryLike(config.uniswapV3Factory.target),
                expectedEvaluator,
                config.companyToken.target,
                config.bondToken.target,
                config.spotPool.target,
                config.feeTier,
                config.observationCardinality,
                config.twapTimeout,
                config.twapWindow
            );
    }

    function _validateSpot(Config memory config) private view {
        if (
            IUniswapV3FactoryLike(config.uniswapV3Factory.target)
                    .getPool(config.companyToken.target, config.bondToken.target, config.feeTier)
                != config.spotPool.target
        ) revert InvalidWiring();

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(config.spotPool.target);
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (
            !(token0 == config.companyToken.target
                    && token1 == config.bondToken.target
                    || token0 == config.bondToken.target
                    && token1 == config.companyToken.target) || pool.fee() != config.feeTier
        ) revert InvalidWiring();
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (sqrtPriceX96 == 0) revert InvalidWiring();
    }

    function _validateMarketWiring(
        Config memory config,
        FAOSiteStackDeployer.Deployed memory market,
        FutarchyArbitration arbitration_,
        FAOSiteEvaluationPipeline evaluator_
    ) private view {
        FAOTwapResolver resolver_ = FAOTwapResolver(market.resolver);
        FAOFutarchyFactory factory_ = FAOFutarchyFactory(market.factory);
        FAOOfficialProposalOrchestrator orchestrator_ =
            FAOOfficialProposalOrchestrator(market.orchestrator);

        if (
            resolver_.orchestrator() != market.orchestrator
                || address(resolver_.CTF()) != config.conditionalTokens.target
                || resolver_.TIMEOUT() != config.twapTimeout
                || resolver_.TWAP_WINDOW() != config.twapWindow
                || factory_.proposalImpl() != config.proposalImplementation.target
                || address(factory_.conditionalTokens()) != config.conditionalTokens.target
                || address(factory_.wrapped1155Factory()) != config.wrapped1155Factory.target
                || factory_.oracle() != market.resolver
                || orchestrator_.ADMIN() != address(evaluator_)
                || address(orchestrator_.FACTORY()) != market.factory
                || address(orchestrator_.UNIV3_FACTORY()) != config.uniswapV3Factory.target
                || orchestrator_.SPOT_POOL() != config.spotPool.target
                || orchestrator_.COMPANY_TOKEN() != config.companyToken.target
                || orchestrator_.CURRENCY_TOKEN() != config.bondToken.target
                || orchestrator_.FEE_TIER() != config.feeTier
                || orchestrator_.OBSERVATION_CARDINALITY() != config.observationCardinality
                || address(orchestrator_.RESOLVER()) != market.resolver
                || orchestrator_.ADAPTER_REPLACEABLE()
                || address(orchestrator_.adapter()) != address(0)
                || evaluator_.arbitrationContract() != address(arbitration_)
                || address(evaluator_.orchestrator()) != market.orchestrator
                || address(evaluator_.resolver()) != market.resolver
                || address(evaluator_.conditionalTokens()) != config.conditionalTokens.target
        ) revert InvalidWiring();
    }

    function _requireDependency(Dependency memory dependency) private view {
        if (dependency.target.code.length == 0) revert InvalidDependency(dependency.target);
        bytes32 actual = dependency.target.codehash;
        if (actual != dependency.codehash) {
            revert InvalidCodehash(dependency.target, dependency.codehash, actual);
        }
    }

    function _createAddress(uint8 nonce) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), bytes1(nonce)))))
        );
    }
}
