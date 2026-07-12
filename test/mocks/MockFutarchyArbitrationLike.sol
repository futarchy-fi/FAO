// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockFutarchyArbitrationLike {
    uint256 public activeEvaluationProposalId;

    bool public lastAccepted;
    uint256 public resolveCalls;

    function setActive(uint256 proposalId) external {
        activeEvaluationProposalId = proposalId;
    }

    function resolveActiveEvaluation(bool accepted) external {
        lastAccepted = accepted;
        resolveCalls += 1;
        activeEvaluationProposalId = 0;
    }
}
