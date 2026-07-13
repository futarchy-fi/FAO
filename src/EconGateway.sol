// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {SXProposalGateway} from "./SXProposalGateway.sol";
import {FAOTreasuryActions} from "./FAOTreasuryActions.sol";

interface IGenesisCriticalWindow {
    function criticalRoundTwoWindow(bytes32 baseHash)
        external
        view
        returns (uint256 opensAt, uint256 closesAt, bool queued);
}

/// @notice The sole arbitration gateway for site releases and typed treasury actions.
contract EconGateway is SXProposalGateway {
    bytes32 public constant KIND_TRANSFER = keccak256("FAO_ECON_TREASURY_TRANSFER_V1");
    bytes32 public constant KIND_PARAM = keccak256("FAO_ECON_TREASURY_PARAM_V1");
    bytes32 public constant KIND_CRITICAL = keccak256("FAO_ECON_TREASURY_CRITICAL_V2");

    address public immutable vault;
    uint256 public immutable treasuryMinActivationBond;

    error CriticalAlreadyQueued(bytes32 baseHash);
    error CriticalNotStaged(bytes32 baseHash);
    error CriticalRoundTwoClosed(uint256 closesAt);
    error CriticalRoundTwoTooEarly(uint256 opensAt);
    error InvalidParamAction();
    error InvalidTransferAction();

    event TransferProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed asset,
        address recipient,
        uint256 amount,
        bytes32 salt
    );
    event ParamProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 indexed key,
        address asset,
        uint256 value,
        bytes32 salt
    );
    event CriticalRoundProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 indexed baseHash,
        address target,
        uint256 value,
        bytes32 dataHash,
        bytes32 salt,
        uint256 round
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

    function transferEvaluationPayload(FAOTreasuryActions.TransferAction calldata action)
        public
        view
        returns (bytes memory)
    {
        return FAOTreasuryActions.transferEvaluationPayload(block.chainid, vault, action);
    }

    function transferProposalId(FAOTreasuryActions.TransferAction calldata action)
        public
        view
        returns (uint256)
    {
        return uint256(FAOTreasuryActions.transferHash(block.chainid, vault, action));
    }

    function paramEvaluationPayload(FAOTreasuryActions.ParamAction calldata action)
        public
        view
        returns (bytes memory)
    {
        return FAOTreasuryActions.paramEvaluationPayload(block.chainid, vault, action);
    }

    function paramProposalId(FAOTreasuryActions.ParamAction calldata action)
        public
        view
        returns (uint256)
    {
        return uint256(FAOTreasuryActions.paramHash(block.chainid, vault, action));
    }

    function criticalBaseHash(FAOTreasuryActions.CriticalAction calldata action)
        public
        view
        returns (bytes32)
    {
        return FAOTreasuryActions.criticalBaseHash(block.chainid, vault, action);
    }

    function criticalEvaluationPayload(
        FAOTreasuryActions.CriticalAction calldata action,
        uint256 round
    ) public view returns (bytes memory) {
        return FAOTreasuryActions.criticalEvaluationPayload(block.chainid, vault, action, round);
    }

    function criticalProposalId(FAOTreasuryActions.CriticalAction calldata action, uint256 round)
        public
        view
        returns (uint256)
    {
        return uint256(FAOTreasuryActions.criticalHash(block.chainid, vault, action, round));
    }

    function proposeTransfer(FAOTreasuryActions.TransferAction calldata action)
        external
        returns (uint256 proposalId)
    {
        if (action.recipient == address(0) || action.amount == 0) {
            revert InvalidTransferAction();
        }
        proposalId = transferProposalId(action);
        arbitration.createProposalWithId(proposalId, treasuryMinActivationBond);
        emit TransferProposed(
            proposalId, msg.sender, action.asset, action.recipient, action.amount, action.salt
        );
    }

    function proposeParam(FAOTreasuryActions.ParamAction calldata action)
        external
        returns (uint256 proposalId)
    {
        if (action.key == bytes32(0)) revert InvalidParamAction();
        proposalId = paramProposalId(action);
        arbitration.createProposalWithId(proposalId, treasuryMinActivationBond);
        emit ParamProposed(
            proposalId, msg.sender, action.key, action.asset, action.value, action.salt
        );
    }

    function proposeCriticalRound(FAOTreasuryActions.CriticalAction calldata action, uint256 round)
        external
        returns (uint256 proposalId)
    {
        if (action.target == address(0)) revert ZeroAddress();
        bytes32 baseHash = criticalBaseHash(action);
        if (round == 2) {
            (uint256 opensAt, uint256 closesAt, bool queued) =
                IGenesisCriticalWindow(vault).criticalRoundTwoWindow(baseHash);
            if (opensAt == 0) revert CriticalNotStaged(baseHash);
            if (queued) revert CriticalAlreadyQueued(baseHash);
            if (block.timestamp < opensAt) revert CriticalRoundTwoTooEarly(opensAt);
            if (block.timestamp > closesAt) revert CriticalRoundTwoClosed(closesAt);
        }

        proposalId = criticalProposalId(action, round);
        arbitration.createProposalWithId(proposalId, treasuryMinActivationBond);
        emit CriticalRoundProposed(
            proposalId,
            msg.sender,
            baseHash,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt,
            round
        );
    }
}
