// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaoToken} from "../../src/FaoToken.sol";
import {FaoPriceBeacon, IBeaconPoolFactory, IBeaconVault} from "../../src/FaoPriceBeacon.sol";
import {FaoTeamOptions, IOptionsBeacon, IOptionsVault} from "../../src/FaoTeamOptions.sol";
import {FaoShortFacility, IShortBeacon, IShortVault} from "../../src/FaoShortFacility.sol";
import {MockWETH, MockPool, MockFactory, MockVault} from "./IssuanceMocks.sol";

abstract contract Base is Test {
    uint256 internal constant WAD = 1e18;
    int24 internal constant DOUBLING = 6940; // a little over one price doubling in ticks
    uint256 internal constant SOLD = 1_000_000e18;

    MockWETH internal weth;
    MockPool internal pool;
    MockFactory internal factory;
    FaoPriceBeacon internal beacon;
    FaoTeamOptions internal options;
    FaoShortFacility internal shorts;
    MockVault internal vault;
    FaoToken internal token;

    address internal team = address(0x7EA11);
    address internal buyer = address(0xB0B);
    address internal shorter = address(0x5407);
    address internal stranger = address(0xBEEF);

    int24 internal baseTick;
    int24 internal up; // +1 if a higher tick means a higher FAO price, else -1
    uint256 internal base;

    function _deploy(uint16 strikeBps) internal {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        pool = new MockPool();
        factory = new MockFactory();
        factory.setPool(address(pool));

        beacon = new FaoPriceBeacon(IBeaconPoolFactory(address(factory)), address(weth), 500);
        options = new FaoTeamOptions(IOptionsBeacon(address(beacon)), team, 3000, strikeBps);
        shorts = new FaoShortFacility(IShortBeacon(address(beacon)), 20_000, 100, 180 days, 7, 5000);
        vault = new MockVault(IERC20(address(weth)), address(options), address(shorts));
        token = vault.token();

        beacon.bind(IBeaconVault(address(vault)));
        options.bind(IOptionsVault(address(vault)));
        shorts.bind(IShortVault(address(vault)));

        up = address(token) < address(weth) ? int24(1) : int24(-1);
        baseTick = up * int24(-115_000); // about 1e-5 WETH per FAO
        pool.setTick(baseTick);
        base = beacon.twap();

        // Genesis: 1,000,000 FAO sold, closing price = the pool's opening price.
        vault.mintTo(buyer, SOLD);
        weth.mint(address(vault), SOLD * base / WAD);
        vault.goLive(SOLD, base);
        options.activate();
    }

    function _setMultiple(uint256 doublings) internal {
        pool.setTick(baseTick + up * DOUBLING * int24(int256(doublings)));
    }

    /// @dev Takes a checkpoint now if one is due, then one a day for `n` days at the current
    /// pool price: `n` day-long intervals.
    function _pokeDays(uint256 n) internal {
        beacon.poke();
        for (uint256 i; i < n; ++i) {
            skip(1 days);
            beacon.poke();
        }
    }

    function _fund(address who, uint256 amount, address spender) internal {
        weth.mint(who, amount);
        vm.prank(who);
        weth.approve(spender, type(uint256).max);
    }
}
