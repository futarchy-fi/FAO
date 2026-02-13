// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockFutarchyProposalLike {
    address public collateralToken1;
    address public collateralToken2;
    address[4] public wrappedOutcomes;

    constructor(
        address _collateralToken1,
        address _collateralToken2,
        address yesComp,
        address noComp,
        address yesCurr,
        address noCurr
    ) {
        collateralToken1 = _collateralToken1;
        collateralToken2 = _collateralToken2;
        wrappedOutcomes[0] = yesComp;
        wrappedOutcomes[1] = noComp;
        wrappedOutcomes[2] = yesCurr;
        wrappedOutcomes[3] = noCurr;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (wrappedOutcomes[index], "");
    }
}
