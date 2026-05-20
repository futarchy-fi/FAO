// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFAOFutarchyOracle} from "./interfaces/IFAOFutarchyOracle.sol";

/// @title FAOFutarchyProposal
/// @notice Cloneable proposal contract for FAO v0 futarchy markets.
///
/// Each proposal represents one binary decision with four conditional outcome tokens
/// (YES_company / NO_company / YES_currency / NO_currency). Resolution is reported by
/// a generic oracle (FutarchyTwapResolver in v0), not Reality.eth.
///
/// This contract is a slimmed fork of Seer's FutarchyProposal that drops the
/// Reality-specific bits (encodedQuestion, FutarchyRealityProxy type) and accepts a
/// generic IFAOFutarchyOracle.
contract FAOFutarchyProposal {
    struct FAOFutarchyProposalParams {
        bytes32 conditionId;
        bytes32 questionId;
        address collateralToken1;
        address collateralToken2;
        bytes32 parentCollectionId;
        uint256 parentOutcome;
        address parentMarket;
        address[] wrapped1155;
        bytes[] tokenData;
    }

    bool public initialized;
    string public marketName;
    string public description;
    string[] public outcomes;
    FAOFutarchyProposalParams internal _params;
    IFAOFutarchyOracle public oracle;

    error AlreadyInitialized();

    function initialize(
        string memory _marketName,
        string memory _description,
        string[] memory _outcomes,
        FAOFutarchyProposalParams memory params,
        IFAOFutarchyOracle _oracle
    ) external {
        if (initialized) revert AlreadyInitialized();
        marketName = _marketName;
        description = _description;
        outcomes = _outcomes;
        _params = params;
        oracle = _oracle;
        initialized = true;
    }

    function questionId() external view returns (bytes32) {
        return _params.questionId;
    }

    function conditionId() external view returns (bytes32) {
        return _params.conditionId;
    }

    function collateralToken1() external view returns (address) {
        return _params.collateralToken1;
    }

    function collateralToken2() external view returns (address) {
        return _params.collateralToken2;
    }

    function parentCollectionId() external view returns (bytes32) {
        return _params.parentCollectionId;
    }

    function parentMarket() external view returns (address) {
        return _params.parentMarket;
    }

    function parentOutcome() external view returns (uint256) {
        return _params.parentOutcome;
    }

    function wrappedOutcome(uint256 index) external view returns (address wrapped1155, bytes memory data) {
        return (_params.wrapped1155[index], _params.tokenData[index]);
    }

    function numOutcomes() external view returns (uint256) {
        return outcomes.length;
    }

    /// @notice Convenience helper; equivalent to oracle.resolve(address(this)).
    /// @dev The oracle can also be invoked directly off-chain by anyone.
    function resolve() external {
        oracle.resolve(address(this));
    }
}
