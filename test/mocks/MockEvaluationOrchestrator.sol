// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock orchestrator for EvaluationPipeline unit tests.
/// @dev Has the same function signatures as FutarchyOfficialProposalOrchestrator so the
///      pipeline can call it via IOrchestratorLike.
contract MockEvaluationOrchestrator {
    address public nextProposal;
    uint256 public nextProposalId;
    uint256 public createCallCount;
    address public manager;
    address public proposalSource;
    address public wiringCaller;
    uint256 public lastMinBond;
    uint32 public lastOpeningTime;

    function setWiring(address manager_, address proposalSource_) external {
        manager = manager_;
        proposalSource = proposalSource_;
        wiringCaller = msg.sender;
    }

    function setNextReturn(uint256 proposalId, address proposal) external {
        nextProposalId = proposalId;
        nextProposal = proposal;
    }

    function createOfficialProposalAndMigrate(
        string calldata,
        string calldata,
        string calldata,
        uint256 minBond,
        uint32 openingTime
    ) external returns (uint256 proposalId, address proposal) {
        createCallCount++;
        lastMinBond = minBond;
        lastOpeningTime = openingTime;
        proposalId = nextProposalId;
        proposal = nextProposal;
    }
}
