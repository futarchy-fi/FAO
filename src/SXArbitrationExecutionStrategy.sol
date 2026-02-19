// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IExecutionStrategy} from "sx/interfaces/IExecutionStrategy.sol";
import {Proposal, ProposalStatus} from "sx/types.sol";

interface IFutarchyArbitrationLike {
    function isAccepted(uint256 proposalId) external view returns (bool);
}

/// @title SXArbitrationExecutionStrategy
/// @notice Snapshot X execution strategy wrapper that gates execution on an external
/// FutarchyArbitration decision.
/// @dev Snapshot X's IExecutionStrategy.getProposalStatus(...) does NOT receive the execution
/// payload, so it cannot decode an arbitration id (arbId) from calldata. To support status-level
/// gating, this strategy derives the
///      arbId deterministically from the proposal's executionPayloadHash:
///
///      arbId := uint256(proposal.executionPayloadHash)
///
///      Then execute(...) uses that derived arbId to require arbitration acceptance before
/// forwarding to `inner`.
contract SXArbitrationExecutionStrategy is IExecutionStrategy {
    error ArbitrationNotAccepted(uint256 arbId);

    IFutarchyArbitrationLike public immutable arbitration;
    IExecutionStrategy public immutable inner;

    constructor(address arbitration_, address inner_) {
        arbitration = IFutarchyArbitrationLike(arbitration_);
        inner = IExecutionStrategy(inner_);
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
        ProposalStatus innerStatus = inner.getProposalStatus(
            proposal, votesFor, votesAgainst, votesAbstain
        );

        // If voting isn't in an "Accepted"-eligible state yet, don't add extra gating logic.
        if (innerStatus != ProposalStatus.Accepted) return innerStatus;

        // Voting is accepted, but execution must still be gated on arbitration.
        uint256 arbId = _arbIdFromProposal(proposal);
        if (_isAccepted(arbId)) return innerStatus;

        // Show as accepted by voting but not yet executable.
        return ProposalStatus.VotingPeriodAccepted;
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
}
