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
///      decides accepted = (yesAvgTick > noAvgTick), and reports payouts to CTF.
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

    error NotOrchestrator();
    error OrchestratorAlreadySet();
    error AlreadyBound(address proposal);
    error NotBound(address proposal);
    error AlreadyResolved(address proposal);
    error TooEarly(address proposal, uint256 windowEnd);
    error InvalidPair(address pool, address token);
    error InvalidConfig(uint32 timeout, uint32 window);

    event OrchestratorSet(address indexed orchestrator);
    event ProposalBound(
        address indexed proposal,
        address yesPool,
        address noPool,
        uint48 anchorTimestamp,
        bytes32 questionId
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

    /// @notice One-shot wiring: set the orchestrator that can call bindProposal.
    function setOrchestrator(address newOrchestrator) external {
        if (orchestrator != address(0)) revert OrchestratorAlreadySet();
        orchestrator = newOrchestrator;
        emit OrchestratorSet(newOrchestrator);
    }

    /// @inheritdoc IFAOFutarchyTwapResolver
    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp
    ) external {
        if (msg.sender != orchestrator) revert NotOrchestrator();
        if (bindings[proposal].anchorTimestamp != 0) revert AlreadyBound(proposal);

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

        emit ProposalBound(proposal, yesPool, noPool, anchorTimestamp, qId);
    }

    /// @inheritdoc IFAOFutarchyOracle
    function resolve(address proposal) external {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) revert NotBound(proposal);
        if (b.resolved) revert AlreadyResolved(proposal);

        uint256 windowEnd = uint256(b.anchorTimestamp) + TIMEOUT;
        if (block.timestamp < windowEnd) revert TooEarly(proposal, windowEnd);

        (address yesCo, address noCo) = _companyWrappers(proposal);
        int24 yesAvgTick = _arithmeticMeanTick(b.yesPool, yesCo, windowEnd);
        int24 noAvgTick = _arithmeticMeanTick(b.noPool, noCo, windowEnd);

        bool accepted = yesAvgTick > noAvgTick;

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

    // ─── views ─────────────────────────────────────────────────────────────

    function windowEndOf(address proposal) external view returns (uint256) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0) return 0;
        return uint256(b.anchorTimestamp) + TIMEOUT;
    }

    function isReadyToResolve(address proposal) external view returns (bool) {
        Binding storage b = bindings[proposal];
        if (b.anchorTimestamp == 0 || b.resolved) return false;
        return block.timestamp >= uint256(b.anchorTimestamp) + TIMEOUT;
    }

    // ─── internals ─────────────────────────────────────────────────────────

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
        returns (int24)
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

        (int56[] memory cums,) = p.observe(secondsAgos);
        int56 delta = cums[1] - cums[0];
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 avgTick = int24(delta / int56(uint56(TWAP_WINDOW)));

        // Normalize: pool tick = log(token1/token0). We want log(currency/company)
        // — i.e. company-as-token0 orientation. If token0 is the company wrapper,
        // tick is already in that orientation; else negate.
        address t0 = p.token0();
        if (t0 == companyWrapper) return avgTick;
        return -avgTick;
    }

    /// @dev Returns the (yesCompanyWrap, noCompanyWrap) for a proposal. Outcome indexing
    /// matches FAOFutarchyFactory: 0 = YES_co, 1 = NO_co, 2 = YES_cur, 3 = NO_cur.
    function _companyWrappers(address proposal) internal view returns (address yesCo, address noCo) {
        FAOFutarchyProposal p = FAOFutarchyProposal(proposal);
        (yesCo,) = p.wrappedOutcome(0);
        (noCo,) = p.wrappedOutcome(1);
    }
}
