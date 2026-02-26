// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";

/// @title ManualEvaluator
/// @notice Phase 4 evaluator: permissioned, owner-controlled resolver for arbitration proposals.
/// @dev The owner sets a decision for a proposalId; anyone can then call resolve(proposalId)
///      which forwards to the bound FutarchyArbitration contract.
contract ManualEvaluator is Ownable, IFutarchyArbitrationEvaluator {
    /// @inheritdoc IFutarchyArbitrationEvaluator
    address public immutable arbitration;

    /// @notice Owner-chosen decision for a given proposalId.
    mapping(uint256 => bool) public decision;

    event DecisionSet(uint256 indexed proposalId, bool accepted);

    error NotArbitration();

    constructor(address arbitration_, address owner_) {
        arbitration = arbitration_;
        _transferOwnership(owner_);
    }

    /// @notice Set the decision to be applied when resolving `proposalId`.
    function setDecision(uint256 proposalId, bool accepted) external onlyOwner {
        decision[proposalId] = accepted;
        emit DecisionSet(proposalId, accepted);
    }

    /// @inheritdoc IFutarchyArbitrationEvaluator
    function resolve(uint256 proposalId) external returns (bool accepted) {
        accepted = decision[proposalId];
        // Forward to arbitration. Arbitration enforces that the proposal is the active evaluation
        // target and that only the evaluator may call.
        _arbitrationResolveActiveEvaluation(accepted);
    }

    function _arbitrationResolveActiveEvaluation(bool accepted) internal {
        // Minimal interface for the Phase 4 hook implemented in FutarchyArbitration.
        (bool ok,) =
            arbitration.call(abi.encodeWithSignature("resolveActiveEvaluation(bool)", accepted));
        require(ok, "ARBITRATION_RESOLVE_FAILED");
    }
}
