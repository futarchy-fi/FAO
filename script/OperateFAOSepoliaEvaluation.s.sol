// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOSiteEvaluationPipeline} from "../src/FAOSiteEvaluationPipeline.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

interface IOperatorArbitration {
    function activeEvaluationProposalId() external view returns (uint256);
}

interface IOperatorConditionalTokens {
    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external;
}

interface IOperatorWeth is IERC20 {
    function deposit() external payable;
}

interface IOperatorPoolLiquidity {
    function liquidity() external view returns (uint128);
}

interface IOperatorPositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IOperatorSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Operator-funded first-liquidity canary for one live Sepolia evaluation.
/// @dev No contract is deployed. `run()` seeds both official pools and buys YES-company with
/// YES-WETH. Call `resolve()` permissionlessly after the immutable TWAP timeout.
///
/// Required env: PRIVATE_KEY, EVALUATOR, ARBITRATION_PROPOSAL_ID. Run immediately after
/// startEvaluation with `forge script script/OperateFAOSepoliaEvaluation.s.sol --rpc-url
/// $SEPOLIA_RPC_URL --broadcast --slow`. After RESOLVE_AFTER, repeat with `--sig "resolve()"`.
contract OperateFAOSepoliaEvaluation is Script {
    using SafeERC20 for IERC20;

    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address internal constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

    bytes32 internal constant POSITION_MANAGER_CODEHASH =
        0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868;
    bytes32 internal constant SWAP_ROUTER_CODEHASH =
        0xe7f98ee73dfe6d5c96cbf8936920f496b1b82f24326d6a415b4144a2252271de;

    uint24 internal constant FEE = 500;
    int24 internal constant TICK_LOWER = -887_270;
    int24 internal constant TICK_UPPER = 887_270;
    uint256 internal constant ONE_TO_ONE_TICK_TOLERANCE = 2;
    uint256 internal constant MAX_POST_MOVE_TICKS = 500;

    error DependencyMismatch(address target);
    error EvaluationNotActive(uint256 expected, uint256 active);
    error EvaluationNotStarted(uint256 proposalId);
    error InitialPriceMismatch(int24 yesTick, int24 noTick);
    error InvalidAmount(uint256 seedAmount, uint256 moveAmount);
    error InvalidBinding();
    error InvalidChain(uint256 chainId);
    error InsufficientBalance(address token, uint256 available, uint256 required);
    error MoveTooLate(uint256 latestMoveTime, uint256 currentTime);
    error PriceMoveFailed(int24 beforeTick, int24 afterTick, int24 noTick);
    error ResolutionRejected();

    function run() external {
        _requireSepoliaDependencies();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address operator = vm.addr(privateKey);
        FAOSiteEvaluationPipeline evaluator = FAOSiteEvaluationPipeline(vm.envAddress("EVALUATOR"));
        uint256 arbitrationProposalId = vm.envUint("ARBITRATION_PROPOSAL_ID");
        uint256 seedAmount = vm.envOr("CONDITIONAL_SEED_AMOUNT", uint256(0.0001 ether));
        uint256 moveAmount = vm.envOr("YES_MOVE_AMOUNT", seedAmount / 100);
        if (seedAmount == 0 || moveAmount == 0 || moveAmount > seedAmount / 20) {
            revert InvalidAmount(seedAmount, moveAmount);
        }

        address arbitration = evaluator.arbitrationContract();
        uint256 active = IOperatorArbitration(arbitration).activeEvaluationProposalId();
        if (active != arbitrationProposalId) {
            revert EvaluationNotActive(arbitrationProposalId, active);
        }

        address proposalAddress = evaluator.futarchyProposalOf(arbitrationProposalId);
        if (proposalAddress == address(0)) revert EvaluationNotStarted(arbitrationProposalId);
        FAOFutarchyProposal proposal = FAOFutarchyProposal(proposalAddress);
        FAOOfficialProposalOrchestrator orchestrator =
            FAOOfficialProposalOrchestrator(address(evaluator.orchestrator()));
        FAOTwapResolver resolver = FAOTwapResolver(address(evaluator.resolver()));
        _requireWiring(evaluator, orchestrator, resolver, proposalAddress);

        (
            address yesPool,
            address noPool,
            address boundCompany,
            address boundCurrency,,
            uint48 anchorTimestamp,
            bool alreadyResolved,
        ) = resolver.bindings(proposalAddress);
        if (
            yesPool == address(0) || noPool == address(0) || alreadyResolved
                || IOperatorPoolLiquidity(yesPool).liquidity() != 0
                || IOperatorPoolLiquidity(noPool).liquidity() != 0
                || boundCompany != orchestrator.COMPANY_TOKEN()
                || boundCurrency != orchestrator.CURRENCY_TOKEN()
        ) revert InvalidBinding();

        uint256 latestMoveTime =
            uint256(anchorTimestamp) + resolver.TIMEOUT() - resolver.TWAP_WINDOW();
        if (block.timestamp > latestMoveTime) revert MoveTooLate(latestMoveTime, block.timestamp);

        (address yesCompany, bytes memory yesCompanyData) = proposal.wrappedOutcome(0);
        (address noCompany, bytes memory noCompanyData) = proposal.wrappedOutcome(1);
        (address yesCurrency, bytes memory yesCurrencyData) = proposal.wrappedOutcome(2);
        (address noCurrency, bytes memory noCurrencyData) = proposal.wrappedOutcome(3);
        _requirePools(orchestrator, yesPool, noPool, yesCompany, noCompany, yesCurrency, noCurrency);

        int24 yesTickBefore = _economicTick(yesPool, yesCompany);
        int24 noTick = _economicTick(noPool, noCompany);
        if (
            _abs(yesTickBefore) > ONE_TO_ONE_TICK_TOLERANCE
                || _abs(noTick) > ONE_TO_ONE_TICK_TOLERANCE
                || _absDiff(yesTickBefore, noTick) > ONE_TO_ONE_TICK_TOLERANCE
        ) revert InitialPriceMismatch(yesTickBefore, noTick);

        address company = orchestrator.COMPANY_TOKEN();
        uint256 currencyRequired = seedAmount + moveAmount;
        uint256 companyBalance = IERC20(company).balanceOf(operator);
        if (companyBalance < seedAmount) {
            revert InsufficientBalance(company, companyBalance, seedAmount);
        }

        vm.startBroadcast(privateKey);
        uint256 wethBalance = IERC20(WETH).balanceOf(operator);
        if (wethBalance < currencyRequired) {
            IOperatorWeth(WETH).deposit{value: currencyRequired - wethBalance}();
        }

        IConditionalTokensLike ctf = IConditionalTokensLike(address(evaluator.conditionalTokens()));
        _split(ctf, company, proposal.conditionId(), seedAmount);
        _split(ctf, WETH, proposal.conditionId(), currencyRequired);

        _wrap(ctf, operator, company, proposal.conditionId(), 1, yesCompanyData, seedAmount);
        _wrap(ctf, operator, company, proposal.conditionId(), 2, noCompanyData, seedAmount);
        _wrap(ctf, operator, WETH, proposal.conditionId(), 1, yesCurrencyData, currencyRequired);
        _wrap(ctf, operator, WETH, proposal.conditionId(), 2, noCurrencyData, currencyRequired);

        (uint256 yesNft, uint128 yesLiquidity) =
            _mint(operator, yesPool, yesCompany, yesCurrency, seedAmount);
        (uint256 noNft, uint128 noLiquidity) =
            _mint(operator, noPool, noCompany, noCurrency, seedAmount);

        IERC20(yesCurrency).safeApprove(SWAP_ROUTER, moveAmount);
        uint256 amountOut = IOperatorSwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IOperatorSwapRouter.ExactInputSingleParams({
                    tokenIn: yesCurrency,
                    tokenOut: yesCompany,
                    fee: FEE,
                    recipient: operator,
                    amountIn: moveAmount,
                    amountOutMinimum: (moveAmount * 98) / 100,
                    sqrtPriceLimitX96: _boundedYesPriceLimit(yesPool, yesCompany)
                })
            );
        vm.stopBroadcast();

        int24 yesTickAfter = _economicTick(yesPool, yesCompany);
        if (
            yesTickAfter <= noTick || yesTickAfter <= yesTickBefore
                || _absDiff(yesTickAfter, yesTickBefore) > MAX_POST_MOVE_TICKS
        ) revert PriceMoveFailed(yesTickBefore, yesTickAfter, noTick);

        console2.log("PROPOSAL=", proposalAddress);
        console2.log("YES_POOL=", yesPool);
        console2.log("NO_POOL=", noPool);
        console2.log("YES_LP_NFT=", yesNft);
        console2.log("NO_LP_NFT=", noNft);
        console2.log("YES_LIQUIDITY=", uint256(yesLiquidity));
        console2.log("NO_LIQUIDITY=", uint256(noLiquidity));
        console2.log("YES_SWAP_OUT=", amountOut);
        console2.log("RESOLVE_AFTER=", resolver.windowEndOf(proposalAddress));
    }

    /// @notice Permissionless second phase, run once RESOLVE_AFTER has passed.
    function resolve() external {
        if (block.chainid != 11_155_111) revert InvalidChain(block.chainid);
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        FAOSiteEvaluationPipeline evaluator = FAOSiteEvaluationPipeline(vm.envAddress("EVALUATOR"));
        uint256 arbitrationProposalId = vm.envUint("ARBITRATION_PROPOSAL_ID");

        vm.startBroadcast(privateKey);
        bool accepted = evaluator.resolve(arbitrationProposalId);
        vm.stopBroadcast();
        if (!accepted) revert ResolutionRejected();
        console2.log("EVALUATED_YES_PROPOSAL=", arbitrationProposalId);
    }

    function _requireSepoliaDependencies() private view {
        if (block.chainid != 11_155_111) revert InvalidChain(block.chainid);
        if (POSITION_MANAGER.codehash != POSITION_MANAGER_CODEHASH) {
            revert DependencyMismatch(POSITION_MANAGER);
        }
        if (SWAP_ROUTER.codehash != SWAP_ROUTER_CODEHASH) {
            revert DependencyMismatch(SWAP_ROUTER);
        }
        if (
            IOperatorPositionManager(POSITION_MANAGER).factory() != UNISWAP_V3_FACTORY
                || IOperatorSwapRouter(SWAP_ROUTER).factory() != UNISWAP_V3_FACTORY
        ) revert DependencyMismatch(UNISWAP_V3_FACTORY);
    }

    function _requireWiring(
        FAOSiteEvaluationPipeline evaluator,
        FAOOfficialProposalOrchestrator orchestrator,
        FAOTwapResolver resolver,
        address proposal
    ) private view {
        FAOFutarchyFactory factory = orchestrator.FACTORY();
        if (
            address(orchestrator.RESOLVER()) != address(resolver)
                || address(orchestrator.UNIV3_FACTORY()) != UNISWAP_V3_FACTORY
                || orchestrator.CURRENCY_TOKEN() != WETH || orchestrator.FEE_TIER() != FEE
                || address(factory.conditionalTokens()) != address(evaluator.conditionalTokens())
                || address(factory.wrapped1155Factory()) != WRAPPED_1155_FACTORY
                || address(resolver.CTF()) != address(evaluator.conditionalTokens())
                || proposal.code.length == 0
        ) revert InvalidBinding();
    }

    function _requirePools(
        FAOOfficialProposalOrchestrator orchestrator,
        address yesPool,
        address noPool,
        address yesCompany,
        address noCompany,
        address yesCurrency,
        address noCurrency
    ) private view {
        IUniswapV3FactoryLike factory = orchestrator.UNIV3_FACTORY();
        if (
            factory.getPool(yesCompany, yesCurrency, FEE) != yesPool
                || factory.getPool(noCompany, noCurrency, FEE) != noPool
        ) revert InvalidBinding();
    }

    function _split(
        IConditionalTokensLike ctf,
        address collateral,
        bytes32 conditionId,
        uint256 amount
    ) private {
        IERC20(collateral).safeApprove(address(ctf), amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        IOperatorConditionalTokens(address(ctf))
            .splitPosition(collateral, bytes32(0), conditionId, partition, amount);
    }

    function _wrap(
        IConditionalTokensLike ctf,
        address operator,
        address collateral,
        bytes32 conditionId,
        uint256 indexSet,
        bytes memory tokenData,
        uint256 amount
    ) private {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = ctf.getPositionId(collateral, collectionId);
        IOperatorConditionalTokens(address(ctf))
            .safeTransferFrom(operator, WRAPPED_1155_FACTORY, tokenId, amount, tokenData);
    }

    function _mint(
        address operator,
        address pool,
        address companyWrapper,
        address currencyWrapper,
        uint256 amount
    ) private returns (uint256 tokenId, uint128 liquidity) {
        address token0 = IUniswapV3PoolLike(pool).token0();
        address token1 = IUniswapV3PoolLike(pool).token1();
        if (
            !(token0 == companyWrapper && token1 == currencyWrapper)
                && !(token0 == currencyWrapper && token1 == companyWrapper)
        ) revert InvalidBinding();

        IERC20(token0).safeApprove(POSITION_MANAGER, amount);
        IERC20(token1).safeApprove(POSITION_MANAGER, amount);
        (tokenId, liquidity,,) = IOperatorPositionManager(POSITION_MANAGER)
            .mint(
                IOperatorPositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: FEE,
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: (amount * 99) / 100,
                    amount1Min: (amount * 99) / 100,
                    recipient: operator,
                    deadline: block.timestamp + 10 minutes
                })
            );
        IERC20(token0).safeApprove(POSITION_MANAGER, 0);
        IERC20(token1).safeApprove(POSITION_MANAGER, 0);
    }

    function _boundedYesPriceLimit(address pool, address yesCompany)
        private
        view
        returns (uint160)
    {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        (uint160 current,,,,,,) = p.slot0();
        // A 2.4% sqrt move is a <4.86% economic-price move. Buying company with currency
        // raises the normalized economic price regardless of wrapper address ordering.
        if (p.token0() == yesCompany) return uint160(uint256(current) * 1024 / 1000);
        return uint160(uint256(current) * 1000 / 1024);
    }

    function _economicTick(address pool, address companyWrapper) private view returns (int24) {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        (, int24 tick,,,,,) = p.slot0();
        return p.token0() == companyWrapper ? tick : -tick;
    }

    function _abs(int24 value) private pure returns (uint256) {
        return value < 0 ? uint256(uint24(-value)) : uint256(uint24(value));
    }

    function _absDiff(int24 a, int24 b) private pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }
}
