// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IBeaconPoolFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IBeaconVault {
    function phase() external view returns (uint8);
    function COMPANY_TOKEN() external view returns (address);
}

interface IBeaconPool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
}

/// @notice Daily price record for the FAO/WETH spot pool, with no owner and no oracle.
/// Anyone may call `poke()` at any time. Each poke reads the pool's 30-minute average price and
/// folds it into that UTC day's low and high. Nothing is recorded before the sale has finalized,
/// because until then the pool is empty and its price costs nothing to set. Consumers that reward
/// a high price read the LOW
/// (anyone can poke during a dip to lower it); consumers that must not be fooled by a pushed-down
/// price read the HIGH (anyone can poke during a peak to raise it).
contract FaoPriceBeacon {
    error OnlyBinder();
    error AlreadyBound();
    error NotBound();
    error NotLive();
    error InvalidToken();
    error PoolMissing();
    error InvalidPrice();

    uint256 public constant WAD = 1e18;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint256 public constant SLOTS = 64;
    uint8 private constant PHASE_LIVE = 2;

    struct Day {
        uint64 day;
        uint96 low;
        uint96 high;
    }

    IBeaconPoolFactory public immutable FACTORY;
    address public immutable WETH;
    uint24 public immutable FEE;
    address public immutable BINDER;

    IBeaconVault public vault;
    address public token;
    address public pool;
    Day[SLOTS] private _days;

    event Bound(address indexed token);
    event Poked(uint64 indexed day, uint256 price, uint256 low, uint256 high);

    constructor(IBeaconPoolFactory factory, address weth, uint24 fee) {
        if (address(factory) == address(0) || weth == address(0) || fee == 0) {
            revert InvalidToken();
        }
        FACTORY = factory;
        WETH = weth;
        FEE = fee;
        BINDER = msg.sender;
    }

    /// @notice One-time wiring by the deployer. The binder has no other power.
    function bind(IBeaconVault vault_) external {
        if (msg.sender != BINDER) revert OnlyBinder();
        if (token != address(0)) revert AlreadyBound();
        address token_ = vault_.COMPANY_TOKEN();
        if (token_ == address(0) || token_ == WETH) revert InvalidToken();
        vault = vault_;
        token = token_;
        emit Bound(token_);
    }

    /// @notice Current 30-minute average price, in WETH per FAO scaled by 1e18.
    function twap() public view returns (uint256 price) {
        address token_ = token;
        if (token_ == address(0)) revert NotBound();
        address pool_ = pool;
        if (pool_ == address(0)) {
            pool_ = FACTORY.getPool(token_, WETH, FEE);
            if (pool_ == address(0)) revert PoolMissing();
        }
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        (int56[] memory tickCumulatives,) = IBeaconPool(pool_).observe(secondsAgos);
        if (tickCumulatives.length != 2) revert InvalidPrice();
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 divisor = int56(uint56(TWAP_WINDOW));
        int56 mean = delta / divisor;
        if (delta < 0 && delta % divisor != 0) mean--;
        if (mean < -887_272 || mean > 887_272) revert InvalidPrice();
        price = _quoteAtTick(int24(mean), token_ < WETH);
        if (price == 0 || price > type(uint96).max) revert InvalidPrice();
    }

    /// @notice Records the current average price into today's low and high.
    function poke() public returns (uint256 price) {
        address token_ = token;
        if (token_ == address(0)) revert NotBound();
        if (vault.phase() != PHASE_LIVE) revert NotLive();
        if (pool == address(0)) {
            address pool_ = FACTORY.getPool(token_, WETH, FEE);
            if (pool_ == address(0)) revert PoolMissing();
            pool = pool_;
        }
        price = twap();
        uint64 day = uint64(block.timestamp / 1 days);
        Day storage slot = _days[day % SLOTS];
        if (slot.day != day) {
            slot.day = day;
            slot.low = uint96(price);
            slot.high = uint96(price);
        } else {
            if (price < slot.low) slot.low = uint96(price);
            if (price > slot.high) slot.high = uint96(price);
        }
        emit Poked(day, price, slot.low, slot.high);
    }

    function today() public view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    /// @return recorded Whether `day` has a record still held in the ring.
    function dayRecord(uint64 day) public view returns (bool recorded, uint256 low, uint256 high) {
        Day storage slot = _days[day % SLOTS];
        if (slot.day != day || slot.high == 0) return (false, 0, 0);
        return (true, slot.low, slot.high);
    }

    /// @notice True when each of the `count` complete days before today has a record whose low
    /// is at least `level`. Today is excluded because its low can still fall.
    function heldAbove(uint256 level, uint256 count) external view returns (bool) {
        uint64 day = today();
        if (count == 0 || count >= SLOTS || day < count) return false;
        for (uint64 d = day - uint64(count); d < day; ++d) {
            (bool recorded, uint256 low,) = dayRecord(d);
            if (!recorded || low < level) return false;
        }
        return true;
    }

    /// @notice Highest recorded price over today and the `count` days before it.
    function highOver(uint256 count) public view returns (uint256 highest) {
        uint64 day = today();
        if (count >= SLOTS) count = SLOTS - 1;
        uint64 first = day > count ? day - uint64(count) : 0;
        for (uint64 d = first; d <= day; ++d) {
            (bool recorded,, uint256 high) = dayRecord(d);
            if (recorded && high > highest) highest = high;
        }
    }

    /// @notice Pokes, then returns the higher of the current average and the recent recorded high.
    function pokeAndHighOver(uint256 count) external returns (uint256) {
        uint256 current = poke();
        uint256 recent = highOver(count);
        return current > recent ? current : recent;
    }

    /// @dev WETH per company token at `tick`, scaled by 1e18.
    function _quoteAtTick(int24 tick, bool companyIsToken0) private pure returns (uint256) {
        uint160 sqrtRatioX96 = _sqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return companyIsToken0
                ? Math.mulDiv(ratioX192, WAD, uint256(1) << 192)
                : Math.mulDiv(uint256(1) << 192, WAD, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(1) << 64);
        return companyIsToken0
            ? Math.mulDiv(ratioX128, WAD, uint256(1) << 128)
            : Math.mulDiv(uint256(1) << 128, WAD, ratioX128);
    }

    /// @dev Canonical Uniswap V3 TickMath.getSqrtRatioAtTick (same constants as
    /// GenesisTreasuryExecutor, which keeps its own private copy).
    function _sqrtRatioAtTick(int24 tick) private pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
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
