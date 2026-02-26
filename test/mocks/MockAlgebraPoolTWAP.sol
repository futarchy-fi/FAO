// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock Algebra pool for TWAP oracle unit tests.
/// Allows setting controlled tick cumulatives and simulating reverts.
contract MockAlgebraPoolTWAP {
    address public token0;
    address public token1;

    int56[] internal _tickCumulatives;
    bool public shouldRevert;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setTickCumulatives(int56 cumulative0, int56 cumulative1)
        external
    {
        delete _tickCumulatives;
        _tickCumulatives.push(cumulative0);
        _tickCumulatives.push(cumulative1);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getTimepoints(uint32[] calldata)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulatives,
            uint112[] memory volatilityCumulatives,
            uint256[] memory volumePerAvgLiquiditys
        )
    {
        require(!shouldRevert, "MockAlgebraPoolTWAP: revert");

        uint256 len = _tickCumulatives.length;
        tickCumulatives = new int56[](len);
        for (uint256 i = 0; i < len; i++) {
            tickCumulatives[i] = _tickCumulatives[i];
        }

        secondsPerLiquidityCumulatives = new uint160[](len);
        volatilityCumulatives = new uint112[](len);
        volumePerAvgLiquiditys = new uint256[](len);
    }
}

/// @notice Mock pool that burns all gas on getTimepoints (for gas griefing
/// tests). Uses an infinite loop to exhaust the forwarded gas.
contract GasGriefingAlgebraPool {
    address public token0;
    address public token1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getTimepoints(uint32[] calldata)
        external
        view
        returns (
            int56[] memory,
            uint160[] memory,
            uint112[] memory,
            uint256[] memory
        )
    {
        // Burn all forwarded gas via infinite loop to simulate OOG.
        uint256 i;
        while (true) {
            i++;
        }
    }
}
