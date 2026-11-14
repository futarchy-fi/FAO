// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaoPriceBeacon, IBeaconPoolFactory, IBeaconVault} from "../src/FaoPriceBeacon.sol";
import {FaoTeamOptions, IOptionsBeacon, IOptionsVault} from "../src/FaoTeamOptions.sol";
import {FaoShortFacility, IShortBeacon, IShortVault} from "../src/FaoShortFacility.sol";
import {MockWETH, MockPool, MockFactory, MockVault, ImpostorVault} from "./mocks/IssuanceMocks.sol";

contract FaoPriceBeaconTest is Test {
    int24 internal constant DOUBLING = 6940;

    MockWETH internal weth;
    MockPool internal pool;
    MockFactory internal factory;
    FaoPriceBeacon internal beacon;
    FaoTeamOptions internal options;
    MockVault internal vault;
    int24 internal up;
    int24 internal baseTick;

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
        baseTick = up * int24(-115_000);
        pool.setTick(baseTick);
    }

    function _live() internal returns (uint256 basePrice) {
        basePrice = beacon.twap();
        vault.mintTo(address(0xB0B), 1_000_000e18);
        vault.goLive(1_000_000e18, basePrice);
    }

    function _days(uint256 n) internal {
        beacon.poke();
        for (uint256 i; i < n; ++i) {
            skip(1 days);
            beacon.poke();
        }
    }

    // ---------------------------------------------------------------- wiring

    function test_bindIsOneShotAndOnlyByTheDeployer() public {
        vm.expectRevert(FaoPriceBeacon.AlreadyBound.selector);
        beacon.bind(IBeaconVault(address(vault)));
        FaoPriceBeacon fresh =
            new FaoPriceBeacon(IBeaconPoolFactory(address(factory)), address(weth), 500);
        vm.prank(address(0xBEEF));
        vm.expectRevert(FaoPriceBeacon.OnlyBinder.selector);
        fresh.bind(IBeaconVault(address(vault)));
    }

    function test_modulesRefuseAVaultThatTheTokenDoesNotName() public {
        FaoPriceBeacon beacon2 =
            new FaoPriceBeacon(IBeaconPoolFactory(address(factory)), address(weth), 500);
        FaoTeamOptions options2 =
            new FaoTeamOptions(IOptionsBeacon(address(beacon2)), address(0x7EA11), 3000, 10_000);
        FaoShortFacility shorts2 =
            new FaoShortFacility(IShortBeacon(address(beacon2)), 20_000, 100, 180 days, 7, 5000);
        MockVault real = new MockVault(IERC20(address(weth)), address(options2), address(shorts2));
        // Points at the real token, whose issuers are the modules above, but is not its vault.
        ImpostorVault impostor = new ImpostorVault(real.COMPANY_TOKEN(), address(weth));

        vm.expectRevert(FaoPriceBeacon.InvalidToken.selector);
        beacon2.bind(IBeaconVault(address(impostor)));
        beacon2.bind(IBeaconVault(address(real)));

        vm.expectRevert(FaoTeamOptions.InvalidConfig.selector);
        options2.bind(IOptionsVault(address(impostor)));
        vm.expectRevert(FaoShortFacility.InvalidConfig.selector);
        shorts2.bind(IShortVault(address(impostor)));

        options2.bind(IOptionsVault(address(real)));
        shorts2.bind(IShortVault(address(real)));
    }

    // ---------------------------------------------------------------- before the sale is live

    function test_nothingIsRecordedBeforeTheSaleIsLive() public {
        pool.setTick(baseTick + up * DOUBLING * 10); // free to set while the pool is empty
        for (uint256 i; i < 40; ++i) {
            vm.expectRevert(FaoPriceBeacon.NotLive.selector);
            beacon.poke();
            skip(1 days);
        }
        assertEq(beacon.intervalCount(), 0);
        assertEq(beacon.checkpointAt(), 0);
    }

    function test_fakedPreLiveHistoryCannotOpenTranches() public {
        pool.setTick(baseTick + up * DOUBLING * 10); // attacker shows 1024x for 40 days pre-LIVE
        for (uint256 i; i < 40; ++i) {
            try beacon.poke() {} catch {}
            skip(1 days);
        }
        pool.setTick(baseTick); // the sale finalizes at the real price
        _live();
        options.activate();
        _days(1);
        for (uint256 k; k < 10; ++k) {
            vm.expectRevert(FaoTeamOptions.NotHeld.selector);
            options.open(k);
        }
    }

    // ---------------------------------------------------------------- intervals

    function test_anIntervalAveragesEverySecondNotTheMomentOfThePoke() public {
        uint256 basePrice = _live();
        beacon.poke();
        pool.setTick(baseTick + up * DOUBLING); // 2x for six hours of the day
        skip(6 hours);
        pool.setTick(baseTick);
        skip(18 hours);
        beacon.poke();

        (uint256 start, uint256 end, uint256 price) = beacon.interval(0);
        assertEq(end - start, 1 days);
        // A quarter of the day at 2x gives a geometric mean of 2^(1/4) = 1.189x.
        assertGt(price, basePrice * 118 / 100);
        assertLt(price, basePrice * 120 / 100);
    }

    function test_pokeInsideThePeriodDoesNothing() public {
        _live();
        beacon.poke();
        uint256 first = beacon.checkpointAt();
        skip(12 hours);
        beacon.poke();
        assertEq(beacon.checkpointAt(), first);
        assertEq(beacon.intervalCount(), 0);
    }

    function test_heldAboveNeedsEveryIntervalAndAFreshCheckpoint() public {
        uint256 basePrice = _live();
        _days(30);
        assertTrue(beacon.heldAbove(basePrice, 30));
        assertFalse(beacon.heldAbove(basePrice, 31));
        assertFalse(beacon.heldAbove(basePrice + basePrice / 100, 30));
        skip(2 days + 1);
        assertFalse(beacon.heldAbove(basePrice, 30)); // stale
    }

    function test_highOverIgnoresIntervalsOlderThanTheLookback() public {
        uint256 basePrice = _live();
        pool.setTick(baseTick + up * DOUBLING * 3);
        _days(1);
        pool.setTick(baseTick);
        assertGt(beacon.highOver(7), 7 * basePrice);
        _days(8);
        assertEq(beacon.highOver(7), basePrice);
    }

    function test_ringKeepsTheLastSixtyFourIntervals() public {
        uint256 basePrice = _live();
        _days(70);
        assertEq(beacon.intervalCount(), 70);
        vm.expectRevert(FaoPriceBeacon.InvalidPrice.selector);
        beacon.interval(5);
        (,, uint256 price) = beacon.interval(69);
        assertEq(price, basePrice);
        assertTrue(beacon.heldAbove(basePrice, 60));
        assertFalse(beacon.heldAbove(basePrice, 65));
    }
}
