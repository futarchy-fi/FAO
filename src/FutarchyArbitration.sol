// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";

/// @title FutarchyArbitration
/// @notice Bond-based arbitration filter with optional graduation queue.
/// @dev Implementation spec: /home/ubuntu/FAO/ARBITRATION.md
///
/// Phases (see Taskmaster T54+):
/// - Phase 1: core bonding state machine (INACTIVE/YES/NO/SETTLED)
/// - Phase 3+: graduation queue (QUEUED/EVALUATING)
/// - Phase 4+: evaluator module interface + ManualEvaluator
/// - Phase 7+: Snapshot X strategy integrations
contract FutarchyArbitration is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // NOTE: This file is intentionally introduced as a skeleton first.
    // Subsequent tasks fill in enums/structs/state + core methods.

    // --- Constants (filled in later tasks) ---
    uint256 internal constant TIMEOUT = 72 hours;

    // --- Immutable config ---
    // WXDAI on Gnosis Chain (xDAI wrapped ERC-20)
    // Ref: https://gnosisscan.io/token/0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d
    IERC20 public immutable WXDAI;

    /// @notice Graduation base threshold (WXDAI, 18 decimals).
    /// @dev Spec: requiredYes(queueLen) = baseX * 2^queueLen.
    uint256 public immutable baseX;

    /// @notice Maximum number of proposals that can be queued + (at most one) evaluating.
    /// @dev Implemented as a config knob so deployments can tune throughput vs safety.
    uint256 public immutable MAX_QUEUE;

    /// @notice Deployer/admin for Phase 4 wiring.
    /// @dev Minimal authority used only to set the evaluator module.
    address public immutable DEPLOYER;

    /// @notice Evaluator module allowed to resolve the active evaluation.
    IFutarchyArbitrationEvaluator public evaluator;

    event EvaluatorSet(address indexed evaluator);

    error NotDeployer();
    error NotEvaluator();
    error InvalidEvaluator();

    constructor() {
        DEPLOYER = msg.sender;
        WXDAI = IERC20(0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d);

        // Defaults for early phases/tests; can be parameterized later if needed.
        baseX = 100e18;
        MAX_QUEUE = 16;
    }

    // --- Phase 1: Core enums ---
    // ProposalType is intentionally generic; it will later be bound to Snapshot X strategy params.
    enum ProposalType {
        A,
        B,
        C,
        D
    }

    // Core state machine (Phase 1) + later queue states (Phase 3).
    enum ProposalState {
        INACTIVE,
        YES,
        NO,
        QUEUED,
        EVALUATING,
        SETTLED
    }

    // --- Phase 1: Core structs ---
    struct Bond {
        address bidder;
        uint256 amount;
    }

    struct Proposal {
        ProposalType proposalType;
        uint256 minActivationBond; // m

        Bond yesBond;
        Bond noBond;

        ProposalState state;
        uint64 lastStateChangeAt; // timestamp of last flip

        // Settlement fields (Phase 1)
        bool settled;
        bool accepted;

        // Queue fields (Phase 3+)
        uint32 queuePosition;

        bool exists;
    }

    // --- Phase 1: Storage ---
    uint256 public nextProposalId = 1;

    mapping(uint256 => Proposal) internal proposals;

    // Pull-payment ledger (WXDAI)
    mapping(address => uint256) public withdrawable;

    // --- Phase 6: Safety accounting (T91+) ---
    /// @notice Total NO bond amount across proposals currently in active NO state.
    /// @dev Used by Phase 6 safety predicates.
    uint256 public totalActiveNoBonds;

    // --- Phase 6: Safety predicates (T92+) ---
    /// @notice Threshold (in WXDAI) above which the system enters "safety mode".
    /// @dev For now we tie this to `baseX` so deployments can tune it without adding
    /// extra constructor params. Later phases can refine this predicate.
    function safetyNoBondThreshold() public view returns (uint256) {
        return baseX;
    }

    /// @notice Returns true when aggregate active NO exposure is high enough to enable safety mode.
    /// @dev Safety mode is used to conservatively disable risky settlement paths (see T93+).
    function safetyModeActive() public view returns (bool) {
        return totalActiveNoBonds >= safetyNoBondThreshold();
    }

    // --- Phase 3: Graduation queue storage (T76+) ---
    // Ring-buffer queue of proposalIds. `queueHead` is the index of the current head element.
    // We intentionally do not `pop(0)` to avoid O(n) shifting.
    uint256[] internal queue;
    uint256 public queueHead;

    // Non-zero when a proposal is in EVALUATING.
    uint256 public activeEvaluationProposalId;

    function _queuedCount() internal view returns (uint256) {
        return queue.length - queueHead;
    }

    // --- Phase 3: Evaluation entrypoint (T81) ---
    event EvaluationStarted(uint256 indexed proposalId);

    /// @notice Move the next queued proposal into evaluation.
    /// @dev Reverts if there is already an active evaluation or if the queue is empty.
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

    // --- Phase 3: Graduation math (T78+) ---
    /// @notice Minimum YES bond required for a proposal to graduate into the queue.
    /// @dev Spec: requiredYes(queueLen) = baseX * 2^queueLen.
    /// queueLen is the current number of items already queued.
    function requiredYes(uint256 queueLen) public view returns (uint256) {
        // queueLen is bounded in practice by MAX_QUEUE (small), but we still guard
        // against shifting by >= 256.
        if (queueLen >= 256) revert InvalidState();
        return baseX * (uint256(1) << queueLen);
    }

    // --- Phase 1: Events ---
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed creator,
        ProposalType proposalType,
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

    // --- Phase 1: Errors ---
    error InvalidMinActivationBond();
    error ProposalAlreadyExists();
    error ProposalNotFound();
    error InvalidState();
    error BondTooSmall();
    error TimeoutNotReached();
    error SafetyModeActive();
    error QueueFull();

    // --- Phase 4: Evaluator wiring (T84) ---
    event EvaluationResolved(
        uint256 indexed proposalId,
        bool accepted,
        address indexed winner,
        uint256 payout
    );

    /// @notice Set the evaluator module address.
    /// @dev Only callable by DEPLOYER. This is intentionally minimal auth for Phase 4.
    function setEvaluator(address evaluator_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (evaluator_ == address(0)) revert InvalidEvaluator();

        // Safety: ensure evaluator is bound to this arbitration instance.
        // This prevents accidentally wiring an evaluator configured for a different deployment.
        if (IFutarchyArbitrationEvaluator(evaluator_).arbitration() != address(this)) {
            revert InvalidEvaluator();
        }

        evaluator = IFutarchyArbitrationEvaluator(evaluator_);
        emit EvaluatorSet(evaluator_);
    }

    /// @notice Resolve the currently active evaluation.
    /// @dev Callable only by the configured evaluator.
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

    // --- Phase 1: Events (continued) ---
    event FinalizedByTimeout(
        uint256 indexed proposalId,
        bool accepted,
        address indexed winner,
        uint256 payout
    );

    /// @notice Create a new arbitration proposal.
    /// @dev Anyone can create proposals for free. The proposal begins INACTIVE with no bonds.
    function createProposal(ProposalType proposalType, uint256 minActivationBond)
        external
        returns (uint256 proposalId)
    {
        if (minActivationBond == 0) revert InvalidMinActivationBond();

        proposalId = nextProposalId;
        nextProposalId = proposalId + 1;

        _initProposal(proposalId, proposalType, minActivationBond);

        emit ProposalCreated(proposalId, msg.sender, proposalType, minActivationBond);
    }

    /// @notice Create a proposal with an explicit id.
    /// @dev This supports integrations that need deterministic ids (e.g. Snapshot X wrappers that use
    /// `arbId := uint256(executionPayloadHash)`).
    /// Reverts if the proposalId is already used.
    function createProposalWithId(uint256 proposalId, ProposalType proposalType, uint256 minActivationBond)
        external
        returns (uint256)
    {
        if (minActivationBond == 0) revert InvalidMinActivationBond();
        if (proposalId == 0) revert InvalidState();
        if (proposals[proposalId].exists) revert ProposalAlreadyExists();

        _initProposal(proposalId, proposalType, minActivationBond);

        emit ProposalCreated(proposalId, msg.sender, proposalType, minActivationBond);
        return proposalId;
    }

    function _initProposal(uint256 proposalId, ProposalType proposalType, uint256 minActivationBond)
        internal
    {
        Proposal storage p = proposals[proposalId];
        // If this id was previously used, we consider it immutable and disallow reuse.
        if (p.exists) revert ProposalAlreadyExists();

        p.proposalType = proposalType;
        p.minActivationBond = minActivationBond;
        p.state = ProposalState.INACTIVE;
        p.lastStateChangeAt = uint64(block.timestamp);
        p.exists = true;
    }

    // --- Phase 1 core methods ---

    /// @notice Place a YES bond. Bids are flip-only.
    /// @dev
    /// - INACTIVE -> YES requires amount >= m
    /// - NO -> YES requires amount >= max(m, 2x current NO)
    /// Replaces any previous YES bond; replaced bond becomes withdrawable immediately.
    function placeYesBond(uint256 proposalId, uint256 amount) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();

        ProposalState s = p.state;
        bool isFlipFromNo = (s == ProposalState.NO);

        if (s == ProposalState.INACTIVE) {
            if (amount < p.minActivationBond) revert BondTooSmall();
        } else if (s == ProposalState.NO) {
            uint256 minFlip = p.noBond.amount * 2;
            if (p.minActivationBond > minFlip) minFlip = p.minActivationBond;
            if (amount < minFlip) revert BondTooSmall();
        } else {
            // YES -> YES not allowed; also disallow queued/evaluating/settled in Phase 1.
            revert InvalidState();
        }

        // Escrow funds.
        WXDAI.safeTransferFrom(msg.sender, address(this), amount);

        // Refund/credit replaced YES bond (if any).
        address replacedBidder = p.yesBond.bidder;
        uint256 replacedAmount = p.yesBond.amount;
        if (replacedAmount != 0) {
            withdrawable[replacedBidder] += replacedAmount;
        }

        p.yesBond = Bond({bidder: msg.sender, amount: amount});
        p.state = ProposalState.YES;
        p.lastStateChangeAt = uint64(block.timestamp);

        emit BondPlaced(
            proposalId, p.state, msg.sender, amount, replacedBidder, replacedAmount
        );

        // --- Phase 6: accounting (T91) ---
        // Leaving NO state -> NO bonds are no longer active.
        if (isFlipFromNo) {
            totalActiveNoBonds -= p.noBond.amount;
        }

        // --- Phase 3: graduation trigger (T79) ---
        // Only trigger graduation on a YES flip (NO -> YES), never on first activation.
        if (isFlipFromNo) {
            uint256 queuedLen = _queuedCount();
            uint256 req = requiredYes(queuedLen);

            // Only graduate if threshold is met.
            if (amount >= req) {
                uint256 totalInQueue = queuedLen + (activeEvaluationProposalId == 0 ? 0 : 1);
                if (totalInQueue >= MAX_QUEUE) revert QueueFull();

                // Enqueue.
                queue.push(proposalId);
                p.queuePosition = uint32(queuedLen + 1);
                p.state = ProposalState.QUEUED;

                emit ProposalGraduated(proposalId, p.queuePosition, req, amount);
            }
        }
    }

    /// @notice Place a NO bond. Bids are flip-only.
    /// @dev
    /// - INACTIVE -> NO is not allowed (first activation must be YES)
    /// - YES -> NO requires amount >= 2x current YES
    /// Replaces any previous NO bond; replaced bond becomes withdrawable immediately.
    function placeNoBond(uint256 proposalId, uint256 amount) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();

        ProposalState s = p.state;
        if (s == ProposalState.INACTIVE) {
            revert InvalidState();
        } else if (s == ProposalState.YES) {
            uint256 minFlip = p.yesBond.amount * 2;
            // Spec for YES->NO is strictly 2x current YES (no max with m).
            if (amount < minFlip) revert BondTooSmall();
        } else {
            // NO -> NO not allowed; also disallow queued/evaluating/settled in Phase 1.
            revert InvalidState();
        }

        // Escrow funds.
        WXDAI.safeTransferFrom(msg.sender, address(this), amount);

        // Refund/credit replaced NO bond (if any).
        address replacedBidder = p.noBond.bidder;
        uint256 replacedAmount = p.noBond.amount;
        if (replacedAmount != 0) {
            withdrawable[replacedBidder] += replacedAmount;
        }

        p.noBond = Bond({bidder: msg.sender, amount: amount});
        p.state = ProposalState.NO;
        p.lastStateChangeAt = uint64(block.timestamp);

        // --- Phase 6: accounting (T91) ---
        totalActiveNoBonds += amount;

        emit BondPlaced(
            proposalId, p.state, msg.sender, amount, replacedBidder, replacedAmount
        );
    }

    /// @notice Finalize an active proposal by timeout.
    /// @dev After TIMEOUT since the last state change (flip), the current side wins and
    /// receives the total of both bonds via the pull-payment ledger.
    function finalizeByTimeout(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.settled) revert InvalidState();

        ProposalState s = p.state;
        if (s != ProposalState.YES && s != ProposalState.NO) revert InvalidState();

        // Require TIMEOUT elapsed since last flip.
        if (block.timestamp < uint256(p.lastStateChangeAt) + TIMEOUT) {
            revert TimeoutNotReached();
        }

        // Phase 6: in safety mode, disable automatic YES-by-timeout acceptance.
        if (s == ProposalState.YES && safetyModeActive()) {
            revert SafetyModeActive();
        }

        // Phase 6 accounting: settling while NO leaves NO active set.
        if (s == ProposalState.NO) {
            totalActiveNoBonds -= p.noBond.amount;
        }

        // Winner is whoever is currently leading.
        address winner = (s == ProposalState.YES) ? p.yesBond.bidder : p.noBond.bidder;
        uint256 payout = p.yesBond.amount + p.noBond.amount;

        p.settled = true;
        p.accepted = (s == ProposalState.YES);
        p.state = ProposalState.SETTLED;
        p.lastStateChangeAt = uint64(block.timestamp);

        if (payout != 0) {
            // In normal usage winner is non-zero whenever payout is non-zero.
            withdrawable[winner] += payout;
        }

        emit FinalizedByTimeout(proposalId, p.accepted, winner, payout);
    }

    event Withdraw(address indexed account, uint256 amount);

    /// @notice Withdraw any WXDAI owed to the caller.
    /// @dev Uses checks-effects-interactions + ReentrancyGuard.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) return;

        // effects
        withdrawable[msg.sender] = 0;

        // interactions
        WXDAI.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // --- Phase 1: Views (T63) ---

    /// @notice Get a proposal by id.
    /// @dev Reverts if proposal does not exist.
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p;
    }

    /// @notice Returns true if proposal is settled and accepted.
    function isAccepted(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled && p.accepted;
    }

    /// @notice Returns true if proposal is settled.
    function isSettled(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled;
    }
}

