// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IExecutionStrategy} from "sx/interfaces/IExecutionStrategy.sol";
import {Proposal, ProposalStatus} from "sx/types.sol";

interface IFutarchyArbitrationLike {
    function isAccepted(uint256 proposalId) external view returns (bool);
    function isSettled(uint256 proposalId) external view returns (bool);
}

/// @title SXArbitrationExecutionStrategy
/// @notice Snapshot X execution strategy that integrates futarchy bond arbitration.
///
/// Two operating modes, configured at deployment:
///
///   BINDING  — The arbitration result IS the decision. Votes are ignored.
///              Use this for full futarchy: proposals are decided by the bond
///              escalation game, not by token-weighted voting. SX is used for
///              its proposal lifecycle, UI, and gating — but not for votes.
///
///   VETO    —  Arbitration runs first as a pre-filter. If bonds reject a
///              proposal it dies immediately. If bonds accept, the proposal
///              still needs to pass the inner (vote-based) execution strategy.
///              This lets existing SX spaces add futarchy incrementally: bond
///              rejection kills bad proposals early, but token holders retain
///              veto power over accepted ones.
///
/// @dev arbId is derived deterministically from the proposal's executionPayloadHash
///      so both SX and the arbitration contract reference the same proposal without
///      off-chain coordination:
///
///          arbId := uint256(proposal.executionPayloadHash)
contract SXArbitrationExecutionStrategy is IExecutionStrategy {
    enum Mode {
        BINDING, // Arbitration result is final — votes don't matter
        VETO     // Arbitration pre-filters — votes have veto power
    }

    error ArbitrationNotAccepted(uint256 arbId);
    error ArbitrationRejected(uint256 arbId);

    IFutarchyArbitrationLike public immutable arbitration;
    IExecutionStrategy public immutable inner;
    Mode public immutable mode;

    constructor(address arbitration_, address inner_, Mode mode_) {
        arbitration = IFutarchyArbitrationLike(arbitration_);
        inner = IExecutionStrategy(inner_);
        mode = mode_;
    }

    function execute(
        uint256 proposalId,
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        bytes memory payload
    ) external override {
        uint256 arbId = _arbIdFromProposal(proposal);
        if (!_isAccepted(arbId)) revert ArbitrationNotAccepted(arbId);

        inner.execute(proposalId, proposal, votesFor, votesAgainst, votesAbstain, payload);
    }

    function getProposalStatus(
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain
    ) external view override returns (ProposalStatus) {
        uint256 arbId = _arbIdFromProposal(proposal);

        if (mode == Mode.BINDING) {
            return _bindingStatus(arbId);
        } else {
            return _vetoStatus(arbId, proposal, votesFor, votesAgainst, votesAbstain);
        }
    }

    /// @dev BINDING: arbitration is the sole decision-maker.
    ///      Not settled → VotingPeriod (proposal stays "active" in SX UI while bonds play out)
    ///      Settled + accepted → Accepted (executable)
    ///      Settled + rejected → Rejected
    function _bindingStatus(uint256 arbId) internal view returns (ProposalStatus) {
        if (_isAccepted(arbId)) return ProposalStatus.Accepted;
        if (_isSettled(arbId)) return ProposalStatus.Rejected;
        return ProposalStatus.VotingPeriod;
    }

    /// @dev VETO: arbitration pre-filters, votes have final say.
    ///      Settled + rejected → Rejected (bonds killed it, no vote needed)
    ///      Not settled → VotingPeriod (waiting for bond game to finish)
    ///      Accepted by bonds → defer to inner (let votes decide)
    function _vetoStatus(
        uint256 arbId,
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain
    ) internal view returns (ProposalStatus) {
        bool settled = _isSettled(arbId);
        bool accepted = _isAccepted(arbId);

        // Bonds rejected → dead
        if (settled && !accepted) return ProposalStatus.Rejected;

        // Bonds not settled → still in progress
        if (!settled) return ProposalStatus.VotingPeriod;

        // Bonds accepted → defer to votes via inner strategy
        return inner.getProposalStatus(proposal, votesFor, votesAgainst, votesAbstain);
    }

    function getStrategyType() external pure override returns (string memory) {
        return "SXArbitrationExecutionStrategy";
    }

    function _arbIdFromProposal(Proposal memory proposal) internal pure returns (uint256) {
        return uint256(proposal.executionPayloadHash);
    }

    function _isAccepted(uint256 arbId) internal view returns (bool accepted) {
        try arbitration.isAccepted(arbId) returns (bool ok) {
            accepted = ok;
        } catch {
            accepted = false;
        }
    }

    function _isSettled(uint256 arbId) internal view returns (bool settled) {
        try arbitration.isSettled(arbId) returns (bool ok) {
            settled = ok;
        } catch {
            settled = false;
        }
    }
}
