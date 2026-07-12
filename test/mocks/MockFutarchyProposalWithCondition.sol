// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockFutarchyProposalWithCondition {
    bytes32 public conditionId;

    constructor(bytes32 _conditionId) {
        conditionId = _conditionId;
    }
}
