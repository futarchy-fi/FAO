// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev More complete CTF mock that supports both read (payouts) and write (prepareCondition,
/// reportPayouts) operations. Used by ArbitrationFutarchyFactory and SnapshotExecutionProxy tests.
contract MockConditionalTokensFull {
    // ── Payout state (for evaluator reads) ──
    mapping(bytes32 => uint256) public payoutDenominator;
    mapping(bytes32 => mapping(uint256 => uint256)) public payoutNumerators;

    // ── Condition state (for factory create) ──
    mapping(bytes32 => uint256) public outcomeSlotCounts;

    // ── Report tracking ──
    bytes32 public lastReportQuestionId;
    uint256[] public lastReportPayouts;
    uint256 public reportCount;

    function setPayout(bytes32 conditionId, uint256 denom, uint256 yesNum, uint256 noNum) external {
        payoutDenominator[conditionId] = denom;
        payoutNumerators[conditionId][0] = yesNum;
        payoutNumerators[conditionId][1] = noNum;
    }

    // ── CTF condition lifecycle ──

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCounts[conditionId];
    }

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
    {
        bytes32 conditionId = keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
        outcomeSlotCounts[conditionId] = outcomeSlotCount;
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        lastReportQuestionId = questionId;
        lastReportPayouts = payouts;
        reportCount++;

        // Also set the payout state for consistency.
        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payouts.length));
        uint256 denom;
        for (uint256 i = 0; i < payouts.length; i++) {
            payoutNumerators[conditionId][i] = payouts[i];
            denom += payouts[i];
        }
        payoutDenominator[conditionId] = denom;
    }

    function getLastReportPayouts() external view returns (uint256[] memory) {
        return lastReportPayouts;
    }

    // ── Position token helpers (for factory ERC20 wrapping) ──

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }
}
