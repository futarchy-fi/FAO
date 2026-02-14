// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyConditionalRouter} from "./interfaces/IFutarchyConditionalRouter.sol";

interface IFutarchyProposalConditionLike {
    function conditionId() external view returns (bytes32);
}

/// @notice Settlement oracle that treats a proposal as settled once the Gnosis CTF condition has
/// a single winning outcome.
contract FutarchyCtfSettlementOracle {
    IFutarchyConditionalRouter public immutable ROUTER;

    constructor(IFutarchyConditionalRouter router) {
        ROUTER = router;
    }

    function isSettled(address proposal) external view returns (bool) {
        if (proposal == address(0)) return false;
        bytes32 conditionId = IFutarchyProposalConditionLike(proposal).conditionId();
        bool[] memory winning = ROUTER.getWinningOutcomes(conditionId);
        if (winning.length < 2) return false;
        bool yesWins = winning[0];
        bool noWins = winning[1];
        return yesWins != noWins;
    }
}

