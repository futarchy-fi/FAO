// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyConditionalRouter} from "./interfaces/IFutarchyConditionalRouter.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";

/// @notice Minimal IFutarchyConditionalRouter that wraps a Gnosis CTF deployment.
///
/// FAO v0 only needs `getWinningOutcomes` to be functional — it is read by
/// FutarchyCtfSettlementOracle to detect when the resolver has reported payouts.
/// `splitPosition`, `mergePositions`, `redeemPositions` are unused in v0 and
/// revert. They can be wired to CTF directly in a later version if needed.
contract CtfRouter is IFutarchyConditionalRouter {
    IConditionalTokensLike public immutable conditionalTokens;

    error NotImplemented();

    constructor(IConditionalTokensLike ctf) {
        conditionalTokens = ctf;
    }

    function getWinningOutcomes(bytes32 conditionId) external view returns (bool[] memory) {
        uint256 n = conditionalTokens.getOutcomeSlotCount(conditionId);
        bool[] memory result = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            result[i] = conditionalTokens.payoutNumerators(conditionId, i) != 0;
        }
        return result;
    }

    function splitPosition(address, address, uint256) external pure {
        revert NotImplemented();
    }

    function mergePositions(address, address, uint256) external pure {
        revert NotImplemented();
    }

    function redeemPositions(address, address, uint256) external pure {
        revert NotImplemented();
    }
}
