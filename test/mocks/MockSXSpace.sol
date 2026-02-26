// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalStatus} from "src/types.sol";

contract MockSXSpace {
    mapping(uint256 => ProposalStatus) internal _statuses;

    function setProposalStatus(uint256 proposalId, ProposalStatus status) external {
        _statuses[proposalId] = status;
    }

    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus) {
        return _statuses[proposalId];
    }
}
