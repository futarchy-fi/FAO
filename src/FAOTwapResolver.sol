// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFAOFutarchyOracle, IFAOFutarchyTwapResolver} from "./interfaces/IFAOFutarchyOracle.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {FAOFutarchyProposal} from "./FAOFutarchyProposal.sol";

/// @title FAOTwapResolver
/// @notice Reads UniV3 TWAP of YES vs NO conditional pools and reports the futarchy
/// decision to the Conditional Tokens Framework as the oracle for the condition.
///
/// Replaces FutarchyRealityProxy (Reality.eth) as the CTF reporter.
///
/// Lifecycle:
///   1. Orchestrator calls bindProposal(...) at promote time, registering the two
///      pools, the company/currency token pair, and the anchor timestamp.
///   2. Anyone calls resolve(proposal) once block.timestamp >= anchor + TIMEOUT.
///   3. resolve() reads tick cumulatives over [windowEnd - TWAP_WINDOW, windowEnd]
///      from both pools, normalizes ticks to "currency per company" orientation,
///      decides accepted = (yesAvgTick - noAvgTick > margin), and reports payouts to CTF.
///
/// All timing parameters are constructor immutables — testnet branch sets
/// TIMEOUT=2h, TWAP_WINDOW=1h; mainnet sets 72h/24h.
///
/// See docs/onchain-futarchy-design.md §3.3 for the full resolution flow.
contract FAOTwapResolver is IFAOFutarchyTwapResolver {
    /// @notice Total time from anchor to resolution (windowEnd = anchor + TIMEOUT).
    uint32 public immutable TIMEOUT;
    /// @notice TWAP window length, ending at windowEnd.
    uint32 public immutable TWAP_WINDOW;
    /// @notice ConditionalTokens deployment we report to.
    IConditionalTokensLike public immutable CTF;
    /// @notice The orchestrator address authorized to call bindProposal.
    address public orchestrator;

    /// @notice Per-proposal binding written by the orchestrator at promote time.
    struct Binding {
        address yesPool;
        address noPool;
        address companyToken;
        address currencyToken;
        bytes32 questionId; // captured at bind time so CTF can be reported later
        uint48 anchorTimestamp;
        bool resolved;
        bool accepted;
    }

    mapping(address => Binding) public bindings;

    /// @notice How far the YES average tick must exceed the NO average tick for a proposal to
    /// pass. One tick is 0.01% in price. Set once at bind time by the orchestrator; 0 means YES
    /// only has to be above NO.
    mapping(address => int24) public decisionMarginTicks;

    /// @notice Largest margin the orchestrator may set: about 10.5% in price.
    int24 public constant MAX_DECISION_MARGIN_TICKS = 1000;

    /// @notice Running tick totals of both pools, recorded once at or after the start of the
    /// averaging window. With a checkpoint the decision reads only the pools' current totals, so
    /// it does not depend on how much history the pools still hold.
    struct Checkpoint {
        int56 yesCumulative;
        int56 noCumulative;
        uint48 timestamp;
    }

    mapping(address => Checkpoint) public windowStart;

    /// @notice The checkpoint must be taken within TWAP_WINDOW / 4 of the scheduled start.
    uint256 public constant CHECKPOINT_GRACE_DIVISOR = 4;

    error NotOrchestrator();
    error OrchestratorAlreadySet();
    error AlreadyBound(address proposal);
    error NotBound(address proposal);
    error AlreadyResolved(address proposal);
    error AlreadyCheckpointed(address proposal);
    error CheckpointTooLate(address proposal, uint256 latest);
    error CheckpointUnavailable(address proposal);
    error TooEarly(address proposal, uint256 windowEnd);
    error InvalidPair(address pool, address token);
    error InvalidConfig(uint32 timeout, uint32 window);
    error InvalidMargin(int24 marginTicks);
    error InsufficientGas();

    event OrchestratorSet(address indexed orchestrator);
    event ProposalBound(
        address indexed proposal,
        address yesPool,
        address noPool,
        uint48 anchorTimestamp,
        bytes32 questionId,
        int24 marginTicks
    );
    event WindowStartCheckpointed(address indexed proposal, uint48 timestamp);
    event ProposalResolved(
        address indexed proposal,
        bool accepted,
        int24 yesAvgTick,
        int24 noAvgTick,
        bytes32 questionId
    );

    constructor(uint32 timeout, uint32 window, IConditionalTokensLike ctf) {
        if (window == 0 || window > timeout) revert InvalidConfig(timeout, window);
        TIMEOUT = timeout;
        TWAP_WINDOW = window;
        CTF = ctf;
    }

    /// @notice One-shot wiring: set the orchestrator that can call bindProposal.
    function setOrchestrator(address newOrchestrator) external {
        if (orchestrator != address(0)) revert OrchestratorAlreadySet();
        orchestrator = newOrchestrator;
        emit OrchestratorSet(newOrchestrator);
    }

    /// @inheritdoc IFAOFutarchyTwapResolver
    /// @custom:spec INV-TWAP-001 — anchor set exactly once; window fixity. See
    /// audit/specs/INVARIANTS.md.
    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp,
        int24 marginTicks
    ) external {
        if (msg.sender != orchestrator) revert NotOrchestrator();
        if (bindings[proposal].anchorTimestamp != 0) revert AlreadyBound(proposal);
        if (marginTicks < 0 || marginTicks > MAX_DECISION_MARGIN_TICKS) {
            revert InvalidMargin(marginTicks);
        }

        bytes32 qId = FAOFutarchyProposal(proposal).questionId();
        bindings[proposal] = Binding({
            yesPool: yesPool,
            noPool: noPool,
            companyToken: companyToken,
            currencyToken: currencyToken,
            questionId: qId,
            anchorTimestamp: anchorTimestamp,
            resolved: false,
            accepted: false
        });

        if (marginTicks != 0) decisionMarginTicks[proposal] = marginTicks;

        emit ProposalBound(proposal, yesPool, noPool, anchorTimestamp, qId, marginTicks);
    }

    /// @notice Record both pools' running tick totals as the start of the averaging window.
    /// @dev Anyone may call once, at or after `anchor + TIMEOUT - TWAP_WINDOW`. Whoever has a
    ///      bond on the proposal has the incentive to. If it is called late the window simply
    ///      starts late: `resolve` then waits until a full TWAP_WINDOW has passed since it.
    function checkpointWindowStart(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        if (windowStart[proposal].timestamp != 0) revert AlreadyCheckpointed(proposal);

        uint256 earliest = uint256(b.anchorTimestamp) + TIMEOUT - TWAP_WINDOW;
        if (block.timestamp < earliest) revert TooEarly(proposal, earliest);
        // A late checkpoint would let its caller choose the window. Past the grace period the
        // decision falls back to the pools' stored history.
        uint256 latest = earliest + TWAP_WINDOW / CHECKPOINT_GRACE_DIVISOR;
        if (block.timestamp > latest) revert CheckpointTooLate(proposal, latest);

        (int56 yesCumulative, bool yesFailed) = _cumulativeNow(b.yesPool);
        (int56 noCumulative, bool noFailed) = _cumulativeNow(b.noPool);
        if (yesFailed || noFailed) revert CheckpointUnavailable(proposal);

        windowStart[proposal] = Checkpoint(yesCumulative, noCumulative, uint48(block.timestamp));
        emit WindowStartCheckpointed(proposal, uint48(block.timestamp));
    }

    /// @inheritdoc IFAOFutarchyOracle
    /// @custom:spec INV-TWAP-002 — resolution determinism. See audit/specs/INVARIANTS.md.
    function resolve(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);

        uint256 windowEnd = uint256(b.anchorTimestamp) + TIMEOUT;
        if (block.timestamp < windowEnd) revert TooEarly(proposal, windowEnd);

        (address yesCo, address noCo) = _companyWrappers(proposal);
        int24 yesAvgTick;
        int24 noAvgTick;
        bool yesFailed;
        bool noFailed;
        Checkpoint memory start = windowStart[proposal];
        if (start.timestamp != 0) {
            // Checkpointed window: [checkpoint, now], at least TWAP_WINDOW long.
            uint256 earliest = uint256(start.timestamp) + TWAP_WINDOW;
            if (block.timestamp < earliest) revert TooEarly(proposal, earliest);
            uint256 elapsed = block.timestamp - start.timestamp;
            (yesAvgTick, yesFailed) = _meanTickSince(b.yesPool, yesCo, start.yesCumulative, elapsed);
            if (!yesFailed) {
                (noAvgTick, noFailed) = _meanTickSince(b.noPool, noCo, start.noCumulative, elapsed);
            }
        } else {
            // No checkpoint was taken: read the window from the pools' stored history. This
            // fails, and resolves NO, if the pools no longer hold that history.
            (yesAvgTick, yesFailed) = _arithmeticMeanTick(b.yesPool, yesCo, windowEnd);
            if (!yesFailed) {
                (noAvgTick, noFailed) = _arithmeticMeanTick(b.noPool, noCo, windowEnd);
            }
        }

        // A genuinely unreadable market cannot be allowed to wedge the arbitration queue.
        // Safe-bias it to NO; low-gas grief attempts revert inside _arithmeticMeanTick instead.
        // YES must beat NO by more than the proposal's margin; a tie or a near-tie keeps the
        // status quo.
        bool accepted = !yesFailed && !noFailed
            && int256(yesAvgTick) - int256(noAvgTick) > int256(decisionMarginTicks[proposal]);

        b.resolved = true;
        b.accepted = accepted;

        uint256[] memory payouts = new uint256[](2);
        if (accepted) {
            payouts[0] = 1;
        } else {
            payouts[1] = 1;
        }
        CTF.reportPayouts(b.questionId, payouts);

        emit ProposalResolved(proposal, accepted, yesAvgTick, noAvgTick, b.questionId);
    }

    // ─── views
    // ─────────────────────────────────────────────────────────────

    function windowEndOf(address proposal) external view returns (uint256) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) return 0;
        return uint256(b.anchorTimestamp) + TIMEOUT;
    }

    function isReadyToResolve(address proposal) external view returns (bool) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0 || b.resolved) return false;
        if (block.timestamp < uint256(b.anchorTimestamp) + TIMEOUT) return false;
        uint256 checkpointed = windowStart[proposal].timestamp;
        return checkpointed == 0 || block.timestamp >= checkpointed + TWAP_WINDOW;
    }

    // ─── internals
    // ─────────────────────────────────────────────────────────

    /// @dev Reads tick cumulatives over [windowEnd - TWAP_WINDOW, windowEnd] from `pool`
    /// and returns the arithmetic mean tick, normalized so that "currency per company"
    /// (i.e. company more expensive in currency) maps to a HIGHER tick.
    ///
    /// The `companyWrapper` is the wrapper address of the side-of-proposal that wraps
    /// the company token (FAO). It is identified by reading the FAOFutarchyProposal:
    /// outcomes 0 / 1 are YES_company / NO_company wrappers; outcomes 2 / 3 are
    /// YES_currency / NO_currency wrappers. We pass the company wrapper for the
    /// branch (YES or NO) of the pool being measured.
    function _arithmeticMeanTick(address pool, address companyWrapper, uint256 windowEnd)
        internal
        view
        returns (int24 avgTick, bool failed)
    {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        uint256 nowTs = block.timestamp;
        uint256 endAgo = nowTs - windowEnd;
        uint256 startAgo = endAgo + TWAP_WINDOW;

        uint32[] memory secondsAgos = new uint32[](2);
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[0] = uint32(startAgo);
        // forge-lint: disable-next-line(unsafe-typecast)
        secondsAgos[1] = uint32(endAgo);

        uint256 gasBefore = gasleft();
        int56[] memory cums;
        try p.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            cums = tickCumulatives;
        } catch {
            // EIP-150 leaves the caller about 1/64th when the callee exhausts its gas. Do not let
            // a deliberately underfunded call turn an otherwise healthy market into a NO result.
            if (gasleft() < gasBefore / 64) revert InsufficientGas();
            return (0, true);
        }
        if (cums.length != 2) return (0, true);

        // Normalize: pool tick = log(token1/token0). We want log(currency/company)
        // — i.e. company-as-token0 orientation. If token0 is the company wrapper,
        // tick is already in that orientation; else negate.
        return _orientedMean(cums[1] - cums[0], TWAP_WINDOW, p.token0() == companyWrapper);
    }

    /// @dev Mean tick over `elapsed` seconds, oriented so a dearer company token is a higher
    /// tick and rounded down in that orientation. Shared by both resolve paths.
    function _orientedMean(int56 delta, uint256 elapsed, bool companyIsToken0)
        internal
        pure
        returns (int24 avgTick, bool failed)
    {
        if (!companyIsToken0) delta = -delta;
        // forge-lint: disable-next-line(unsafe-typecast)
        int56 divisor = int56(uint56(elapsed));
        int56 mean = delta / divisor;
        if (delta < 0 && delta % divisor != 0) mean--;
        if (mean < type(int24).min || mean > type(int24).max) return (0, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        avgTick = int24(mean);
    }

    /// @dev The pool's running tick total at this block. Reading "now" never depends on how
    /// many observations the pool keeps.
    function _cumulativeNow(address pool) internal view returns (int56 cumulative, bool failed) {
        uint32[] memory secondsAgos = new uint32[](1);
        uint256 gasBefore = gasleft();
        try IUniswapV3PoolLike(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            if (tickCumulatives.length != 1) return (0, true);
            return (tickCumulatives[0], false);
        } catch {
            if (gasleft() < gasBefore / 64) revert InsufficientGas();
            return (0, true);
        }
    }

    /// @dev Mean tick of `pool` since a checkpoint, oriented so a dearer company token is a
    /// higher tick, and rounded down in that orientation for both pools alike.
    function _meanTickSince(
        address pool,
        address companyWrapper,
        int56 startCumulative,
        uint256 elapsed
    ) internal view returns (int24 avgTick, bool failed) {
        (int56 nowCumulative, bool readFailed) = _cumulativeNow(pool);
        if (readFailed) return (0, true);
        int56 delta = nowCumulative - startCumulative;
        return _orientedMean(delta, elapsed, IUniswapV3PoolLike(pool).token0() == companyWrapper);
    }

    /// @dev Returns the (yesCompanyWrap, noCompanyWrap) for a proposal. Outcome indexing
    /// matches FAOFutarchyFactory: 0 = YES_co, 1 = NO_co, 2 = YES_cur, 3 = NO_cur.
    function _companyWrappers(address proposal)
        internal
        view
        returns (address yesCo, address noCo)
    {
        FAOFutarchyProposal p = FAOFutarchyProposal(proposal);
        (yesCo,) = p.wrappedOutcome(0);
        (noCo,) = p.wrappedOutcome(1);
    }
}
