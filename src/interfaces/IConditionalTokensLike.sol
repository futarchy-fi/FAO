// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of Gnosis ConditionalTokens used by the FAO stack.
interface IConditionalTokensLike {
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    function payoutDenominator(bytes32 conditionId) external view returns (uint256);

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256);

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
}
