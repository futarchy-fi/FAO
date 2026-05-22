// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title FAORenewableAdmin
/// @notice Sketch for Step D in audit/specs/SECURITY.md: DEFAULT_ADMIN_ROLE holders
/// must renew within a grace period or anyone can revoke the stale admin.
/// @dev // pragma: TODO step D - inherit this in the next registry/admin-surface
/// revision before mainnet. Existing immutable-admin v5 contracts cannot be
/// retrofitted safely without redeploying the affected instances.
abstract contract FAORenewableAdmin is AccessControl {
    uint256 public immutable ADMIN_RENEWAL_GRACE_PERIOD;

    mapping(address admin => uint256 renewedAt) public defaultAdminRenewedAt;

    error InvalidGracePeriod();
    error ZeroAdmin();
    error DefaultAdminMissing(address account);
    error DefaultAdminFresh(address account, uint256 staleAt);

    event RenewableDefaultAdminGranted(address indexed account, uint256 renewedAt);
    event DefaultAdminRenewed(address indexed account, uint256 renewedAt);
    event StaleDefaultAdminRevoked(address indexed account, address indexed caller);

    constructor(uint256 gracePeriod) {
        if (gracePeriod == 0) revert InvalidGracePeriod();
        ADMIN_RENEWAL_GRACE_PERIOD = gracePeriod;
    }

    /// @notice Refresh the caller's DEFAULT_ADMIN_ROLE lease.
    function renewDefaultAdmin() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _renewDefaultAdmin(msg.sender);
    }

    /// @notice Revoke a DEFAULT_ADMIN_ROLE holder that has not renewed before the grace deadline.
    function renounceIfStale(address account) public {
        if (!hasRole(DEFAULT_ADMIN_ROLE, account)) revert DefaultAdminMissing(account);

        uint256 staleAt = defaultAdminRenewedAt[account] + ADMIN_RENEWAL_GRACE_PERIOD;
        if (block.timestamp < staleAt) revert DefaultAdminFresh(account, staleAt);

        _revokeRole(DEFAULT_ADMIN_ROLE, account);
        emit StaleDefaultAdminRevoked(account, msg.sender);
    }

    function _grantRenewableDefaultAdmin(address account) internal {
        if (account == address(0)) revert ZeroAdmin();

        _grantRole(DEFAULT_ADMIN_ROLE, account);
        _renewDefaultAdmin(account);
        emit RenewableDefaultAdminGranted(account, block.timestamp);
    }

    function _renewDefaultAdmin(address account) internal {
        defaultAdminRenewedAt[account] = block.timestamp;
        emit DefaultAdminRenewed(account, block.timestamp);
    }
}
