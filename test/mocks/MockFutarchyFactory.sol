// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockFutarchyProposalLike} from "./MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "./MockMintableERC20.sol";

/// @notice Minimal mock FutarchyFactory that deploys a proposal with fresh outcome ERC20s.
contract MockFutarchyFactory {
    struct CreateProposalParams {
        string marketName;
        address collateralToken1;
        address collateralToken2;
        string category;
        string lang;
        uint256 minBond;
        uint32 openingTime;
    }

    address[] public proposals;

    function marketsCount() external view returns (uint256) {
        return proposals.length;
    }

    function createProposal(CreateProposalParams calldata params)
        external
        returns (address proposal)
    {
        // Fresh outcome tokens per proposal.
        MockMintableERC20 yesCompany = new MockMintableERC20("YES_COMP", "YCOMP");
        MockMintableERC20 noCompany = new MockMintableERC20("NO_COMP", "NCOMP");
        MockMintableERC20 yesCurrency = new MockMintableERC20("YES_CURR", "YCURR");
        MockMintableERC20 noCurrency = new MockMintableERC20("NO_CURR", "NCURR");

        bytes32 conditionId = keccak256(abi.encodePacked("cond", proposals.length));
        proposal = address(
            new MockFutarchyProposalLike(
                params.collateralToken1,
                params.collateralToken2,
                conditionId,
                address(yesCompany),
                address(noCompany),
                address(yesCurrency),
                address(noCurrency)
            )
        );

        proposals.push(proposal);
    }
}

