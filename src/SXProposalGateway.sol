// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ISpaceActions} from "./interfaces/space/ISpaceActions.sol";
import {IExecutionStrategy} from "./interfaces/IExecutionStrategy.sol";
import {Strategy} from "./types.sol";

interface IFutarchyArbitrationRegistry {
    function createProposalWithId(uint256 proposalId, uint256 minActivationBond)
        external
        returns (uint256);
}

/// @notice A Snapshot X authenticator that exposes proposal creation, but no vote or update path.
contract SXProposalGateway {
    error InvalidMinActivationBond();
    error ZeroAddress();

    ISpaceActions public immutable space;
    IExecutionStrategy public immutable executionStrategy;
    IFutarchyArbitrationRegistry public immutable arbitration;
    uint256 public immutable minActivationBond;

    constructor(
        address space_,
        address executionStrategy_,
        address arbitration_,
        uint256 minActivationBond_
    ) {
        if (space_ == address(0) || executionStrategy_ == address(0) || arbitration_ == address(0)) revert ZeroAddress();
        if (minActivationBond_ == 0) revert InvalidMinActivationBond();

        space = ISpaceActions(space_);
        executionStrategy = IExecutionStrategy(executionStrategy_);
        arbitration = IFutarchyArbitrationRegistry(arbitration_);
        minActivationBond = minActivationBond_;
    }

    function propose(
        string calldata metadataURI,
        bytes calldata executionPayload,
        bytes calldata proposalValidationParams
    ) external {
        arbitration.createProposalWithId(uint256(keccak256(executionPayload)), minActivationBond);
        space.propose(
            msg.sender,
            metadataURI,
            Strategy({addr: address(executionStrategy), params: executionPayload}),
            proposalValidationParams
        );
    }
}
