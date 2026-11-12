// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./mocks/IssuanceBase.sol";
import {FaoTeamOptions, IOptionsBeacon, IOptionsVault} from "../src/FaoTeamOptions.sol";
import {FaoToken} from "../src/FaoToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A minimal contract holder: it can exercise and hand the whole right to another address.
contract OptionHolder {
    FaoTeamOptions internal immutable options;

    constructor(FaoTeamOptions options_, IERC20 weth) {
        options = options_;
        weth.approve(address(options_), type(uint256).max);
    }

    function exercise(uint256 k, uint256 amount, address to) external {
        options.exercise(k, amount, to, type(uint256).max);
    }

    function pass(address to) external {
        options.transferHolder(to);
    }
}

contract FaoTeamOptionsTest is Base {
    uint256 internal tranche; // 3% of tokens sold

    function setUp() public {
        _deploy(10_000);
        tranche = SOLD * 300 / 10_000;
        _fund(team, 1_000_000 ether, address(options));
    }

    // ---------------------------------------------------------------- genesis

    function test_nothingIsMintedAtGenesis() public {
        assertEq(token.totalSupply(), SOLD);
        assertEq(token.optionMinted(), 0);
        assertEq(options.trancheSize(), tranche);
        assertEq(options.basePrice(), base);
        assertEq(options.strike(), base);
        assertEq(options.holder(), team);
        for (uint256 k; k < 10; ++k) {
            assertEq(options.level(k), base << (k + 1));
            assertEq(options.exercisable(k), 0);
        }
    }

    function test_onlyOptionIssuerCanMint() public {
        vm.expectRevert(FaoToken.OnlyOptionIssuer.selector);
        token.issueOption(team, 1);
        vm.prank(team);
        vm.expectRevert(FaoToken.OnlyOptionIssuer.selector);
        token.issueOption(team, 1);
    }

    function test_bindAndActivateAreOneShot() public {
        vm.expectRevert(FaoTeamOptions.AlreadyBound.selector);
        options.bind(IOptionsVault(address(vault)));
        vm.expectRevert(FaoTeamOptions.AlreadyActivated.selector);
        options.activate();
        vm.prank(stranger);
        vm.expectRevert(FaoTeamOptions.OnlyBinder.selector);
        options.bind(IOptionsVault(address(vault)));
    }

    // ---------------------------------------------------------------- opening a tranche

    function test_trancheDoesNotOpenBelowLevel() public {
        _pokeDays(40); // 40 days at the base price
        vm.expectRevert(FaoTeamOptions.NotHeld.selector);
        options.open(0);
    }

    function test_trancheNeedsThirtyCompleteDays() public {
        _setMultiple(1);
        _pokeDays(29);
        beacon.poke(); // day 30 is today and not complete
        vm.expectRevert(FaoTeamOptions.NotHeld.selector);
        options.open(0);
        skip(1 days);
        options.open(0);
        assertGt(options.openedAt(0), 0);
        vm.expectRevert(FaoTeamOptions.AlreadyOpen.selector);
        options.open(0);
    }

    function test_oneDayDipBlocksOpening() public {
        _setMultiple(1);
        _pokeDays(15);
        _setMultiple(0); // anyone pokes during a dip
        beacon.poke();
        _setMultiple(1);
        beacon.poke(); // same day, back up: the day's low stays at the dip
        skip(1 days);
        _pokeDays(15);
        vm.expectRevert(FaoTeamOptions.NotHeld.selector);
        options.open(0);
        _pokeDays(15); // 30 clean days after the dip
        options.open(0);
    }

    function test_unrecordedDayBlocksOpening() public {
        _setMultiple(1);
        _pokeDays(10);
        skip(1 days); // nobody poked this day
        _pokeDays(20);
        vm.expectRevert(FaoTeamOptions.NotHeld.selector);
        options.open(0);
    }

    function test_holdingTwoXOpensOnlyTheFirstTranche() public {
        _setMultiple(1);
        _pokeDays(30);
        options.open(0);
        vm.expectRevert(FaoTeamOptions.NotHeld.selector);
        options.open(1);
    }

    function test_holdingThousandXOpensAllTen() public {
        _setMultiple(10);
        _pokeDays(30);
        for (uint256 k; k < 10; ++k) {
            options.open(k);
        }
    }

    function test_anyoneCanOpenAndPoke() public {
        _setMultiple(1);
        vm.startPrank(stranger);
        _pokeDays(30);
        options.open(0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- vesting

    function _openFirst() internal {
        _setMultiple(1);
        _pokeDays(30);
        options.open(0);
    }

    function test_nothingExercisableBeforeTheCliff() public {
        _openFirst();
        skip(300 days); // day 330 after genesis
        assertEq(options.exercisable(0), 0);
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.ExceedsExercisable.selector);
        options.exercise(0, 1, team, type(uint256).max);
    }

    function test_vestsLinearlyOverAYearAfterTheCliff() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 365 days);
        assertEq(options.exercisable(0), 0);
        skip(73 days); // one fifth of the vesting year
        assertEq(options.exercisable(0), tranche / 5);
        skip(365 days);
        assertEq(options.exercisable(0), tranche);
    }

    function test_trancheOpenedAfterTheCliffVestsFromItsOpening() public {
        vm.warp(uint256(options.genesisAt()) + 500 days);
        _openFirst();
        assertEq(options.exercisable(0), 0);
        skip(365 days / 2);
        assertApproxEqAbs(options.exercisable(0), tranche / 2, 1e12);
    }

    // ---------------------------------------------------------------- exercise

    function test_exercisePaysTheStrikeToTheTreasuryAndMints() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 730 days);
        uint256 treasuryBefore = weth.balanceOf(address(vault));
        uint256 teamBefore = weth.balanceOf(team);

        vm.prank(team);
        uint256 cost = options.exercise(0, tranche, team, type(uint256).max);

        assertEq(cost, tranche * base / WAD);
        assertEq(weth.balanceOf(address(vault)) - treasuryBefore, cost);
        assertEq(teamBefore - weth.balanceOf(team), cost);
        assertEq(token.balanceOf(team), tranche);
        assertEq(token.optionMinted(), tranche);
        assertEq(options.exercisable(0), 0);
    }

    function test_exerciseNeverLowersWethPerToken() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 730 days);
        uint256 beforePerToken = weth.balanceOf(address(vault)) * WAD / vault.effectiveSupply();
        vm.prank(team);
        options.exercise(0, tranche, team, type(uint256).max);
        uint256 afterPerToken = weth.balanceOf(address(vault)) * WAD / vault.effectiveSupply();
        assertGe(afterPerToken, beforePerToken);
    }

    function test_onlyTheHolderCanExercise() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 730 days);
        _fund(stranger, 100 ether, address(options));
        vm.prank(stranger);
        vm.expectRevert(FaoTeamOptions.OnlyHolder.selector);
        options.exercise(0, 1e18, stranger, type(uint256).max);
    }

    function test_maxCostProtectsTheHolder() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 730 days);
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.CostExceedsMax.selector);
        options.exercise(0, tranche, team, 1);
    }

    function test_optionsLapseAfterTenYears() public {
        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 3650 days);
        assertEq(options.exercisable(0), 0);
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.Expired.selector);
        options.exercise(0, 1, team, type(uint256).max);
        vm.expectRevert(FaoTeamOptions.Expired.selector);
        options.open(1);
    }

    function test_fullPoolIsThirtyPercentOfSold() public {
        _setMultiple(10);
        _pokeDays(30);
        for (uint256 k; k < 10; ++k) {
            options.open(k);
        }
        vm.warp(uint256(options.genesisAt()) + 730 days);
        vm.startPrank(team);
        for (uint256 k; k < 10; ++k) {
            options.exercise(k, tranche, team, type(uint256).max);
        }
        vm.stopPrank();
        assertEq(token.optionMinted(), SOLD * 3000 / 10_000);
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.ExceedsExercisable.selector);
        options.exercise(0, 1, team, type(uint256).max);
    }

    function testFuzz_neverMintsMoreThanHasVested(uint256 elapsed, uint256 first, uint256 second)
        public
    {
        _openFirst();
        elapsed = bound(elapsed, 1, 800 days);
        vm.warp(uint256(options.genesisAt()) + 365 days + elapsed);
        first = bound(first, 0, options.exercisable(0));
        vm.startPrank(team);
        if (first != 0) options.exercise(0, first, team, type(uint256).max);
        second = bound(second, 0, options.exercisable(0));
        if (second != 0) options.exercise(0, second, team, type(uint256).max);
        vm.stopPrank();
        assertEq(token.optionMinted(), first + second);
        assertLe(options.exercised(0), options.vested(0));
        assertLe(options.vested(0), tranche);
    }

    // ---------------------------------------------------------------- the holder

    function test_onlyTheHolderCanHandTheRightOn() public {
        vm.prank(stranger);
        vm.expectRevert(FaoTeamOptions.OnlyHolder.selector);
        options.transferHolder(stranger);
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.InvalidConfig.selector);
        options.transferHolder(address(0));
    }

    function test_contractCanHoldExerciseAndPassTheRightOn() public {
        OptionHolder first = new OptionHolder(options, weth);
        OptionHolder second = new OptionHolder(options, weth);
        vm.prank(team);
        options.transferHolder(address(first));
        assertEq(options.holder(), address(first));

        // The previous holder has no rights left.
        vm.prank(team);
        vm.expectRevert(FaoTeamOptions.OnlyHolder.selector);
        options.transferHolder(team);

        _openFirst();
        vm.warp(uint256(options.genesisAt()) + 730 days);
        weth.mint(address(first), 1000 ether);
        first.exercise(0, tranche / 2, address(first));
        assertEq(token.balanceOf(address(first)), tranche / 2);

        // The contract hands the rest to a second contract, which exercises it.
        first.pass(address(second));
        assertEq(options.holder(), address(second));
        vm.expectRevert(FaoTeamOptions.OnlyHolder.selector);
        first.exercise(0, 1, address(first));

        weth.mint(address(second), 1000 ether);
        assertEq(options.exercisable(0), tranche / 2);
        second.exercise(0, tranche / 2, address(second));
        assertEq(token.balanceOf(address(second)), tranche / 2);
        assertEq(options.exercisable(0), 0);
    }

    // ---------------------------------------------------------------- strike zero (2025 design)

    function test_zeroStrikeVariantMintsFree() public {
        _deploy(0);
        _fund(team, 1 ether, address(options));
        _setMultiple(1);
        _pokeDays(30);
        options.open(0);
        vm.warp(uint256(options.genesisAt()) + 730 days);
        uint256 teamBefore = weth.balanceOf(team);
        vm.prank(team);
        uint256 cost = options.exercise(0, SOLD * 300 / 10_000, team, 0);
        assertEq(cost, 0);
        assertEq(weth.balanceOf(team), teamBefore);
        assertEq(token.balanceOf(team), SOLD * 300 / 10_000);
    }
}
