// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockConditionalTokens {
    mapping(bytes32 => uint256) public payoutDenominator;
    mapping(bytes32 => mapping(uint256 => uint256)) public payoutNumerators;

    function setPayout(bytes32 conditionId, uint256 denom, uint256 yesNum, uint256 noNum) external {
        payoutDenominator[conditionId] = denom;
        payoutNumerators[conditionId][0] = yesNum;
        payoutNumerators[conditionId][1] = noNum;
    }
}
