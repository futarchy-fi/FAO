// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Pricing rule for the genesis sale, kept apart from the vault that holds the money.
///
/// The price of the next token when `s` tokens are sold is
///
///     price(s) = INITIAL_PRICE                              for s <= base
///     price(s) = INITIAL_PRICE + slope * (s - base)         for s >  base
///
/// Two configurations:
///
/// 1. Fixed price, then doubling curve (`FIXED_MINIMUM != 0`). Every token costs `INITIAL_PRICE`
///    until `FIXED_PRICE_END`, with no cap on how much is sold in that window. `base` is the
///    amount sold at the fixed price, and never less than `FIXED_MINIMUM`: if the window ends
///    short of the minimum, the fixed price continues until the minimum is sold. After that
///    `slope = INITIAL_PRICE / base`, so the price has doubled when the supply has doubled.
///
/// 2. Plain linear curve (`FIXED_MINIMUM == 0`). `base` is zero and `slope` is the explicit
///    `SLOPE`, which may be zero for a flat price.
///
/// The curve is deployed before its vault and bound to it once by its deployer: the vault's
/// address can depend on the curve's (through the genesis configuration hash), so it cannot be a
/// constructor argument. The vault refuses a curve that is not bound to it.
///
/// The only other state is `base`, written once by the vault on the first purchase after the
/// fixed-price window. `reserveAt` is then a fixed function of the amount sold, rounded once, so
/// what a range of tokens costs does not depend on how the purchases were split.
contract FaoSaleCurve {
    error InvalidConfig();
    error OnlyVault();
    error OnlyBinder();
    error AlreadyBound();

    uint256 public constant WAD = 1e18;

    /// @notice The deployer. Its only power is to bind the curve to its vault, once.
    address public immutable BINDER;
    /// @notice The vault this curve prices for. Zero until bound.
    address public vault;
    /// @notice WETH per token, scaled by 1e18.
    uint256 public immutable INITIAL_PRICE;
    /// @notice Explicit slope for the plain linear curve; must be zero with a fixed-price window.
    uint256 public immutable SLOPE;
    uint64 public immutable FIXED_PRICE_END;
    uint256 public immutable FIXED_MINIMUM;

    /// @notice Tokens sold at the fixed price. Zero until the curve starts.
    uint256 public base;
    bool public started;

    event Bound(address indexed vault);
    event CurveStarted(uint256 base);

    constructor(uint256 initialPrice, uint256 slope, uint64 fixedPriceEnd, uint256 fixedMinimum) {
        if (initialPrice == 0) revert InvalidConfig();
        if (fixedMinimum == 0 ? fixedPriceEnd != 0 : slope != 0) revert InvalidConfig();
        BINDER = msg.sender;
        INITIAL_PRICE = initialPrice;
        SLOPE = slope;
        FIXED_PRICE_END = fixedPriceEnd;
        FIXED_MINIMUM = fixedMinimum;
    }

    /// @notice One-time wiring by the deployer, before the vault is created.
    function bind(address vault_) external {
        if (msg.sender != BINDER) revert OnlyBinder();
        if (vault != address(0)) revert AlreadyBound();
        if (vault_ == address(0)) revert InvalidConfig();
        vault = vault_;
        emit Bound(vault_);
    }

    /// @notice Called by the vault before it prices a purchase. Starts the curve once the
    /// fixed-price window is over.
    function sync(uint256 totalSold) external {
        if (msg.sender != vault) revert OnlyVault();
        if (!started && block.timestamp >= FIXED_PRICE_END) {
            uint256 base_ = _baseAt(totalSold);
            base = base_;
            started = true;
            emit CurveStarted(base_);
        }
    }

    /// @notice Total WETH paid for the first `supply` tokens, given `totalSold` sold so far.
    /// @dev Rounded up once, so a purchase never pays less than the exact price.
    function reserveAt(uint256 supply, uint256 totalSold) public view returns (uint256) {
        if (FIXED_MINIMUM == 0) {
            uint256 linearTerm = 2 * INITIAL_PRICE * WAD + SLOPE * supply;
            return Math.mulDiv(supply, linearTerm, 2 * WAD * WAD, Math.Rounding.Up);
        }
        (bool curve, uint256 base_) = _phase(totalSold);
        if (!curve || supply <= base_) {
            return Math.mulDiv(supply, INITIAL_PRICE, WAD, Math.Rounding.Up);
        }
        // INITIAL_PRICE * base + integral of INITIAL_PRICE * x / base from base to supply
        //   = INITIAL_PRICE * (base^2 + supply^2) / (2 * base)
        return Math.mulDiv(
            INITIAL_PRICE, base_ * base_ + supply * supply, 2 * base_ * WAD, Math.Rounding.Up
        );
    }

    /// @notice Cost of buying `amount` more tokens when `totalSold` are sold.
    function cost(uint256 totalSold, uint256 amount) external view returns (uint256) {
        return reserveAt(totalSold + amount, totalSold) - reserveAt(totalSold, totalSold);
    }

    /// @notice Price of the next token when `totalSold` are sold.
    function priceAt(uint256 totalSold) external view returns (uint256) {
        if (FIXED_MINIMUM == 0) return INITIAL_PRICE + Math.mulDiv(SLOPE, totalSold, WAD);
        (bool curve, uint256 base_) = _phase(totalSold);
        if (!curve || totalSold <= base_) return INITIAL_PRICE;
        return Math.mulDiv(INITIAL_PRICE, totalSold, base_);
    }

    /// @notice Highest price the sale can reach if `saleCap` tokens are sold. The deployment
    /// uses it to refuse a sale whose closing price a Uniswap pool could not represent.
    function maxPrice(uint256 saleCap) external view returns (uint256) {
        if (FIXED_MINIMUM == 0) return INITIAL_PRICE + Math.mulDiv(SLOPE, saleCap, WAD);
        if (saleCap <= FIXED_MINIMUM) return INITIAL_PRICE;
        return Math.mulDiv(INITIAL_PRICE, saleCap, FIXED_MINIMUM);
    }

    /// @dev Whether the curve applies now, and the base it uses or would start with.
    function _phase(uint256 totalSold) private view returns (bool curve, uint256 base_) {
        if (started) return (true, base);
        if (block.timestamp < FIXED_PRICE_END) return (false, 0);
        return (true, _baseAt(totalSold));
    }

    function _baseAt(uint256 totalSold) private view returns (uint256) {
        return totalSold > FIXED_MINIMUM ? totalSold : FIXED_MINIMUM;
    }
}
