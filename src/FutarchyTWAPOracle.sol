// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Algebra pool interface for TWAP queries.
interface IAlgebraPoolTWAP {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulatives,
            uint112[] memory volatilityCumulatives,
            uint256[] memory volumePerAvgLiquiditys
        );
}

/// @title FutarchyTWAPOracle
/// @notice Compares YES vs NO pool TWAP prices to determine the futarchy signal.
///
/// When a proposal enters evaluation, the EvaluationPipeline calls `bind()` to register
/// the YES/NO Algebra pools. After the trading period ends, anyone calls `resolve()` which:
///   1. Reads tick cumulatives from both pools via getTimepoints()
///   2. Computes arithmetic mean tick over the TWAP window
///   3. Normalizes ticks to "collateral per company token" orientation
///   4. Compares: if yesTick > noTick + threshold → YES (accepted), else NO (rejected)
///
/// Key design decisions:
///   - Tick-based comparison avoids overflow/sqrt math (standard on-chain TWAP pattern).
///   - Fixed measurement window [deadline - twapWindow, deadline] for determinism.
///   - Token ordering normalization: negate tick if company token is token1.
///   - Direct oracle (not CTF-mediated) for simplicity.
contract FutarchyTWAPOracle {
    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

    struct ProposalTWAP {
        address yesPool; // YES_TOKEN / YES_COLLATERAL Algebra pool
        address noPool; // NO_TOKEN / NO_COLLATERAL Algebra pool
        address yesBase; // YES company token (for tick sign normalization)
        address noBase; // NO company token
        uint48 startTime; // when trading started (set during bind)
        bool resolved;
        bool accepted;
    }

    // ═══════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════

    error NotDAO();
    error NotBinder();
    error AlreadyBound(address proposal);
    error NotBound(address proposal);
    error TradingNotEnded(address proposal, uint256 deadline, uint256 currentTime);
    error AlreadyResolved(address proposal);
    error InvalidConfig(uint32 tradingPeriod, uint32 twapWindow);
    error ZeroAddress();
    error InsufficientGas();

    // ═══════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════

    event ProposalBound(
        address indexed proposal, address yesPool, address noPool, uint48 startTime
    );
    event ProposalResolved(
        address indexed proposal, bool accepted, int56 yesAvgTick, int56 noAvgTick
    );
    event ConfigUpdated(uint32 tradingPeriod, uint32 twapWindow, int24 thresholdTicks);

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    /// @notice DAO address that controls configuration.
    address public dao;

    /// @notice Seconds from market creation to resolution deadline.
    uint32 public tradingPeriod;

    /// @notice Trailing TWAP measurement window in seconds (≤ tradingPeriod).
    uint32 public twapWindow;

    /// @notice YES avg tick must exceed NO avg tick by this amount to pass.
    int24 public thresholdTicks;

    /// @notice Address authorized to bind proposals (the EvaluationPipeline).
    address public binder;

    /// @notice Per-proposal TWAP binding and result storage.
    mapping(address proposal => ProposalTWAP) public proposals;

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor(
        address _dao,
        address _binder,
        uint32 _tradingPeriod,
        uint32 _twapWindow,
        int24 _thresholdTicks
    ) {
        if (_dao == address(0)) revert ZeroAddress();
        if (_binder == address(0)) revert ZeroAddress();
        if (_twapWindow > _tradingPeriod) {
            revert InvalidConfig(_tradingPeriod, _twapWindow);
        }
        dao = _dao;
        binder = _binder;
        tradingPeriod = _tradingPeriod;
        twapWindow = _twapWindow;
        thresholdTicks = _thresholdTicks;
        emit ConfigUpdated(_tradingPeriod, _twapWindow, _thresholdTicks);
    }

    // ═══════════════════════════════════════════════════════
    //  Modifiers
    // ═══════════════════════════════════════════════════════

    modifier onlyDAO() {
        if (msg.sender != dao) revert NotDAO();
        _;
    }

    modifier onlyBinder() {
        if (msg.sender != binder) revert NotBinder();
        _;
    }

    // ═══════════════════════════════════════════════════════
    //  Binding
    // ═══════════════════════════════════════════════════════

    /// @notice Register YES/NO pools for a proposal. Called by the
    /// EvaluationPipeline during market creation. Sets startTime to now.
    function bind(
        address proposal,
        address yesPool,
        address noPool,
        address yesBase,
        address noBase
    ) external onlyBinder {
        if (proposal == address(0)) revert ZeroAddress();
        if (yesPool == address(0)) revert ZeroAddress();
        if (noPool == address(0)) revert ZeroAddress();
        if (proposals[proposal].yesPool != address(0)) {
            revert AlreadyBound(proposal);
        }

        proposals[proposal] = ProposalTWAP({
            yesPool: yesPool,
            noPool: noPool,
            yesBase: yesBase,
            noBase: noBase,
            startTime: uint48(block.timestamp),
            resolved: false,
            accepted: false
        });

        emit ProposalBound(proposal, yesPool, noPool, uint48(block.timestamp));
    }

    // ═══════════════════════════════════════════════════════
    //  Resolution
    // ═══════════════════════════════════════════════════════

    /// @notice Resolve a proposal's TWAP comparison. Permissionless — anyone
    /// can call once the trading period has elapsed.
    /// @return accepted True if YES avg tick > NO avg tick + threshold.
    function resolve(address proposal) external returns (bool accepted) {
        ProposalTWAP storage p = proposals[proposal];
        if (p.yesPool == address(0)) revert NotBound(proposal);
        if (p.resolved) revert AlreadyResolved(proposal);

        uint256 deadline = uint256(p.startTime) + tradingPeriod;
        if (block.timestamp < deadline) {
            revert TradingNotEnded(proposal, deadline, block.timestamp);
        }

        (int56 yesAvgTick, bool yesFailed) = _computeTWAP(p.yesPool, p.yesBase, deadline);
        (int56 noAvgTick, bool noFailed) = _computeTWAP(p.noPool, p.noBase, deadline);

        // If either pool is broken, default to rejection.
        if (yesFailed || noFailed) {
            accepted = false;
        } else {
            accepted = yesAvgTick > noAvgTick + int56(int24(thresholdTicks));
        }

        p.resolved = true;
        p.accepted = accepted;

        emit ProposalResolved(proposal, accepted, yesAvgTick, noAvgTick);
    }

    /// @notice Read the resolution result for a proposal.
    /// @return resolved True if resolve() has been called.
    /// @return accepted True if the proposal was accepted (YES won).
    function getDecision(address proposal) external view returns (bool resolved, bool accepted) {
        ProposalTWAP storage p = proposals[proposal];
        return (p.resolved, p.accepted);
    }

    // ═══════════════════════════════════════════════════════
    //  DAO Configuration
    // ═══════════════════════════════════════════════════════

    /// @notice Update oracle parameters. DAO-only.
    function setConfig(uint32 _tradingPeriod, uint32 _twapWindow, int24 _thresholdTicks)
        external
        onlyDAO
    {
        if (_twapWindow > _tradingPeriod) {
            revert InvalidConfig(_tradingPeriod, _twapWindow);
        }
        tradingPeriod = _tradingPeriod;
        twapWindow = _twapWindow;
        thresholdTicks = _thresholdTicks;
        emit ConfigUpdated(_tradingPeriod, _twapWindow, _thresholdTicks);
    }

    // ═══════════════════════════════════════════════════════
    //  Internal: TWAP Computation
    // ═══════════════════════════════════════════════════════

    /// @dev Computes the arithmetic mean tick over the TWAP window for a pool,
    /// normalized to "collateral per company token" orientation.
    ///
    /// The measurement window is always [deadline - twapWindow, deadline],
    /// ensuring deterministic results regardless of when resolve() is called.
    ///
    /// Gas griefing protection: if the pool call reverts with insufficient gas
    /// remaining (EIP-150), we revert rather than settling as NO, to prevent
    /// attackers from forcing rejection by sending low-gas transactions.
    function _computeTWAP(address pool, address baseToken, uint256 deadline)
        internal
        view
        returns (int56 economicAvgTick, bool failed)
    {
        uint32 window = twapWindow;
        uint32[] memory secondsAgos = new uint32[](2);
        // Older point: deadline - twapWindow
        secondsAgos[0] = uint32(block.timestamp - (deadline - window));
        // Newer point: deadline
        secondsAgos[1] = uint32(block.timestamp - deadline);

        uint256 gasBefore = gasleft();
        try IAlgebraPoolTWAP(pool).getTimepoints(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory, uint112[] memory, uint256[] memory
        ) {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];

            // Normalize for token ordering:
            // If baseToken (company) is token0, tick already represents
            // currency/company. If token1, negate to get the same
            // orientation.
            int56 sign = IAlgebraPoolTWAP(pool).token0() == baseToken ? int56(1) : int56(-1);
            economicAvgTick = (sign * tickDelta) / int56(int32(window));
        } catch {
            // EIP-150: caller retains ≥ 1/64th of gas on CALL.
            // If remaining gas < gasBefore/64, the call likely ran out
            // of gas (attacker sent low gas), not a real pool revert.
            if (gasleft() < gasBefore / 64) revert InsufficientGas();
            // Pool is genuinely broken — flag as failed.
            failed = true;
        }
    }
}
