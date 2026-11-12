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

    function _wethPerToken() internal view returns (uint256) {
        return weth.balanceOf(address(vault)) * WAD / vault.effectiveSupply();
    }

    // ---------------------------------------------------------------- open

    function test_openLocksTwiceThePriceAndMints() public {
        (uint256 id, uint256 lock) = _open(N);
        assertEq(id, 0);
        assertEq(lock, N * 2 * base / WAD);
        assertEq(token.balanceOf(shorter), N);
        assertEq(token.shortOutstanding(), N);
        assertEq(weth.balanceOf(address(shorts)), lock);
        assertEq(shorts.totalLocked(), lock);
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
        beacon.poke(); // today's high recorded at 8x
        skip(2 days);
        _setMultiple(0); // price pushed back to 1x for the 30-minute window
        (, uint256 lock) = _open(N);
        assertGe(lock, N * 16 * base / WAD); // still locks against the 7-day high
    }

    function test_oldHighsStopCountingAfterTheLookback() public {
        _setMultiple(3);
        beacon.poke();
        skip(8 days);
        _setMultiple(0);
        (, uint256 lock) = _open(N);
        assertEq(lock, N * 2 * base / WAD);
    }

    function test_lockNeverBelowTheSaleClosingPrice() public {
        pool.setTick(baseTick - up * DOUBLING * 3); // market at one eighth of the sale price
        (, uint256 lock) = _open(N);
        assertEq(lock, N * base / WAD);
    }

    function test_maxLockProtectsTheOpener() public {
        vm.prank(shorter);
        vm.expectRevert(FaoShortFacility.LockExceedsMax.selector);
        shorts.open(N, 1, shorter);
    }

    function test_openInterestCap() public {
        _open(SOLD / 2); // exactly half of all other tokens
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
        assertEq(shorts.totalLocked(), 0);
        assertEq(weth.balanceOf(address(shorts)), 0);
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

    function test_forfeitRaisesTheRagequitFloor() public {
        uint256 floorBefore = _wethPerToken();
        (uint256 id,) = _open(N);
        skip(180 days);
        shorts.forfeit(id);
        assertGt(_wethPerToken(), floorBefore);
    }

    // ---------------------------------------------------------------- ragequit is never diluted

    function test_openShortsDoNotDiluteRagequit() public {
        uint256 floorBefore = _wethPerToken();
        _open(SOLD / 2);
        assertEq(_wethPerToken(), floorBefore);

        uint256 wethBefore = weth.balanceOf(buyer);
        vm.prank(buyer);
        vault.ragequit(100e18);
        assertEq(weth.balanceOf(buyer) - wethBefore, 100e18 * floorBefore / WAD);
        assertApproxEqAbs(_wethPerToken(), floorBefore, 1);
    }

    function test_borrowedTokensCanRagequitWithoutHurtingOthers() public {
        uint256 floorBefore = _wethPerToken();
        (uint256 id,) = _open(N);
        vm.prank(shorter);
        vault.ragequit(N); // the short ragequits the tokens it minted
        assertApproxEqAbs(_wethPerToken(), floorBefore, 1);

        // To close it must buy tokens back from holders; otherwise the lock is forfeited.
        skip(180 days);
        shorts.forfeit(id);
        assertGt(_wethPerToken(), floorBefore);
    }

    function test_lastTokensWaitForShortsWhenEveryoneExits() public {
        _open(SOLD / 2);
        vm.prank(shorter);
        token.transfer(stranger, SOLD / 2); // sold to the market
        vm.prank(buyer);
        vault.ragequit(SOLD); // every non-short token's worth exits at the full floor
        assertEq(vault.effectiveSupply(), 0);
        vm.prank(stranger);
        vm.expectRevert(bytes("effective supply"));
        vault.ragequit(1e18);

        // The short cannot buy back what was burned; after the term its lock backs the rest.
        skip(180 days);
        shorts.forfeit(0);
        uint256 before = weth.balanceOf(stranger);
        vm.prank(stranger);
        vault.ragequit(SOLD / 2);
        assertGe(weth.balanceOf(stranger) - before, (SOLD / 2) * 2 * base / WAD - 1);
    }

    // ---------------------------------------------------------------- accounting invariant (fuzz)

    function testFuzz_lockAlwaysCoversOpenPositions(uint256 seed) public {
        uint256 ids;
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = seed % 4;
            if (action == 0) {
                uint256 amount = bound(seed >> 8, 1e12, 20_000e18);
                vm.prank(shorter);
                try shorts.open(amount, type(uint256).max, shorter) {
                    ++ids;
                } catch {}
            } else if (action == 1 && ids != 0) {
                uint256 id = (seed >> 8) % ids;
                (,, uint256 amount,) = shorts.position(id);
                if (amount != 0) {
                    uint256 part = bound(seed >> 40, 1, amount);
                    vm.prank(shorter);
                    try shorts.close(id, part, shorter) {} catch {}
                }
            } else if (action == 2 && ids != 0) {
                try shorts.forfeit((seed >> 8) % ids) {} catch {}
            } else {
                skip(bound(seed >> 8, 1 hours, 70 days));
                _setMultiple((seed >> 60) % 4);
            }
            uint256 open;
            uint256 locked;
            for (uint256 id; id < ids; ++id) {
                (,, uint256 amount, uint256 lock) = shorts.position(id);
                open += amount;
                locked += lock;
            }
            assertEq(token.shortOutstanding(), open);
            assertEq(shorts.totalLocked(), locked);
            assertEq(weth.balanceOf(address(shorts)), locked);
        }
    }
}
