// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaoPriceBeacon, IBeaconPoolFactory, IBeaconVault} from "../src/FaoPriceBeacon.sol";
import {FaoTeamOptions, IOptionsBeacon, IOptionsVault} from "../src/FaoTeamOptions.sol";
import {FaoShortFacility, IShortBeacon} from "../src/FaoShortFacility.sol";
import {MockWETH, MockPool, MockFactory, MockVault} from "./mocks/IssuanceMocks.sol";

/// @dev Before the sale finalizes the pool is empty, so its price can be set for free. The beacon
/// must not record anything then, or all team tranches could be opened with a faked history.
contract FaoPriceBeaconTest is Test {
    MockWETH internal weth;
    MockPool internal pool;
    MockFactory internal factory;
    FaoPriceBeacon internal beacon;
    FaoTeamOptions internal options;
    MockVault internal vault;
    int24 internal up;

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        pool = new MockPool();
        factory = new MockFactory();
        factory.setPool(address(pool));
        beacon = new FaoPriceBeacon(IBeaconPoolFactory(address(factory)), address(weth), 500);
        options =
            new FaoTeamOptions(IOptionsBeacon(address(beacon)), address(0x7EA11), 3000, 10_000);
        FaoShortFacility shorts =
            new FaoShortFacility(IShortBeacon(address(beacon)), 20_000, 100, 180 days, 7, 5000);
        vault = new MockVault(IERC20(address(weth)), address(options), address(shorts));
        beacon.bind(IBeaconVault(address(vault)));
        options.bind(IOptionsVault(address(vault)));
        up = address(vault.token()) < address(weth) ? int24(1) : int24(-1);
    }

    function test_bindIsOneShotAndOnlyByTheDeployer() public {
        vm.expectRevert(FaoPriceBeacon.AlreadyBound.selector);
        beacon.bind(IBeaconVault(address(vault)));
        FaoPriceBeacon fresh =
            new FaoPriceBeacon(IBeaconPoolFactory(address(factory)), address(weth), 500);
        vm.prank(address(0xBEEF));
        vm.expectRevert(FaoPriceBeacon.OnlyBinder.selector);
        fresh.bind(IBeaconVault(address(vault)));
    }

    function test_nothingIsRecordedBeforeTheSaleIsLive() public {
        pool.setTick(up * int24(-115_000 + 6940 * 10)); // free to set while the pool is empty
        for (uint256 i; i < 40; ++i) {
            vm.expectRevert(FaoPriceBeacon.NotLive.selector);
            beacon.poke();
            skip(1 days);
        }
        (bool recorded,,) = beacon.dayRecord(beacon.today() - 1);
        assertFalse(recorded);
    }

    function test_fakedPreLiveHistoryCannotOpenTranches() public {
        int24 baseTick = up * int24(-115_000);
        pool.setTick(baseTick + up * int24(6940 * 10)); // attacker shows 1024x for 40 days pre-LIVE
        for (uint256 i; i < 40; ++i) {
            try beacon.poke() {} catch {}
            skip(1 days);
        }
        // The sale finalizes at the real price.
        pool.setTick(baseTick);
        vault.mintTo(address(0xB0B), 1_000_000e18);
        vault.goLive(1_000_000e18, beacon.twap());
        options.activate();
        beacon.poke();
        skip(1 days);
        for (uint256 k; k < 10; ++k) {
            vm.expectRevert(FaoTeamOptions.NotHeld.selector);
            options.open(k);
        }
    }

    function test_lowAndHighOfTheDay() public {
        int24 baseTick = up * int24(-115_000);
        pool.setTick(baseTick);
        vault.goLive(1e18, 1);
        uint256 p1 = beacon.poke();
        pool.setTick(baseTick + up * 6940);
        uint256 p2 = beacon.poke();
        pool.setTick(baseTick - up * 6940);
        uint256 p3 = beacon.poke();
        (bool recorded, uint256 low, uint256 high) = beacon.dayRecord(beacon.today());
        assertTrue(recorded);
        assertEq(low, p3);
        assertEq(high, p2);
        assertLt(p3, p1);
        assertLt(p1, p2);
        assertEq(beacon.highOver(7), p2);
        skip(8 days);
        assertEq(beacon.highOver(7), 0);
    }

    function test_ringForgetsDaysOlderThanItsSize() public {
        pool.setTick(up * int24(-115_000));
        vault.goLive(1e18, 1);
        beacon.poke();
        uint64 first = beacon.today();
        skip(64 days);
        beacon.poke(); // same slot, new day
        (bool recorded,,) = beacon.dayRecord(first);
        assertFalse(recorded);
        assertFalse(beacon.heldAbove(1, 64));
    }
}
