// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";

interface IGenesisBuybackVault {
    function WETH() external view returns (IERC20);
    function COMPANY_TOKEN() external view returns (IERC20);
    function BOOTSTRAP_HOOK() external view returns (address);
    function effectiveSupply() external view returns (uint256);
}

interface IGenesisBuybackReceipt {
    function spotPool() external view returns (address);
    function guard() external view returns (address);
}

interface IGenesisBuybackGuard {
    function FACTORY() external view returns (address);
    function FEE() external view returns (uint24);
    function TWAP_WINDOW() external view returns (uint32);
    function assertStablePair(address tokenA, address tokenB) external view;
}

interface IGenesisBuybackFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IGenesisBuybackPool is IUniswapV3PoolLike {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Immutable custody and call identity controlled only by its vault.
contract GenesisTreasuryExecutor {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BUYBACK_NAV_BPS = 9500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;
    uint32 public constant BUYBACK_TWAP_WINDOW = 30 minutes;
    uint256 public constant BUYBACK_WINDOW = 1 days;
    uint256 public constant BUYBACK_DAILY_CAP = 0.01 ether;
    uint256 public constant BUYBACK_DAILY_BPS = 100;
    int24 public constant BUYBACK_MAX_TICK_DEVIATION = 50;
    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    address public immutable VAULT;

    uint64 public buybackWindowStart;
    uint192 public buybackWethSpent;

    address private callbackPool;
    IERC20 private callbackWeth;
    uint256 private callbackRemaining;
    bool private callbackWethIsToken0;

    error InvalidVault();
    error Unauthorized(address caller);
    error CallFailed(bytes reason);
    error InvalidBuybackPool();
    error InvalidBuybackPrice();
    error InvalidBuybackResult();
    error NothingToBuy();
    error InvalidCallback(address caller, int256 amount0Delta, int256 amount1Delta);

    constructor(address vault) {
        if (vault == address(0)) revert InvalidVault();
        VAULT = vault;
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) revert Unauthorized(msg.sender);
        _;
    }

    receive() external payable {}

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyVault
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
    }

    function transferAsset(address asset, address payable recipient, uint256 amount)
        external
        onlyVault
    {
        if (asset == address(0)) {
            (bool success, bytes memory reason) = recipient.call{value: amount}("");
            if (!success) revert CallFailed(reason);
            return;
        }
        IERC20(asset).safeTransfer(recipient, amount);
    }

    /// @notice Executes the fixed-policy WETH buyback; the vault burns the exact output atomically.
    function buyback() external onlyVault returns (uint256 wethSpent, uint256 companyBought) {
        IGenesisBuybackVault vault = IGenesisBuybackVault(VAULT);
        IERC20 weth = vault.WETH();
        IERC20 company = vault.COMPANY_TOKEN();
        uint256 supply = vault.effectiveSupply();
        uint256 wethBalance = weth.balanceOf(address(this));
        if (supply == 0 || wethBalance == 0) revert NothingToBuy();

        uint256 navPrice = Math.mulDiv(wethBalance, WAD, supply);
        uint256 buybackPrice = Math.mulDiv(navPrice, BUYBACK_NAV_BPS, BPS_DENOMINATOR);
        if (buybackPrice == 0) revert NothingToBuy();

        IGenesisBuybackReceipt receipt = IGenesisBuybackReceipt(vault.BOOTSTRAP_HOOK());
        IGenesisBuybackPool pool = IGenesisBuybackPool(receipt.spotPool());
        if (address(pool) == address(0) || address(pool).code.length == 0) {
            revert InvalidBuybackPool();
        }
        address token0 = pool.token0();
        address token1 = pool.token1();
        if (!(token0 == address(company) && token1 == address(weth) || token0 == address(weth)
                    && token1 == address(company))) revert InvalidBuybackPool();

        IGenesisBuybackGuard guard = IGenesisBuybackGuard(receipt.guard());
        uint24 fee = pool.fee();
        if (
            address(guard) == address(0) || address(guard).code.length == 0
                || guard.TWAP_WINDOW() != BUYBACK_TWAP_WINDOW || guard.FEE() != fee
                || IGenesisBuybackFactory(guard.FACTORY())
                        .getPool(address(company), address(weth), fee) != address(pool)
        ) revert InvalidBuybackPool();
        guard.assertStablePair(address(company), address(weth));
        int24 meanTick = _meanTick(pool);
        if (_quoteAtTick(meanTick, address(company), address(weth)) >= buybackPrice) {
            revert NothingToBuy();
        }

        if (fee >= FEE_DENOMINATOR) revert InvalidBuybackPrice();
        uint256 executionPrice = Math.mulDiv(buybackPrice, FEE_DENOMINATOR - fee, FEE_DENOMINATOR);
        uint160 priceLimit = _priceLimit(address(company) == token0, executionPrice, meanTick);
        (uint160 current,,,,,,) = pool.slot0();
        bool zeroForOne = address(weth) == token0;
        if (
            priceLimit <= MIN_SQRT_RATIO || priceLimit >= MAX_SQRT_RATIO
                || (zeroForOne ? current <= priceLimit : current >= priceLimit)
        ) revert NothingToBuy();

        uint256 windowStart = buybackWindowStart;
        uint256 spent = buybackWethSpent;
        if (windowStart == 0 || block.timestamp >= windowStart + BUYBACK_WINDOW) {
            windowStart = block.timestamp;
            spent = 0;
        }
        uint256 callCap = Math.min(
            BUYBACK_DAILY_CAP, Math.mulDiv(wethBalance, BUYBACK_DAILY_BPS, BPS_DENOMINATOR)
        );
        if (callCap <= spent) revert NothingToBuy();
        uint256 amountIn = Math.min(wethBalance, callCap - spent);
        if (amountIn > uint256(type(int256).max)) revert InvalidBuybackResult();

        uint256 companyBefore = company.balanceOf(address(this));
        callbackPool = address(pool);
        callbackWeth = weth;
        callbackRemaining = amountIn;
        callbackWethIsToken0 = zeroForOne;
        (int256 amount0, int256 amount1) =
            pool.swap(address(this), zeroForOne, int256(amountIn), priceLimit, "");
        if (callbackPool != address(0)) revert InvalidBuybackResult();
        wethSpent = wethBalance - weth.balanceOf(address(this));
        if (wethSpent != amountIn - callbackRemaining) revert InvalidBuybackResult();
        delete callbackPool;
        delete callbackWeth;
        delete callbackRemaining;
        delete callbackWethIsToken0;

        uint256 companyAfter = company.balanceOf(address(this));
        if (companyAfter <= companyBefore || wethSpent == 0) revert InvalidBuybackResult();
        companyBought = companyAfter - companyBefore;
        if (companyBought >= supply || wethSpent > Math.mulDiv(companyBought, buybackPrice, WAD)) {
            revert InvalidBuybackResult();
        }
        if (zeroForOne
                ? amount0 <= 0 || amount1 >= 0 || uint256(amount0) != wethSpent
                    || uint256(-amount1) != companyBought
                : amount0 >= 0 || amount1 <= 0 || uint256(amount1) != wethSpent
                    || uint256(-amount0) != companyBought) revert InvalidBuybackResult();

        if (windowStart > type(uint64).max) revert InvalidBuybackResult();
        buybackWindowStart = uint64(windowStart);
        buybackWethSpent = uint192(spent + wethSpent);
    }

    /// @dev Pays only the WETH leg of the one active canonical pool swap.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
    {
        IERC20 weth = callbackWeth;
        address pool = callbackPool;
        if (msg.sender != pool || pool == address(0)) {
            revert InvalidCallback(msg.sender, amount0Delta, amount1Delta);
        }
        bool wethIsToken0 = callbackWethIsToken0;
        if (wethIsToken0
                ? amount0Delta <= 0 || amount1Delta >= 0
                : amount1Delta <= 0 || amount0Delta >= 0) {
            revert InvalidCallback(msg.sender, amount0Delta, amount1Delta);
        }
        uint256 payment = uint256(wethIsToken0 ? amount0Delta : amount1Delta);
        if (payment > callbackRemaining) {
            revert InvalidCallback(msg.sender, amount0Delta, amount1Delta);
        }
        callbackRemaining -= payment;
        delete callbackPool;
        uint256 executorBefore = weth.balanceOf(address(this));
        uint256 poolBefore = weth.balanceOf(pool);
        weth.safeTransfer(pool, payment);
        if (
            executorBefore - weth.balanceOf(address(this)) != payment
                || weth.balanceOf(pool) - poolBefore != payment
        ) revert InvalidBuybackResult();
    }

    function _meanTick(IGenesisBuybackPool pool) private view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = BUYBACK_TWAP_WINDOW;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        if (tickCumulatives.length != 2) revert InvalidBuybackPrice();
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 divisor = int56(uint56(BUYBACK_TWAP_WINDOW));
        int56 mean = delta / divisor;
        if (delta < 0 && delta % divisor != 0) mean--;
        if (mean < type(int24).min || mean > type(int24).max) {
            revert InvalidBuybackPrice();
        }
        return int24(mean);
    }

    function _quoteAtTick(int24 tick, address company, address weth)
        private
        pure
        returns (uint256)
    {
        uint160 sqrtRatioX96 = _sqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return company < weth
                ? Math.mulDiv(ratioX192, WAD, uint256(1) << 192)
                : Math.mulDiv(uint256(1) << 192, WAD, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(1) << 64);
        return company < weth
            ? Math.mulDiv(ratioX128, WAD, uint256(1) << 128)
            : Math.mulDiv(uint256(1) << 128, WAD, ratioX128);
    }

    function _priceLimit(bool companyIsToken0, uint256 executionPrice, int24 meanTick)
        private
        pure
        returns (uint160)
    {
        if (executionPrice == 0) revert InvalidBuybackPrice();
        uint256 q192 = uint256(1) << 192;
        uint256 root;
        if (companyIsToken0) {
            root = Math.sqrt(Math.mulDiv(executionPrice, q192, WAD));
        } else {
            uint256 numerator = WAD * q192;
            uint256 ratio = numerator / executionPrice;
            root = Math.sqrt(ratio);
            if (root * root != ratio || numerator % executionPrice != 0) root++;
        }
        if (root > type(uint160).max) revert InvalidBuybackPrice();
        uint160 navLimit = uint160(root);
        if (companyIsToken0) {
            int256 upperTick = int256(meanTick) + BUYBACK_MAX_TICK_DEVIATION;
            if (upperTick > 887_272) upperTick = 887_272;
            uint160 upperEnvelope = _sqrtRatioAtTick(int24(upperTick));
            return navLimit < upperEnvelope ? navLimit : upperEnvelope;
        }
        int256 lowerTick = int256(meanTick) - BUYBACK_MAX_TICK_DEVIATION;
        if (lowerTick < -887_272) lowerTick = -887_272;
        uint160 lowerEnvelope = _sqrtRatioAtTick(int24(lowerTick)) + 1;
        return navLimit > lowerEnvelope ? navLimit : lowerEnvelope;
    }

    /// @dev Canonical Uniswap V3 TickMath.getSqrtRatioAtTick, inlined to avoid a new dependency.
    function _sqrtRatioAtTick(int24 tick) private pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > 887_272) revert InvalidBuybackPrice();
        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = ratio * 0xfff97272373d413259a46990580e213a >> 128;
        if (absTick & 0x4 != 0) ratio = ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc >> 128;
        if (absTick & 0x8 != 0) ratio = ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0 >> 128;
        if (absTick & 0x10 != 0) ratio = ratio * 0xffcb9843d60f6159c9db58835c926644 >> 128;
        if (absTick & 0x20 != 0) ratio = ratio * 0xff973b41fa98c081472e6896dfb254c0 >> 128;
        if (absTick & 0x40 != 0) ratio = ratio * 0xff2ea16466c96a3843ec78b326b52861 >> 128;
        if (absTick & 0x80 != 0) ratio = ratio * 0xfe5dee046a99a2a811c461f1969c3053 >> 128;
        if (absTick & 0x100 != 0) ratio = ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4 >> 128;
        if (absTick & 0x200 != 0) ratio = ratio * 0xf987a7253ac413176f2b074cf7815e54 >> 128;
        if (absTick & 0x400 != 0) ratio = ratio * 0xf3392b0822b70005940c7a398e4b70f3 >> 128;
        if (absTick & 0x800 != 0) ratio = ratio * 0xe7159475a2c29b7443b29c7fa6e889d9 >> 128;
        if (absTick & 0x1000 != 0) ratio = ratio * 0xd097f3bdfd2022b8845ad8f792aa5825 >> 128;
        if (absTick & 0x2000 != 0) ratio = ratio * 0xa9f746462d870fdf8a65dc1f90e061e5 >> 128;
        if (absTick & 0x4000 != 0) ratio = ratio * 0x70d869a156d2a1b890bb3df62baf32f7 >> 128;
        if (absTick & 0x8000 != 0) ratio = ratio * 0x31be135f97d08fd981231505542fcfa6 >> 128;
        if (absTick & 0x10000 != 0) ratio = ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9 >> 128;
        if (absTick & 0x20000 != 0) ratio = ratio * 0x5d6af8dedb81196699c329225ee604 >> 128;
        if (absTick & 0x40000 != 0) ratio = ratio * 0x2216e584f5fa1ea926041bedfe98 >> 128;
        if (absTick & 0x80000 != 0) ratio = ratio * 0x48a170391f7dc42444e8fa2 >> 128;
        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (uint256(1) << 32) == 0 ? 0 : 1));
    }
}
