// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {UniswapV3LiquidityAdapter} from "flm/adapters/UniswapV3LiquidityAdapter.sol";
import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {UniV3PoolStabilityGuard} from "flm/oracles/UniV3PoolStabilityGuard.sol";
import {FutarchyConditionalRouter} from "flm/routers/FutarchyConditionalRouter.sol";

import {
    FAOFlmProposalSourceRelay,
    IFAOFlmArbitrationView,
    IFAOFlmManagerView
} from "./FAOFlmProposalSourceRelay.sol";
import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "./FAOOfficialProposalOrchestrator.sol";
import {FAOSiteEvaluationPipeline} from "./FAOSiteEvaluationPipeline.sol";
import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {FlmCodeHashes} from "./generated/FlmCodeHashes.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";

/// @notice Inert receipt that atomically deploys and seals the canonical Sepolia FLM bundle.
/// @dev Child creation code arrives through a normal call so this contract's initcode stays below
/// EIP-3860. Five distinct pinned blobs produce six contracts because both adapters share a blob.
contract SepoliaFlmBundleDeployment {
    using SafeERC20 for IERC20;

    struct Dependency {
        address target;
        bytes32 codehash;
    }

    struct Config {
        Dependency weth;
        Dependency conditionalTokens;
        Dependency wrapped1155Factory;
        Dependency uniswapV3Factory;
        Dependency positionManager;
        Dependency companyToken;
        Dependency spotPool;
        Dependency arbitration;
        Dependency pipeline;
        Dependency orchestrator;
        Dependency resolver;
        Dependency futarchyFactory;
        uint256 bootstrapCompanyAmount;
        uint256 bootstrapWethAmount;
    }

    uint256 private constant CODE_BLOB_COUNT = 5;
    uint24 public constant FEE_TIER = 500;
    int24 public constant TICK_LOWER = -887_270;
    int24 public constant TICK_UPPER = 887_270;
    int24 public constant MAX_BOOTSTRAP_TICK_DEVIATION = 50;
    uint16 public constant MIN_OBSERVATION_CARDINALITY = 120;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable WETH;
    IERC20 public immutable COMPANY_TOKEN;
    address public immutable CONDITIONAL_TOKENS;
    address public immutable WRAPPED_1155_FACTORY;
    address public immutable UNIV3_FACTORY;
    address public immutable POSITION_MANAGER;
    address public immutable SPOT_POOL;
    address public immutable ARBITRATION;
    address public immutable PIPELINE;
    address public immutable ORCHESTRATOR;
    address public immutable RESOLVER;
    address public immutable FUTARCHY_FACTORY;
    uint256 public immutable BOOTSTRAP_COMPANY_AMOUNT;
    uint256 public immutable BOOTSTRAP_WETH_AMOUNT;

    bool public isSealed;
    bool public bootstrapped;
    address public relay;
    address public spotAdapter;
    address public conditionalAdapter;
    address public guard;
    address public router;
    address public manager;

    error AlreadyBootstrapped();
    error AlreadySealed();
    error ActiveEvaluation(uint256 proposalId);
    error BootstrapPoolNotReady(int24 tick, uint16 observationCardinalityNext);
    error EmptyCodeBlob(uint256 index);
    error InvalidAssetTransfer();
    error InvalidCodeBlobCount(uint256 count);
    error InvalidCodeHash(uint256 index, bytes32 expected, bytes32 actual);
    error InvalidConfig();
    error InvalidDependency(address target);
    error InvalidDependencyCodeHash(address target, bytes32 expected, bytes32 actual);
    error InvalidWiring();
    error ModuleDeploymentFailed(uint256 index);
    error NotSealed();
    error UnexpectedDeploymentAddress(uint256 nonce, address expected, address actual);

    event BundleSealed(
        address indexed relay,
        address indexed manager,
        address indexed spotAdapter,
        address conditionalAdapter,
        address guard,
        address router
    );
    event BundleBootstrapped(
        address indexed funder,
        uint256 companyAmount,
        uint256 wethAmount,
        uint256 sharesBurned,
        uint256 companyRefund,
        uint256 wethRefund
    );

    constructor(Config memory config) {
        _validateDependencies(config);
        _validateW0Wiring(config);
        if (config.bootstrapCompanyAmount == 0 || config.bootstrapWethAmount == 0) {
            revert InvalidConfig();
        }

        WETH = IERC20(config.weth.target);
        COMPANY_TOKEN = IERC20(config.companyToken.target);
        CONDITIONAL_TOKENS = config.conditionalTokens.target;
        WRAPPED_1155_FACTORY = config.wrapped1155Factory.target;
        UNIV3_FACTORY = config.uniswapV3Factory.target;
        POSITION_MANAGER = config.positionManager.target;
        SPOT_POOL = config.spotPool.target;
        ARBITRATION = config.arbitration.target;
        PIPELINE = config.pipeline.target;
        ORCHESTRATOR = config.orchestrator.target;
        RESOLVER = config.resolver.target;
        FUTARCHY_FACTORY = config.futarchyFactory.target;
        BOOTSTRAP_COMPANY_AMOUNT = config.bootstrapCompanyAmount;
        BOOTSTRAP_WETH_AMOUNT = config.bootstrapWethAmount;
    }

    /// @notice Permissionlessly deploys the exact hash-pinned bundle and consumes all bindings.
    function deployAndBind(bytes[] calldata baseCodes) external {
        if (isSealed) revert AlreadySealed();
        uint256 activeProposalId = IFAOFlmArbitrationView(ARBITRATION).activeEvaluationProposalId();
        if (activeProposalId != 0) revert ActiveEvaluation(activeProposalId);
        _validateBaseCodes(baseCodes);

        address relay_ = _deploy(
            abi.encodePacked(
                baseCodes[0],
                abi.encode(
                    ARBITRATION,
                    PIPELINE,
                    UNIV3_FACTORY,
                    CONDITIONAL_TOKENS,
                    FEE_TIER,
                    address(COMPANY_TOKEN),
                    address(WETH)
                )
            ),
            0,
            1
        );
        address spotAdapter_ = _deploy(
            abi.encodePacked(baseCodes[1], abi.encode(POSITION_MANAGER, TICK_LOWER, TICK_UPPER)),
            1,
            2
        );
        address conditionalAdapter_ = _deploy(
            abi.encodePacked(baseCodes[1], abi.encode(POSITION_MANAGER, TICK_LOWER, TICK_UPPER)),
            1,
            3
        );
        address guard_ =
            _deploy(abi.encodePacked(baseCodes[2], abi.encode(UNIV3_FACTORY, FEE_TIER)), 2, 4);
        address router_ = _deploy(
            abi.encodePacked(baseCodes[3], abi.encode(CONDITIONAL_TOKENS, WRAPPED_1155_FACTORY)),
            3,
            5
        );

        FutarchyLiquidityManager.LpTokenMetadata memory metadata =
            FutarchyLiquidityManager.LpTokenMetadata({name: "FAO Liquidity", symbol: "FAO-LP"});
        address manager_ = _deploy(
            abi.encodePacked(
                baseCodes[4],
                abi.encode(
                    address(this),
                    address(COMPANY_TOKEN),
                    address(WETH),
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
            6
        );

        FAOFlmProposalSourceRelay(relay_)
            .bindManager(
                // The relay checks the manager's exact public wiring before consuming its binding.
                // forge-lint: disable-next-line(unsafe-typecast)
                IFAOFlmManagerView(manager_)
            );
        UniswapV3LiquidityAdapter(spotAdapter_).bindManager(manager_);
        UniswapV3LiquidityAdapter(conditionalAdapter_).bindManager(manager_);
        _validateBundle(relay_, spotAdapter_, conditionalAdapter_, guard_, router_, manager_);

        relay = relay_;
        spotAdapter = spotAdapter_;
        conditionalAdapter = conditionalAdapter_;
        guard = guard_;
        router = router_;
        manager = manager_;
        isSealed = true;

        emit BundleSealed(relay_, manager_, spotAdapter_, conditionalAdapter_, guard_, router_);
    }

    /// @notice Pulls the exact canonical seed and permanently sends every initial share to DEAD.
    /// @dev An early caller can only donate the complete configured seed; dust initialization is
    /// impossible because this function has no amount parameters.
    function bootstrap() external {
        if (!isSealed) revert NotSealed();
        if (bootstrapped) revert AlreadyBootstrapped();
        _requireBootstrapPoolReady();
        bootstrapped = true;

        uint256 companyBefore = COMPANY_TOKEN.balanceOf(address(this));
        uint256 wethBefore = WETH.balanceOf(address(this));
        _pullExact(COMPANY_TOKEN, BOOTSTRAP_COMPANY_AMOUNT);
        _pullExact(WETH, BOOTSTRAP_WETH_AMOUNT);
        _forceApprove(COMPANY_TOKEN, manager, BOOTSTRAP_COMPANY_AMOUNT);
        _forceApprove(WETH, manager, BOOTSTRAP_WETH_AMOUNT);

        uint128 liquidity = FutarchyLiquidityManager(payable(manager))
            .initializeFromBootstrap(BOOTSTRAP_COMPANY_AMOUNT, BOOTSTRAP_WETH_AMOUNT);
        _forceApprove(COMPANY_TOKEN, manager, 0);
        _forceApprove(WETH, manager, 0);

        IERC20 shares = IERC20(manager);
        uint256 shareAmount = shares.balanceOf(address(this));
        if (shareAmount == 0 || shareAmount != liquidity) revert InvalidAssetTransfer();
        shares.safeTransfer(DEAD, shareAmount);

        uint256 companyRefund = _returnResidue(COMPANY_TOKEN, companyBefore, msg.sender);
        uint256 wethRefund = _returnResidue(WETH, wethBefore, msg.sender);
        if (
            COMPANY_TOKEN.balanceOf(address(this)) != 0 || WETH.balanceOf(address(this)) != 0
                || COMPANY_TOKEN.allowance(address(this), manager) != 0
                || WETH.allowance(address(this), manager) != 0
                || shares.balanceOf(address(this)) != 0
                || shares.balanceOf(DEAD) != shares.totalSupply()
        ) revert InvalidAssetTransfer();

        emit BundleBootstrapped(
            msg.sender,
            BOOTSTRAP_COMPANY_AMOUNT,
            BOOTSTRAP_WETH_AMOUNT,
            shareAmount,
            companyRefund,
            wethRefund
        );
    }

    function _validateBaseCodes(bytes[] calldata baseCodes) private pure {
        if (baseCodes.length != CODE_BLOB_COUNT) revert InvalidCodeBlobCount(baseCodes.length);
        bytes32[5] memory expected = [
            FlmCodeHashes.RELAY,
            FlmCodeHashes.ADAPTER,
            FlmCodeHashes.GUARD,
            FlmCodeHashes.ROUTER,
            FlmCodeHashes.MANAGER
        ];
        for (uint256 i; i < CODE_BLOB_COUNT; ++i) {
            if (baseCodes[i].length == 0) revert EmptyCodeBlob(i);
            bytes32 actual = keccak256(baseCodes[i]);
            if (actual != expected[i]) revert InvalidCodeHash(i, expected[i], actual);
        }
    }

    function _deploy(bytes memory initCode, uint256 blobIndex, uint8 nonce)
        private
        returns (address deployed)
    {
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            let size := returndatasize()
            if and(iszero(deployed), gt(size, 0)) {
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        if (deployed == address(0)) revert ModuleDeploymentFailed(blobIndex);
        address expected = _createAddress(nonce);
        if (deployed != expected) revert UnexpectedDeploymentAddress(nonce, expected, deployed);
    }

    function _validateBundle(
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
                || address(relayLike.ARBITRATION()) != ARBITRATION
                || address(relayLike.PIPELINE()) != PIPELINE
                || address(relayLike.UNIV3_FACTORY()) != UNIV3_FACTORY
                || address(relayLike.CTF()) != CONDITIONAL_TOKENS
                || relayLike.FEE_TIER() != FEE_TIER
                || relayLike.COMPANY_TOKEN() != address(COMPANY_TOKEN)
                || relayLike.CURRENCY_TOKEN() != address(WETH) || spotLike.MANAGER() != manager_
                || conditionalLike.MANAGER() != manager_
                || address(spotLike.POSITION_MANAGER()) != POSITION_MANAGER
                || address(conditionalLike.POSITION_MANAGER()) != POSITION_MANAGER
                || spotLike.DEFAULT_TICK_LOWER() != TICK_LOWER
                || spotLike.DEFAULT_TICK_UPPER() != TICK_UPPER
                || conditionalLike.DEFAULT_TICK_LOWER() != TICK_LOWER
                || conditionalLike.DEFAULT_TICK_UPPER() != TICK_UPPER
                || address(guardLike.FACTORY()) != UNIV3_FACTORY || guardLike.FEE() != FEE_TIER
                || address(routerLike.CONDITIONAL_TOKENS()) != CONDITIONAL_TOKENS
                || address(routerLike.WRAPPED_1155_FACTORY()) != WRAPPED_1155_FACTORY
                || managerLike.owner() != DEAD || managerLike.BOOTSTRAP_RECIPIENT() != address(this)
                || managerLike.OFFICIAL_PROPOSER() != relay_
                || address(managerLike.PROPOSAL_SOURCE()) != relay_
                || address(managerLike.SPOT_ADAPTER()) != spotAdapter_
                || address(managerLike.CONDITIONAL_ADAPTER()) != conditionalAdapter_
                || address(managerLike.CONDITIONAL_ROUTER()) != router_
                || address(managerLike.POOL_STABILITY_GUARD()) != guard_
                || address(managerLike.COMPANY_TOKEN()) != address(COMPANY_TOKEN)
                || address(managerLike.WRAPPED_NATIVE()) != address(WETH)
                || managerLike.initializedFromBootstrap() || managerLike.totalSupply() != 0
        ) revert InvalidWiring();
    }

    function _validateDependencies(Config memory config) private view {
        _requireDependency(config.weth);
        _requireDependency(config.conditionalTokens);
        _requireDependency(config.wrapped1155Factory);
        _requireDependency(config.uniswapV3Factory);
        _requireDependency(config.positionManager);
        _requireDependency(config.companyToken);
        _requireDependency(config.spotPool);
        _requireDependency(config.arbitration);
        _requireDependency(config.pipeline);
        _requireDependency(config.orchestrator);
        _requireDependency(config.resolver);
        _requireDependency(config.futarchyFactory);
    }

    function _validateW0Wiring(Config memory config) private view {
        FAOSiteEvaluationPipeline pipeline = FAOSiteEvaluationPipeline(config.pipeline.target);
        FAOOfficialProposalOrchestrator orchestrator =
            FAOOfficialProposalOrchestrator(config.orchestrator.target);
        FAOTwapResolver resolver_ = FAOTwapResolver(config.resolver.target);
        FAOFutarchyFactory factory = FAOFutarchyFactory(config.futarchyFactory.target);

        if (
            pipeline.arbitrationContract() != config.arbitration.target
                || address(pipeline.orchestrator()) != config.orchestrator.target
                || address(pipeline.resolver()) != config.resolver.target
                || address(pipeline.conditionalTokens()) != config.conditionalTokens.target
                || orchestrator.ADMIN() != config.pipeline.target
                || address(orchestrator.FACTORY()) != config.futarchyFactory.target
                || address(orchestrator.UNIV3_FACTORY()) != config.uniswapV3Factory.target
                || orchestrator.SPOT_POOL() != config.spotPool.target
                || orchestrator.COMPANY_TOKEN() != config.companyToken.target
                || orchestrator.CURRENCY_TOKEN() != config.weth.target
                || orchestrator.FEE_TIER() != FEE_TIER
                || address(orchestrator.RESOLVER()) != config.resolver.target
                || orchestrator.ADAPTER_REPLACEABLE()
                || address(orchestrator.adapter()) != address(0)
                || resolver_.orchestrator() != config.orchestrator.target
                || address(resolver_.CTF()) != config.conditionalTokens.target
                || address(factory.conditionalTokens()) != config.conditionalTokens.target
                || address(factory.wrapped1155Factory()) != config.wrapped1155Factory.target
                || factory.oracle() != config.resolver.target
                || factory.proposalImpl().code.length == 0
                || IUniswapV3FactoryLike(config.uniswapV3Factory.target)
                        .getPool(config.companyToken.target, config.weth.target, FEE_TIER)
                    != config.spotPool.target
        ) revert InvalidWiring();

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(config.spotPool.target);
        address token0 = pool.token0();
        address token1 = pool.token1();
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        if (
            !(token0 == config.companyToken.target
                    && token1 == config.weth.target
                    || token0 == config.weth.target
                    && token1 == config.companyToken.target) || pool.fee() != FEE_TIER
                || sqrtPriceX96 == 0
        ) revert InvalidWiring();
    }

    function _requireBootstrapPoolReady() private view {
        (uint160 sqrtPriceX96, int24 tick,,, uint16 observationCardinalityNext,,) =
            IUniswapV3PoolLike(SPOT_POOL).slot0();
        int256 deviation = int256(tick);
        if (deviation < 0) deviation = -deviation;
        if (
            sqrtPriceX96 == 0 || deviation > MAX_BOOTSTRAP_TICK_DEVIATION
                || observationCardinalityNext < MIN_OBSERVATION_CARDINALITY
        ) revert BootstrapPoolNotReady(tick, observationCardinalityNext);

        UniV3PoolStabilityGuard(guard).assertStablePair(address(COMPANY_TOKEN), address(WETH));
    }

    function _pullExact(IERC20 token, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) {
            revert InvalidAssetTransfer();
        }
    }

    function _returnResidue(IERC20 token, uint256 preexisting, address recipient)
        private
        returns (uint256 refund)
    {
        uint256 balance = token.balanceOf(address(this));
        if (balance < preexisting) revert InvalidAssetTransfer();
        refund = balance - preexisting;
        if (refund != 0) token.safeTransfer(recipient, refund);
        if (preexisting != 0) token.safeTransfer(DEAD, preexisting);
    }

    function _forceApprove(IERC20 token, address spender, uint256 amount) private {
        if (token.allowance(address(this), spender) != 0) token.safeApprove(spender, 0);
        if (amount != 0) token.safeApprove(spender, amount);
    }

    function _requireDependency(Dependency memory dependency) private view {
        if (dependency.target.code.length == 0) revert InvalidDependency(dependency.target);
        bytes32 actual = dependency.target.codehash;
        if (actual != dependency.codehash) {
            revert InvalidDependencyCodeHash(dependency.target, dependency.codehash, actual);
        }
    }

    function _createAddress(uint8 nonce) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), bytes1(nonce)))))
        );
    }
}
