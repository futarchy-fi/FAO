// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IVotingStrategy} from "./interfaces/IVotingStrategy.sol";

/// @notice Satisfies Snapshot X's voting-strategy invariant without granting voting power.
contract AlwaysZeroVotingStrategy is IVotingStrategy {
    function getVotingPower(uint32, address, bytes calldata, bytes calldata)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}
