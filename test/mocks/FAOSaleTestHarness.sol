// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOSale} from "../../src/FAOSale.sol";
import {FAOToken} from "../../src/FAOToken.sol";

/// @notice Test-only extension for fast end-to-end lifecycle tests.
contract FAOSaleTestHarness is FAOSale {
    constructor(
        FAOToken _token,
        uint256 _minInitialPhaseSold,
        uint256 _initialPhaseDuration,
        address _admin,
        address _incentive,
        address _insider
    ) FAOSale(_token, _minInitialPhaseSold, _initialPhaseDuration, _admin, _incentive, _insider) {}

    function forceFinalizeInitialPhaseForTests() external onlyAdmin {
        require(saleStart != 0, "Sale not started");
        require(!initialPhaseFinalized, "already finalized");

        initialPhaseEnd = block.timestamp;
        initialPhaseFinalized = true;
        initialNetSale = initialTokensSold;

        _mintToPools(initialNetSale);
    }
}
