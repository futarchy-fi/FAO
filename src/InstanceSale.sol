// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IFutarchyLiquidityManager} from "./interfaces/IFutarchyLiquidityManager.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function burn(uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title InstanceSale
/// @notice Per-instance token sale used by `FutarchyRegistry` v4. Mirrors the
///         core of `FAOSale`: initial fixed-price phase + linear bonding
///         curve + `ragequit(numTokens)` that burns the caller's tokens and
///         pays a pro-rata share of the sale treasury (ETH + each whitelisted
///         ERC20). The "manager" address passed to `seedLiquidityManager` is
///         auto-added to the ragequit list — so when the spot seeder is an
///         ERC20 (`Futarchy LP` / `fLP`) the LP claim flows out through
///         ragequit alongside ETH.
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

    // Whitelist of ERC20s the sale will distribute pro-rata on ragequit.
    // Typically holds one entry: the fLP share token from the spot seeder.
    address[] public ragequitTokens;
    mapping(address => bool) public isRagequitToken;

    event Purchase(address indexed buyer, uint256 numTokens, uint256 costWei);
    event InitialPhaseFinalized(uint256 initialNetSale, uint256 initialFundsRaised);
    event LiquiditySeeded(address indexed manager, uint256 tokenAmount, uint256 nativeAmount);
    event Ragequit(address indexed user, uint256 burnedAmount, uint256 ethReturned);
    event RagequitTokenAdded(address indexed token);
    event RagequitTokenRemoved(address indexed token);

    error ZeroNumTokens();
    error IncorrectEth();
    error NotAdmin();
    error InsufficientTreasury();
    error ZeroManager();
    error ZeroSeed();
    error NothingToReturn();
    error EthTransferFailed();
    error ZeroAddr();
    error AlreadyOnList();
    error NotOnList();
    error CannotRagequitSelf();
    error CannotAddSaleToken();

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

    function currentPriceWeiPerToken() public view returns (uint256) {
        if (!initialPhaseFinalized) return INITIAL_PRICE_WEI_PER_TOKEN;
        if (initialNetSale == 0) return INITIAL_PRICE_WEI_PER_TOKEN;
        return INITIAL_PRICE_WEI_PER_TOKEN + (INITIAL_PRICE_WEI_PER_TOKEN * totalCurveTokensSold) / initialNetSale;
    }

    function ragequitTokensLength() external view returns (uint256) {
        return ragequitTokens.length;
    }

    /// @notice Token supply that participates in ragequit. The sale's own
    ///         balance is excluded so freshly-minted-for-LP tokens (held by
    ///         the sale right before they leave via `seedLiquidityManager`)
    ///         don't dilute the per-token ETH share.
    function effectiveSupply() public view returns (uint256) {
        uint256 totalSupply = TOKEN.totalSupply();
        uint256 saleBal = TOKEN.balanceOf(address(this));
        return totalSupply > saleBal ? totalSupply - saleBal : 0;
    }

    /// @notice Pure read for the UI: ETH a `numTokens` ragequit would return
    ///         at the current treasury / supply state.
    function quoteRagequit(uint256 numTokens) external view returns (uint256 ethReturned) {
        if (numTokens == 0) return 0;
        uint256 burnAmount = numTokens * 1e18;
        uint256 eff = effectiveSupply();
        if (eff == 0) return 0;
        ethReturned = (address(this).balance * burnAmount) / eff;
    }

    // ─── buy ───────────────────────────────────────────────────────────────

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

    // ─── ragequit ──────────────────────────────────────────────────────────

    /// @notice Burn `numTokens` tokens and receive pro-rata ETH + each
    ///         whitelisted ERC20 in `ragequitTokens[]`.
    /// @dev    Caller must `token.approve(sale, numTokens * 1e18)` first.
    ///         The sale `transferFrom`s the user's tokens, then burns them.
    function ragequit(uint256 numTokens) external nonReentrant {
        if (numTokens == 0) revert ZeroNumTokens();
        if (msg.sender == address(this)) revert CannotRagequitSelf();

        uint256 burnAmount = numTokens * 1e18;
        uint256 eff = effectiveSupply();
        if (eff == 0) revert NothingToReturn();
        require(burnAmount <= eff, "burn > effectiveSupply");

        // Pull tokens then burn — sale must hold MINTER_ROLE (it minted these
        // in the first place) and the token's ERC20Burnable lets the holder
        // burn its own balance.
        require(TOKEN.transferFrom(msg.sender, address(this), burnAmount), "transferFrom failed");
        TOKEN.burn(burnAmount);

        // ETH pro-rata.
        uint256 ethBalance = address(this).balance;
        uint256 ethShare = (ethBalance * burnAmount) / eff;
        if (ethShare > 0) {
            (bool ok, ) = payable(msg.sender).call{value: ethShare}("");
            if (!ok) revert EthTransferFailed();
        }

        // Each whitelisted ERC20 pro-rata. Pulls balance fresh per token so
        // a removed entry that's still in the array is a no-op.
        uint256 len = ragequitTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address erc20 = ragequitTokens[i];
            if (!isRagequitToken[erc20]) continue;
            uint256 bal = IERC20Min(erc20).balanceOf(address(this));
            if (bal == 0) continue;
            uint256 share = (bal * burnAmount) / eff;
            if (share > 0) {
                require(IERC20Min(erc20).transfer(msg.sender, share), "rq erc20 transfer failed");
            }
        }

        emit Ragequit(msg.sender, burnAmount, ethShare);
    }

    // ─── ragequit list admin ───────────────────────────────────────────────

    function addRagequitToken(address erc20) external onlyAdmin {
        if (erc20 == address(0)) revert ZeroAddr();
        if (erc20 == address(TOKEN)) revert CannotAddSaleToken();
        if (isRagequitToken[erc20]) revert AlreadyOnList();
        ragequitTokens.push(erc20);
        isRagequitToken[erc20] = true;
        emit RagequitTokenAdded(erc20);
    }

    function removeRagequitToken(address erc20) external onlyAdmin {
        if (!isRagequitToken[erc20]) revert NotOnList();
        isRagequitToken[erc20] = false;
        emit RagequitTokenRemoved(erc20);
    }

    // ─── liquidity seeding ─────────────────────────────────────────────────

    /// @notice Admin: mint `tokenAmount` to `manager` and forward
    ///         `nativeAmount` ETH; `manager.initializeFromSale` mints UniV3
    ///         LP + (if the manager is an fLP-issuing seeder) mints fLP
    ///         shares back to this sale. The manager address is auto-added
    ///         to `ragequitTokens` on first seed so the fLP flows out
    ///         through ragequit.
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
            TOKEN.mint(manager, tokenAmount);
        }

        IFutarchyLiquidityManager(manager).initializeFromSale{value: nativeAmount}(
            tokenAmount, spotAddData
        );

        // Auto-add the manager to the ragequit list (idempotent).
        if (!isRagequitToken[manager] && manager != address(TOKEN)) {
            ragequitTokens.push(manager);
            isRagequitToken[manager] = true;
            emit RagequitTokenAdded(manager);
        }

        emit LiquiditySeeded(manager, tokenAmount, nativeAmount);
    }

    receive() external payable {}
}
