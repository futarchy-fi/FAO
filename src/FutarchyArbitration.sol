// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";

/// @title FutarchyArbitration
/// @notice Bond-based arbitration with escalation, graduation queue, and evaluator settlement.
///
/// Proposals go through a bond escalation game where participants stake WXDAI on YES or NO.
/// Each flip requires doubling the opposing bond. If unchallenged for 72 hours, the current
/// side wins by timeout. Sufficiently large YES bonds graduate the proposal into an evaluation
/// queue, where an external evaluator (e.g., CTF oracle) determines the final outcome.
///
/// State machine:
///
///   INACTIVE ──[YES bond]──► YES ◄───────► NO
///                           │   │              │
///                  [graduate]   [timeout]   [timeout]
///                           │   │              │
///                           ▼   ▼              ▼
///                        QUEUED  SETTLED    SETTLED
///                           │
///                           ▼
///                       EVALUATING
///                           │
///                           ▼
///                        SETTLED
contract FutarchyArbitration is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════
    //  Constants & Immutables
    // ═══════════════════════════════════════════════════════

    /// @notice Duration after the last bond flip before timeout settlement is allowed.
    uint256 internal constant TIMEOUT = 72 hours;

    /// @notice Bond token (WXDAI on Gnosis Chain).
    IERC20 public immutable WXDAI;

    /// @notice Base graduation threshold (WXDAI, 18 decimals).
    /// @dev requiredYes(queueLen) = baseX * 2^queueLen.
    uint256 public immutable baseX;

    /// @notice Maximum proposals in queue + evaluation combined.
    uint256 public immutable MAX_QUEUE;

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    /// @notice Auto-incrementing id for proposals created without an explicit id.
    uint256 public nextProposalId = 1;

    /// @notice All proposals by id.
    mapping(uint256 => Proposal) internal proposals;

    /// @notice Pull-payment ledger for WXDAI payouts.
    mapping(address => uint256) public withdrawable;

    /// @notice Aggregate NO bond amount across all proposals currently in NO state.
    /// @dev When this exceeds `baseX`, safety mode activates — blocking YES-by-timeout.
    uint256 public totalActiveNoBonds;

    /// @notice Evaluator module that resolves proposals in EVALUATING state.
    IFutarchyArbitrationEvaluator public evaluator;

    // ── Graduation queue ──

    /// @dev Ring-buffer of proposal ids. We advance `queueHead` instead of shifting.
    uint256[] internal queue;

    /// @notice Index of the next proposal to dequeue.
    uint256 public queueHead;

    /// @notice Proposal id currently being evaluated (0 = none).
    uint256 public activeEvaluationProposalId;

    // ═══════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed creator,
        uint256 minActivationBond
    );

    event BondPlaced(
        uint256 indexed proposalId,
        ProposalState indexed newState,
        address indexed bidder,
        uint256 amount,
        address replacedBidder,
        uint256 replacedAmount
    );

    event ProposalGraduated(
        uint256 indexed proposalId,
        uint32 indexed queuePosition,
        uint256 requiredYesBond,
        uint256 yesBondAmount
    );

    event EvaluationStarted(uint256 indexed proposalId);

    event EvaluationResolved(
        uint256 indexed proposalId, bool accepted, address indexed winner, uint256 payout
    );

    event FinalizedByTimeout(
        uint256 indexed proposalId, bool accepted, address indexed winner, uint256 payout
    );

    event EvaluatorSet(address indexed evaluator);
    event Withdraw(address indexed account, uint256 amount);

    // ═══════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════

    error InvalidMinActivationBond();
    error ProposalAlreadyExists();
    error ProposalNotFound();
    error InvalidState();
    error BondTooSmall();
    error TimeoutNotReached();
    error NoBondExceedsBaseX();
    error SafetyModeActive();
    error QueueFull();
    error NotEvaluator();
    error InvalidEvaluator();

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor() {
        _transferOwnership(msg.sender);
        WXDAI = IERC20(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);
        baseX = 100e18;
        MAX_QUEUE = 16;
    }

    // ═══════════════════════════════════════════════════════
    //  Proposal Creation
    // ═══════════════════════════════════════════════════════

    /// @notice Create a new arbitration proposal with an auto-assigned id.
    /// @dev Anyone can create proposals. Starts INACTIVE with no bonds.
    function createProposal(uint256 minActivationBond)
        external
        returns (uint256 proposalId)
    {
        if (minActivationBond == 0) revert InvalidMinActivationBond();

        proposalId = nextProposalId;
        nextProposalId = proposalId + 1;

        _initProposal(proposalId, minActivationBond);
        emit ProposalCreated(proposalId, msg.sender, minActivationBond);
    }

    /// @notice Create a proposal with an explicit id.
    /// @dev Supports integrations that need deterministic ids (e.g., SX execution strategies
    /// that derive arbId from executionPayloadHash). Reverts if the id is already taken.
    function createProposalWithId(
        uint256 proposalId,
        uint256 minActivationBond
    ) external returns (uint256) {
        if (minActivationBond == 0) revert InvalidMinActivationBond();
        if (proposalId == 0) revert InvalidState();
        if (proposals[proposalId].exists) revert ProposalAlreadyExists();

        _initProposal(proposalId, minActivationBond);
        emit ProposalCreated(proposalId, msg.sender, minActivationBond);
        return proposalId;
    }

    // ═══════════════════════════════════════════════════════
    //  Bond Escalation
    // ═══════════════════════════════════════════════════════

    /// @notice Place a YES bond (flip-only).
    /// @dev INACTIVE → YES requires amount >= minActivationBond.
    ///      NO → YES requires amount >= max(minActivationBond, 2x current NO bond),
    ///      BUT a YES bond >= the current graduation threshold is always accepted —
    ///      guaranteeing graduation is always reachable regardless of NO bond size.
    ///      On NO → YES flip, if the bond meets the graduation threshold, the proposal
    ///      enters the evaluation queue.
    function placeYesBond(uint256 proposalId, uint256 amount) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();

        ProposalState s = p.state;
        bool isFlipFromNo = (s == ProposalState.NO);

        if (s == ProposalState.INACTIVE) {
            if (amount < p.minActivationBond) revert BondTooSmall();
        } else if (isFlipFromNo) {
            // A YES bond >= the graduation threshold is always accepted,
            // ensuring graduation is reachable regardless of NO bond size.
            uint256 gradThreshold = requiredYes(_queuedCount());
            if (amount < gradThreshold) {
                uint256 minFlip = p.noBond.amount * 2;
                if (p.minActivationBond > minFlip) minFlip = p.minActivationBond;
                if (amount < minFlip) revert BondTooSmall();
            }
        } else {
            revert InvalidState();
        }

        WXDAI.safeTransferFrom(msg.sender, address(this), amount);

        // Refund replaced YES bond.
        address replacedBidder = p.yesBond.bidder;
        uint256 replacedAmount = p.yesBond.amount;
        if (replacedAmount != 0) {
            withdrawable[replacedBidder] += replacedAmount;
        }

        p.yesBond = Bond({bidder: msg.sender, amount: amount});
        p.state = ProposalState.YES;
        p.lastStateChangeAt = uint64(block.timestamp);

        emit BondPlaced(proposalId, p.state, msg.sender, amount, replacedBidder, replacedAmount);

        if (isFlipFromNo) {
            // NO bonds leave the active set.
            totalActiveNoBonds -= p.noBond.amount;

            // Check graduation: only on NO → YES flip, never on first activation.
            _tryGraduate(proposalId, p, amount);
        }
    }

    /// @notice Place a NO bond (flip-only).
    /// @dev YES → NO requires amount >= 2x current YES bond, capped at baseX.
    ///      First activation must be YES (INACTIVE → NO is not allowed).
    function placeNoBond(uint256 proposalId, uint256 amount) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (amount > baseX) revert NoBondExceedsBaseX();

        ProposalState s = p.state;
        if (s == ProposalState.YES) {
            uint256 minFlip = p.yesBond.amount * 2;
            if (amount < minFlip) revert BondTooSmall();
        } else {
            revert InvalidState();
        }

        WXDAI.safeTransferFrom(msg.sender, address(this), amount);

        // Refund replaced NO bond.
        address replacedBidder = p.noBond.bidder;
        uint256 replacedAmount = p.noBond.amount;
        if (replacedAmount != 0) {
            withdrawable[replacedBidder] += replacedAmount;
        }

        p.noBond = Bond({bidder: msg.sender, amount: amount});
        p.state = ProposalState.NO;
        p.lastStateChangeAt = uint64(block.timestamp);

        totalActiveNoBonds += amount;

        emit BondPlaced(proposalId, p.state, msg.sender, amount, replacedBidder, replacedAmount);
    }

    // ═══════════════════════════════════════════════════════
    //  Settlement
    // ═══════════════════════════════════════════════════════

    /// @notice Finalize a proposal by timeout (72h unchallenged).
    /// @dev The current leading side wins and receives both bonds.
    ///      In safety mode, YES-by-timeout is blocked to prevent low-liquidity attacks.
    function finalizeByTimeout(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.settled) revert InvalidState();

        ProposalState s = p.state;
        if (s != ProposalState.YES && s != ProposalState.NO) revert InvalidState();

        if (block.timestamp < uint256(p.lastStateChangeAt) + TIMEOUT) {
            revert TimeoutNotReached();
        }

        // Safety mode blocks YES-by-timeout when aggregate NO exposure is high.
        if (s == ProposalState.YES && safetyModeActive()) {
            revert SafetyModeActive();
        }

        if (s == ProposalState.NO) {
            totalActiveNoBonds -= p.noBond.amount;
        }

        address winner = (s == ProposalState.YES) ? p.yesBond.bidder : p.noBond.bidder;
        uint256 payout = p.yesBond.amount + p.noBond.amount;

        p.settled = true;
        p.accepted = (s == ProposalState.YES);
        p.state = ProposalState.SETTLED;
        p.lastStateChangeAt = uint64(block.timestamp);

        if (payout != 0) {
            withdrawable[winner] += payout;
        }

        emit FinalizedByTimeout(proposalId, p.accepted, winner, payout);
    }

    // ═══════════════════════════════════════════════════════
    //  Graduation Queue & Evaluation
    // ═══════════════════════════════════════════════════════

    /// @notice Minimum YES bond required for graduation.
    /// @dev requiredYes(queueLen) = baseX * 2^queueLen. Exponential backpressure
    ///      makes it progressively harder to enqueue proposals when the queue is busy.
    function requiredYes(uint256 queueLen) public view returns (uint256) {
        if (queueLen >= 256) revert InvalidState();
        return baseX * (uint256(1) << queueLen);
    }

    /// @notice Move the next queued proposal into evaluation.
    /// @dev Reverts if there is already an active evaluation or the queue is empty.
    function startNextEvaluation() external {
        if (activeEvaluationProposalId != 0) revert InvalidState();

        uint256 queuedLen = _queuedCount();
        if (queuedLen == 0) revert InvalidState();

        uint256 proposalId = queue[queueHead];
        queueHead += 1;

        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.state != ProposalState.QUEUED) revert InvalidState();

        p.state = ProposalState.EVALUATING;
        p.lastStateChangeAt = uint64(block.timestamp);
        activeEvaluationProposalId = proposalId;

        emit EvaluationStarted(proposalId);
    }

    /// @notice Resolve the active evaluation.
    /// @dev Only callable by the configured evaluator module.
    function resolveActiveEvaluation(bool accepted) external {
        if (msg.sender != address(evaluator)) revert NotEvaluator();

        uint256 proposalId = activeEvaluationProposalId;
        if (proposalId == 0) revert InvalidState();

        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.state != ProposalState.EVALUATING) revert InvalidState();
        if (p.settled) revert InvalidState();

        p.settled = true;
        p.accepted = accepted;
        p.state = ProposalState.SETTLED;
        p.lastStateChangeAt = uint64(block.timestamp);

        address winner = accepted ? p.yesBond.bidder : p.noBond.bidder;
        uint256 payout = p.yesBond.amount + p.noBond.amount;
        if (payout != 0) {
            withdrawable[winner] += payout;
        }

        activeEvaluationProposalId = 0;

        emit EvaluationResolved(proposalId, accepted, winner, payout);
    }

    // ═══════════════════════════════════════════════════════
    //  Admin
    // ═══════════════════════════════════════════════════════

    /// @notice Set the evaluator module.
    /// @dev Validates that the evaluator is bound to this arbitration instance.
    function setEvaluator(address evaluator_) external onlyOwner {
        if (evaluator_ == address(0)) revert InvalidEvaluator();
        if (IFutarchyArbitrationEvaluator(evaluator_).arbitration() != address(this)) {
            revert InvalidEvaluator();
        }

        evaluator = IFutarchyArbitrationEvaluator(evaluator_);
        emit EvaluatorSet(evaluator_);
    }

    // ═══════════════════════════════════════════════════════
    //  Withdrawals
    // ═══════════════════════════════════════════════════════

    /// @notice Withdraw any WXDAI owed to the caller.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) return;

        withdrawable[msg.sender] = 0;
        WXDAI.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    /// @notice Get a proposal by id. Reverts if it does not exist.
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p;
    }

    /// @notice Returns true if the proposal is settled and accepted.
    function isAccepted(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled && p.accepted;
    }

    /// @notice Returns true if the proposal is settled (accepted or rejected).
    function isSettled(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled;
    }

    // ═══════════════════════════════════════════════════════
    //  Safety
    // ═══════════════════════════════════════════════════════

    /// @notice Threshold above which safety mode activates (= baseX).
    function safetyNoBondThreshold() public view returns (uint256) {
        return baseX;
    }

    /// @notice True when aggregate active NO bonds exceed the safety threshold.
    /// @dev In safety mode, YES-by-timeout settlement is disabled to prevent
    ///      low-liquidity manipulation.
    function safetyModeActive() public view returns (bool) {
        return totalActiveNoBonds >= safetyNoBondThreshold();
    }

    // ═══════════════════════════════════════════════════════
    //  Internals
    // ═══════════════════════════════════════════════════════

    function _initProposal(uint256 proposalId, uint256 minActivationBond)
        internal
    {
        Proposal storage p = proposals[proposalId];
        if (p.exists) revert ProposalAlreadyExists();

        p.minActivationBond = minActivationBond;
        p.state = ProposalState.INACTIVE;
        p.lastStateChangeAt = uint64(block.timestamp);
        p.exists = true;
    }

    /// @dev Attempt to graduate a proposal into the evaluation queue after a NO → YES flip.
    function _tryGraduate(uint256 proposalId, Proposal storage p, uint256 yesBondAmount) internal {
        uint256 queuedLen = _queuedCount();
        uint256 req = requiredYes(queuedLen);

        if (yesBondAmount < req) return;

        uint256 totalInQueue = queuedLen + (activeEvaluationProposalId == 0 ? 0 : 1);
        if (totalInQueue >= MAX_QUEUE) revert QueueFull();

        queue.push(proposalId);
        p.queuePosition = uint32(queuedLen + 1);
        p.state = ProposalState.QUEUED;

        emit ProposalGraduated(proposalId, p.queuePosition, req, yesBondAmount);
    }

    function _queuedCount() internal view returns (uint256) {
        return queue.length - queueHead;
    }
}
