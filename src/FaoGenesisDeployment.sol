// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {IProxyFactory} from "src/interfaces/IProxyFactory.sol";
import {InitializeCalldata, Strategy} from "src/types.sol";

import {UniswapV3LiquidityAdapter} from "flm/adapters/UniswapV3LiquidityAdapter.sol";
import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {UniV3PoolStabilityGuard} from "flm/oracles/UniV3PoolStabilityGuard.sol";
import {FutarchyConditionalRouter} from "flm/routers/FutarchyConditionalRouter.sol";

import {AlwaysZeroVotingStrategy} from "./AlwaysZeroVotingStrategy.sol";
import {EconGateway} from "./EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "./FAOEconomicEvaluationPipeline.sol";
import {FAOFlmProposalSourceRelay, IFAOFlmManagerView} from "./FAOFlmProposalSourceRelay.sol";
import {FAOSiteStackDeployer} from "./FAOSiteStackDeployer.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {FutarchyArbitration} from "./FutarchyArbitration.sol";
import {
    GenesisVault,
    IGenesisArbitration,
    IGenesisBootstrapHook,
    IGenesisFlm
} from "./GenesisVault.sol";
import {SXArbitrationExecutionStrategy} from "./SXArbitrationExecutionStrategy.sol";
import {FlmCodeHashes} from "./generated/FlmCodeHashes.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";

interface IFaoGenesisSwapPool is IUniswapV3PoolLike {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Hash-sealed, permissionless receipt for an economic FAO genesis.
/// @dev Receipt CREATE nonces are fixed: arbitration/vault/SX modules/evaluator are 1..6 and the
/// five W1 FLM blobs (with two adapters) are 7..12. The receipt is also the vault's bootstrap hook.
contract FaoGenesisDeployment {
    struct Dependency {
        address target;
        bytes32 codehash;
    }

    struct CoreConfig {
        Dependency proxyFactory;
        Dependency spaceImplementation;
        Dependency proposalValidationStrategy;
        Dependency stackDeployer;
        Dependency proposalImplementation;
        Dependency weth;
        Dependency conditionalTokens;
        Dependency wrapped1155Factory;
        Dependency uniswapV3Factory;
        uint256 graduationThreshold;
        uint256 arbitrationTimeout;
        uint256 siteMinActivationBond;
        uint256 treasuryMinActivationBond;
        GenesisVault.AssetPolicyConfig[] assetPolicies;
        uint32 twapTimeout;
        uint32 twapWindow;
        uint256 spaceSaltNonce;
        string daoURI;
        string metadataURI;
        string votingStrategyMetadataURI;
        string proposalValidationStrategyMetadataURI;
        string tokenName;
        string tokenSymbol;
        uint64 saleEnd;
        uint64 bootstrapDeadline;
        uint256 saleCap;
        uint256 minimumRaise;
        uint256 tokenMaxSupply;
        uint256 initialPrice;
        uint256 slope;
        uint16 bootstrapBps;
    }

    struct FlmConfig {
        Dependency positionManager;
    }

    uint256 private constant CORE_CODE_BLOB_COUNT = 6;
    uint256 private constant FLM_CODE_BLOB_COUNT = 5;
    uint256 private constant MAX_VESTING_GRANTS = 32;
    uint24 public constant FEE_TIER = 500;
    int24 public constant TICK_LOWER = -887_270;
    int24 public constant TICK_UPPER = 887_270;
    uint16 public constant OBSERVATION_CARDINALITY = 120;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 public constant UNIV3_POOL_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    bytes32 public constant ARBITRATION_CODE_HASH =
        0xa013f13694e439351383e11933ba6fd9f7471c7f6e71b61bd916e4c5a3e6eb6e;
    bytes32 public constant VAULT_CODE_HASH =
        0xc9ca8b11dd66ea48cdd586f7b865585cb9696c2ef4c07ea12b5f8c211a11e87d;
    bytes32 public constant RELEASE_STRATEGY_CODE_HASH =
        0x522d5fde9e454fb06cb61d574a409589d73833694d16401293ac1dc9d10c347b;
    bytes32 public constant ZERO_VOTING_CODE_HASH =
        0x9cbf5af087c9e5c9ec9d2e02c921612e05dd73ef6c3b38021e8b04c7e47d3d5e;
    bytes32 public constant ECON_GATEWAY_CODE_HASH =
        0x2b267e83b551ac5a158b8bad1bb3bade5ad5d61dd3cc5719156e4489adcbeaf8;
    bytes32 public constant ECON_EVALUATOR_CODE_HASH =
        0x01376a87b521baf67a9c9cdef18c7720790e8d0bc0d1b4028658d6ebe301d7d9;
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    bytes32 public immutable CORE_CONFIG_HASH;
    bytes32 public immutable FLM_CONFIG_HASH;

    bool public coreSealed;
    bool public flmSealed;
    bool private callbackActive;

    address public space;
    address public arbitration;
    address public vault;
    address public companyToken;
    address public proposalGateway;
    address public releaseStrategy;
    address public votingStrategy;
    address public evaluator;
    address public orchestrator;
    address public resolver;
    address public futarchyFactory;
    address public weth;
    address public conditionalTokens;
    address public wrapped1155Factory;
    address public uniswapV3Factory;
    bytes32 public uniswapV3FactoryCodehash;
    address public spotPool;

    address public relay;
    address public spotAdapter;
    address public conditionalAdapter;
    address public guard;
    address public router;
    address public manager;

    error AlreadySealed();
    error EmptyCodeBlob(uint256 index);
    error InvalidCallback(address caller, int256 amount0Delta, int256 amount1Delta);
    error InvalidCodeBlobCount(uint256 count);
    error InvalidCodeHash(uint256 index, bytes32 expected, bytes32 actual);
    error InvalidConfig();
    error InvalidConfigHash(bytes32 expected, bytes32 actual);
    error InvalidDependency(address target, bytes32 expected, bytes32 actual);
    error InvalidMetadataURI();
    error InvalidPool();
    error InvalidPrice();
    error InvalidWiring();
    error ModuleDeploymentFailed(uint256 index);
    error NotSealed();
    error OnlyVault();
    error UnexpectedDeploymentAddress(uint256 nonce, address expected, address actual);

    event CoreSealed(
        address indexed vault,
        address indexed companyToken,
        address indexed space,
        address arbitration,
        address evaluator,
        address spotPool
    );
    event FlmSealed(address indexed manager, address relay, address spotAdapter);
    event BootstrapPoolPrepared(address indexed pool, uint160 sqrtPriceX96);

    constructor(bytes32 coreConfigHash, bytes32 flmConfigHash) {
        if (coreConfigHash == bytes32(0) || flmConfigHash == bytes32(0)) revert InvalidConfig();
        CORE_CONFIG_HASH = coreConfigHash;
        FLM_CONFIG_HASH = flmConfigHash;
    }

    function hashCoreConfig(CoreConfig calldata config, GenesisVault.GrantConfig[] calldata grants)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(config, grants));
    }

    function hashFlmConfig(FlmConfig calldata config) external pure returns (bytes32) {
        return keccak256(abi.encode(config));
    }

    /// @notice Permissionlessly deploys and renounces the hash-pinned economic/Snapshot core.
    function deployCore(
        CoreConfig calldata config,
        GenesisVault.GrantConfig[] calldata grants,
        bytes[] calldata baseCodes
    ) external {
        if (coreSealed) revert AlreadySealed();
        bytes32 actualHash = keccak256(abi.encode(config, grants));
        if (actualHash != CORE_CONFIG_HASH) {
            revert InvalidConfigHash(CORE_CONFIG_HASH, actualHash);
        }
        _validateCoreConfig(config, grants.length);
        _validateCoreBaseCodes(baseCodes);

        address predictedVault = _createAddress(address(this), 2);
        address predictedToken = _createAddress(predictedVault, grants.length + 2);
        address predictedPool =
            _poolAddress(config.uniswapV3Factory.target, predictedToken, config.weth.target);
        _sqrtPriceX96For(predictedToken, config.weth.target, config.initialPrice);
        uint256 terminalIncrease = Math.mulDiv(config.slope, config.saleCap, 1e18);
        if (terminalIncrease > type(uint256).max - config.initialPrice) revert InvalidPrice();
        _sqrtPriceX96For(predictedToken, config.weth.target, config.initialPrice + terminalIncrease);
        bytes32 proxySalt = keccak256(abi.encodePacked(address(this), config.spaceSaltNonce));
        address predictedSpace = IProxyFactory(config.proxyFactory.target)
            .predictProxyAddress(config.spaceImplementation.target, proxySalt);
        if (
            predictedSpace == address(0) || predictedSpace.code.length != 0
                || predictedVault.code.length != 0 || predictedToken.code.length != 0
        ) revert InvalidConfig();

        FutarchyArbitration arbitration_ = FutarchyArbitration(
            _deploy(
                abi.encodePacked(
                    baseCodes[0],
                    abi.encode(
                        IERC20(config.weth.target),
                        config.graduationThreshold,
                        config.arbitrationTimeout
                    )
                ),
                0,
                1
            )
        );

        GenesisVault.Config memory vaultConfig = GenesisVault.Config({
            tokenName: config.tokenName,
            tokenSymbol: config.tokenSymbol,
            weth: IERC20(config.weth.target),
            assembler: address(this),
            arbitration: IGenesisArbitration(address(arbitration_)),
            bootstrapHook: IGenesisBootstrapHook(address(this)),
            saleEnd: config.saleEnd,
            bootstrapDeadline: config.bootstrapDeadline,
            saleCap: config.saleCap,
            minimumRaise: config.minimumRaise,
            tokenMaxSupply: config.tokenMaxSupply,
            initialPrice: config.initialPrice,
            slope: config.slope,
            bootstrapBps: config.bootstrapBps,
            assetPolicies: config.assetPolicies
        });
        GenesisVault vault_ = GenesisVault(
            payable(_deploy(abi.encodePacked(baseCodes[1], abi.encode(vaultConfig, grants)), 1, 2))
        );
        if (address(vault_.COMPANY_TOKEN()) != predictedToken) revert InvalidWiring();

        SXArbitrationExecutionStrategy release_ = SXArbitrationExecutionStrategy(
            _deploy(
                abi.encodePacked(baseCodes[2], abi.encode(predictedSpace, address(arbitration_))),
                2,
                3
            )
        );
        AlwaysZeroVotingStrategy voting_ = AlwaysZeroVotingStrategy(_deploy(baseCodes[3], 3, 4));
        EconGateway gateway_ = EconGateway(
            _deploy(
                abi.encodePacked(
                    baseCodes[4],
                    abi.encode(
                        predictedSpace,
                        address(release_),
                        address(arbitration_),
                        address(vault_),
                        config.siteMinActivationBond,
                        config.treasuryMinActivationBond
                    )
                ),
                4,
                5
            )
        );

        address expectedEvaluator = _createAddress(address(this), 6);
        FAOSiteStackDeployer.Deployed memory market = FAOSiteStackDeployer(
                config.stackDeployer.target
            )
            .deployStack(
                config.proposalImplementation.target,
                IConditionalTokensLike(config.conditionalTokens.target),
                IWrapped1155FactoryLike(config.wrapped1155Factory.target),
                IUniswapV3FactoryLike(config.uniswapV3Factory.target),
                expectedEvaluator,
                predictedToken,
                config.weth.target,
                predictedPool,
                FEE_TIER,
                OBSERVATION_CARDINALITY,
                config.twapTimeout,
                config.twapWindow
            );
        FAOEconomicEvaluationPipeline evaluator_ = FAOEconomicEvaluationPipeline(
            _deploy(
                abi.encodePacked(
                    baseCodes[5],
                    abi.encode(
                        address(arbitration_),
                        market.orchestrator,
                        market.resolver,
                        config.conditionalTokens.target,
                        address(vault_)
                    )
                ),
                5,
                6
            )
        );

        FAOTwapResolver(market.resolver).setOrchestrator(market.orchestrator);
        arbitration_.setProposalGateway(address(gateway_));
        arbitration_.setEvaluator(address(evaluator_));
        _deploySpace(config, predictedSpace, address(gateway_), address(voting_));
        arbitration_.renounceOwnership();

        if (
            Space(predictedSpace).owner() != address(0) || arbitration_.owner() != address(0)
                || arbitration_.pendingOwner() != address(0)
                || arbitration_.proposalGateway() != address(gateway_)
                || address(arbitration_.evaluator()) != address(evaluator_)
        ) revert InvalidWiring();

        space = predictedSpace;
        arbitration = address(arbitration_);
        vault = address(vault_);
        companyToken = predictedToken;
        proposalGateway = address(gateway_);
        releaseStrategy = address(release_);
        votingStrategy = address(voting_);
        evaluator = address(evaluator_);
        orchestrator = market.orchestrator;
        resolver = market.resolver;
        futarchyFactory = market.factory;
        weth = config.weth.target;
        conditionalTokens = config.conditionalTokens.target;
        wrapped1155Factory = config.wrapped1155Factory.target;
        uniswapV3Factory = config.uniswapV3Factory.target;
        uniswapV3FactoryCodehash = config.uniswapV3Factory.codehash;
        spotPool = predictedPool;
        coreSealed = true;

        emit CoreSealed(
            address(vault_),
            predictedToken,
            predictedSpace,
            address(arbitration_),
            address(evaluator_),
            predictedPool
        );
    }

    /// @notice Permissionlessly deploys the exact W1 modules with economic bootstrap ownership.
    function deployFlm(FlmConfig calldata config, bytes[] calldata baseCodes) external {
        if (!coreSealed) revert NotSealed();
        if (flmSealed) revert AlreadySealed();
        bytes32 actualHash = keccak256(abi.encode(config));
        if (actualHash != FLM_CONFIG_HASH) {
            revert InvalidConfigHash(FLM_CONFIG_HASH, actualHash);
        }
        _requireDependency(config.positionManager);
        _validateBaseCodes(baseCodes);

        address relay_ = _deploy(
            abi.encodePacked(
                baseCodes[0],
                abi.encode(
                    arbitration,
                    evaluator,
                    uniswapV3Factory,
                    conditionalTokens,
                    FEE_TIER,
                    companyToken,
                    weth
                )
            ),
            0,
            7
        );
        address spotAdapter_ = _deploy(
            abi.encodePacked(
                baseCodes[1], abi.encode(config.positionManager.target, TICK_LOWER, TICK_UPPER)
            ),
            1,
            8
        );
        address conditionalAdapter_ = _deploy(
            abi.encodePacked(
                baseCodes[1], abi.encode(config.positionManager.target, TICK_LOWER, TICK_UPPER)
            ),
            1,
            9
        );
        address guard_ =
            _deploy(abi.encodePacked(baseCodes[2], abi.encode(uniswapV3Factory, FEE_TIER)), 2, 10);
        address router_ = _deploy(
            abi.encodePacked(baseCodes[3], abi.encode(conditionalTokens, wrapped1155Factory)), 3, 11
        );
        FutarchyLiquidityManager.LpTokenMetadata memory metadata =
            FutarchyLiquidityManager.LpTokenMetadata({name: "FAO Liquidity", symbol: "FAO-LP"});
        address manager_ = _deploy(
            abi.encodePacked(
                baseCodes[4],
                abi.encode(
                    vault,
                    companyToken,
                    weth,
                    relay_,
                    relay_,
                    spotAdapter_,
                    conditionalAdapter_,
                    router_,
                    guard_,
                    DEAD,
                    metadata
                )
            ),
            4,
            12
        );

        FAOFlmProposalSourceRelay(relay_).bindManager(IFAOFlmManagerView(manager_));
        UniswapV3LiquidityAdapter(spotAdapter_).bindManager(manager_);
        UniswapV3LiquidityAdapter(conditionalAdapter_).bindManager(manager_);
        GenesisVault(payable(vault)).bindManager(IGenesisFlm(manager_));

        _validateFlmBundle(
            config.positionManager.target,
            relay_,
            spotAdapter_,
            conditionalAdapter_,
            guard_,
            router_,
            manager_
        );

        relay = relay_;
        spotAdapter = spotAdapter_;
        conditionalAdapter = conditionalAdapter_;
        guard = guard_;
        router = router_;
        manager = manager_;
        flmSealed = true;
        emit FlmSealed(manager_, relay_, spotAdapter_);
    }

    /// @notice Vault-only normalization of an empty canonical fee-500 pool.
    /// @dev A pool with liquidity needs a positive callback delta and therefore reverts atomically.
    function prepareAndAssert(uint256 terminalPrice) external {
        if (msg.sender != vault) revert OnlyVault();
        if (!coreSealed || !flmSealed) revert NotSealed();
        if (uniswapV3Factory.codehash != uniswapV3FactoryCodehash) {
            revert InvalidDependency(
                uniswapV3Factory, uniswapV3FactoryCodehash, uniswapV3Factory.codehash
            );
        }

        uint160 target = _sqrtPriceX96(terminalPrice);
        IUniswapV3FactoryLike factory = IUniswapV3FactoryLike(uniswapV3Factory);
        address pool = factory.getPool(companyToken, weth, FEE_TIER);
        if (pool == address(0)) pool = factory.createPool(companyToken, weth, FEE_TIER);
        if (pool != spotPool || pool.code.length == 0) revert InvalidPool();

        IFaoGenesisSwapPool poolLike = IFaoGenesisSwapPool(pool);
        if (
            poolLike.token0() != (companyToken < weth ? companyToken : weth)
                || poolLike.token1() != (companyToken < weth ? weth : companyToken)
                || poolLike.fee() != FEE_TIER
        ) revert InvalidPool();

        (uint160 current,,,,,,) = poolLike.slot0();
        if (current == 0) {
            poolLike.initialize(target);
        } else if (current != target) {
            callbackActive = true;
            poolLike.swap(address(this), target < current, type(int256).max, target, "");
            callbackActive = false;
        }

        poolLike.increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);
        (uint160 prepared,,,, uint16 cardinalityNext,,) = poolLike.slot0();
        if (prepared != target || cardinalityNext < OBSERVATION_CARDINALITY) revert InvalidPool();
        emit BootstrapPoolPrepared(pool, target);
    }

    /// @notice Uniswap V3 callback that deliberately cannot pay either token.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
        view
    {
        if (!callbackActive || msg.sender != spotPool || amount0Delta != 0 || amount1Delta != 0) {
            revert InvalidCallback(msg.sender, amount0Delta, amount1Delta);
        }
    }

    function sqrtPriceX96(uint256 terminalPrice) external view returns (uint160) {
        return _sqrtPriceX96(terminalPrice);
    }

    function _sqrtPriceX96(uint256 terminalPrice) private view returns (uint160 result) {
        return _sqrtPriceX96For(companyToken, weth, terminalPrice);
    }

    function _sqrtPriceX96For(address company, address collateral, uint256 terminalPrice)
        private
        pure
        returns (uint160 result)
    {
        if (terminalPrice == 0) revert InvalidPrice();
        uint256 q192 = uint256(1) << 192;
        uint256 ratioX192 = company < collateral
            ? Math.mulDiv(terminalPrice, q192, 1e18)
            : Math.mulDiv(1e18, q192, terminalPrice);
        uint256 root = Math.sqrt(ratioX192);
        if (root <= MIN_SQRT_RATIO || root >= MAX_SQRT_RATIO) revert InvalidPrice();
        result = uint160(root);
    }

    function _deploySpace(
        CoreConfig calldata config,
        address predictedSpace,
        address gateway,
        address voting
    ) private {
        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: voting, params: ""});
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = config.votingStrategyMetadataURI;
        address[] memory authenticators = new address[](1);
        authenticators[0] = gateway;

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
        Space(predictedSpace).renounceOwnership();
    }

    function _validateCoreConfig(CoreConfig calldata config, uint256 grantCount) private view {
        _requireDependency(config.proxyFactory);
        _requireDependency(config.spaceImplementation);
        _requireDependency(config.proposalValidationStrategy);
        _requireDependency(config.stackDeployer);
        _requireDependency(config.proposalImplementation);
        _requireDependency(config.weth);
        _requireDependency(config.conditionalTokens);
        _requireDependency(config.wrapped1155Factory);
        _requireDependency(config.uniswapV3Factory);
        if (
            grantCount > MAX_VESTING_GRANTS || config.graduationThreshold == 0
                || config.arbitrationTimeout == 0 || config.siteMinActivationBond == 0
                || config.treasuryMinActivationBond == 0 || config.twapWindow == 0
                || config.twapWindow > config.twapTimeout
                || FAOSiteStackDeployer(config.stackDeployer.target).ADAPTER_REPLACEABLE()
        ) revert InvalidConfig();
        _requireMetadataURI(config.daoURI);
        _requireMetadataURI(config.metadataURI);
        _requireMetadataURI(config.votingStrategyMetadataURI);
        _requireMetadataURI(config.proposalValidationStrategyMetadataURI);
    }

    function _requireMetadataURI(string calldata uri) private pure {
        bytes calldata value = bytes(uri);
        if (
            value.length != 66 || value[0] != "i" || value[1] != "p" || value[2] != "f"
                || value[3] != "s" || value[4] != ":" || value[5] != "/" || value[6] != "/"
                || value[7] != "b"
        ) revert InvalidMetadataURI();
        for (uint256 i = 8; i < value.length; ++i) {
            bytes1 char = value[i];
            if (!((char >= "a" && char <= "z") || (char >= "2" && char <= "7"))) {
                revert InvalidMetadataURI();
            }
        }
    }

    function _validateBaseCodes(bytes[] calldata baseCodes) private pure {
        if (baseCodes.length != FLM_CODE_BLOB_COUNT) {
            revert InvalidCodeBlobCount(baseCodes.length);
        }
        bytes32[5] memory expected = [
            FlmCodeHashes.RELAY,
            FlmCodeHashes.ADAPTER,
            FlmCodeHashes.GUARD,
            FlmCodeHashes.ROUTER,
            FlmCodeHashes.MANAGER
        ];
        for (uint256 i; i < FLM_CODE_BLOB_COUNT; ++i) {
            if (baseCodes[i].length == 0) revert EmptyCodeBlob(i);
            bytes32 actual = keccak256(baseCodes[i]);
            if (actual != expected[i]) revert InvalidCodeHash(i, expected[i], actual);
        }
    }

    function _validateFlmBundle(
        address positionManager,
        address relay_,
        address spotAdapter_,
        address conditionalAdapter_,
        address guard_,
        address router_,
        address manager_
    ) private view {
        FAOFlmProposalSourceRelay relayLike = FAOFlmProposalSourceRelay(relay_);
        UniswapV3LiquidityAdapter spotLike = UniswapV3LiquidityAdapter(spotAdapter_);
        UniswapV3LiquidityAdapter conditionalLike = UniswapV3LiquidityAdapter(conditionalAdapter_);
        UniV3PoolStabilityGuard guardLike = UniV3PoolStabilityGuard(guard_);
        FutarchyConditionalRouter routerLike = FutarchyConditionalRouter(router_);
        FutarchyLiquidityManager managerLike = FutarchyLiquidityManager(payable(manager_));

        if (
            address(relayLike.MANAGER()) != manager_
                || address(relayLike.ARBITRATION()) != arbitration
                || address(relayLike.PIPELINE()) != evaluator
                || address(relayLike.UNIV3_FACTORY()) != uniswapV3Factory
                || address(relayLike.CTF()) != conditionalTokens || relayLike.FEE_TIER() != FEE_TIER
                || relayLike.COMPANY_TOKEN() != companyToken || relayLike.CURRENCY_TOKEN() != weth
                || spotLike.MANAGER() != manager_ || conditionalLike.MANAGER() != manager_
                || address(spotLike.POSITION_MANAGER()) != positionManager
                || address(conditionalLike.POSITION_MANAGER()) != positionManager
                || spotLike.DEFAULT_TICK_LOWER() != TICK_LOWER
                || spotLike.DEFAULT_TICK_UPPER() != TICK_UPPER
                || conditionalLike.DEFAULT_TICK_LOWER() != TICK_LOWER
                || conditionalLike.DEFAULT_TICK_UPPER() != TICK_UPPER
                || address(guardLike.FACTORY()) != uniswapV3Factory || guardLike.FEE() != FEE_TIER
                || address(routerLike.CONDITIONAL_TOKENS()) != conditionalTokens
                || address(routerLike.WRAPPED_1155_FACTORY()) != wrapped1155Factory
                || managerLike.owner() != DEAD || managerLike.BOOTSTRAP_RECIPIENT() != vault
                || managerLike.OFFICIAL_PROPOSER() != relay_
                || address(managerLike.PROPOSAL_SOURCE()) != relay_
                || address(managerLike.SPOT_ADAPTER()) != spotAdapter_
                || address(managerLike.CONDITIONAL_ADAPTER()) != conditionalAdapter_
                || address(managerLike.CONDITIONAL_ROUTER()) != router_
                || address(managerLike.POOL_STABILITY_GUARD()) != guard_
                || address(managerLike.COMPANY_TOKEN()) != companyToken
                || address(managerLike.WRAPPED_NATIVE()) != weth
                || managerLike.initializedFromBootstrap() || managerLike.totalSupply() != 0
                || address(GenesisVault(payable(vault)).manager()) != manager_
        ) revert InvalidWiring();
    }

    function _validateCoreBaseCodes(bytes[] calldata baseCodes) private pure {
        if (baseCodes.length != CORE_CODE_BLOB_COUNT) {
            revert InvalidCodeBlobCount(baseCodes.length);
        }
        bytes32[6] memory expected = [
            ARBITRATION_CODE_HASH,
            VAULT_CODE_HASH,
            RELEASE_STRATEGY_CODE_HASH,
            ZERO_VOTING_CODE_HASH,
            ECON_GATEWAY_CODE_HASH,
            ECON_EVALUATOR_CODE_HASH
        ];
        for (uint256 i; i < CORE_CODE_BLOB_COUNT; ++i) {
            if (baseCodes[i].length == 0) revert EmptyCodeBlob(i);
            bytes32 actual = keccak256(baseCodes[i]);
            if (actual != expected[i]) revert InvalidCodeHash(i, expected[i], actual);
        }
    }

    function _deploy(bytes memory initCode, uint256 blobIndex, uint256 nonce)
        private
        returns (address deployed)
    {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            let size := returndatasize()
            if and(iszero(deployed), gt(size, 0)) {
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        if (deployed == address(0)) revert ModuleDeploymentFailed(blobIndex);
        _expectCreate(nonce, deployed);
    }

    function _expectCreate(uint256 nonce, address deployed) private view {
        address expected = _createAddress(address(this), nonce);
        if (deployed != expected) revert UnexpectedDeploymentAddress(nonce, expected, deployed);
    }

    function _requireDependency(Dependency calldata dependency) private view {
        bytes32 actual = dependency.target.codehash;
        if (dependency.target.code.length == 0 || actual != dependency.codehash) {
            revert InvalidDependency(dependency.target, dependency.codehash, actual);
        }
    }

    function _poolAddress(address factory, address tokenA, address tokenB)
        private
        pure
        returns (address)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encode(token0, token1, FEE_TIER));
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", factory, salt, UNIV3_POOL_INIT_CODE_HASH))
                )
            )
        );
    }

    function _createAddress(address deployer, uint256 nonce) private pure returns (address) {
        if (nonce == 0 || nonce > 0x7f) revert InvalidConfig();
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, bytes1(uint8(nonce))))))
        );
    }
}
