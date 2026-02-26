// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock orchestrator for EvaluationPipeline unit tests.
/// @dev Has the same function signatures as FutarchyOfficialProposalOrchestrator so the
///      pipeline can call it via IOrchestratorLike.
contract MockEvaluationOrchestrator {
    address public nextProposal;
    uint256 public nextProposalId;
    uint256 public createCallCount;

    function setNextReturn(uint256 proposalId, address proposal) external {
        nextProposalId = proposalId;
        nextProposal = proposal;
    }

    function createOfficialProposalAndMigrate(
        string calldata,
        string calldata,
        string calldata,
        uint256,
        uint32
    ) external returns (uint256 proposalId, address proposal) {
        createCallCount++;
        proposalId = nextProposalId;
        proposal = nextProposal;
    }
}
