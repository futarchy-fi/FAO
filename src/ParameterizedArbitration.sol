// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";

/// @title ParameterizedArbitration
/// @notice Multi-instance variant of FutarchyArbitration.
///
/// Why a copy and not inheritance:
/// - `FutarchyArbitration` hardcodes Sepolia WETH, `baseX = 0.001 ether`, and
///   `MAX_QUEUE = 3` in its constructor (which takes no arguments), and treats
///   `TIMEOUT` as a `uint256 internal constant` (= 2 hours).
/// - For a meta-factory (`FutarchyRegistry`) that spins up many futarchy
///   instances on the same chain, all four of those knobs need to be
///   constructor-supplied so each org can pick its own bond token, base bond,
///   queue depth, and escalation timeout.
/// - Solidity does not let a child contract pass arguments to a no-arg parent
///   constructor (or override a `constant`), so inheriting would still require
///   shadow-immutables and a forked code path for the constant.
/// - The remaining code (placeYesBond / placeNoBond / finalizeByTimeout /
///   evaluation queue / withdrawals) is functionally identical to
///   `FutarchyArbitration` — we copy verbatim so future audits can diff the
///   two files and confirm the only changes are the parameterized constructor.
contract ParameterizedArbitration is Ownable2Step, ReentrancyGuard {
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
    uint256 public immutable TIMEOUT;

    /// @notice Bond token (WETH on Sepolia / Ethereum mainnet by default).
    IERC20 public immutable WETH;

    /// @notice Base graduation threshold (bond token, 18 decimals).
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

    /// @notice Pull-payment ledger for bond-token payouts.
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
    error SafetyModeActive();
    error QueueFull();
    error NotEvaluator();
    error InvalidEvaluator();
    error InvalidConstructor();

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor(
        address admin,
        address weth,
        uint256 baseX_,
        uint256 maxQueue,
        uint256 timeout
    ) {
        if (admin == address(0) || weth == address(0)) revert InvalidConstructor();
        if (baseX_ == 0 || maxQueue == 0 || timeout == 0) revert InvalidConstructor();

        _transferOwnership(admin);
        WETH = IERC20(weth);
        baseX = baseX_;
        MAX_QUEUE = maxQueue;
        TIMEOUT = timeout;
    }

    // ═══════════════════════════════════════════════════════
    //  Proposal Creation
    // ═══════════════════════════════════════════════════════

    /// @notice Create a new arbitration proposal with an auto-assigned id.
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

    function placeYesBond(uint256 proposalId, uint256 amount) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();

        ProposalState s = p.state;
        bool isFlipFromNo = (s == ProposalState.NO);

        if (s == ProposalState.INACTIVE) {
            if (amount < p.minActivationBond) revert BondTooSmall();
        } else if (isFlipFromNo) {
            uint256 gradThreshold = requiredYes(_queuedCount());
            if (amount < gradThreshold) {
                uint256 minFlip = p.noBond.amount * 2;
                if (p.minActivationBond > minFlip) minFlip = p.minActivationBond;
                if (amount < minFlip) revert BondTooSmall();
            }
        } else {
            revert InvalidState();
        }

        WETH.safeTransferFrom(msg.sender, address(this), amount);

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
            totalActiveNoBonds -= p.noBond.amount;
            _tryGraduate(proposalId, p, amount);
        }
    }

    function placeNoBond(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();

        ProposalState s = p.state;
        if (s != ProposalState.YES) revert InvalidState();

        uint256 amount = p.yesBond.amount;

        WETH.safeTransferFrom(msg.sender, address(this), amount);

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

    function finalizeByTimeout(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.settled) revert InvalidState();

        ProposalState s = p.state;
        if (s != ProposalState.YES && s != ProposalState.NO) revert InvalidState();

        if (block.timestamp < uint256(p.lastStateChangeAt) + TIMEOUT) {
            revert TimeoutNotReached();
        }

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

    function requiredYes(uint256 queueLen) public view returns (uint256) {
        if (queueLen >= 256) revert InvalidState();
        return baseX * (uint256(1) << queueLen);
    }

    function tryGraduate(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.state != ProposalState.YES) revert InvalidState();

        _tryGraduate(proposalId, p, p.yesBond.amount);
    }

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

    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) return;

        withdrawable[msg.sender] = 0;
        WETH.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p;
    }

    function isAccepted(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled && p.accepted;
    }

    function isSettled(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p.settled;
    }

    // ═══════════════════════════════════════════════════════
    //  Safety
    // ═══════════════════════════════════════════════════════

    function safetyNoBondThreshold() public view returns (uint256) {
        return baseX;
    }

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
