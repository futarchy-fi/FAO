// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Proposal, ProposalStatus} from "sx/types.sol";
import {
    IExecutionStrategyErrors
} from "sx/interfaces/execution-strategies/IExecutionStrategyErrors.sol";

/// @notice Compatibility bridge so imports of `src/interfaces/IExecutionStrategy.sol`
/// resolve to the Snapshot X interface shape expected by `Space.sol`.
interface IExecutionStrategy is IExecutionStrategyErrors {
    function execute(
        uint256 proposalId,
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain,
        bytes memory payload
    ) external;

    function getProposalStatus(
        Proposal memory proposal,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 votesAbstain
    ) external view returns (ProposalStatus);

    function getStrategyType() external view returns (string memory);
}
