// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FaoToken} from "./FaoToken.sol";
import {FAOTreasuryActions} from "./FAOTreasuryActions.sol";

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
    function isSettled(uint256 proposalId) external view returns (bool);
    function isAccepted(uint256 proposalId) external view returns (bool);
}

interface IGenesisBootstrapHook {
    function prepareAndAssert(uint256 terminalPrice) external;
}

/// @notice Finite genesis sale, FLM bootstrap, immutable vesting and perpetual ragequit treasury.
contract GenesisVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_VESTING_GRANTS = 32;
    uint256 public constant TREASURY_GRACE = 24 hours;
    uint256 public constant TREASURY_EXPIRY = 7 days;
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
    error ArbitrationNotAccepted();
    error ActionAlreadyQueued();
    error ActionNotQueued();
    error ActionInGracePeriod();
    error ActionExpired();
    error TreasuryCallFailed(bytes reason);

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
    event TreasuryActionQueued(bytes32 indexed actionHash, uint256 executeAfter, uint256 expiresAt);
    event TreasuryActionExecuted(bytes32 indexed actionHash, address indexed target, uint256 value);
    event TreasuryActionExpired(bytes32 indexed actionHash);

    IERC20 public immutable WETH;
    FaoToken public immutable COMPANY_TOKEN;
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

    mapping(address account => uint256 amount) public purchased;
    mapping(address account => uint256 amount) public contribution;
    Grant[] public grants;
    mapping(bytes32 actionHash => QueuedAction action) public queuedActions;

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
                || config.bootstrapBps == 0 || config.bootstrapBps > BPS_DENOMINATOR
        ) revert InvalidConfig();

        WETH = config.weth;
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
        if (unusedSeed != 0) COMPANY_TOKEN.burnFromVault(address(this), unusedSeed);
        if (
            COMPANY_TOKEN.balanceOf(address(this)) != totalUnclaimedSold
                || COMPANY_TOKEN.allowance(address(this), address(manager_)) != 0
                || WETH.allowance(address(this), address(manager_)) != 0
        ) revert InvalidManager();

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

        uint256 wethBalance = WETH.balanceOf(address(this));
        uint256 managerBalance = manager.balanceOf(address(this));
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
            extraBalances[i] = asset == address(0)
                ? address(this).balance
                : IERC20(asset).balanceOf(address(this));
        }

        COMPANY_TOKEN.burnFromVault(msg.sender, amount);
        _pushProRata(WETH, recipient, wethBalance, amount, supply);
        _pushProRata(IERC20(address(manager)), recipient, managerBalance, amount, supply);
        for (uint256 i; i < sortedExtras.length; ++i) {
            uint256 payout = Math.mulDiv(extraBalances[i], amount, supply);
            if (sortedExtras[i] == address(0)) {
                _pushNativeExact(recipient, payout);
            } else {
                _pushExact(IERC20(sortedExtras[i]), recipient, payout);
            }
        }
        if (COMPANY_TOKEN.balanceOf(address(this)) < totalUnclaimedSold) {
            revert ClaimReserveUndercollateralized();
        }
        emit Ragequit(msg.sender, recipient, amount, supply);
    }

    function treasuryActionHash(FAOTreasuryActions.TreasuryAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.hash(block.chainid, address(this), action);
    }

    /// @notice Queues the exact action already settled and accepted by futarchy arbitration.
    function queueTreasuryAction(FAOTreasuryActions.TreasuryAction calldata action)
        external
        nonReentrant
        returns (bytes32 actionHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        _validateTreasuryTarget(action.target);
        actionHash = treasuryActionHash(action);
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter != 0 || queued.executed || queued.expired) {
            revert ActionAlreadyQueued();
        }
        uint256 proposalId = uint256(actionHash);
        if (!ARBITRATION.isSettled(proposalId) || !ARBITRATION.isAccepted(proposalId)) {
            revert ArbitrationNotAccepted();
        }

        uint256 executeAfter = block.timestamp + TREASURY_GRACE;
        uint256 expiresAt = executeAfter + TREASURY_EXPIRY;
        if (expiresAt > type(uint64).max) revert InvalidTreasuryAction();
        queued.executeAfter = uint64(executeAfter);
        queued.expiresAt = uint64(expiresAt);
        emit TreasuryActionQueued(actionHash, executeAfter, expiresAt);
    }

    function executeTreasuryAction(FAOTreasuryActions.TreasuryAction calldata action)
        external
        nonReentrant
        returns (bytes memory result)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        _validateTreasuryTarget(action.target);
        bytes32 actionHash = treasuryActionHash(action);
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter == 0) revert ActionNotQueued();
        if (queued.executed) revert ActionAlreadyQueued();
        if (queued.expired) revert ActionExpired();
        if (block.timestamp < queued.executeAfter) revert ActionInGracePeriod();
        if (block.timestamp > queued.expiresAt) revert ActionExpired();

        queued.executed = true;
        (bool ok, bytes memory returndata) = action.target.call{value: action.value}(action.data);
        if (!ok) revert TreasuryCallFailed(returndata);
        if (COMPANY_TOKEN.balanceOf(address(this)) < totalUnclaimedSold) {
            revert ClaimReserveUndercollateralized();
        }
        if (COMPANY_TOKEN.allowance(address(this), address(manager)) != 0) {
            revert InvalidTreasuryAction();
        }
        emit TreasuryActionExecuted(actionHash, action.target, action.value);
        return returndata;
    }

    /// @notice Irreversibly closes an accepted action whose execution window elapsed.
    function expireTreasuryAction(FAOTreasuryActions.TreasuryAction calldata action)
        external
        nonReentrant
        returns (bytes32 actionHash)
    {
        if (phase != Phase.LIVE) revert InvalidPhase();
        actionHash = treasuryActionHash(action);
        QueuedAction storage queued = queuedActions[actionHash];
        if (queued.executeAfter == 0) revert ActionNotQueued();
        if (queued.executed || queued.expired) revert ActionAlreadyQueued();
        if (block.timestamp <= queued.expiresAt) revert TooEarly();
        queued.expired = true;
        emit TreasuryActionExpired(actionHash);
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

    function _pushProRata(
        IERC20 asset,
        address recipient,
        uint256 balance,
        uint256 amount,
        uint256 supply
    ) private {
        _pushExact(asset, recipient, Math.mulDiv(balance, amount, supply));
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
