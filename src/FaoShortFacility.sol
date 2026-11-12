// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IShortVault {
    function phase() external view returns (uint8);
    function terminalPrice() external view returns (uint256);
    function effectiveSupply() external view returns (uint256);
    function COMPANY_TOKEN() external view returns (address);
    function TREASURY_EXECUTOR() external view returns (address);
    function WETH() external view returns (address);
}

interface IShortToken is IERC20 {
    function shortIssuer() external view returns (address);
    function shortOutstanding() external view returns (uint256);
    function issueShort(address to, uint256 amount) external;
    function closeShort(uint256 amount) external;
    function forfeitShort(uint256 amount) external;
}

interface IShortBeacon {
    function token() external view returns (address);
    function pokeAndHighOver(uint256 count) external returns (uint256);
}

/// @notice Permanent, permissionless way to short FAO from the first day.
///
/// Anyone may mint new FAO by locking WETH worth `LOCK_MULTIPLE` times the reference price per
/// token (and never less than the sale's closing price). The reference price is the higher of the
/// pool's current 30-minute average and the highest daily reading of the last `LOOKBACK_DAYS`,
/// so a briefly pushed-down price cannot be used to mint cheaply.
///
/// The minter sells the FAO. Returning the same amount before the term ends burns it and releases
/// the lock, less a fee to the treasury that grows with time and is never below one 30-day period.
/// There are no liquidations and no price is read after opening: the lock always covers the tokens
/// it minted. A position left
/// open past its term is forfeited by anyone; the whole lock goes to the treasury and the tokens
/// stay in circulation, so the organization has sold them at the lock price.
///
/// Tokens minted here and not yet closed or forfeited are excluded from the ragequit denominator
/// by the vault (FaoToken.shortOutstanding), so open shorts never dilute a ragequit.
///
/// There is no owner, no admin and no changeable parameter. The token names this contract as its
/// immutable short issuer, so no proposal can switch it off.
contract FaoShortFacility is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error OnlyBinder();
    error AlreadyBound();
    error InvalidConfig();
    error NotLive();
    error ZeroAmount();
    error LockExceedsMax();
    error OpenInterestCap();
    error NotPositionOwner();
    error InvalidPosition();
    error TermEnded();
    error TermNotEnded();
    error ExceedsPosition();
    error InvalidRecipient();

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint8 private constant PHASE_LIVE = 2;

    /// @notice Lock per token as a multiple of the reference price, in bps (20_000 = 2x).
    uint32 public immutable LOCK_MULTIPLE_BPS;
    /// @notice Fee on the released lock per 30 days the position was open, in bps.
    uint16 public immutable FEE_BPS_PER_30_DAYS;
    /// @notice Longest a position may stay open.
    uint32 public immutable TERM;
    /// @notice Days of recorded highs included in the reference price.
    uint8 public immutable LOOKBACK_DAYS;
    /// @notice Open short tokens may not exceed this share of the ragequit-entitled supply, in bps.
    uint32 public immutable MAX_OPEN_BPS;
    IShortBeacon public immutable BEACON;
    address public immutable BINDER;

    IShortVault public vault;
    IShortToken public token;
    IERC20 public weth;
    address public treasury;

    struct Position {
        address owner;
        uint64 openedAt;
        uint256 amount;
        uint256 lock;
    }

    Position[] private _positions;
    uint256 public totalLocked;

    event Bound(address indexed vault);
    event Opened(
        uint256 indexed id,
        address indexed owner,
        address indexed recipient,
        uint256 amount,
        uint256 lock
    );
    event Closed(uint256 indexed id, uint256 amount, uint256 released, uint256 fee);
    event Forfeited(uint256 indexed id, uint256 amount, uint256 lock);
    event PositionTransferred(uint256 indexed id, address indexed from, address indexed to);

    constructor(
        IShortBeacon beacon,
        uint32 lockMultipleBps,
        uint16 feeBpsPer30Days,
        uint32 term,
        uint8 lookbackDays,
        uint32 maxOpenBps
    ) {
        if (
            address(beacon) == address(0) || lockMultipleBps <= BPS || feeBpsPer30Days > 1000
                || term < 1 days || lookbackDays == 0 || lookbackDays > 60 || maxOpenBps == 0
                || maxOpenBps > BPS
        ) revert InvalidConfig();
        BEACON = beacon;
        LOCK_MULTIPLE_BPS = lockMultipleBps;
        FEE_BPS_PER_30_DAYS = feeBpsPer30Days;
        TERM = term;
        LOOKBACK_DAYS = lookbackDays;
        MAX_OPEN_BPS = maxOpenBps;
        BINDER = msg.sender;
    }

    /// @notice One-time wiring by the deployer, who has no other power. The vault's token must
    /// already name this contract as its immutable short issuer.
    function bind(IShortVault vault_) external {
        if (msg.sender != BINDER) revert OnlyBinder();
        if (address(vault) != address(0)) revert AlreadyBound();
        IShortToken token_ = IShortToken(vault_.COMPANY_TOKEN());
        if (token_.shortIssuer() != address(this) || BEACON.token() != address(token_)) {
            revert InvalidConfig();
        }
        vault = vault_;
        token = token_;
        weth = IERC20(vault_.WETH());
        treasury = vault_.TREASURY_EXECUTOR();
        emit Bound(address(vault_));
    }

    // ------------------------------------------------------------------ views

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function position(uint256 id)
        external
        view
        returns (address owner, uint64 openedAt, uint256 amount, uint256 lock)
    {
        if (id >= _positions.length) revert InvalidPosition();
        Position storage p = _positions[id];
        return (p.owner, p.openedAt, p.amount, p.lock);
    }

    /// @notice Lock per token for a given reference price.
    function lockPrice(uint256 referencePrice) public view returns (uint256 price) {
        price = Math.mulDiv(referencePrice, LOCK_MULTIPLE_BPS, BPS, Math.Rounding.Up);
        IShortVault vault_ = vault;
        uint256 base = vault_.terminalPrice();
        if (price < base) price = base;
        // Never mint for less than the WETH one token can redeem from the treasury. (Liquidity
        // shares held by the treasury are not valued here.)
        uint256 entitled = vault_.effectiveSupply();
        if (entitled != 0) {
            uint256 backing = Math.mulDiv(weth.balanceOf(treasury), WAD, entitled, Math.Rounding.Up);
            if (price < backing) price = backing;
        }
    }

    // ------------------------------------------------------------------ open

    /// @notice Locks WETH and mints `amount` FAO to `recipient`.
    /// @param maxLock Reverts if the required lock is higher (protects against a moving price).
    function open(uint256 amount, uint256 maxLock, address recipient)
        external
        nonReentrant
        returns (uint256 id, uint256 lock)
    {
        IShortVault vault_ = vault;
        if (address(vault_) == address(0) || vault_.phase() != PHASE_LIVE) revert NotLive();
        if (amount == 0) revert ZeroAmount();
        // Tokens held by the vault or the treasury are already left out of the ragequit count;
        // minting short tokens there would leave them out twice.
        if (
            recipient == address(0) || recipient == address(vault_) || recipient == treasury
                || recipient == address(this)
        ) revert InvalidRecipient();

        IShortToken token_ = token;
        uint256 outstanding = token_.shortOutstanding();
        if (outstanding + amount > Math.mulDiv(vault_.effectiveSupply(), MAX_OPEN_BPS, BPS)) {
            revert OpenInterestCap();
        }

        uint256 refPrice = BEACON.pokeAndHighOver(LOOKBACK_DAYS);
        lock = Math.mulDiv(amount, lockPrice(refPrice), WAD, Math.Rounding.Up);
        if (lock == 0) revert ZeroAmount();
        if (lock > maxLock) revert LockExceedsMax();

        id = _positions.length;
        _positions.push(Position(msg.sender, uint64(block.timestamp), amount, lock));
        totalLocked += lock;

        weth.safeTransferFrom(msg.sender, address(this), lock);
        token_.issueShort(recipient, amount);
        emit Opened(id, msg.sender, recipient, amount, lock);
    }

    // ------------------------------------------------------------------ close

    /// @notice Returns `amount` FAO, burns it and releases the matching share of the lock to
    /// `recipient`, less the time-based fee paid to the treasury.
    function close(uint256 id, uint256 amount, address recipient)
        external
        nonReentrant
        returns (uint256 released, uint256 fee)
    {
        Position storage p = _ownedPosition(id);
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidConfig();
        if (amount > p.amount) revert ExceedsPosition();
        uint256 elapsed = block.timestamp - p.openedAt;
        if (elapsed >= TERM) revert TermEnded();

        uint256 share = amount == p.amount ? p.lock : Math.mulDiv(p.lock, amount, p.amount);
        fee = Math.mulDiv(
            share, uint256(FEE_BPS_PER_30_DAYS) * elapsed, BPS * 30 days, Math.Rounding.Up
        );
        uint256 minimumFee = Math.mulDiv(share, FEE_BPS_PER_30_DAYS, BPS, Math.Rounding.Up);
        if (fee < minimumFee) fee = minimumFee;
        if (fee > share) fee = share;
        released = share - fee;

        p.amount -= amount;
        p.lock -= share;
        totalLocked -= share;

        IShortToken token_ = token;
        IERC20(address(token_)).safeTransferFrom(msg.sender, address(this), amount);
        token_.closeShort(amount);

        if (fee != 0) weth.safeTransfer(treasury, fee);
        if (released != 0) weth.safeTransfer(recipient, released);
        emit Closed(id, amount, released, fee);
    }

    /// @notice After the term, anyone may send an unclosed position's whole lock to the treasury.
    function forfeit(uint256 id) external nonReentrant returns (uint256 lock) {
        if (id >= _positions.length) revert InvalidPosition();
        Position storage p = _positions[id];
        uint256 amount = p.amount;
        if (amount == 0) revert InvalidPosition();
        if (block.timestamp - p.openedAt < TERM) revert TermNotEnded();

        lock = p.lock;
        p.amount = 0;
        p.lock = 0;
        totalLocked -= lock;

        token.forfeitShort(amount);
        weth.safeTransfer(treasury, lock);
        emit Forfeited(id, amount, lock);
    }

    function transferPosition(uint256 id, address to) external {
        Position storage p = _ownedPosition(id);
        if (to == address(0)) revert InvalidConfig();
        p.owner = to;
        emit PositionTransferred(id, msg.sender, to);
    }

    function _ownedPosition(uint256 id) private view returns (Position storage p) {
        if (id >= _positions.length) revert InvalidPosition();
        p = _positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
    }
}
