// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Immutable custody and call identity controlled only by its vault.
contract GenesisTreasuryExecutor {
    using SafeERC20 for IERC20;

    address public immutable VAULT;

    error InvalidVault();
    error Unauthorized(address caller);
    error CallFailed(bytes reason);
    error NativeTransferFailed(bytes reason);
    error InexactTokenTransfer(address asset, address recipient, uint256 expected, uint256 actual);

    constructor(address vault) {
        if (vault == address(0)) revert InvalidVault();
        VAULT = vault;
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) revert Unauthorized(msg.sender);
        _;
    }

    receive() external payable {}

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyVault
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
    }

    function release(address asset, address payable recipient, uint256 amount) external onlyVault {
        if (asset == address(0)) {
            (bool success, bytes memory reason) = recipient.call{value: amount}("");
            if (!success) revert NativeTransferFailed(reason);
            return;
        }

        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 afterBalance = token.balanceOf(recipient);
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) {
            revert InexactTokenTransfer(asset, recipient, amount, received);
        }
    }
}
