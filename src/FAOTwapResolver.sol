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
/// @notice Reads UniV3 TWAP of YES vs NO conditional pools, freezes `s_bar > margin`, and resolves
///         execution + CTF payouts either deterministically or via a two-step verifiable random
///         draw under `p(NOOP)(s) = max(eps, sigma / (sigma + s - margin))` for `s > margin`.
contract FAOTwapResolver is IFAOFutarchyTwapResolver {
    uint32 public immutable TIMEOUT;
    uint32 public immutable TWAP_WINDOW;
    IConditionalTokensLike public immutable CTF;
    address public orchestrator;
    IFutarchyRandomnessSource public randomnessSource;

    struct Binding {
        address yesPool;
        address noPool;
        address companyToken;
        address currencyToken;
        bytes32 questionId;
        uint48 anchorTimestamp;
        bool resolved;
        bool accepted;
    }

    mapping(address => Binding) public bindings;
    mapping(address => int24) public decisionMarginTicks;

    struct Checkpoint {
        int56 yesCumulative;
        int56 noCumulative;
        uint48 timestamp;
    }

    mapping(address => Checkpoint) public windowStart;

    /// @dev Packed into 2 storage slots (21 bytes + bytes32).
    struct SealedDecision {
        bool committed;
        bool twapPassed;
        uint16 noopFloorBps;
        int24 noopScaleTicks;
        int24 yesAvgTick;
        int24 noAvgTick;
        uint64 drawBlock;
        bytes32 vrfRequestId;
    }

    mapping(address => SealedDecision) public sealedDecisions;

    int24 public constant MAX_DECISION_MARGIN_TICKS = 1000;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    int24 public constant MAX_NOOP_SCALE_TICKS = 10_000;
    uint64 public constant DRAW_DELAY_BLOCKS = 2;
    uint256 public constant CHECKPOINT_GRACE_DIVISOR = 4;

    address internal constant HISTORY_STORAGE_ADDRESS = 0x0000F90827F1C53a10cb7A02335B175320002935;
    uint256 internal constant HISTORY_SERVE_WINDOW = 8191;
    uint256 internal constant BLOCKHASH_SERVE_WINDOW = 256;

    error NotOrchestrator();
    error OrchestratorAlreadySet();
    error AlreadyBound(address proposal);
    error NotBound(address proposal);
    error AlreadySealed(address proposal);
    error AlreadyResolved(address proposal);
    error NotSealed(address proposal);
    error DrawNotSealed(address proposal);
    error RandomnessNotReady(address proposal);
    error DrawExpired(address proposal, uint64 drawBlock);
    error DrawNotExpired(address proposal, uint64 drawBlock);
    error InvalidRandomnessSource();
    error InvalidRandomnessRequest();
    error PolicyAlreadySet(address proposal);
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
        uint64 drawBlock,
        bytes32 vrfRequestId
    );
    event DrawRearmed(address indexed proposal, uint64 newDrawBlock);
    event RandomDrawResolved(
        address indexed proposal, bytes32 randomWord, bool noopDrawn, bool accepted
    );
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

    function setOrchestrator(address newOrchestrator) external {
        _setOrchestrator(newOrchestrator, IFutarchyRandomnessSource(address(0)));
    }

    function setOrchestratorWithRandomness(
        address newOrchestrator,
        IFutarchyRandomnessSource newRandomnessSource
    ) external {
        if (
            address(newRandomnessSource) != address(0)
                && address(newRandomnessSource).code.length == 0
        ) revert InvalidRandomnessSource();
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
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
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

    function checkpointWindowStart(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        if (windowStart[proposal].timestamp != 0) revert AlreadyCheckpointed(proposal);

        uint256 earliest = uint256(b.anchorTimestamp) + TIMEOUT - TWAP_WINDOW;
        if (block.timestamp < earliest) revert TooEarly(proposal, earliest);
        uint256 latest = earliest + TWAP_WINDOW / CHECKPOINT_GRACE_DIVISOR;
        if (block.timestamp > latest) revert CheckpointTooLate(proposal, latest);

        (int56 yesCumulative, bool yesFailed) = _cumulativeNow(b.yesPool);
        (int56 noCumulative, bool noFailed) = _cumulativeNow(b.noPool);
        if (yesFailed || noFailed) revert CheckpointUnavailable(proposal);

        windowStart[proposal] = Checkpoint(yesCumulative, noCumulative, uint48(block.timestamp));
        emit WindowStartCheckpointed(proposal, uint48(block.timestamp));
    }

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

        if (!twapOk || (sd.noopFloorBps == 0 && sd.noopScaleTicks == 0)) {
            emit ProposalSealed(proposal, yesAvgTick, noAvgTick, twapOk, 0, bytes32(0));
            _finalize(proposal, b, twapOk, yesAvgTick, noAvgTick);
            return;
        }

        uint64 targetBlock;
        bytes32 reqId;
        if (address(randomnessSource) != address(0)) {
            reqId = randomnessSource.requestRandomness(
                keccak256(abi.encode(address(this), proposal, b.questionId))
            );
            if (reqId == bytes32(0)) revert InvalidRandomnessRequest();
            sd.vrfRequestId = reqId;
        } else {
            targetBlock = uint64(block.number) + DRAW_DELAY_BLOCKS;
            sd.drawBlock = targetBlock;
        }

        emit ProposalSealed(proposal, yesAvgTick, noAvgTick, true, targetBlock, reqId);
    }

    /// @inheritdoc IFAOFutarchyOracle
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
            _finalize(proposal, b, twapOk, yesAvgTick, noAvgTick);
            return;
        }

        bytes32 word;
        if (address(randomnessSource) != address(0)) {
            (bool fulfilled, bytes32 vrfWord) = randomnessSource.readRandomness(sd.vrfRequestId);
            if (!fulfilled) revert RandomnessNotReady(proposal);
            word = keccak256(abi.encode(vrfWord, address(this), proposal, b.questionId));
        } else {
            if (block.number <= sd.drawBlock) revert RandomnessNotReady(proposal);
            bytes32 bh = _historicalBlockHash(sd.drawBlock);
            if (bh == bytes32(0)) revert DrawExpired(proposal, sd.drawBlock);
            word = keccak256(abi.encode(bh, address(this), proposal, b.questionId));
        }

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

    function rearmExpiredDraw(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);
        if (address(randomnessSource) != address(0)) revert InvalidRandomnessSource();

        SealedDecision storage sd = sealedDecisions[proposal];
        if (!sd.committed) revert NotSealed(proposal);

        uint256 serveWindow = HISTORY_STORAGE_ADDRESS.code.length != 0
            ? HISTORY_SERVE_WINDOW
            : BLOCKHASH_SERVE_WINDOW;
        if (
            block.number <= uint256(sd.drawBlock) + serveWindow
                || _historicalBlockHash(sd.drawBlock) != bytes32(0)
        ) {
            revert DrawNotExpired(proposal, sd.drawBlock);
        }

        uint64 newTarget = uint64(block.number) + DRAW_DELAY_BLOCKS;
        sd.drawBlock = newTarget;
        emit DrawRearmed(proposal, newTarget);
    }

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
            if (address(randomnessSource) != address(0)) {
                (bool fulfilled,) = randomnessSource.readRandomness(sd.vrfRequestId);
                return fulfilled;
            }
            return block.number > sd.drawBlock && _historicalBlockHash(sd.drawBlock) != bytes32(0);
        }
        if (block.timestamp < uint256(b.anchorTimestamp) + TIMEOUT) return false;
        uint256 checkpointed = windowStart[proposal].timestamp;
        return checkpointed == 0 || block.timestamp >= checkpointed + TWAP_WINDOW;
    }

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
            uint256 earliest = uint256(start.timestamp) + TWAP_WINDOW;
            if (block.timestamp < earliest) revert TooEarly(proposal, earliest);
            uint256 elapsed = block.timestamp - start.timestamp;
            (yesAvgTick, yesFailed) = _meanTickSince(b.yesPool, yesCo, start.yesCumulative, elapsed);
            if (!yesFailed) {
                (noAvgTick, noFailed) = _meanTickSince(b.noPool, noCo, start.noCumulative, elapsed);
            }
        } else {
            (yesAvgTick, yesFailed) = _arithmeticMeanTick(b.yesPool, yesCo, windowEnd);
            if (!yesFailed) {
                (noAvgTick, noFailed) = _arithmeticMeanTick(b.noPool, noCo, windowEnd);
            }
        }

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

    function _historicalBlockHash(uint64 targetBlock) internal view returns (bytes32 bh) {
        bh = blockhash(targetBlock);
        if (bh != bytes32(0)) return bh;
        if (HISTORY_STORAGE_ADDRESS.code.length == 0) return bytes32(0);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory ret) =
            HISTORY_STORAGE_ADDRESS.staticcall(abi.encode(uint256(targetBlock)));
        if (!ok && gasleft() < gasBefore / 64) revert InsufficientGas();
        if (ok && ret.length == 32) {
            bh = abi.decode(ret, (bytes32));
        }
    }

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
            if (gasleft() < gasBefore / 64) revert InsufficientGas();
            return (0, true);
        }
        if (cums.length != 2) return (0, true);

        return _orientedMean(cums[1] - cums[0], TWAP_WINDOW, p.token0() == companyWrapper);
    }

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
