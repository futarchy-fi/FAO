// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FaoToken} from "./FaoToken.sol";
import {FAOTreasuryActions} from "./FAOTreasuryActions.sol";
import {GenesisTreasuryExecutor} from "./GenesisTreasuryExecutor.sol";

uint256 constant GENESIS_MAX_VESTING_GRANTS = 16;

interface IGenesisFlm is IERC20 {
    function BOOTSTRAP_RECIPIENT() external view returns (address);
    function COMPANY_TOKEN() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
    function initializedFromBootstrap() external view returns (bool);
    function owner() external view returns (address);

    function initializeFromBootstrap(uint256 companyAmount, uint256 collateralAmount)
        external
        returns (uint128 liquidityMinted);
}

interface IGenesisArbitration {
    enum ProposalState {
        INACTIVE,
        YES,
        NO,
        QUEUED,
        EVALUATING,
        SETTLED
    }

    struct Bond {
        address bidder;
        uint256 amount;
    }

    struct Proposal {
        uint256 minActivationBond;
        Bond yesBond;
        Bond noBond;
        ProposalState state;
        uint64 lastStateChangeAt;
        bool settled;
        bool accepted;
        uint32 queuePosition;
        bool exists;
    }

    function getProposal(uint256 proposalId) external view returns (Proposal memory);
}

interface IGenesisBootstrapHook {
    function prepareAndAssert(uint256 terminalPrice) external;
}

/// @notice Finite genesis sale, FLM bootstrap, immutable vesting and perpetual ragequit treasury.
contract GenesisVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_VESTING_GRANTS = GENESIS_MAX_VESTING_GRANTS;
    uint256 public constant MAX_ASSET_POLICIES = 8;
    uint256 public constant TREASURY_GRACE = 24 hours;
    uint256 public constant TREASURY_EXPIRY = 7 days;
    uint256 public constant TAP_WINDOW = 30 days;
    uint256 public constant CRITICAL_INTERVAL = 30 days;
    uint256 public constant STAGING_EXPIRY = 90 days;
    uint256 public constant CRITICAL_GRACE = 7 days;
    bytes32 public constant KEY_TAP_BUDGET = keccak256("FAO_ECON_TAP_BUDGET_V1");
    address public constant DEAD = address(0xdead);

    enum Phase {
        FUNDING,
        SEALING,
        LIVE,
        FAILED
    }

    struct Config {
        string tokenName;
        string tokenSymbol;
        IERC20 weth;
        address assembler;
        IGenesisArbitration arbitration;
        IGenesisBootstrapHook bootstrapHook;
        uint64 saleEnd;
        uint64 bootstrapDeadline;
        uint256 saleCap;
        uint256 minimumRaise;
        uint256 tokenMaxSupply;
        uint256 initialPrice;
        uint256 slope;
        uint16 bootstrapBps;
        AssetPolicyConfig[] assetPolicies;
    }

    struct GrantConfig {
        address beneficiary;
        uint64 start;
        uint64 duration;
        uint256 amount;
    }

    struct Grant {
        address vestingWallet;
        uint64 start;
        uint64 duration;
        uint256 amount;
    }

    struct QueuedAction {
        uint64 executeAfter;
        uint64 expiresAt;
        bool executed;
        bool expired;
    }

    struct AssetPolicyConfig {
        address asset;
        uint128 c1;
        uint128 c2;
        uint128 tapBudget;
        uint128 tapBudgetMax;
    }

    struct AssetPolicy {
        uint128 c1;
        uint128 c2;
        uint128 tapBudget;
        uint128 tapBudgetMax;
        bool exists;
    }

    struct TapState {
        uint64 windowStart;
        uint192 spent;
    }

    struct CriticalStaging {
        uint64 stagedAt;
        bool queued;
    }

    error InvalidConfig();
    error InvalidPhase();
    error SaleClosed();
    error DeadlineExpired();
    error ZeroAmount();
    error ZeroCost();
    error SaleCapExceeded();
    error MaxCostExceeded();
    error InvalidAssetTransfer();
    error TooEarly();
    error BootstrapNotReady();
    error OnlyAssembler();
    error ManagerAlreadyBound();
    error InvalidManager();
    error InvalidBootstrapHook();
    error NothingToClaim();
    error ClaimReserveUndercollateralized();
    error InvalidEffectiveSupply();
    error InvalidRecipient();
    error InvalidExtraAsset();
    error ExtrasNotStrictlySorted();
    error InvalidTreasuryAction();
    error InvalidAssetPolicy();
    error TooManyAssetPolicies();
    error AssetNotConfigured(address asset);
    error TransferAboveCap(address asset, uint256 amount, uint256 cap);
    error TapBudgetExceeded(address asset, uint256 requested, uint256 available);
    error EvaluatedAcceptanceRequired(uint256 proposalId);
    error UnsupportedTreasuryParam(bytes32 key);
    error OnlySelf();
    error CriticalAlreadyStaged(bytes32 baseHash);
    error CriticalNotStaged(bytes32 baseHash);
    error CriticalRoundTwoTooEarly(uint256 opensAt);
    error CriticalStagingExpired(uint256 closesAt);
    error CriticalAlreadyQueued(bytes32 baseHash);
    error ArbitrationNotAccepted();
    error ActionAlreadyQueued();
    error ActionNotQueued();
    error ActionInGracePeriod();
    error ActionExpired();
    error UnauthorizedTokenBurn();

    event Purchased(address indexed buyer, uint256 tokenAmount, uint256 cost);
    event Sealed(uint256 sold, uint256 raised);
    event Failed();
    event Refunded(address indexed account, uint256 amount);
    event ManagerBound(address indexed manager);
    event Finalized(
        uint256 sold,
        uint256 raised,
        uint256 bootstrapCompany,
        uint256 bootstrapCollateral,
        uint256 flmShares
    );
    event Claimed(address indexed account, uint256 amount);
    event Ragequit(
        address indexed account, address indexed recipient, uint256 amount, uint256 supply
    );
    event TreasuryActionExpired(bytes32 indexed actionHash);
    event AssetPolicySet(
        address indexed asset, uint128 c1, uint128 c2, uint128 tapBudget, uint128 tapBudgetMax
    );
    event TapSpent(
        address indexed asset, uint256 amount, uint256 spent, uint256 budget, uint256 windowStart
    );
    event TreasuryTransferQueued(
        bytes32 indexed actionHash,
        uint256 indexed proposalId,
        uint256 executeAfter,
        uint256 expiresAt
    );
    event TreasuryTransferExecuted(
        bytes32 indexed actionHash, address indexed asset, address indexed recipient, uint256 amount
    );
    event TreasuryParamQueued(
        bytes32 indexed actionHash,
        uint256 indexed proposalId,
        uint256 executeAfter,
        uint256 expiresAt
    );
    event TreasuryParamExecuted(
        bytes32 indexed actionHash, bytes32 indexed key, address indexed asset, uint256 value
    );
    event CriticalActionStaged(
        bytes32 indexed baseHash,
        uint256 indexed roundOneProposalId,
        uint256 stagedAt,
        uint256 roundTwoOpensAt,
        uint256 stagingExpiresAt
    );
    event CriticalActionQueued(
        bytes32 indexed baseHash,
        uint256 indexed roundTwoProposalId,
        uint256 executeAfter,
        uint256 expiresAt
    );
    event CriticalActionExecuted(bytes32 indexed baseHash, address indexed target, uint256 value);
    event Buyback(address indexed caller, uint256 wethSpent, uint256 companyBurned);

    IERC20 public immutable WETH;
    FaoToken public immutable COMPANY_TOKEN;
    GenesisTreasuryExecutor public immutable TREASURY_EXECUTOR;
    address public immutable ASSEMBLER;
    IGenesisArbitration public immutable ARBITRATION;
    IGenesisBootstrapHook public immutable BOOTSTRAP_HOOK;
    uint64 public immutable SALE_END;
    uint64 public immutable BOOTSTRAP_DEADLINE;
    uint256 public immutable SALE_CAP;
    uint256 public immutable MINIMUM_RAISE;
    uint256 public immutable INITIAL_PRICE;
    uint256 public immutable SLOPE;
    uint16 public immutable BOOTSTRAP_BPS;

    Phase public phase;
    IGenesisFlm public manager;
    uint256 public totalSold;
    uint256 public totalRaised;
    uint256 public totalUnclaimedSold;
    uint256 public assetPolicyCount;

    mapping(address account => uint256 amount) public purchased;
    mapping(address account => uint256 amount) public contribution;
    Grant[] public grants;
    mapping(bytes32 actionHash => QueuedAction action) public queuedActions;
    mapping(address asset => AssetPolicy policy) public assetPolicies;
    mapping(address asset => TapState state) public tapStates;
    mapping(bytes32 baseHash => CriticalStaging staging) public criticalStagings;
    address private authorizedBurnAccount;
    uint256 private authorizedBurnAmount;

    constructor(Config memory config, GrantConfig[] memory grantConfigs) {
        if (
            address(config.weth) == address(0) || address(config.weth).code.length == 0
                || config.assembler == address(0) || address(config.arbitration) == address(0)
                || address(config.arbitration).code.length == 0 || config.saleEnd <= block.timestamp
                || address(config.bootstrapHook) == address(0)
                || address(config.bootstrapHook).code.length == 0
                || config.bootstrapDeadline <= config.saleEnd || config.saleCap == 0
                || config.minimumRaise == 0 || config.tokenMaxSupply == 0
                || config.initialPrice == 0 || grantConfigs.length > MAX_VESTING_GRANTS
                || config.assetPolicies.length > MAX_ASSET_POLICIES || config.bootstrapBps == 0
                || config.bootstrapBps > BPS_DENOMINATOR
                || Math.mulDiv(config.minimumRaise, config.bootstrapBps, BPS_DENOMINATOR) == 0
        ) revert InvalidConfig();

        WETH = config.weth;
        TREASURY_EXECUTOR = new GenesisTreasuryExecutor(address(this));
        ASSEMBLER = config.assembler;
        ARBITRATION = config.arbitration;
        BOOTSTRAP_HOOK = config.bootstrapHook;
        SALE_END = config.saleEnd;
        BOOTSTRAP_DEADLINE = config.bootstrapDeadline;
        SALE_CAP = config.saleCap;
        MINIMUM_RAISE = config.minimumRaise;
        INITIAL_PRICE = config.initialPrice;
        SLOPE = config.slope;
        BOOTSTRAP_BPS = config.bootstrapBps;

        for (uint256 i; i < config.assetPolicies.length; ++i) {
            AssetPolicyConfig memory policy = config.assetPolicies[i];
            if (assetPolicies[policy.asset].exists) revert InvalidAssetPolicy();
            _setAssetPolicy(
                policy.asset, policy.c1, policy.c2, policy.tapBudget, policy.tapBudgetMax
            );
        }

        // Evaluating the endpoint here rejects arithmetic domains that cannot be priced safely.
        if (config.minimumRaise > reserveAt(config.saleCap)) revert InvalidConfig();

        uint256 totalGrants;
        for (uint256 i; i < grantConfigs.length; ++i) {
            GrantConfig memory grant = grantConfigs[i];
            if (grant.beneficiary == address(0) || grant.duration == 0 || grant.amount == 0) {
                revert InvalidConfig();
            }
            if (grant.amount > type(uint256).max - totalGrants) revert InvalidConfig();
            totalGrants += grant.amount;
            VestingWallet wallet = new VestingWallet(grant.beneficiary, grant.start, grant.duration);
            grants.push(Grant(address(wallet), grant.start, grant.duration, grant.amount));
        }

        // The seed is at most sold plus one WAD of discrete reserve rounding.
        if (config.saleCap > (type(uint256).max - WAD) / 2) revert InvalidConfig();
        uint256 maximumGenesisSupply = config.saleCap * 2 + WAD;
        if (totalGrants > type(uint256).max - maximumGenesisSupply) revert InvalidConfig();
        maximumGenesisSupply += totalGrants;
        if (config.tokenMaxSupply < maximumGenesisSupply) {
            revert InvalidConfig();
        }
        COMPANY_TOKEN = new FaoToken(
            config.tokenName, config.tokenSymbol, address(this), config.tokenMaxSupply
        );
    }

    receive() external payable {}

    function grantCount() external view returns (uint256) {
        return grants.length;
    }

    /// @notice Cumulative WETH reserve for `supply` token atoms.
    /// @dev A single endpoint rounding makes reserve differences exactly path-independent.
    function reserveAt(uint256 supply) public view returns (uint256) {
        if (supply > SALE_CAP) revert SaleCapExceeded();
        uint256 linearTerm = 2 * INITIAL_PRICE * WAD + SLOPE * supply;
        return Math.mulDiv(supply, linearTerm, 2 * WAD * WAD, Math.Rounding.Up);
    }

    function terminalPrice() public view returns (uint256) {
        return INITIAL_PRICE + Math.mulDiv(SLOPE, totalSold, WAD);
    }

    function buy(uint256 tokenOut, uint256 maxCost, uint256 deadline)
        external
        nonReentrant
        returns (uint256 cost)
    {
        if (phase != Phase.FUNDING) revert InvalidPhase();
        if (block.timestamp >= SALE_END) revert SaleClosed();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (tokenOut == 0) revert ZeroAmount();

        uint256 soldAfter = totalSold + tokenOut;
        if (soldAfter > SALE_CAP) revert SaleCapExceeded();
        cost = reserveAt(soldAfter) - reserveAt(totalSold);
        if (cost == 0) revert ZeroCost();
        if (cost > maxCost) revert MaxCostExceeded();

        _pullExact(WETH, msg.sender, cost);
        totalSold = soldAfter;
        totalRaised += cost;
        purchased[msg.sender] += tokenOut;
        contribution[msg.sender] += cost;
        emit Purchased(msg.sender, tokenOut, cost);

        if (soldAfter == SALE_CAP) _seal();
    }

    /// @notice Permissionlessly advances a successful ended sale to bootstrap preparation.
    function seal() external nonReentrant {
        if (phase != Phase.FUNDING) revert InvalidPhase();
        if (block.timestamp < SALE_END) revert TooEarly();
        if (totalRaised < MINIMUM_RAISE) revert BootstrapNotReady();
        _seal();
    }

    function _seal() private {
        phase = Phase.SEALING;
        totalUnclaimedSold = totalSold;
        emit Sealed(totalSold, totalRaised);
    }

    /// @notice Irreversibly binds the one manager assembled for this vault.
    function bindManager(IGenesisFlm manager_) external nonReentrant {
        if (msg.sender != ASSEMBLER) revert OnlyAssembler();
        if (address(manager) != address(0)) revert ManagerAlreadyBound();
        _validateManager(manager_);
        manager = manager_;
        emit ManagerBound(address(manager_));
    }

    /// @notice Atomically mints genesis allocations and bootstraps the already-prepared FLM.
    function finalize() external nonReentrant returns (uint256 flmShares) {
        if (phase != Phase.SEALING) revert InvalidPhase();
        if (block.timestamp >= BOOTSTRAP_DEADLINE) revert DeadlineExpired();
        IGenesisFlm manager_ = manager;
        if (address(manager_) == address(0)) revert BootstrapNotReady();
        _validateManager(manager_);
        IGenesisBootstrapHook hook = BOOTSTRAP_HOOK;
        if (address(hook).code.length == 0) revert InvalidBootstrapHook();
        hook.prepareAndAssert(terminalPrice());

        uint256 bootstrapCollateral = Math.mulDiv(totalRaised, BOOTSTRAP_BPS, BPS_DENOMINATOR);
        if (bootstrapCollateral == 0) revert BootstrapNotReady();
        uint256 bootstrapCompany =
            Math.mulDiv(bootstrapCollateral, WAD, terminalPrice(), Math.Rounding.Up);
        if (bootstrapCompany == 0) revert BootstrapNotReady();

        COMPANY_TOKEN.mint(address(this), totalSold);
        for (uint256 i; i < grants.length; ++i) {
            Grant memory grant = grants[i];
            COMPANY_TOKEN.mint(grant.vestingWallet, grant.amount);
        }
        COMPANY_TOKEN.mint(address(this), bootstrapCompany);

        uint256 sharesBefore = manager_.balanceOf(address(this));
        _forceApprove(IERC20(address(COMPANY_TOKEN)), address(manager_), bootstrapCompany);
        _forceApprove(WETH, address(manager_), bootstrapCollateral);
        uint128 reported = manager_.initializeFromBootstrap(bootstrapCompany, bootstrapCollateral);
        _forceApprove(IERC20(address(COMPANY_TOKEN)), address(manager_), 0);
        _forceApprove(WETH, address(manager_), 0);

        uint256 sharesAfter = manager_.balanceOf(address(this));
        flmShares = sharesAfter - sharesBefore;
        if (flmShares == 0 || flmShares != reported) revert InvalidManager();

        uint256 vaultTokens = COMPANY_TOKEN.balanceOf(address(this));
        if (vaultTokens < totalUnclaimedSold) revert ClaimReserveUndercollateralized();
        uint256 unusedSeed = vaultTokens - totalUnclaimedSold;
        if (unusedSeed != 0) _burnCompanyToken(address(this), unusedSeed);
        if (
            COMPANY_TOKEN.balanceOf(address(this)) != totalUnclaimedSold
                || COMPANY_TOKEN.allowance(address(this), address(manager_)) != 0
                || WETH.allowance(address(this), address(manager_)) != 0
        ) revert InvalidManager();

        _pushExact(WETH, address(TREASURY_EXECUTOR), WETH.balanceOf(address(this)));
        _pushExact(
            IERC20(address(manager_)), address(TREASURY_EXECUTOR), manager_.balanceOf(address(this))
        );

        COMPANY_TOKEN.finishMinting();
        phase = Phase.LIVE;
        emit Finalized(totalSold, totalRaised, bootstrapCompany, bootstrapCollateral, flmShares);
    }

    /// @notice Makes an unsuccessful or unbootstrapped sale refundable without privileged help.
    function fail() external nonReentrant {
        if (phase == Phase.LIVE || phase == Phase.FAILED) revert InvalidPhase();
        bool missedBootstrap = block.timestamp >= BOOTSTRAP_DEADLINE;
        bool missedMinimum =
            phase == Phase.FUNDING && block.timestamp >= SALE_END && totalRaised < MINIMUM_RAISE;
        if (!missedBootstrap && !missedMinimum) revert TooEarly();
        phase = Phase.FAILED;
        emit Failed();
    }

    /// @notice Refunds `account` to that same account; anybody may keep refund liveness alive.
    function refund(address account) external nonReentrant returns (uint256 amount) {
        if (phase != Phase.FAILED) revert InvalidPhase();
        amount = contribution[account];
        if (amount == 0) revert NothingToClaim();
        contribution[account] = 0;
        purchased[account] = 0;
        _pushExact(WETH, account, amount);
        emit Refunded(account, amount);
    }

    /// @notice Delivers an escrowed sale allocation only to its buyer.
    function claim(address account) external nonReentrant returns (uint256 amount) {
        if (phase != Phase.LIVE) revert InvalidPhase();
        amount = purchased[account];
        if (amount == 0) revert NothingToClaim();
        purchased[account] = 0;
        totalUnclaimedSold -= amount;
        _pushExact(IERC20(address(COMPANY_TOKEN)), account, amount);
        emit Claimed(account, amount);
    }

    /// @notice Supply entitled to the treasury, excluding this vault and immutable unvested grants.
    function effectiveSupply() public view returns (uint256 supply) {
        uint256 vaultBalance = COMPANY_TOKEN.balanceOf(address(this));
        if (vaultBalance < totalUnclaimedSold) revert ClaimReserveUndercollateralized();
        supply = COMPANY_TOKEN.totalSupply() - vaultBalance + totalUnclaimedSold;

        uint256 executorBalance = COMPANY_TOKEN.balanceOf(address(TREASURY_EXECUTOR));
        if (executorBalance > supply) revert InvalidEffectiveSupply();
        supply -= executorBalance;

        uint256 unvested;
        for (uint256 i; i < grants.length; ++i) {
            Grant memory grant = grants[i];
            unvested += _unvested(grant, block.timestamp);
        }
        if (unvested > supply) revert InvalidEffectiveSupply();
        supply -= unvested;
    }

    /// @notice Burns the caller's tokens for its exact pro-rata share of every selected vault
    /// asset.
    function ragequit(uint256 amount, address payable recipient, address[] calldata sortedExtras)
        external
        nonReentrant
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();

        uint256 supply = effectiveSupply();
        if (supply == 0 || amount > supply) revert InvalidEffectiveSupply();

        address treasury = address(TREASURY_EXECUTOR);
        uint256 wethBalance = WETH.balanceOf(treasury);
        uint256 managerBalance = manager.balanceOf(treasury);
        uint256[] memory extraBalances = new uint256[](sortedExtras.length);
        for (uint256 i; i < sortedExtras.length; ++i) {
            address asset = sortedExtras[i];
            if (i != 0 && uint160(asset) <= uint160(sortedExtras[i - 1])) {
                revert ExtrasNotStrictlySorted();
            }
            if (
                asset == address(COMPANY_TOKEN) || asset == address(WETH)
                    || asset == address(manager)
            ) revert InvalidExtraAsset();
            extraBalances[i] =
                asset == address(0) ? treasury.balance : IERC20(asset).balanceOf(treasury);
        }

        _burnCompanyToken(msg.sender, amount);
        _releaseProRata(address(WETH), recipient, wethBalance, amount, supply);
        _releaseProRata(address(manager), recipient, managerBalance, amount, supply);
        for (uint256 i; i < sortedExtras.length; ++i) {
            uint256 payout = Math.mulDiv(extraBalances[i], amount, supply);
            _releaseExact(sortedExtras[i], recipient, payout);
        }
        if (COMPANY_TOKEN.balanceOf(address(this)) < totalUnclaimedSold) {
            revert ClaimReserveUndercollateralized();
        }
        emit Ragequit(msg.sender, recipient, amount, supply);
    }

    /// @dev One-shot callback consumed by the immutable token during an active vault burn.
    function consumeTokenBurnAuthorization(address account, uint256 amount) external {
        if (
            msg.sender != address(COMPANY_TOKEN) || account != authorizedBurnAccount
                || amount != authorizedBurnAmount || amount == 0
        ) revert UnauthorizedTokenBurn();
        delete authorizedBurnAccount;
        delete authorizedBurnAmount;
    }

    /// @notice Permissionlessly moves a misdirected LIVE treasury deposit into canonical custody.
    function sweepToExecutor(address asset) external nonReentrant returns (uint256 amount) {
        if (phase != Phase.LIVE) revert InvalidPhase();
        if (asset == address(COMPANY_TOKEN)) revert InvalidExtraAsset();
        if (asset == address(0)) {
            amount = address(this).balance;
            _pushNativeExact(payable(address(TREASURY_EXECUTOR)), amount);
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            _pushExact(IERC20(asset), address(TREASURY_EXECUTOR), amount);
        }
    }

    /// @notice Permissionlessly buys undervalued FAO under the executor's fixed policy and burns
    /// it.
    function buyback() external nonReentrant returns (uint256 wethSpent, uint256 companyBurned) {
        if (phase != Phase.LIVE) revert InvalidPhase();
        address treasury = address(TREASURY_EXECUTOR);
        uint256 companyBefore = COMPANY_TOKEN.balanceOf(treasury);
        uint256 wethBefore = WETH.balanceOf(treasury);
        uint256 supplyBefore = COMPANY_TOKEN.totalSupply();
        (wethSpent, companyBurned) = TREASURY_EXECUTOR.buyback();
        if (
            companyBurned == 0 || COMPANY_TOKEN.balanceOf(treasury) - companyBefore != companyBurned
                || wethBefore - WETH.balanceOf(treasury) != wethSpent
        ) revert InvalidAssetTransfer();
        _burnCompanyToken(treasury, companyBurned);
        if (
            COMPANY_TOKEN.balanceOf(treasury) != companyBefore
                || supplyBefore - COMPANY_TOKEN.totalSupply() != companyBurned
        ) revert InvalidAssetTransfer();
        emit Buyback(msg.sender, wethSpent, companyBurned);
    }

    function transferActionHash(FAOTreasuryActions.TransferAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.transferHash(block.chainid, address(this), action);
    }

    function paramActionHash(FAOTreasuryActions.ParamAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.paramHash(block.chainid, address(this), action);
    }

    function criticalActionBaseHash(FAOTreasuryActions.CriticalAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.criticalBaseHash(block.chainid, address(this), action);
    }

    function criticalActionProposalId(
        FAOTreasuryActions.CriticalAction calldata action,
        uint256 round
    ) public view returns (uint256) {
        return uint256(FAOTreasuryActions.criticalHash(block.chainid, address(this), action, round));
    }

    function criticalRoundTwoWindow(bytes32 baseHash)
        external
        view
        returns (uint256 opensAt, uint256 closesAt, bool queued)
    {
        CriticalStaging memory staging = criticalStagings[baseHash];
        if (staging.stagedAt == 0) return (0, 0, false);
        return (
            uint256(staging.stagedAt) + CRITICAL_INTERVAL,
            uint256(staging.stagedAt) + STAGING_EXPIRY,
            staging.queued
        );
    }

    function queueTreasuryTransfer(FAOTreasuryActions.TransferAction calldata action)
        external
        nonReentrant
        returns (bytes32 actionHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        actionHash = transferActionHash(action);
        (bool evaluated, uint256 settledAt) = _acceptedRoute(uint256(actionHash));
        _validateTransfer(action, evaluated);
        (uint256 executeAfter, uint256 expiresAt) =
            _queueSettledAction(actionHash, settledAt, TREASURY_GRACE, TREASURY_EXPIRY);
        emit TreasuryTransferQueued(actionHash, uint256(actionHash), executeAfter, expiresAt);
    }

    function executeTreasuryTransfer(FAOTreasuryActions.TransferAction calldata action)
        external
        nonReentrant
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        bytes32 actionHash = transferActionHash(action);
        (bool evaluated,) = _acceptedRoute(uint256(actionHash));
        _validateTransfer(action, evaluated);
        QueuedAction storage queued = _readyAction(actionHash);
        queued.executed = true;
        if (!evaluated) _spendTap(action.asset, action.amount);
        _releaseExact(action.asset, payable(action.recipient), action.amount);
        emit TreasuryTransferExecuted(actionHash, action.asset, action.recipient, action.amount);
    }

    function queueTreasuryParam(FAOTreasuryActions.ParamAction calldata action)
        external
        nonReentrant
        returns (bytes32 actionHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        actionHash = paramActionHash(action);
        (bool evaluated, uint256 settledAt) = _acceptedRoute(uint256(actionHash));
        if (!evaluated) {
            revert EvaluatedAcceptanceRequired(uint256(actionHash));
        }
        _validateParam(action);
        (uint256 executeAfter, uint256 expiresAt) =
            _queueSettledAction(actionHash, settledAt, TREASURY_GRACE, TREASURY_EXPIRY);
        emit TreasuryParamQueued(actionHash, uint256(actionHash), executeAfter, expiresAt);
    }

    function executeTreasuryParam(FAOTreasuryActions.ParamAction calldata action)
        external
        nonReentrant
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        bytes32 actionHash = paramActionHash(action);
        (bool evaluated,) = _acceptedRoute(uint256(actionHash));
        if (!evaluated) {
            revert EvaluatedAcceptanceRequired(uint256(actionHash));
        }
        _validateParam(action);
        QueuedAction storage queued = _readyAction(actionHash);
        queued.executed = true;
        AssetPolicy storage policy = assetPolicies[action.asset];
        policy.tapBudget = uint128(action.value);
        emit AssetPolicySet(
            action.asset, policy.c1, policy.c2, policy.tapBudget, policy.tapBudgetMax
        );
        emit TreasuryParamExecuted(actionHash, action.key, action.asset, action.value);
    }

    function stageCriticalAction(FAOTreasuryActions.CriticalAction calldata action)
        external
        nonReentrant
        returns (bytes32 baseHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        _validateTreasuryTarget(action.target);
        baseHash = criticalActionBaseHash(action);
        CriticalStaging storage staging = criticalStagings[baseHash];
        if (staging.stagedAt != 0) revert CriticalAlreadyStaged(baseHash);
        uint256 roundOneProposalId = criticalActionProposalId(action, 1);
        (bool roundOneEvaluated,) = _acceptedRoute(roundOneProposalId);
        if (!roundOneEvaluated) {
            revert EvaluatedAcceptanceRequired(roundOneProposalId);
        }
        if (block.timestamp > type(uint64).max) revert InvalidTreasuryAction();
        staging.stagedAt = uint64(block.timestamp);
        emit CriticalActionStaged(
            baseHash,
            roundOneProposalId,
            block.timestamp,
            block.timestamp + CRITICAL_INTERVAL,
            block.timestamp + STAGING_EXPIRY
        );
    }

    function queueCriticalAction(FAOTreasuryActions.CriticalAction calldata action)
        external
        nonReentrant
        returns (bytes32 baseHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        _validateTreasuryTarget(action.target);
        baseHash = criticalActionBaseHash(action);
        CriticalStaging storage staging = criticalStagings[baseHash];
        if (staging.stagedAt == 0) revert CriticalNotStaged(baseHash);
        if (staging.queued) revert CriticalAlreadyQueued(baseHash);
        uint256 opensAt = uint256(staging.stagedAt) + CRITICAL_INTERVAL;
        uint256 closesAt = uint256(staging.stagedAt) + STAGING_EXPIRY;
        if (block.timestamp < opensAt) revert CriticalRoundTwoTooEarly(opensAt);
        if (block.timestamp > closesAt) revert CriticalStagingExpired(closesAt);
        uint256 roundTwoProposalId = criticalActionProposalId(action, 2);
        (bool roundTwoEvaluated,) = _acceptedRoute(roundTwoProposalId);
        if (!roundTwoEvaluated) {
            revert EvaluatedAcceptanceRequired(roundTwoProposalId);
        }
        staging.queued = true;
        (uint256 executeAfter, uint256 expiresAt) =
            _queueAction(baseHash, CRITICAL_GRACE, TREASURY_EXPIRY);
        emit CriticalActionQueued(baseHash, roundTwoProposalId, executeAfter, expiresAt);
    }

    function executeCriticalAction(FAOTreasuryActions.CriticalAction calldata action)
        external
        nonReentrant
        returns (bytes memory result)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        _validateTreasuryTarget(action.target);
        bytes32 baseHash = criticalActionBaseHash(action);
        if (!criticalStagings[baseHash].queued) revert CriticalNotStaged(baseHash);
        QueuedAction storage queued = _readyAction(baseHash);
        queued.executed = true;
        bytes memory returndata =
            TREASURY_EXECUTOR.execute(action.target, action.value, action.data);
        emit CriticalActionExecuted(baseHash, action.target, action.value);
        return returndata;
    }

    function expireQueuedAction(bytes32 actionHash) external nonReentrant {
        if (phase != Phase.LIVE) revert InvalidPhase();
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter == 0) revert ActionNotQueued();
        if (queued.executed || queued.expired) revert ActionAlreadyQueued();
        if (block.timestamp <= queued.expiresAt) revert TooEarly();
        queued.expired = true;
        emit TreasuryActionExpired(actionHash);
    }

    function setAssetPolicy(
        address asset,
        uint128 c1,
        uint128 c2,
        uint128 tapBudget,
        uint128 tapBudgetMax
    ) external {
        if (msg.sender != address(TREASURY_EXECUTOR)) revert OnlySelf();
        _setAssetPolicy(asset, c1, c2, tapBudget, tapBudgetMax);
    }

    function _acceptedRoute(uint256 proposalId)
        private
        view
        returns (bool evaluated, uint256 settledAt)
    {
        IGenesisArbitration.Proposal memory proposal = ARBITRATION.getProposal(proposalId);
        if (!proposal.settled || !proposal.accepted) revert ArbitrationNotAccepted();
        return (proposal.queuePosition != 0, proposal.lastStateChangeAt);
    }

    function _validateTransfer(FAOTreasuryActions.TransferAction calldata action, bool evaluated)
        private
        view
    {
        if (action.recipient == address(0) || action.amount == 0) {
            revert InvalidTreasuryAction();
        }
        AssetPolicy memory policy = assetPolicies[action.asset];
        if (!policy.exists) revert AssetNotConfigured(action.asset);
        if (action.amount > policy.c2) {
            revert TransferAboveCap(action.asset, action.amount, policy.c2);
        }
        if (action.amount > policy.c1 && !evaluated) {
            revert EvaluatedAcceptanceRequired(uint256(transferActionHash(action)));
        }
    }

    function _validateParam(FAOTreasuryActions.ParamAction calldata action) private view {
        if (action.key != KEY_TAP_BUDGET) revert UnsupportedTreasuryParam(action.key);
        AssetPolicy memory policy = assetPolicies[action.asset];
        if (!policy.exists) revert AssetNotConfigured(action.asset);
        if (action.value > policy.tapBudgetMax) revert InvalidAssetPolicy();
    }

    function _queueAction(bytes32 actionHash, uint256 grace, uint256 expiry)
        private
        returns (uint256 executeAfter, uint256 expiresAt)
    {
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter != 0 || queued.executed || queued.expired) {
            revert ActionAlreadyQueued();
        }
        executeAfter = block.timestamp + grace;
        expiresAt = executeAfter + expiry;
        if (expiresAt > type(uint64).max) revert InvalidTreasuryAction();
        queued.executeAfter = uint64(executeAfter);
        queued.expiresAt = uint64(expiresAt);
    }

    function _queueSettledAction(
        bytes32 actionHash,
        uint256 settledAt,
        uint256 grace,
        uint256 expiry
    ) private returns (uint256 executeAfter, uint256 expiresAt) {
        executeAfter = settledAt + grace;
        expiresAt = executeAfter + expiry;
        if (block.timestamp > expiresAt) revert ActionExpired();
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter != 0 || queued.executed || queued.expired) {
            revert ActionAlreadyQueued();
        }
        if (expiresAt > type(uint64).max) revert InvalidTreasuryAction();
        queued.executeAfter = uint64(executeAfter);
        queued.expiresAt = uint64(expiresAt);
    }

    function _readyAction(bytes32 actionHash) private view returns (QueuedAction storage queued) {
        queued = queuedActions[actionHash];
        if (queued.executeAfter == 0) revert ActionNotQueued();
        if (queued.executed) revert ActionAlreadyQueued();
        if (queued.expired) revert ActionExpired();
        if (block.timestamp < queued.executeAfter) revert ActionInGracePeriod();
        if (block.timestamp > queued.expiresAt) revert ActionExpired();
    }

    function _spendTap(address asset, uint256 amount) private {
        AssetPolicy memory policy = assetPolicies[asset];
        TapState storage tap = tapStates[asset];
        if (tap.windowStart == 0 || block.timestamp >= uint256(tap.windowStart) + TAP_WINDOW) {
            if (block.timestamp > type(uint64).max) revert InvalidTreasuryAction();
            tap.windowStart = uint64(block.timestamp);
            tap.spent = 0;
        }
        uint256 available = policy.tapBudget > tap.spent ? policy.tapBudget - tap.spent : 0;
        if (amount > available) revert TapBudgetExceeded(asset, amount, available);
        tap.spent += uint192(amount);
        emit TapSpent(asset, amount, tap.spent, policy.tapBudget, tap.windowStart);
    }

    function _setAssetPolicy(
        address asset,
        uint128 c1,
        uint128 c2,
        uint128 tapBudget,
        uint128 tapBudgetMax
    ) private {
        if ((asset != address(0) && asset.code.length == 0) || c1 > c2 || tapBudget > tapBudgetMax) revert InvalidAssetPolicy();
        AssetPolicy storage policy = assetPolicies[asset];
        if (!policy.exists) {
            if (assetPolicyCount >= MAX_ASSET_POLICIES) revert TooManyAssetPolicies();
            policy.exists = true;
            assetPolicyCount += 1;
        }
        policy.c1 = c1;
        policy.c2 = c2;
        policy.tapBudget = tapBudget;
        policy.tapBudgetMax = tapBudgetMax;
        emit AssetPolicySet(asset, c1, c2, tapBudget, tapBudgetMax);
    }

    function _validateManager(IGenesisFlm manager_) private view {
        if (
            address(manager_) == address(0) || address(manager_).code.length == 0
                || manager_.BOOTSTRAP_RECIPIENT() != address(this)
                || manager_.COMPANY_TOKEN() != address(COMPANY_TOKEN)
                || manager_.WRAPPED_NATIVE() != address(WETH) || manager_.totalSupply() != 0
                || manager_.initializedFromBootstrap() || manager_.owner() != DEAD
        ) revert InvalidManager();
    }

    function _validateTreasuryTarget(address target) private pure {
        if (target == address(0)) revert InvalidTreasuryAction();
    }

    function _unvested(Grant memory grant, uint256 timestamp) private pure returns (uint256) {
        if (timestamp < grant.start) return grant.amount;
        uint256 end = uint256(grant.start) + grant.duration;
        if (timestamp >= end) return 0;
        uint256 vested = Math.mulDiv(grant.amount, timestamp - grant.start, grant.duration);
        return grant.amount - vested;
    }

    function _pullExact(IERC20 asset, address from, uint256 amount) private {
        uint256 beforeBalance = asset.balanceOf(address(this));
        asset.safeTransferFrom(from, address(this), amount);
        if (asset.balanceOf(address(this)) - beforeBalance != amount) {
            revert InvalidAssetTransfer();
        }
    }

    function _pushExact(IERC20 asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 vaultBefore = asset.balanceOf(address(this));
        uint256 recipientBefore = asset.balanceOf(recipient);
        asset.safeTransfer(recipient, amount);
        if (
            vaultBefore - asset.balanceOf(address(this)) != amount
                || asset.balanceOf(recipient) - recipientBefore != amount
        ) revert InvalidAssetTransfer();
    }

    function _releaseProRata(
        address asset,
        address payable recipient,
        uint256 balance,
        uint256 amount,
        uint256 supply
    ) private {
        _releaseExact(asset, recipient, Math.mulDiv(balance, amount, supply));
    }

    function _burnCompanyToken(address account, uint256 amount) private {
        if (authorizedBurnAmount != 0) revert UnauthorizedTokenBurn();
        authorizedBurnAccount = account;
        authorizedBurnAmount = amount;
        COMPANY_TOKEN.burnFromVault(account, amount);
        if (authorizedBurnAmount != 0) revert UnauthorizedTokenBurn();
    }

    function _releaseExact(address asset, address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        address treasury = address(TREASURY_EXECUTOR);
        if (asset == address(0)) {
            uint256 beforeBalance = treasury.balance;
            TREASURY_EXECUTOR.transferAsset(asset, recipient, amount);
            if (beforeBalance - treasury.balance != amount) revert InvalidAssetTransfer();
            return;
        }

        IERC20 token = IERC20(asset);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 recipientBefore = token.balanceOf(recipient);
        TREASURY_EXECUTOR.transferAsset(asset, recipient, amount);
        if (
            treasuryBefore - token.balanceOf(treasury) != amount
                || token.balanceOf(recipient) - recipientBefore != amount
        ) revert InvalidAssetTransfer();
    }

    function _pushNativeExact(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 vaultBefore = address(this).balance;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok || vaultBefore - address(this).balance != amount) revert InvalidAssetTransfer();
    }

    /// @dev OpenZeppelin v4 SafeERC20 has no forceApprove.
    function _forceApprove(IERC20 asset, address spender, uint256 amount) private {
        uint256 allowance = asset.allowance(address(this), spender);
        if (allowance != 0) asset.safeApprove(spender, 0);
        if (amount != 0) asset.safeApprove(spender, amount);
    }
}
