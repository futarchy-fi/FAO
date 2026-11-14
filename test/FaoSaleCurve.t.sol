// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FaoSaleCurve} from "../src/FaoSaleCurve.sol";
import {newBoundCurve} from "./mocks/SaleCurveFixture.sol";

contract FaoSaleCurveTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant P0 = 1e13; // 1 ETH = 100,000 FAO
    uint256 internal constant MINIMUM = 10_000_000e18; // 100 ETH at the fixed price
    uint64 internal end;
    FaoSaleCurve internal curve;

    function test_bindIsOneShotByTheDeployerAndTheVaultAloneSyncs() public {
        FaoSaleCurve fresh = new FaoSaleCurve(P0, 1e9, 0, 0);
        assertEq(fresh.vault(), address(0));
        vm.expectRevert(FaoSaleCurve.OnlyVault.selector);
        fresh.sync(0); // nobody can drive an unbound curve

        vm.prank(address(0xBEEF));
        vm.expectRevert(FaoSaleCurve.OnlyBinder.selector);
        fresh.bind(address(0xBEEF));
        vm.expectRevert(FaoSaleCurve.InvalidConfig.selector);
        fresh.bind(address(0));

        fresh.bind(address(0xA11CE));
        assertEq(fresh.vault(), address(0xA11CE));
        vm.expectRevert(FaoSaleCurve.AlreadyBound.selector);
        fresh.bind(address(this));
        vm.prank(address(0xA11CE));
        fresh.sync(0);
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        end = uint64(block.timestamp + 14 days);
        curve = newBoundCurve(address(this), P0, 0, end, MINIMUM);
    }

    // ---------------------------------------------------------------- fixed-price window

    function test_everyTokenCostsTheSameInsideTheWindow() public {
        assertEq(curve.priceAt(0), P0);
        assertEq(curve.priceAt(1_000_000_000e18), P0);
        assertEq(curve.cost(0, 100_000e18), 1 ether);
        assertEq(curve.cost(500_000_000e18, 100_000e18), 1 ether); // uncapped, still 1 ETH
    }

    function test_syncDoesNothingInsideTheWindow() public {
        curve.sync(123e18);
        assertEq(curve.base(), 0);
        assertFalse(curve.started());
    }

    function test_configMustBeOneOfTheTwoShapes() public {
        vm.expectRevert(FaoSaleCurve.InvalidConfig.selector);
        new FaoSaleCurve(P0, 1, end, MINIMUM); // a window cannot carry an explicit slope
        vm.expectRevert(FaoSaleCurve.InvalidConfig.selector);
        new FaoSaleCurve(P0, 0, end, 0); // a window needs a minimum
        vm.expectRevert(FaoSaleCurve.InvalidConfig.selector);
        new FaoSaleCurve(0, 0, 0, 0);
    }

    // ---------------------------------------------------------------- plain linear curve

    function testFuzz_plainLinearCurveMatchesTheOriginalVaultFormula(
        uint256 p0,
        uint256 slope,
        uint256 supply
    ) public {
        p0 = bound(p0, 1, 1e24);
        slope = bound(slope, 0, 1e18);
        supply = bound(supply, 0, 1e27);
        FaoSaleCurve linear = newBoundCurve(address(this), p0, slope, 0, 0);
        linear.sync(0);
        uint256 linearTerm = 2 * p0 * WAD + slope * supply;
        uint256 expected = supply * linearTerm / (2 * WAD * WAD);
        if (mulmod(supply, linearTerm, 2 * WAD * WAD) != 0) expected += 1;
        assertEq(linear.reserveAt(supply, 0), expected);
        assertEq(linear.reserveAt(supply, supply), expected);
        assertEq(linear.priceAt(supply), p0 + slope * supply / WAD);
    }

    function test_onlyTheVaultCanSync() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(FaoSaleCurve.OnlyVault.selector);
        curve.sync(1);
    }

    // ---------------------------------------------------------------- curve

    function test_curveStartsFromWhatWasSoldAtTheFixedPrice() public {
        uint256 sold = 50_000_000e18; // 500 ETH raised in the window
        vm.warp(end);
        curve.sync(sold);
        assertEq(curve.base(), sold);
        assertEq(curve.priceAt(sold), P0);
        assertEq(curve.priceAt(2 * sold), 2 * P0); // supply doubled, price doubled
        assertEq(curve.priceAt(4 * sold), 4 * P0);
    }

    function test_baseIsWrittenOnce() public {
        vm.warp(end);
        curve.sync(50_000_000e18);
        curve.sync(90_000_000e18);
        assertEq(curve.base(), 50_000_000e18);
    }

    function test_belowTheMinimumTheFixedPriceContinuesAfterTheWindow() public {
        uint256 sold = 1_000_000e18; // only 10 ETH raised in the window
        vm.warp(end + 30 days);
        curve.sync(sold);
        assertEq(curve.base(), MINIMUM);
        assertEq(curve.priceAt(sold), P0);
        assertEq(curve.cost(sold, MINIMUM - sold), (MINIMUM - sold) * P0 / WAD);
        assertEq(curve.priceAt(2 * MINIMUM), 2 * P0);
    }

    function test_doublingTheSupplyCostsOneAndAHalfTimesTheFixedRaise() public {
        uint256 sold = 50_000_000e18;
        vm.warp(end);
        curve.sync(sold);
        // Integral of p0*x/base from base to 2*base = 1.5 * p0 * base.
        assertEq(curve.cost(sold, sold), 750 ether);
    }

    function test_quoteBeforeSyncMatchesAfterSync() public {
        uint256 sold = 50_000_000e18;
        vm.warp(end + 1);
        uint256 quoted = curve.cost(sold, 7_000_000e18);
        curve.sync(sold);
        assertEq(curve.cost(sold, 7_000_000e18), quoted);
    }

    function test_maxPriceBoundsEveryReachablePrice() public {
        uint256 cap = 8 * MINIMUM;
        assertEq(curve.maxPrice(MINIMUM), P0);
        assertEq(curve.maxPrice(cap), 8 * P0); // lowest possible base gives the steepest curve
        vm.warp(end);
        curve.sync(3 * MINIMUM);
        assertLe(curve.priceAt(cap), curve.maxPrice(cap));

        FaoSaleCurve linear = newBoundCurve(address(this), P0, 1e9, 0, 0);
        assertEq(linear.maxPrice(cap), linear.priceAt(cap));
    }

    // ---------------------------------------------------------------- properties

    function testFuzz_splittingAPurchaseNeverPaysLess(uint256 sold, uint256 a, uint256 b) public {
        sold = bound(sold, 0, 1e27);
        a = bound(a, 1, 1e27);
        b = bound(b, 1, 1e27);
        vm.warp(end);
        curve.sync(sold);
        uint256 whole = curve.cost(sold, a + b);
        uint256 parts = curve.cost(sold, a) + curve.cost(sold + a, b);
        assertGe(parts + 1, whole); // identical up to one wei of rounding
        assertLe(parts, whole + 1);
    }

    function testFuzz_priceNeverFallsAsMoreIsSold(uint256 sold, uint256 s1, uint256 s2) public {
        sold = bound(sold, 0, 1e27);
        s1 = bound(s1, 0, 1e28);
        s2 = bound(s2, s1, 1e28);
        vm.warp(end);
        curve.sync(sold);
        assertLe(curve.priceAt(s1), curve.priceAt(s2));
        assertGe(curve.priceAt(s1), P0);
    }

    function testFuzz_costIsAtLeastTheFixedPriceAndAtMostTheEndPrice(uint256 sold, uint256 amount)
        public
    {
        sold = bound(sold, 0, 1e27);
        amount = bound(amount, 1e6, 1e27);
        vm.warp(end);
        curve.sync(sold);
        uint256 paid = curve.cost(sold, amount);
        assertGe(paid, amount * P0 / WAD);
        assertLe(paid, amount * curve.priceAt(sold + amount) / WAD + 2);
    }
}
