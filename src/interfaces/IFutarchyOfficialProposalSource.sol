// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraFactoryLike} from "./IAlgebraFactoryLike.sol";

interface IFutarchyOfficialProposalSource {
    function ALGEBRA_FACTORY() external view returns (IAlgebraFactoryLike);

    struct OfficialProposalData {
        uint256 proposalId;
        address proposal;
        address creator;
        bool exists;
        bool settled;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
    }

    function officialProposal()
        external
        view
        returns (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPool,
            address noPool
        );

    function officialProposalExtended()
        external
        view
        returns (OfficialProposalData memory proposalData);
}
