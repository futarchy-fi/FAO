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

/// @notice Price record for the FAO/WETH spot pool, with no owner and no oracle.
///
/// The pool keeps a running total of its tick over time. Anyone may call `poke()`. A poke made
/// at least `PERIOD` after the previous checkpoint reads that total, closes the interval since
/// the previous checkpoint and stores the interval's time-weighted average price. Because an
/// interval is at least a day long, its average cannot be moved by a short push in either
/// direction, and it does not matter who pokes or when: the average covers every second of the
/// interval. Reading the running total "now" never depends on how much history the pool keeps.
///
/// Nothing is recorded before the sale has finalized: until then the pool is empty and its price
/// costs nothing to set.
contract FaoPriceBeacon {
    error OnlyBinder();
    error AlreadyBound();
    error NotBound();
    error NotLive();
    error InvalidToken();
    error PoolMissing();
    error InvalidPrice();

    uint256 public constant WAD = 1e18;
    /// @notice Shortest interval between two checkpoints.
    uint256 public constant PERIOD = 1 days;
    /// @notice Longest interval that still counts as evidence of a sustained price.
    uint256 public constant MAX_INTERVAL = 2 days;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint256 public constant SLOTS = 64;
    uint8 private constant PHASE_LIVE = 2;

    struct Interval {
        uint48 start;
        uint48 end;
        uint96 price; // time-weighted average over [start, end], WETH per FAO scaled by 1e18
    }

    IBeaconPoolFactory public immutable FACTORY;
    address public immutable WETH;
    uint24 public immutable FEE;
    address public immutable BINDER;

    IBeaconVault public vault;
    address public token;
    address public pool;

    /// @notice Time and running tick total of the latest checkpoint. Zero time means none yet.
    uint48 public checkpointAt;
    int56 public checkpointCumulative;

    /// @notice Number of intervals ever closed. Interval i lives in slot i % SLOTS.
    uint256 public intervalCount;
    Interval[SLOTS] private _intervals;

    event Bound(address indexed token);
    event Checkpointed(uint256 timestamp);
    event IntervalClosed(uint256 indexed index, uint256 start, uint256 end, uint256 price);

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

    // ------------------------------------------------------------------ recording

    /// @notice Takes a checkpoint if at least `PERIOD` has passed since the last one, closing the
    /// interval in between. Does nothing otherwise.
    function poke() public {
        address token_ = token;
        if (token_ == address(0)) revert NotBound();
        if (vault.phase() != PHASE_LIVE) revert NotLive();
        address pool_ = pool;
        if (pool_ == address(0)) {
            pool_ = FACTORY.getPool(token_, WETH, FEE);
            if (pool_ == address(0)) revert PoolMissing();
            pool = pool_;
        }

        uint256 last = checkpointAt;
        if (last != 0 && block.timestamp - last < PERIOD) return;

        int56 cumulative = _cumulativeNow(pool_);
        if (last != 0) {
            uint256 price = _meanPrice(cumulative - checkpointCumulative, block.timestamp - last);
            uint256 index = intervalCount;
            _intervals[index % SLOTS] =
                Interval(uint48(last), uint48(block.timestamp), uint96(price));
            intervalCount = index + 1;
            emit IntervalClosed(index, last, block.timestamp, price);
        }
        checkpointAt = uint48(block.timestamp);
        checkpointCumulative = cumulative;
        emit Checkpointed(block.timestamp);
    }

    // ------------------------------------------------------------------ reading

    /// @notice Interval `index` (0 is the first ever closed). Reverts once the ring has reused
    /// its slot.
    function interval(uint256 index)
        external
        view
        returns (uint256 start, uint256 end, uint256 price)
    {
        uint256 count = intervalCount;
        if (index >= count || count - index > SLOTS) revert InvalidPrice();
        Interval memory i = _intervals[index % SLOTS];
        return (i.start, i.end, i.price);
    }

    /// @notice True when the most recent closed intervals, back to at least `daysHeld` days
    /// before the latest checkpoint, each averaged at least `level` and none is longer than
    /// `MAX_INTERVAL`, and the latest checkpoint is itself no older than `MAX_INTERVAL`.
    function heldAbove(uint256 level, uint256 daysHeld) external view returns (bool) {
        uint256 count = intervalCount;
        uint256 needed = daysHeld * 1 days;
        if (needed == 0 || count == 0) return false;
        if (block.timestamp - checkpointAt > MAX_INTERVAL) return false;

        uint256 covered;
        uint256 oldest = count > SLOTS ? count - SLOTS : 0;
        for (uint256 index = count; index > oldest;) {
            unchecked {
                --index;
            }
            Interval memory i = _intervals[index % SLOTS];
            uint256 length = uint256(i.end) - i.start;
            if (length > MAX_INTERVAL || i.price < level) return false;
            covered += length;
            if (covered >= needed) return true;
        }
        return false;
    }

    /// @notice Highest average among intervals that ended within the last `lookbackDays` days.
    function highOver(uint256 lookbackDays) public view returns (uint256 highest) {
        uint256 count = intervalCount;
        uint256 horizon = lookbackDays * 1 days;
        uint256 oldest = count > SLOTS ? count - SLOTS : 0;
        for (uint256 index = count; index > oldest;) {
            unchecked {
                --index;
            }
            Interval memory i = _intervals[index % SLOTS];
            if (block.timestamp - i.end > horizon) break;
            if (i.price > highest) highest = i.price;
        }
    }

    /// @notice Current 30-minute average price, in WETH per FAO scaled by 1e18.
    function twap() public view returns (uint256) {
        address pool_ = _poolView();
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        (int56[] memory tickCumulatives,) = IBeaconPool(pool_).observe(secondsAgos);
        if (tickCumulatives.length != 2) revert InvalidPrice();
        return _meanPrice(tickCumulatives[1] - tickCumulatives[0], TWAP_WINDOW);
    }

    /// @notice Pokes, then returns a price that a short push downwards cannot lower: the highest
    /// of the current 30-minute average, the average since the latest checkpoint, and the
    /// highest interval average of the last `lookbackDays` days.
    function pokeAndReference(uint256 lookbackDays) external returns (uint256 refPrice) {
        poke();
        refPrice = twap();
        uint256 recent = highOver(lookbackDays);
        if (recent > refPrice) refPrice = recent;
        uint256 elapsed = block.timestamp - checkpointAt;
        if (elapsed >= TWAP_WINDOW) {
            uint256 running = _meanPrice(_cumulativeNow(pool) - checkpointCumulative, elapsed);
            if (running > refPrice) refPrice = running;
        }
    }

    // ------------------------------------------------------------------ internals

    function _poolView() private view returns (address pool_) {
        pool_ = pool;
        if (pool_ == address(0)) {
            address token_ = token;
            if (token_ == address(0)) revert NotBound();
            pool_ = FACTORY.getPool(token_, WETH, FEE);
            if (pool_ == address(0)) revert PoolMissing();
        }
    }

    function _cumulativeNow(address pool_) private view returns (int56) {
        uint32[] memory secondsAgos = new uint32[](1);
        (int56[] memory tickCumulatives,) = IBeaconPool(pool_).observe(secondsAgos);
        if (tickCumulatives.length != 1) revert InvalidPrice();
        return tickCumulatives[0];
    }

    /// @dev Average price over `elapsed` seconds from a change in the pool's running tick total.
    /// The mean tick is oriented so that a dearer FAO is a higher tick and rounded down, so the
    /// price is never overstated.
    function _meanPrice(int56 delta, uint256 elapsed) private view returns (uint256 price) {
        bool companyIsToken0 = token < WETH;
        if (!companyIsToken0) delta = -delta;
        int56 divisor = int56(uint56(elapsed));
        int56 mean = delta / divisor;
        if (delta < 0 && delta % divisor != 0) mean--;
        if (mean < -887_272 || mean > 887_272) revert InvalidPrice();
        // In the oriented frame the company is always the base token.
        price = _quoteAtTick(int24(mean));
        if (price == 0 || price > type(uint96).max) revert InvalidPrice();
    }

    /// @dev Quote-per-base price at `tick` (1.0001^tick), scaled by 1e18.
    function _quoteAtTick(int24 tick) private pure returns (uint256) {
        uint160 sqrtRatioX96 = _sqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return Math.mulDiv(ratioX192, WAD, uint256(1) << 192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, uint256(1) << 64);
        return Math.mulDiv(ratioX128, WAD, uint256(1) << 128);
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
