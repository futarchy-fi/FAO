// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IFutarchyLiquidityManager} from "./interfaces/IFutarchyLiquidityManager.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title InstanceSale
/// @notice Minimal per-instance token sale used by `FutarchyRegistry` v3.
///         A trimmed shape of `FAOSale`:
///           - Initial fixed-price phase (price set at deploy).
///           - Linear bonding curve after the initial phase finalizes.
///           - Mints supply on demand via `IMintableERC20.mint` — the token
///             must grant this contract `MINTER_ROLE` at deploy.
///         **No** insider vesting, **no** incentive contract, **no** treasury
///         splits, **no** ragequit, **no** start gating: the sale is active
///         immediately at construction so we don't need a separate startSale
///         tx in the registry's atomic `createFutarchyPart1`.
///
///         The admin (= instance creator) can call `seedLiquidityManager` to
///         drip raised ETH + a slice of newly-minted token into the spot pool
///         via an `IFutarchyLiquidityManager` (typically `SaleSpotSeeder`).
contract InstanceSale is ReentrancyGuard {
    IMintableERC20 public immutable TOKEN;
    address public immutable ADMIN;
    uint256 public immutable INITIAL_PRICE_WEI_PER_TOKEN;
    uint256 public immutable MIN_INITIAL_PHASE_SOLD;
    uint256 public immutable INITIAL_PHASE_DURATION;

    uint256 public immutable SALE_START;
    uint256 public immutable INITIAL_PHASE_END;

    bool public initialPhaseFinalized;
    uint256 public initialTokensSold;
    uint256 public initialFundsRaised;
    uint256 public initialNetSale;
    uint256 public totalCurveTokensSold;
    uint256 public totalCurveFundsRaised;

    event Purchase(address indexed buyer, uint256 numTokens, uint256 costWei);
    event InitialPhaseFinalized(uint256 initialNetSale, uint256 initialFundsRaised);
    event LiquiditySeeded(address indexed manager, uint256 tokenAmount, uint256 nativeAmount);

    error ZeroNumTokens();
    error IncorrectEth();
    error NotAdmin();
    error InsufficientTreasury();
    error ZeroManager();
    error ZeroSeed();

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAdmin();
        _;
    }

    constructor(
        address token,
        address admin,
        uint256 initialPriceWeiPerToken,
        uint256 minInitialPhaseSold,
        uint256 initialPhaseDuration
    ) {
        require(token != address(0), "InstanceSale: token=0");
        require(admin != address(0), "InstanceSale: admin=0");
        require(initialPriceWeiPerToken > 0, "InstanceSale: price=0");
        require(minInitialPhaseSold > 0, "InstanceSale: minInitial=0");
        require(initialPhaseDuration > 0, "InstanceSale: duration=0");

        TOKEN = IMintableERC20(token);
        ADMIN = admin;
        INITIAL_PRICE_WEI_PER_TOKEN = initialPriceWeiPerToken;
        MIN_INITIAL_PHASE_SOLD = minInitialPhaseSold;
        INITIAL_PHASE_DURATION = initialPhaseDuration;
        SALE_START = block.timestamp;
        INITIAL_PHASE_END = block.timestamp + initialPhaseDuration;
    }

    // ─── views ─────────────────────────────────────────────────────────────

    function totalSaleTokens() public view returns (uint256) {
        if (!initialPhaseFinalized) return initialTokensSold;
        return initialNetSale + totalCurveTokensSold;
    }

    function bondingCurveSaleTokens() public view returns (uint256) {
        return totalCurveTokensSold;
    }

    function totalAmountRaised() public view returns (uint256) {
        return initialFundsRaised + totalCurveFundsRaised;
    }

    /// @notice Quotes the per-whole-token price at the current state.
    function currentPriceWeiPerToken() public view returns (uint256) {
        if (!initialPhaseFinalized) return INITIAL_PRICE_WEI_PER_TOKEN;
        if (initialNetSale == 0) return INITIAL_PRICE_WEI_PER_TOKEN;
        return INITIAL_PRICE_WEI_PER_TOKEN + (INITIAL_PRICE_WEI_PER_TOKEN * totalCurveTokensSold) / initialNetSale;
    }

    // ─── buy ───────────────────────────────────────────────────────────────

    /// @notice Buy `numTokens` whole tokens (mints to msg.sender).
    /// @dev Each call may also flip the sale into bonding-curve mode if the
    ///      initial phase ended + min-sold threshold has been hit.
    function buy(uint256 numTokens) external payable nonReentrant {
        if (numTokens == 0) revert ZeroNumTokens();

        _finalizeInitialPhaseIfNeeded();

        uint256 costWei;
        if (!initialPhaseFinalized) {
            costWei = numTokens * INITIAL_PRICE_WEI_PER_TOKEN;
            initialTokensSold += numTokens;
            initialFundsRaised += costWei;
        } else {
            uint256 priceWeiPerToken = currentPriceWeiPerToken();
            costWei = numTokens * priceWeiPerToken;
            totalCurveTokensSold += numTokens;
            totalCurveFundsRaised += costWei;
        }

        if (msg.value != costWei) revert IncorrectEth();

        TOKEN.mint(msg.sender, numTokens * 1e18);
        emit Purchase(msg.sender, numTokens, costWei);
    }

    function _finalizeInitialPhaseIfNeeded() internal {
        if (
            !initialPhaseFinalized
                && block.timestamp >= INITIAL_PHASE_END
                && initialTokensSold >= MIN_INITIAL_PHASE_SOLD
        ) {
            initialPhaseFinalized = true;
            initialNetSale = initialTokensSold;
            emit InitialPhaseFinalized(initialNetSale, initialFundsRaised);
        }
    }

    // ─── liquidity seeding ─────────────────────────────────────────────────

    /// @notice Admin-only: mint `tokenAmount` (whole-units) into the sale,
    ///         then forward `nativeAmount` ETH + `tokenAmount` to an
    ///         `IFutarchyLiquidityManager` (typically `SaleSpotSeeder`) so
    ///         the spot pool grows from the sale's treasury.
    /// @dev Minting fresh tokens for LP keeps accounting simple — the sale's
    ///      ETH reserve is the only constraint. The freshly-minted tokens are
    ///      backed by ETH already collected from buyers.
    function seedLiquidityManager(
        address manager,
        uint256 tokenAmount,
        uint256 nativeAmount,
        bytes calldata spotAddData
    ) external onlyAdmin nonReentrant {
        if (manager == address(0)) revert ZeroManager();
        if (tokenAmount == 0 && nativeAmount == 0) revert ZeroSeed();
        if (address(this).balance < nativeAmount) revert InsufficientTreasury();

        if (tokenAmount > 0) {
            // Mint fresh sale tokens to the manager (sale must hold MINTER_ROLE).
            TOKEN.mint(manager, tokenAmount);
        }

        IFutarchyLiquidityManager(manager).initializeFromSale{value: nativeAmount}(
            tokenAmount, spotAddData
        );

        emit LiquiditySeeded(manager, tokenAmount, nativeAmount);
    }

    receive() external payable {}
}
