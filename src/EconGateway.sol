// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {SXProposalGateway} from "./SXProposalGateway.sol";
import {FAOTreasuryActions} from "./FAOTreasuryActions.sol";

/// @notice The sole arbitration gateway for site releases and treasury actions.
/// @dev Site releases retain SXProposalGateway's payload-hash id. Treasury actions are scoped to
///      this chain and vault so an accepted action cannot be replayed into another FAO instance.
contract EconGateway is SXProposalGateway {
    bytes32 public constant KIND_TREASURY = FAOTreasuryActions.KIND_TREASURY;

    address public immutable vault;
    uint256 public immutable treasuryMinActivationBond;

    event TreasuryActionProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes32 dataHash,
        bytes32 salt
    );

    constructor(
        address space_,
        address executionStrategy_,
        address arbitration_,
        address vault_,
        uint256 siteMinActivationBond_,
        uint256 treasuryMinActivationBond_
    ) SXProposalGateway(space_, executionStrategy_, arbitration_, siteMinActivationBond_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (treasuryMinActivationBond_ == 0) revert InvalidMinActivationBond();

        vault = vault_;
        treasuryMinActivationBond = treasuryMinActivationBond_;
    }

    /// @notice The exact domain-separated hash a vault uses to verify an accepted action.
    function treasuryActionHash(FAOTreasuryActions.TreasuryAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.hash(block.chainid, vault, action);
    }

    function treasuryProposalId(FAOTreasuryActions.TreasuryAction calldata action)
        public
        view
        returns (uint256)
    {
        return uint256(treasuryActionHash(action));
    }

    /// @notice Exact payload supplied permissionlessly when this item enters market evaluation.
    function treasuryEvaluationPayload(FAOTreasuryActions.TreasuryAction calldata action)
        external
        view
        returns (bytes memory)
    {
        return FAOTreasuryActions.evaluationPayload(block.chainid, vault, action);
    }

    /// @notice Permissionlessly creates an arbitration-only treasury proposal.
    function proposeTreasuryAction(FAOTreasuryActions.TreasuryAction calldata action)
        external
        returns (uint256 proposalId)
    {
        bytes32 actionHash = treasuryActionHash(action);
        proposalId = uint256(actionHash);
        arbitration.createProposalWithId(proposalId, treasuryMinActivationBond);

        emit TreasuryActionProposed(
            proposalId, msg.sender, action.target, action.value, keccak256(action.data), action.salt
        );
    }
}
