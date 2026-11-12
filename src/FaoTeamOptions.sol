// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IOptionsVault {
    function phase() external view returns (uint8);
    function totalSold() external view returns (uint256);
    function terminalPrice() external view returns (uint256);
    function COMPANY_TOKEN() external view returns (address);
    function TREASURY_EXECUTOR() external view returns (address);
    function WETH() external view returns (address);
}

interface IOptionsToken {
    function optionIssuer() external view returns (address);
    function issueOption(address to, uint256 amount) external;
}

interface IOptionsBeacon {
    function token() external view returns (address);
    function heldAbove(uint256 level, uint256 daysHeld) external view returns (bool);
}

/// @notice Team and insider allocation as price-milestone options. Nothing is minted at genesis.
///
/// The pool is `POOL_BPS` of the tokens sold in the genesis sale, split into ten equal tranches.
/// Tranche k (k = 0..9) opens only after the market has held at least 2^(k+1) times the sale's
/// closing price for `SUSTAIN_DAYS` days in a row, measured as the time-weighted average of
/// every interval of a day or more recorded by the price beacon.
/// An opened tranche becomes exercisable linearly over `VESTING`, and nothing is exercisable
/// before `CLIFF` after genesis. To exercise, the holder pays `strike` WETH per token to the
/// treasury and the token is minted. Unexercised options lapse `EXPIRY` after genesis.
///
/// One address, `holder`, owns the whole right. It can be any contract or an EOA, and it can
/// hand the right to another address at any time (for example to a contract that divides it
/// between people). There is no admin and no parameter that can change after deployment.
contract FaoTeamOptions is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyBinder();
    error OnlyHolder();
    error AlreadyBound();
    error InvalidConfig();
    error NotLive();
    error AlreadyActivated();
    error NotActivated();
    error InvalidTranche();
    error AlreadyOpen();
    error NotHeld();
    error ZeroAmount();
    error ExceedsExercisable();
    error Expired();
    error CostExceedsMax();

    uint256 public constant WAD = 1e18;
    uint256 public constant TRANCHES = 10;
    uint256 public constant BPS = 10_000;
    uint8 private constant PHASE_LIVE = 2;

    uint256 public constant SUSTAIN_DAYS = 30;
    uint256 public constant CLIFF = 365 days;
    uint256 public constant VESTING = 365 days;
    uint256 public constant EXPIRY = 3650 days;

    /// @notice Whole option pool as a share of tokens sold in the genesis sale.
    uint16 public immutable POOL_BPS;
    /// @notice Strike as a share of the sale's closing price. 10_000 = the closing price.
    uint16 public immutable STRIKE_BPS;
    IOptionsBeacon public immutable BEACON;
    address public immutable BINDER;

    /// @notice The one address that may exercise and may hand the right on.
    address public holder;

    IOptionsVault public vault;
    IOptionsToken public token;
    IERC20 public weth;
    address public treasury;

    uint64 public genesisAt;
    uint256 public basePrice;
    uint256 public strike;
    uint256 public trancheSize;

    uint64[TRANCHES] public openedAt;
    uint256[TRANCHES] public exercised;

    event Bound(address indexed vault);
    event Activated(uint256 basePrice, uint256 strike, uint256 trancheSize);
    event TrancheOpened(uint256 indexed tranche, uint256 level);
    event HolderChanged(address indexed from, address indexed to);
    event Exercised(
        uint256 indexed tranche, address indexed recipient, uint256 amount, uint256 cost
    );

    constructor(IOptionsBeacon beacon, address initialHolder, uint16 poolBps, uint16 strikeBps) {
        if (
            address(beacon) == address(0) || initialHolder == address(0) || poolBps == 0
                || poolBps > BPS || strikeBps > BPS
        ) revert InvalidConfig();
        BEACON = beacon;
        POOL_BPS = poolBps;
        STRIKE_BPS = strikeBps;
        BINDER = msg.sender;
        holder = initialHolder;
        emit HolderChanged(address(0), initialHolder);
    }

    // ------------------------------------------------------------------ wiring

    /// @notice One-time wiring by the deployer, who has no other power. The vault's token must
    /// already name this contract as its immutable option issuer.
    function bind(IOptionsVault vault_) external {
        if (msg.sender != BINDER) revert OnlyBinder();
        if (address(vault) != address(0)) revert AlreadyBound();
        IOptionsToken token_ = IOptionsToken(vault_.COMPANY_TOKEN());
        if (token_.optionIssuer() != address(this) || BEACON.token() != address(token_)) {
            revert InvalidConfig();
        }
        vault = vault_;
        token = token_;
        weth = IERC20(vault_.WETH());
        treasury = vault_.TREASURY_EXECUTOR();
        emit Bound(address(vault_));
    }

    /// @notice Anyone may call once the sale has finalized. Fixes the pool size and prices.
    function activate() external {
        IOptionsVault vault_ = vault;
        if (address(vault_) == address(0) || vault_.phase() != PHASE_LIVE) revert NotLive();
        if (genesisAt != 0) revert AlreadyActivated();
        uint256 base = vault_.terminalPrice();
        uint256 size = Math.mulDiv(vault_.totalSold(), POOL_BPS, BPS * TRANCHES);
        if (base == 0 || size == 0) revert InvalidConfig();
        genesisAt = uint64(block.timestamp);
        basePrice = base;
        strike = Math.mulDiv(base, STRIKE_BPS, BPS, Math.Rounding.Up);
        trancheSize = size;
        emit Activated(base, strike, size);
    }

    // ------------------------------------------------------------------ holder

    /// @notice Hands the whole right, including everything not yet exercised, to `newHolder`.
    function transferHolder(address newHolder) external {
        if (msg.sender != holder) revert OnlyHolder();
        if (newHolder == address(0)) revert InvalidConfig();
        holder = newHolder;
        emit HolderChanged(msg.sender, newHolder);
    }

    // ------------------------------------------------------------------ milestones

    /// @notice Price the market must hold for tranche `k` to open: 2^(k+1) times the base price.
    function level(uint256 k) public view returns (uint256) {
        if (k >= TRANCHES) revert InvalidTranche();
        return basePrice << (k + 1);
    }

    /// @notice Anyone may open a tranche once the beacon shows the level held for the whole
    /// sustain period.
    function open(uint256 k) external {
        if (genesisAt == 0) revert NotActivated();
        if (k >= TRANCHES) revert InvalidTranche();
        if (openedAt[k] != 0) revert AlreadyOpen();
        if (block.timestamp >= uint256(genesisAt) + EXPIRY) revert Expired();
        uint256 level_ = level(k);
        if (!BEACON.heldAbove(level_, SUSTAIN_DAYS)) revert NotHeld();
        openedAt[k] = uint64(block.timestamp);
        emit TrancheOpened(k, level_);
    }

    /// @notice Tokens of tranche `k` that have become exercisable so far, exercised or not.
    function vested(uint256 k) public view returns (uint256) {
        if (k >= TRANCHES) revert InvalidTranche();
        uint256 opened = openedAt[k];
        if (opened == 0) return 0;
        uint256 start = uint256(genesisAt) + CLIFF;
        if (opened > start) start = opened;
        if (block.timestamp <= start) return 0;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= VESTING) return trancheSize;
        return Math.mulDiv(trancheSize, elapsed, VESTING);
    }

    /// @notice Tokens of tranche `k` the holder can exercise now.
    function exercisable(uint256 k) public view returns (uint256) {
        if (genesisAt == 0 || block.timestamp >= uint256(genesisAt) + EXPIRY) return 0;
        return vested(k) - exercised[k];
    }

    // ------------------------------------------------------------------ exercise

    /// @notice The holder pays the strike to the treasury and `amount` tokens of tranche `k`
    /// are minted to `recipient`.
    function exercise(uint256 k, uint256 amount, address recipient, uint256 maxCost)
        external
        nonReentrant
        returns (uint256 cost)
    {
        if (msg.sender != holder) revert OnlyHolder();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidConfig();
        if (genesisAt == 0) revert NotActivated();
        if (block.timestamp >= uint256(genesisAt) + EXPIRY) revert Expired();
        if (amount > exercisable(k)) revert ExceedsExercisable();

        cost = Math.mulDiv(amount, strike, WAD, Math.Rounding.Up);
        if (cost > maxCost) revert CostExceedsMax();

        exercised[k] += amount;

        if (cost != 0) weth.safeTransferFrom(msg.sender, treasury, cost);
        token.issueOption(recipient, amount);
        emit Exercised(k, recipient, amount, cost);
    }
}
