// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IFAOFutarchyOracle,
    IFAOFutarchyTwapResolver,
    IFutarchyRandomnessSource
} from "./interfaces/IFAOFutarchyOracle.sol";
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
///      pools, the company/currency token pair, and the anchor timestamp. For treasury
///      proposals, the orchestrator atomically calls setNoopPolicy(...) in the same block,
///      requiring a configured IFutarchyRandomnessSource on the resolver.
///   2. Deterministic markets (no NOOP policy) and rejected markets (`yesAvgTick - noAvgTick <=
/// margin`) resolve in a single step once `block.timestamp >= anchor + TIMEOUT`: resolve() reads
/// tick
///      cumulatives over [windowEnd - TWAP_WINDOW, windowEnd] from both pools, normalizes ticks to
///      "currency per company" orientation, records `twapPassed`, and reports payouts to CTF.
///   3. Randomized markets whose TWAP beats `margin` resolve in two steps:
///      - Step 1 (`seal`): freezes `yesAvgTick`, `noAvgTick`, and `twapPassed = true`, and requests
///        verifiable randomness from `randomnessSource`.
///      - Step 2 (`resolve`): once `randomnessSource` fulfills the request, evaluates
///        `p(NOOP)(s) = max(eps, sigma / (sigma + s - margin))` in 128-bit arithmetic and reports
///        binary `[1, 0]` or `[0, 1]` payouts to CTF (with `resolveExpiredVrf` safe-biasing to NOOP
///        if the external VRF remains unfulfilled past `VRF_TIMEOUT`).
///
/// All timing parameters are constructor immutables — testnet branch sets
/// TIMEOUT=2h, TWAP_WINDOW=1h; mainnet sets 72h/24h.
///
/// See docs/onchain-futarchy-design.md §3.3 for the base resolution flow.
contract FAOTwapResolver is IFAOFutarchyTwapResolver {
    /// @notice Total time from anchor to resolution (windowEnd = anchor + TIMEOUT).
    uint32 public immutable TIMEOUT;
    /// @notice TWAP window length, ending at windowEnd.
    uint32 public immutable TWAP_WINDOW;
    /// @notice ConditionalTokens deployment we report to.
    IConditionalTokensLike public immutable CTF;
    /// @notice Deployer permitted to pre-bind `randomnessSource` before `orchestrator` is set.
    address public immutable DEPLOYER;
    /// @notice The orchestrator address authorized to call bindProposal.
    address public orchestrator;
    /// @notice Configured verifiable randomness source required for randomized NOOP policies.
    IFutarchyRandomnessSource public randomnessSource;

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

    /// @notice Frozen TWAP verdict and VRF request state (packed into 2 storage slots).
    struct SealedDecision {
        bool committed;
        bool twapPassed;
        uint16 noopFloorBps;
        int24 noopScaleTicks;
        int24 yesAvgTick;
        int24 noAvgTick;
        uint48 sealedAt;
        bytes32 vrfRequestId;
    }

    mapping(address => SealedDecision) public sealedDecisions;

    /// @notice The checkpoint must be taken within TWAP_WINDOW / 4 of the scheduled start.
    uint256 public constant CHECKPOINT_GRACE_DIVISOR = 4;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    int24 public constant MAX_NOOP_SCALE_TICKS = 10_000;
    /// @notice Liveness escape delay if an external VRF never fulfills, freeing FLM liquidity
    ///         well before `FutarchyArbitration.MAX_EVALUATION` (21 days).
    uint256 public constant VRF_TIMEOUT = 7 days;

    error NotDeployer();
    error NotOrchestrator();
    error OrchestratorAlreadySet();
    error RandomnessAlreadySet();
    error RandomnessSourceRequired();
    error InvalidRandomnessSource();
    error InvalidRandomnessRequest();
    error AlreadyBound(address proposal);
    error NotBound(address proposal);
    error PolicyAlreadySet(address proposal);
    error PolicyWindowClosed(address proposal);
    error AlreadySealed(address proposal);
    error NotSealed(address proposal);
    error DrawNotSealed(address proposal);
    error RandomnessNotReady(address proposal);
    error VrfTimeoutNotReached(address proposal, uint256 readyAt);
    error VrfAlreadyFulfilled(address proposal);
    error AlreadyResolved(address proposal);
    error AlreadyCheckpointed(address proposal);
    error CheckpointTooLate(address proposal, uint256 latest);
    error CheckpointUnavailable(address proposal);
    error TooEarly(address proposal, uint256 windowEnd);
    error InvalidPair(address pool, address token);
    error InvalidConfig(uint32 timeout, uint32 window);
    error InvalidMargin(int24 marginTicks);
    error InvalidNoopConfig(uint16 floorBps, int24 scaleTicks);
    error InsufficientGas();

    event OrchestratorSet(address indexed orchestrator);
    event RandomnessSourceSet(address indexed randomnessSource);
    event ProposalBound(
        address indexed proposal,
        address yesPool,
        address noPool,
        uint48 anchorTimestamp,
        bytes32 questionId,
        int24 marginTicks
    );
    event ProposalNoopPolicySet(
        address indexed proposal, uint16 noopFloorBps, int24 noopScaleTicks
    );
    event WindowStartCheckpointed(address indexed proposal, uint48 timestamp);
    event ProposalSealed(
        address indexed proposal,
        int24 yesAvgTick,
        int24 noAvgTick,
        bool twapPassed,
        bytes32 vrfRequestId
    );
    event RandomDrawResolved(
        address indexed proposal, bytes32 randomWord, bool noopDrawn, bool accepted
    );
    event ExpiredVrfSafeBiased(address indexed proposal, bool twapPassed);
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
        DEPLOYER = msg.sender;
    }

    /// @notice Pre-bind an external VRF source from the deploying stack helper before
    /// `setOrchestrator` seals authority. Write-once.
    function initRandomnessSource(IFutarchyRandomnessSource newRandomnessSource) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (orchestrator != address(0) || address(randomnessSource) != address(0)) {
            revert RandomnessAlreadySet();
        }
        if (
            address(newRandomnessSource) == address(0)
                || address(newRandomnessSource).code.length == 0
        ) revert InvalidRandomnessSource();
        randomnessSource = newRandomnessSource;
        emit RandomnessSourceSet(address(newRandomnessSource));
    }

    /// @notice One-shot setter so the resolver can be deployed before the orchestrator
    /// without a circular constructor dependency.
    function setOrchestrator(address newOrchestrator) external {
        _setOrchestrator(newOrchestrator, IFutarchyRandomnessSource(address(0)));
    }

    /// @notice One-shot setter binding both the orchestrator and an external VRF source.
    function setOrchestratorWithRandomness(
        address newOrchestrator,
        IFutarchyRandomnessSource newRandomnessSource
    ) external {
        if (
            address(newRandomnessSource) == address(0)
                || address(newRandomnessSource).code.length == 0
        ) revert InvalidRandomnessSource();
        if (address(randomnessSource) != address(0)) revert RandomnessAlreadySet();
        _setOrchestrator(newOrchestrator, newRandomnessSource);
    }

    function _setOrchestrator(
        address newOrchestrator,
        IFutarchyRandomnessSource newRandomnessSource
    ) internal {
        if (orchestrator != address(0)) {
            revert OrchestratorAlreadySet();
        }
        if (newOrchestrator == address(0)) revert NotOrchestrator();
        orchestrator = newOrchestrator;
        emit OrchestratorSet(newOrchestrator);
        if (address(newRandomnessSource) != address(0)) {
            randomnessSource = newRandomnessSource;
            emit RandomnessSourceSet(address(newRandomnessSource));
        }
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

    /// @inheritdoc IFAOFutarchyTwapResolver
    function setNoopPolicy(address proposal, uint16 floorBps, int24 scaleTicks) external {
        if (msg.sender != orchestrator) revert NotOrchestrator();
        if (address(randomnessSource) == address(0)) revert RandomnessSourceRequired();
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        if (block.timestamp != b.anchorTimestamp) revert PolicyWindowClosed(proposal);
        SealedDecision storage sd = sealedDecisions[proposal];
        if (sd.committed || sd.noopFloorBps != 0 || sd.noopScaleTicks != 0) {
            revert PolicyAlreadySet(proposal);
        }
        if (
            floorBps >= BPS_DENOMINATOR || scaleTicks < 0 || scaleTicks > MAX_NOOP_SCALE_TICKS
                || (floorBps == 0 && scaleTicks == 0)
        ) {
            revert InvalidNoopConfig(floorBps, scaleTicks);
        }
        sd.noopFloorBps = floorBps;
        sd.noopScaleTicks = scaleTicks;
        emit ProposalNoopPolicySet(proposal, floorBps, scaleTicks);
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

    /// @notice Step 1 for randomized proposals: freeze the TWAP verdict and request VRF randomness.
    ///         If `!twapPassed` or no NOOP policy is set, finalizes immediately in one transaction.
    function seal(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        SealedDecision storage sd = sealedDecisions[proposal];
        if (sd.committed) revert AlreadySealed(proposal);

        (int24 yesAvgTick, int24 noAvgTick, bool twapOk) = _evaluateWindow(proposal, b);
        sd.committed = true;
        sd.twapPassed = twapOk;
        sd.yesAvgTick = yesAvgTick;
        sd.noAvgTick = noAvgTick;
        sd.sealedAt = uint48(block.timestamp);

        if (!twapOk || (sd.noopFloorBps == 0 && sd.noopScaleTicks == 0)) {
            emit ProposalSealed(proposal, yesAvgTick, noAvgTick, twapOk, bytes32(0));
            _finalize(proposal, b, twapOk, yesAvgTick, noAvgTick);
            return;
        }

        if (address(randomnessSource) == address(0)) revert RandomnessSourceRequired();
        bytes32 reqId = randomnessSource.requestRandomness(
            keccak256(abi.encode(address(this), proposal, b.questionId))
        );
        if (reqId == bytes32(0)) revert InvalidRandomnessRequest();
        sd.vrfRequestId = reqId;

        emit ProposalSealed(proposal, yesAvgTick, noAvgTick, true, reqId);
    }

    /// @inheritdoc IFAOFutarchyOracle
    /// @custom:spec INV-TWAP-002 — deterministic TWAP verdict (`twapPassed`) for all proposals;
    /// deterministic CTF resolution when unrandomized or `s_bar <= margin`, and VRF-determined
    /// binary CTF payout when a NOOP policy is bound and `s_bar > margin`.
    function resolve(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);

        SealedDecision storage sd = sealedDecisions[proposal];
        if (!sd.committed) {
            (int24 yesAvgTick, int24 noAvgTick, bool twapOk) = _evaluateWindow(proposal, b);
            if (twapOk && (sd.noopFloorBps != 0 || sd.noopScaleTicks != 0)) {
                revert DrawNotSealed(proposal);
            }
            sd.committed = true;
            sd.twapPassed = twapOk;
            sd.yesAvgTick = yesAvgTick;
            sd.noAvgTick = noAvgTick;
            sd.sealedAt = uint48(block.timestamp);
            _finalize(proposal, b, twapOk, yesAvgTick, noAvgTick);
            return;
        }

        if (address(randomnessSource) == address(0)) revert RandomnessSourceRequired();
        if (sd.vrfRequestId == bytes32(0)) revert RandomnessNotReady(proposal);
        (bool fulfilled, bytes32 vrfWord) = randomnessSource.readRandomness(sd.vrfRequestId);
        if (!fulfilled) revert RandomnessNotReady(proposal);

        bytes32 word = keccak256(abi.encode(vrfWord, address(this), proposal, b.questionId));
        uint256 excessSpread = uint256(
            int256(sd.yesAvgTick) - int256(sd.noAvgTick) - int256(decisionMarginTicks[proposal])
        );
        uint256 epsBps = sd.noopFloorBps;
        uint256 sigma = uint256(uint24(sd.noopScaleTicks));
        uint256 r = uint256(uint128(uint256(word)));
        uint256 scale128 = uint256(1) << 128;

        bool noopDrawn = (r * BPS_DENOMINATOR < epsBps * scale128)
            || (sigma > 0 && r * (sigma + excessSpread) < sigma * scale128);
        bool accepted = !noopDrawn;

        emit RandomDrawResolved(proposal, word, noopDrawn, accepted);
        _finalize(proposal, b, accepted, sd.yesAvgTick, sd.noAvgTick);
    }

    /// @notice Liveness escape if the configured VRF oracle fails to fulfill (or reverts on
    /// `requestRandomness`) for `VRF_TIMEOUT` past the window/seal: safe-biases execution and CTF
    /// payouts to NOOP (`[0, 1]`) while preserving the deterministic `twapPassed` bond verdict so
    /// neither FLM conditional liquidity nor the arbitration queue can stay wedged.
    function resolveExpiredVrf(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        SealedDecision storage sd = sealedDecisions[proposal];
        if (sd.noopFloorBps == 0 && sd.noopScaleTicks == 0) revert NotSealed(proposal);

        if (sd.committed) {
            uint256 readyAt = uint256(sd.sealedAt) + VRF_TIMEOUT;
            if (block.timestamp < readyAt) revert VrfTimeoutNotReached(proposal, readyAt);
            uint256 gasBefore = gasleft();
            try randomnessSource.readRandomness(sd.vrfRequestId) returns (bool fulfilled, bytes32) {
                if (fulfilled) revert VrfAlreadyFulfilled(proposal);
            } catch {
                if (gasleft() < gasBefore / 64) revert InsufficientGas();
            }
            emit ExpiredVrfSafeBiased(proposal, sd.twapPassed);
            _finalize(proposal, b, false, sd.yesAvgTick, sd.noAvgTick);
            return;
        }

        (int24 yesAvgTick, int24 noAvgTick, bool twapOk) = _evaluateWindow(proposal, b);
        uint256 windowEnd = uint256(b.anchorTimestamp) + TIMEOUT;
        uint256 checkpointEnd = windowStart[proposal].timestamp == 0
            ? windowEnd
            : uint256(windowStart[proposal].timestamp) + TWAP_WINDOW;
        uint256 baseEnd = checkpointEnd > windowEnd ? checkpointEnd : windowEnd;
        uint256 unsealedReadyAt = baseEnd + VRF_TIMEOUT;
        if (block.timestamp < unsealedReadyAt) {
            revert VrfTimeoutNotReached(proposal, unsealedReadyAt);
        }

        sd.committed = true;
        sd.twapPassed = twapOk;
        sd.yesAvgTick = yesAvgTick;
        sd.noAvgTick = noAvgTick;
        sd.sealedAt = uint48(block.timestamp);
        emit ExpiredVrfSafeBiased(proposal, twapOk);
        _finalize(proposal, b, false, yesAvgTick, noAvgTick);
    }

    // ─── views
    // ─────────────────────────────────────────────────────────────

    function isRandomized(address proposal) public view returns (bool) {
        SealedDecision storage sd = sealedDecisions[proposal];
        return sd.noopFloorBps != 0 || sd.noopScaleTicks != 0;
    }

    function twapPassed(address proposal) external view returns (bool) {
        if (bindings[proposal].anchorTimestamp == 0) revert NotBound(proposal);
        SealedDecision storage sd = sealedDecisions[proposal];
        if (!sd.committed) revert NotSealed(proposal);
        return sd.twapPassed;
    }

    function windowEndOf(address proposal) external view returns (uint256) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) return 0;
        return uint256(b.anchorTimestamp) + TIMEOUT;
    }

    function isReadyToResolve(address proposal) external view returns (bool) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0 || b.resolved) return false;
        SealedDecision storage sd = sealedDecisions[proposal];
        if (sd.committed) {
            if (address(randomnessSource) == address(0) || sd.vrfRequestId == bytes32(0)) {
                return false;
            }
            try randomnessSource.readRandomness(sd.vrfRequestId) returns (bool fulfilled, bytes32) {
                return fulfilled;
            } catch {
                return false;
            }
        }
        if (block.timestamp < uint256(b.anchorTimestamp) + TIMEOUT) return false;
        uint256 checkpointed = windowStart[proposal].timestamp;
        return checkpointed == 0 || block.timestamp >= checkpointed + TWAP_WINDOW;
    }

    // ─── internals
    // ─────────────────────────────────────────────────────────

    function _evaluateWindow(address proposal, Binding storage b)
        internal
        view
        returns (int24 yesAvgTick, int24 noAvgTick, bool twapOk)
    {
        uint256 windowEnd = uint256(b.anchorTimestamp) + TIMEOUT;
        if (block.timestamp < windowEnd) revert TooEarly(proposal, windowEnd);

        (address yesCo, address noCo) = _companyWrappers(proposal);
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
        twapOk = !yesFailed && !noFailed
            && int256(yesAvgTick) - int256(noAvgTick) > int256(decisionMarginTicks[proposal]);
    }

    function _finalize(
        address proposal,
        Binding storage b,
        bool accepted,
        int24 yesAvgTick,
        int24 noAvgTick
    ) internal {
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
