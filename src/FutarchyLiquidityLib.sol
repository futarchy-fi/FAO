// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyLiquidityAdapter} from "./interfaces/IFutarchyLiquidityAdapter.sol";
import {IFutarchyConditionalRouter} from "./interfaces/IFutarchyConditionalRouter.sol";

/// @title FutarchyLiquidityLib
/// @notice Extracted helpers to keep FutarchyLiquidityManager under EIP-170 size limit.
/// @dev Public library functions are deployed separately and called via DELEGATECALL,
///      removing their bytecode from the main contract.
library FutarchyLiquidityLib {
    using SafeERC20 for IERC20;

    /// @dev OpenZeppelin v4 SafeERC20 does not include `forceApprove`.
    function forceApprove(IERC20 token, address spender, uint256 value) public {
        uint256 current = token.allowance(address(this), spender);
        if (current != 0) {
            token.safeApprove(spender, 0);
        }
        token.safeApprove(spender, value);
    }

    function mergeOutcomePair(
        IFutarchyConditionalRouter router,
        address proposal,
        address collateralToken,
        address yesToken,
        address noToken
    ) public {
        if (yesToken == address(0) || noToken == address(0)) return;
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        uint256 noBal = IERC20(noToken).balanceOf(address(this));
        uint256 mergeAmount = yesBal < noBal ? yesBal : noBal;
        if (mergeAmount == 0) return;

        forceApprove(IERC20(yesToken), address(router), mergeAmount);
        forceApprove(IERC20(noToken), address(router), mergeAmount);
        router.mergePositions(proposal, collateralToken, mergeAmount);
    }

    function tryRedeemOutcomeRemainder(
        IFutarchyConditionalRouter router,
        address proposal,
        address collateralToken,
        address yesToken,
        address noToken
    ) public {
        if (yesToken == address(0) || noToken == address(0)) return;
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        uint256 noBal = IERC20(noToken).balanceOf(address(this));
        uint256 redeemAmount = yesBal > noBal ? yesBal : noBal;
        if (redeemAmount == 0) return;

        forceApprove(IERC20(yesToken), address(router), redeemAmount);
        forceApprove(IERC20(noToken), address(router), redeemAmount);

        try router.redeemPositions(proposal, collateralToken, redeemAmount) {} catch {}
    }

    function transferOutcomeDelta(
        address recipient,
        address[4] memory tokens,
        uint256[4] memory beforeBalances
    ) public {
        for (uint256 i; i < 4; i++) {
            if (tokens[i] != address(0)) {
                uint256 afterBal = IERC20(tokens[i]).balanceOf(address(this));
                if (afterBal > beforeBalances[i]) {
                    IERC20(tokens[i]).safeTransfer(recipient, afterBal - beforeBalances[i]);
                }
            }
        }
    }

    function sweepOutcomeTokensTo(address recipient, address[4] memory tokens) public {
        if (recipient == address(0)) return;
        for (uint256 i; i < 4; i++) {
            if (tokens[i] != address(0)) {
                uint256 bal = IERC20(tokens[i]).balanceOf(address(this));
                if (bal > 0) IERC20(tokens[i]).safeTransfer(recipient, bal);
            }
        }
    }

    function approvePairForAdapter(
        IFutarchyLiquidityAdapter adapter,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) public {
        if (amount0 > 0) {
            forceApprove(IERC20(token0), address(adapter), amount0);
        }
        if (amount1 > 0) {
            forceApprove(IERC20(token1), address(adapter), amount1);
        }
    }

    function splitCollateral(
        IFutarchyConditionalRouter router,
        address proposal,
        address collateralToken,
        uint256 amount
    ) public {
        if (amount == 0) return;
        forceApprove(IERC20(collateralToken), address(router), amount);
        router.splitPosition(proposal, collateralToken, amount);
    }
}
