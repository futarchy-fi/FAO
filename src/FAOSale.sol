// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FAOToken} from "./FAOToken.sol";
import {IFutarchyLiquidityManager} from "./interfaces/IFutarchyLiquidityManager.sol";

/// @title FAO Sale / Treasury / Ragequit Contract
/// @notice
/// - Accepts ETH for FAO via:
///   - 2-week initial fixed-price phase
///   - Then linear bonding curve:
///       price = initialPrice + (initialPrice * bondingCurveSale / initialNetSale)
/// - Mints distribution per 1 FAO sold:
///     1.0 FAO to buyer
///     0.5 FAO to this contract (treasury)
///     0.2 FAO to incentive contract
///     0.3 FAO to insider vesting contract
/// - Ragequit: burn FAO to get pro-rata ETH + selected ERC20s
/// - Designed to be owned / governed by an OZ TimelockController
contract FAOSale is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // --- Core config ---

    FAOToken public immutable TOKEN;
    address public admin;

    // Addresses that receive minted FAO per sale
    address public incentiveContract;
    address public insiderVestingContract;

    // Initial price: 1 ETH = 10,000 FAO -> 1 FAO = 0.0001 ETH
    uint256 public immutable INITIAL_PRICE_WEI_PER_TOKEN; // e.g. 1e14 wei

    // Sale timing
    uint256 public saleStart; // timestamp
    uint256 public immutable MIN_INITIAL_PHASE_SOLD; // e.g. 1_000_000 * 10**decimals
    uint256 public immutable INITIAL_PHASE_DURATION;
    uint256 public initialPhaseEnd; // saleStart + 2 weeks
    bool public initialPhaseFinalized;

    // Token sale tracking (whole tokens, NOT 1e18 units)
    uint256 public initialTokensSold; // during initial phase, net of ragequits
    uint256 public initialNetSale; // frozen after initial phase finalize
    uint256 public totalCurveTokensSold; // tokens sold after initial phase

    // ETH raised tracking
    uint256 public initialFundsRaised; // wei, net of in-phase ragequits
    uint256 public totalCurveFundsRaised; // wei
    uint256 public longTargetReachedAt; // timestamp when totalSale >= LONG_TARGET_TOKENS

    // Long target: 200,000,000 FAO sold to buyers (whole tokens)
    uint256 public constant LONG_TARGET_TOKENS = 200_000_000;

    // Ragequit tokens (ERC20s, not including FAO)
    address[] public ragequitTokens;
    mapping(address => bool) public isRagequitToken;

    // --- Events ---

    event SaleStarted(uint256 startTime, uint256 initialPhaseEnd);
    event Purchase(address indexed buyer, uint256 numTokens, uint256 costWei);
    event Ragequit(address indexed user, uint256 faoBurned, uint256 ethReturned);
    event RagequitTokenAdded(address indexed token);
    event RagequitTokenRemoved(address indexed token);
    event IncentiveContractSet(address indexed incentive);
    event InsiderVestingContractSet(address indexed insider);
    event LiquidityManagerSeeded(address indexed manager, uint256 faoAmount, uint256 nativeAmount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // --- Modifiers ---

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    // --- Constructor ---

    /// @param _token FAOToken contract address
    /// @param _admin Initial admin (likely an OZ TimelockController)
    /// @param _incentive Initial incentive contract address
    /// @param _insider Initial insider vesting contract address
    constructor(
        FAOToken _token,
        uint256 _minInitialPhaseSold,
        uint256 _initialPhaseDuration,
        address _admin,
        address _incentive,
        address _insider
    ) {
        require(address(_token) != address(0), "FAO: zero token");
        require(_admin != address(0), "FAO: zero admin");
        require(_minInitialPhaseSold > 0, "minInitialPhaseSold must be > 0");
        require(_initialPhaseDuration > 0, "initialPhaseDuration must be > 0");

        TOKEN = _token;
        INITIAL_PRICE_WEI_PER_TOKEN = 1e14; // 0.0001 ETH per whole FAO
        MIN_INITIAL_PHASE_SOLD = _minInitialPhaseSold;
        INITIAL_PHASE_DURATION = _initialPhaseDuration;

        incentiveContract = _incentive;
        insiderVestingContract = _insider;

        admin = _admin;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // --- View helpers ---

    /// @return min tokens sold at initial phase
    function minInitialPhaseSold() public view returns (uint256) {
        return MIN_INITIAL_PHASE_SOLD;
    }

    /// @return initial phase duration
    function initialPhaseDuration() public view returns (uint256) {
        return INITIAL_PHASE_DURATION;
    }

    /// @return initial phase end
    function initialPhaseEndTime() public view returns (uint256) {
        return initialPhaseEnd;
    }

    /// @return total tokens sold to buyers (whole tokens) including both phases
    function totalSaleTokens() public view returns (uint256) {
        if (!initialPhaseFinalized) {
            return initialTokensSold + totalCurveTokensSold;
        } else {
            return initialNetSale + totalCurveTokensSold;
        }
    }

    /// @return bonding curve sale tokens (after initial phase, whole tokens)
    function bondingCurveSaleTokens() public view returns (uint256) {
        return totalCurveTokensSold;
    }

    /// @return total ETH ever raised (initial + curve), in wei
    function totalAmountRaised() public view returns (uint256) {
        // initialFundsRaised is already net of in-phase ragequits
        return initialFundsRaised + totalCurveFundsRaised;
    }

    /// @return current spot price (wei per whole FAO token)
    function currentPriceWeiPerToken() public view returns (uint256) {
        if (!initialPhaseFinalized) {
            // Still in initial phase: flat initial price
            return INITIAL_PRICE_WEI_PER_TOKEN;
        }

        if (initialNetSale == 0) {
            // No net initial sale: fall back to initial price
            return INITIAL_PRICE_WEI_PER_TOKEN;
        }

        uint256 bcSale = bondingCurveSaleTokens();
        // price = initialPrice + (initialPrice * bondingCurveSale / initialNetSale)
        return INITIAL_PRICE_WEI_PER_TOKEN + (INITIAL_PRICE_WEI_PER_TOKEN * bcSale) / initialNetSale;
    }

    /// @return number of ragequit ERC20 tokens currently configured
    function ragequitTokensLength() external view returns (uint256) {
        return ragequitTokens.length;
    }

    // --- Admin: sale lifecycle / curve control ---

    /// @notice Start the sale and the 2-week initial phase
    function startSale() external onlyAdmin {
        require(saleStart == 0, "Sale already started");
        saleStart = block.timestamp;
        initialPhaseEnd = block.timestamp + INITIAL_PHASE_DURATION;

        emit SaleStarted(saleStart, initialPhaseEnd);
    }

    // --- Admin: ragequit token list ---

    function addRagequitToken(address erc20) external onlyAdmin {
        require(erc20 != address(0), "zero token");
        require(!isRagequitToken[erc20], "already added");
        require(erc20 != address(TOKEN), "FAO not ragequittable");

        ragequitTokens.push(erc20);
        isRagequitToken[erc20] = true;

        emit RagequitTokenAdded(erc20);
    }

    function removeRagequitToken(address erc20) external onlyAdmin {
        require(isRagequitToken[erc20], "not set");
        isRagequitToken[erc20] = false;
        emit RagequitTokenRemoved(erc20);
    }

    // --- Admin: set incentive / insider contracts ---

    function setIncentiveContract(address _incentive) external onlyAdmin {
        incentiveContract = _incentive;
        emit IncentiveContractSet(_incentive);
    }

    function setInsiderVestingContract(address _insider) external onlyAdmin {
        insiderVestingContract = _insider;
        emit InsiderVestingContractSet(_insider);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "FAO: zero admin");
        require(newAdmin != admin, "FAO: same admin");

        address oldAdmin = admin;
        admin = newAdmin;

        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

        emit AdminUpdated(oldAdmin, newAdmin);
    }

    /// @notice Sends FAO + native funds from sale treasury to liquidity manager and seeds spot LP.
    /// @dev Intended to be timelocked in production.
    function seedLiquidityManager(
        address manager,
        uint256 faoAmount,
        uint256 nativeAmount,
        bytes calldata spotAddData
    ) external onlyAdmin nonReentrant {
        require(manager != address(0), "zero manager");
        require(faoAmount > 0 || nativeAmount > 0, "zero seed");
        require(address(this).balance >= nativeAmount, "insufficient ETH");

        if (faoAmount > 0) {
            IERC20(address(TOKEN)).safeTransfer(manager, faoAmount);
        }

        IFutarchyLiquidityManager(manager).initializeFromSale{value: nativeAmount}(
            faoAmount, spotAddData
        );

        // The LP share token (fLP) should be ragequittable once seeded.
        if (!isRagequitToken[manager]) {
            ragequitTokens.push(manager);
            isRagequitToken[manager] = true;
            emit RagequitTokenAdded(manager);
        }

        emit LiquidityManagerSeeded(manager, faoAmount, nativeAmount);
    }
    // --- Internal: finalize initial phase ---

    function _mintToBuyer(uint256 numTokens, address to) internal {
        uint256 baseAmount = numTokens * 1e18;
        TOKEN.mint(to, baseAmount);
    }

    function _mintToPools(uint256 numTokens) internal {
        uint256 baseAmount = numTokens * 1e18;
        // 0.5 to treasury
        TOKEN.mint(address(this), baseAmount / 2);

        // 0.2 to incentive
        if (incentiveContract != address(0)) {
            TOKEN.mint(incentiveContract, baseAmount / 5);
        }

        // 0.3 to insider
        if (insiderVestingContract != address(0)) {
            TOKEN.mint(insiderVestingContract, (baseAmount * 3) / 10);
        }
    }

    function _finalizeInitialPhaseIfNeeded() internal {
        if (
            !initialPhaseFinalized && saleStart != 0 && block.timestamp >= initialPhaseEnd
                && initialTokensSold >= MIN_INITIAL_PHASE_SOLD
        ) {
            initialPhaseFinalized = true;
            initialNetSale = initialTokensSold;
            // initialFundsRaised already net (we adjust on in-phase ragequit)

            // For token purchased on Phase I, tokens to the pools are minted when the phase is
            // finalized.
            _mintToPools(initialNetSale);
        }
    }

    // --- Buying logic ---

    /// @notice Buy `numTokens` FAO (whole tokens) using ETH
    /// @dev
    /// - 1 FAO = 1e18 units in the token contract
    /// - User must send exactly the required ETH
    /// - Reverts if sale not started or ended (long target + 1 year)
    function buy(uint256 numTokens) external payable nonReentrant {
        require(numTokens > 0, "numTokens=0");
        require(saleStart != 0, "Sale not started");

        // Check if sale period ended due to long target + 1 year
        if (longTargetReachedAt != 0) {
            require(block.timestamp <= longTargetReachedAt + 365 days, "Sale period over");
        }

        // If initial phase time passed, finalize it
        _finalizeInitialPhaseIfNeeded();

        uint256 costWei;
        uint256 currentTotalSaleTokensBefore = totalSaleTokens();

        if (!initialPhaseFinalized) {
            // Initial fixed-price phase
            costWei = numTokens * INITIAL_PRICE_WEI_PER_TOKEN;
            initialTokensSold += numTokens;
            initialFundsRaised += costWei;
        } else {
            // Bonding curve phase
            require(initialNetSale > 0, "No initial net sale");
            uint256 bcSale = bondingCurveSaleTokens();
            uint256 priceWeiPerToken = INITIAL_PRICE_WEI_PER_TOKEN
                + (INITIAL_PRICE_WEI_PER_TOKEN * bcSale) / initialNetSale;

            costWei = numTokens * priceWeiPerToken;
            totalCurveTokensSold += numTokens;
            totalCurveFundsRaised += costWei;
        }

        // Check ETH sent
        require(msg.value == costWei, "Incorrect ETH sent");

        // Update long target flag
        uint256 newTotalSaleTokens = currentTotalSaleTokensBefore + numTokens;
        if (longTargetReachedAt == 0 && newTotalSaleTokens >= LONG_TARGET_TOKENS) {
            longTargetReachedAt = block.timestamp;
        }

        // During Phase I, mints to treasury + incentive + insider only when the phase is finalized.
        // After that, mints for each sale.

        _mintToBuyer(numTokens, msg.sender);
        if (initialPhaseFinalized) {
            _mintToPools(numTokens);
        }
        emit Purchase(msg.sender, numTokens, costWei);
    }

    // --- Ragequit ---

    /// @notice Ragequit by burning `numTokens` whole FAO and claiming pro-rata ETH + ragequitTokens
    /// @dev
    /// - Uses effectiveSupply = totalSupply - incentive - insider - treasury
    /// - FAO itself is never distributed
    /// - Adjusts initialTokensSold / initialFundsRaised if called during initial phase
    function ragequit(uint256 numTokens) external nonReentrant {
        require(numTokens > 0, "numTokens=0");

        // Disallow ragequit from treasury, incentive, and insider contracts
        require(
            msg.sender != address(this) && msg.sender != incentiveContract
                && msg.sender != insiderVestingContract,
            "ragequit: not allowed for treasury/incentive/insider"
        );

        uint256 burnAmount = numTokens * 1e18;

        uint256 userBalance = TOKEN.balanceOf(msg.sender);
        require(userBalance >= burnAmount, "Insufficient FAO balance");

        // Calculate effective supply BEFORE burn
        uint256 totalSupply = TOKEN.totalSupply();
        uint256 incentiveBal =
            incentiveContract == address(0) ? 0 : TOKEN.balanceOf(incentiveContract);
        uint256 insiderBal =
            insiderVestingContract == address(0) ? 0 : TOKEN.balanceOf(insiderVestingContract);
        uint256 treasuryBal = TOKEN.balanceOf(address(this));

        uint256 effectiveSupply = totalSupply - incentiveBal - insiderBal - treasuryBal;
        require(effectiveSupply > 0, "No effective supply");
        require(burnAmount <= effectiveSupply, "Burn > effective supply");

        // Burn user's tokens (requires approval of this contract if using burnFrom)
        TOKEN.burnFrom(msg.sender, burnAmount);

        // Compute and transfer ETH share
        uint256 ethBalance = address(this).balance;
        uint256 ethShare = (ethBalance * burnAmount) / effectiveSupply;

        if (ethShare > 0) {
            payable(msg.sender).sendValue(ethShare);
        }

        // Transfer pro-rata shares of configured ERC20 ragequit tokens
        uint256 len = ragequitTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address erc20 = ragequitTokens[i];
            if (!isRagequitToken[erc20]) continue; // removed but still in array

            uint256 bal = IERC20(erc20).balanceOf(address(this));
            if (bal == 0) continue;

            uint256 share = (bal * burnAmount) / effectiveSupply;
            if (share > 0) {
                IERC20(erc20).safeTransfer(msg.sender, share);
            }
        }

        // If ragequit happened during initial phase (before finalize),
        // reduce initialTokensSold and initialFundsRaised proportionally.
        if (!initialPhaseFinalized && saleStart != 0 && block.timestamp < initialPhaseEnd) {
            // We assume numTokens were part of initialTokensSold.
            if (numTokens <= initialTokensSold) {
                initialTokensSold -= numTokens;

                // Approximate adjustment: subtract ethShare from initialFundsRaised
                if (ethShare >= initialFundsRaised) {
                    initialFundsRaised = 0;
                } else {
                    initialFundsRaised -= ethShare;
                }
            }
        }

        emit Ragequit(msg.sender, burnAmount, ethShare);
    }

    // --- Admin withdrawals (timelocked via TimelockController) ---

    /// @notice Admin ETH withdrawal (not rate-limited, but should be timelocked)
    function adminWithdrawEth(uint256 amountWei, address payable to)
        external
        onlyAdmin
        nonReentrant
    {
        require(to != address(0), "zero to");
        require(address(this).balance >= amountWei, "insufficient ETH");
        to.sendValue(amountWei);
    }

    /// @notice Admin rescue of non-FAO ERC20s (should be timelocked)
    function adminRescueToken(address erc20, uint256 amount, address to)
        external
        onlyAdmin
        nonReentrant
    {
        require(erc20 != address(TOKEN), "cannot rescue FAO");
        require(to != address(0), "zero to");
        IERC20(erc20).safeTransfer(to, amount);
    }

    // Fallbacks: allow direct ETH (e.g., donations) or revert if you prefer
    receive() external payable {
        // Accept ETH
    }

    fallback() external payable {
        revert("FAOSale: fallback not allowed");
    }
}
