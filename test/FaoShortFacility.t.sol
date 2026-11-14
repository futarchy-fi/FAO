// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./mocks/IssuanceBase.sol";
import {FaoShortFacility} from "../src/FaoShortFacility.sol";
import {FaoToken} from "../src/FaoToken.sol";

contract FaoShortFacilityTest is Base {
    uint256 internal constant N = 10_000e18;

    function setUp() public {
        _deploy(10_000);
        _fund(shorter, 1_000_000 ether, address(shorts));
        vm.prank(shorter);
        token.approve(address(shorts), type(uint256).max);
    }

    function _open(uint256 amount) internal returns (uint256 id, uint256 lock) {
        vm.prank(shorter);
        (id, lock) = shorts.open(amount, type(uint256).max, shorter);
    }

    /// @dev WETH one token redeems by ragequit: treasury plus the short pool, over the supply.
    function _ragequitValue() internal view returns (uint256) {
        return (weth.balanceOf(address(vault)) + shorts.pooled()) * WAD / vault.effectiveSupply();
    }

    function _lockOf(uint256 id) internal view returns (uint256 lock) {
        (,,, lock) = shorts.position(id);
    }

    // ---------------------------------------------------------------- open

    function test_openLocksTwiceThePriceAndMints() public {
        (uint256 id, uint256 lock) = _open(N);
        assertEq(id, 0);
        assertEq(lock, N * 2 * base / WAD);
        assertEq(token.balanceOf(shorter), N);
        assertEq(token.shortOutstanding(), N);
        assertEq(weth.balanceOf(address(shorts)), lock);
        assertEq(shorts.pooled(), lock);
        assertEq(_lockOf(id), lock);
    }

    function test_onlyShortIssuerCanMintOrSettle() public {
        vm.expectRevert(FaoToken.OnlyShortIssuer.selector);
        token.issueShort(shorter, 1);
        vm.expectRevert(FaoToken.OnlyShortIssuer.selector);
        token.closeShort(1);
        vm.expectRevert(FaoToken.OnlyShortIssuer.selector);
        token.forfeitShort(1);
    }

    function test_lockFollowsARisingPrice() public {
        _setMultiple(3); // 8x
        (, uint256 lock) = _open(N);
        assertGe(lock, N * 16 * base / WAD);
    }

    function test_pushedDownPriceDoesNotCheapenTheLock() public {
        _setMultiple(3);
        beacon.poke();
        skip(2 days);
        _setMultiple(0); // price pushed back to 1x for the 30-minute window
        (, uint256 lock) = _open(N);
        assertGe(lock, N * 16 * base / WAD); // still locks against the recorded 8x average
    }

    function test_oldHighsStopCountingAfterTheLookback() public {
        _setMultiple(3);
        beacon.poke();
        skip(1 days);
        beacon.poke(); // one day at 8x is on record
        _setMultiple(0);
        skip(8 days);
        (, uint256 lock) = _open(N); // the 8x day ended more than seven days ago
        assertEq(lock, N * 2 * base / WAD);
    }

    function test_lockNeverBelowTheSaleClosingPrice() public {
        pool.setTick(baseTick - up * DOUBLING * 3); // market at one eighth of the sale price
        skip(1 hours);
        (, uint256 lock) = _open(N);
        assertEq(lock, N * base / WAD);
    }

    function test_lockNeverBelowTheWethOneTokenCanRedeem() public {
        weth.mint(address(vault), 4 * SOLD * base / WAD); // treasury WETH per token is now 5x base
        (, uint256 lock) = _open(N);
        assertEq(lock, N * 5 * base / WAD);
    }

    function test_maxLockProtectsTheOpener() public {
        vm.prank(shorter);
        vm.expectRevert(FaoShortFacility.LockExceedsMax.selector);
        shorts.open(N, 1, shorter);
    }

    function test_openInterestCapIsHalfOfTheOtherTokens() public {
        _open(SOLD / 2);
        vm.prank(shorter);
        vm.expectRevert(FaoShortFacility.OpenInterestCap.selector);
        shorts.open(1, type(uint256).max, shorter);
    }

    function test_cannotMintIntoTheTreasuryOrVault() public {
        vm.startPrank(shorter);
        vm.expectRevert(FaoShortFacility.InvalidRecipient.selector);
        shorts.open(N, type(uint256).max, address(vault)); // the mock vault is also the treasury
        vm.expectRevert(FaoShortFacility.InvalidRecipient.selector);
        shorts.open(N, type(uint256).max, address(shorts));
        vm.expectRevert(FaoShortFacility.InvalidRecipient.selector);
        shorts.open(N, type(uint256).max, address(0));
        vm.stopPrank();
    }

    function test_notOpenBeforeTheSaleIsLive() public {
        FaoShortFacility fresh = new FaoShortFacility(
            FaoShortFacility(address(shorts)).BEACON(), 20_000, 100, 180 days, 7, 5000
        );
        vm.expectRevert(FaoShortFacility.NotLive.selector);
        fresh.open(1, type(uint256).max, shorter);
    }

    // ---------------------------------------------------------------- close

    function test_closeBurnsAndReleasesTheLockLessTheFee() public {
        (uint256 id, uint256 lock) = _open(N);
        skip(60 days);
        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = weth.balanceOf(address(vault));
        uint256 shorterBefore = weth.balanceOf(shorter);

        vm.prank(shorter);
        (uint256 released, uint256 fee) = shorts.close(id, N, shorter);

        assertEq(fee, lock * 2 / 100); // 1% per 30 days, 60 days
        assertEq(released, lock - fee);
        assertEq(weth.balanceOf(shorter) - shorterBefore, released);
        assertEq(weth.balanceOf(address(vault)) - treasuryBefore, fee);
        assertEq(supplyBefore - token.totalSupply(), N);
        assertEq(token.shortOutstanding(), 0);
        assertEq(shorts.pooled(), 0);
        assertEq(shorts.totalShares(), 0);
        assertEq(weth.balanceOf(address(shorts)), 0);
    }

    function test_sameBlockOpenAndCloseStillPaysOneFeePeriod() public {
        (uint256 id, uint256 lock) = _open(N);
        vm.prank(shorter);
        (uint256 released, uint256 fee) = shorts.close(id, N, shorter);
        assertEq(fee, lock / 100);
        assertEq(released, lock - fee);
    }

    function test_partialCloseKeepsTheRestLocked() public {
        (uint256 id, uint256 lock) = _open(N);
        vm.prank(shorter);
        shorts.close(id, N / 4, shorter);
        (,, uint256 amount, uint256 remaining) = shorts.position(id);
        assertEq(amount, N * 3 / 4);
        assertEq(remaining, lock - lock / 4);
        assertEq(token.shortOutstanding(), N * 3 / 4);
        assertEq(weth.balanceOf(address(shorts)), remaining);
    }

    function test_onlyTheOwnerCanClose() public {
        (uint256 id,) = _open(N);
        vm.prank(stranger);
        vm.expectRevert(FaoShortFacility.NotPositionOwner.selector);
        shorts.close(id, N, stranger);
    }

    function test_cannotCloseAfterTheTerm() public {
        (uint256 id,) = _open(N);
        skip(180 days);
        vm.prank(shorter);
        vm.expectRevert(FaoShortFacility.TermEnded.selector);
        shorts.close(id, N, shorter);
    }

    // ---------------------------------------------------------------- forfeit

    function test_forfeitSendsTheWholeLockToTheTreasury() public {
        (uint256 id, uint256 lock) = _open(N);
        vm.expectRevert(FaoShortFacility.TermNotEnded.selector);
        shorts.forfeit(id);
        skip(180 days);
        uint256 treasuryBefore = weth.balanceOf(address(vault));

        vm.prank(stranger);
        shorts.forfeit(id);

        assertEq(weth.balanceOf(address(vault)) - treasuryBefore, lock);
        assertEq(token.shortOutstanding(), 0);
        assertEq(token.totalSupply(), SOLD + N); // the tokens stay in circulation
        assertEq(weth.balanceOf(address(shorts)), 0);
        vm.expectRevert(FaoShortFacility.InvalidPosition.selector);
        shorts.forfeit(id);
    }

    function test_forfeitDoesNotChangeTheRagequitValue() public {
        (uint256 id,) = _open(N);
        skip(180 days);
        uint256 valueBefore = _ragequitValue();
        shorts.forfeit(id);
        assertEq(_ragequitValue(), valueBefore); // the lock only moves from the pool to the
        // treasury
    }

    // ---------------------------------------------------------------- locked WETH backs every
    // token

    function test_openingAShortNeverLowersTheRagequitValue() public {
        uint256 valueBefore = _ragequitValue();
        _open(SOLD / 2);
        // Half as many tokens again, each locked at 2x: (1 + 0.5 * 2) / 1.5 of the old value.
        assertEq(_ragequitValue(), valueBefore * 4 / 3);
    }

    function test_ragequitTakesTheSameFractionOfTreasuryAndPool() public {
        (, uint256 lock) = _open(N);
        uint256 supply = vault.effectiveSupply();
        uint256 treasury = weth.balanceOf(address(vault));
        uint256 valueBefore = _ragequitValue();
        uint256 amount = supply / 10;

        uint256 buyerBefore = weth.balanceOf(buyer);
        vm.prank(buyer);
        vault.ragequit(amount);

        assertEq(weth.balanceOf(buyer) - buyerBefore, treasury / 10 + lock / 10);
        assertEq(shorts.pooled(), lock - lock / 10);
        assertEq(weth.balanceOf(address(shorts)), shorts.pooled());
        assertApproxEqAbs(_ragequitValue(), valueBefore, 1);
    }

    function test_aShortOpenThroughRagequitsGetsBackLess() public {
        (uint256 id, uint256 lock) = _open(N);
        uint256 supply = vault.effectiveSupply();
        vm.prank(buyer);
        vault.ragequit(supply / 10);

        assertEq(_lockOf(id), lock - lock / 10);
        vm.prank(shorter);
        (uint256 released, uint256 fee) = shorts.close(id, N, shorter);
        assertEq(released + fee, lock - lock / 10);
    }

    function test_laterPositionsDoNotPayForEarlierRagequits() public {
        (uint256 first, uint256 firstLock) = _open(N);
        uint256 supply = vault.effectiveSupply();
        vm.prank(buyer);
        vault.ragequit(supply / 10);

        (uint256 second, uint256 secondLock) = _open(N);
        assertApproxEqAbs(_lockOf(second), secondLock, 1);
        assertApproxEqAbs(_lockOf(first), firstLock - firstLock / 10, 1);
    }

    function test_mintingAndRagequittingAtOnceNeverProfits() public {
        uint256 wethBefore = weth.balanceOf(shorter);
        (uint256 id, uint256 lock) = _open(N);
        vm.prank(shorter);
        vault.ragequit(N); // ragequit the tokens just minted

        uint256 received = weth.balanceOf(shorter) + lock - wethBefore;
        assertLt(received, lock); // less than was locked, even before the position is forfeited
        skip(180 days);
        shorts.forfeit(id);
        assertLt(weth.balanceOf(shorter), wethBefore);
    }

    function test_everyoneCanExitWithoutWaitingForShorts() public {
        _open(SOLD / 2);
        vm.prank(shorter);
        token.transfer(stranger, SOLD / 2); // the short sells what it minted

        vm.prank(buyer);
        vault.ragequit(SOLD);
        vm.prank(stranger);
        vault.ragequit(SOLD / 2); // the last tokens exit too, with no short closed

        assertEq(token.totalSupply(), 0);
        assertLe(weth.balanceOf(address(vault)), 1);
        assertLe(shorts.pooled(), 1);
        // The buyer and the short's buyer shared treasury and pool by tokens held.
        assertApproxEqAbs(weth.balanceOf(buyer), 2 * weth.balanceOf(stranger), 2);
    }

    function test_onlyTheVaultCanDrawOnThePool() public {
        _open(N);
        vm.prank(stranger);
        vm.expectRevert(FaoShortFacility.OnlyVault.selector);
        shorts.onRagequit(stranger, 1, 1);
    }

    // ---------------------------------------------------------------- accounting invariant (fuzz)

    function testFuzz_poolAlwaysCoversOpenPositions(uint256 seed) public {
        uint256 ids;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 5;
            if (action == 0) {
                uint256 amount = bound(seed >> 8, 1e12, 20_000e18);
                vm.prank(shorter);
                try shorts.open(amount, type(uint256).max, shorter) {
                    ++ids;
                } catch {}
            } else if (action == 1 && ids != 0) {
                uint256 id = (seed >> 8) % ids;
                (,, uint256 amount,) = shorts.position(id);
                uint256 held = token.balanceOf(shorter);
                if (amount != 0 && held != 0) {
                    uint256 part = bound(seed >> 40, 1, amount < held ? amount : held);
                    vm.prank(shorter);
                    try shorts.close(id, part, shorter) {} catch {}
                }
            } else if (action == 2 && ids != 0) {
                try shorts.forfeit((seed >> 8) % ids) {} catch {}
            } else if (action == 3) {
                uint256 part = bound(seed >> 8, 1, token.balanceOf(buyer) / 20 + 1);
                vm.prank(buyer);
                try vault.ragequit(part) {} catch {}
            } else {
                skip(bound(seed >> 8, 1 hours, 70 days));
                _setMultiple((seed >> 60) % 4);
            }

            uint256 open;
            uint256 claims;
            for (uint256 id; id < ids; ++id) {
                (,, uint256 amount, uint256 lock) = shorts.position(id);
                open += amount;
                claims += lock;
            }
            assertEq(token.shortOutstanding(), open);
            assertEq(weth.balanceOf(address(shorts)), shorts.pooled());
            assertLe(claims, shorts.pooled());
        }
    }
}
