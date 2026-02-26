// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ArbitrationFutarchyProposal
/// @notice Clone-pattern proposal template for ArbitrationFutarchyFactory.
///
/// Stores the same data as Seer's FutarchyProposal but without the Reality.eth dependency.
/// This is a pure data container — resolution is handled externally by the CTF oracle
/// (SnapshotExecutionProxy for market settlement, TWAP oracle for the futarchy signal).
///
/// External interface matches Seer's FutarchyProposal for ecosystem compatibility:
///   conditionId(), questionId(), collateralToken1(), collateralToken2(),
///   wrappedOutcome(index), numOutcomes(), parentCollectionId(), parentMarket(), parentOutcome()
contract ArbitrationFutarchyProposal {
    bool public initialized;

    struct ProposalParams {
        bytes32 conditionId;
        address collateralToken1;
        address collateralToken2;
        bytes32 parentCollectionId;
        uint256 parentOutcome;
        address parentMarket;
        bytes32 questionId;
        address[] wrapped1155;
        bytes[] tokenData;
    }

    string public marketName;
    string[] internal _outcomes;
    ProposalParams internal _params;

    function initialize(
        string memory _marketName,
        string[] memory outcomes_,
        ProposalParams memory params
    ) external {
        require(!initialized, "Already initialized.");
        marketName = _marketName;
        _outcomes = outcomes_;
        _params = params;
        initialized = true;
    }

    function conditionId() external view returns (bytes32) {
        return _params.conditionId;
    }

    function questionId() external view returns (bytes32) {
        return _params.questionId;
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

    function wrappedOutcome(uint256 index)
        external
        view
        returns (address wrapped1155, bytes memory data)
    {
        return (_params.wrapped1155[index], _params.tokenData[index]);
    }

    function parentWrappedOutcome() external view returns (address wrapped1155, bytes memory data) {
        if (_params.parentMarket != address(0)) {
            (wrapped1155, data) = ArbitrationFutarchyProposal(_params.parentMarket)
                .wrappedOutcome(_params.parentOutcome);
        }
    }

    function numOutcomes() external view returns (uint256) {
        return _outcomes.length;
    }

    function outcomes(uint256 index) external view returns (string memory) {
        return _outcomes[index];
    }
}
