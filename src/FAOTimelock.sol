// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title FAOTimelock
/// @notice Mainnet-posture wrapper around OpenZeppelin's TimelockController.
/// @dev TODO: deploy on mainnet and record the address in deployments.json::active.timelock.
/// @dev // pragma: TODO step B - pass the chosen Safe/multisig from audit/specs/SECURITY.md Step B.
contract FAOTimelock is TimelockController {
    /// @notice Mainnet target for privileged writes.
    uint256 public constant MIN_DELAY_MAINNET = 1 days;

    /// @notice Staging rehearsal delay, not used by the mainnet constructor.
    uint256 public constant MIN_DELAY_STAGING = 1 hours;

    error ZeroMultisig();

    constructor(address multisig)
        TimelockController(MIN_DELAY_MAINNET, _singleton(multisig), _openExecutors(), multisig)
    {}

    function _singleton(address account) private pure returns (address[] memory accounts) {
        if (account == address(0)) revert ZeroMultisig();
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _openExecutors() private pure returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = address(0);
    }
}
