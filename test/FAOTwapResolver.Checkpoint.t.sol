// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {MockCTF, MockProposal} from "./FAOTwapResolver.t.sol";

/// @dev Pool that behaves like Uniswap v3 with a short history: it accumulates tick over time,
/// answers "now" always, and reverts for any time older than `historySeconds`.
contract ShortHistoryPool {
    address public immutable token0;
    address public immutable token1;
    int24 public tick;
    int56 public cumulative;
    uint256 public lastUpdate;
    uint256 public historySeconds;

    constructor(address t0, address t1, int24 tick_, uint256 historySeconds_) {
        token0 = t0;
        token1 = t1;
        tick = tick_;
        historySeconds = historySeconds_;
        lastUpdate = block.timestamp;
    }

    function setTick(int24 tick_) external {
        _accrue();
        tick = tick_;
    }

    function _accrue() internal {
        cumulative += int56(tick) * int56(uint56(block.timestamp - lastUpdate));
        lastUpdate = block.timestamp;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory liquidity)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        liquidity = new uint160[](secondsAgos.length);
        int56 nowCumulative = cumulative + int56(tick) * int56(uint56(block.timestamp - lastUpdate));
        for (uint256 i; i < secondsAgos.length; ++i) {
            require(secondsAgos[i] <= historySeconds, "OLD");
            // Only "now" is exact in this mock; older points assume the current tick.
            tickCumulatives[i] = nowCumulative - int56(tick) * int56(uint56(secondsAgos[i]));
        }
    }
}

/// @notice The decision must not depend on how much price history the pools still hold.
contract FAOTwapResolverCheckpointTest is Test {
    FAOTwapResolver internal resolver;
    MockCTF internal ctf;
    MockProposal internal proposal;
    ShortHistoryPool internal yesPool;
    ShortHistoryPool internal noPool;
    address internal constant ORCH = address(0xDEAD);
    bytes32 internal constant QID = bytes32(uint256(0xABCD));
    address internal yesCo = address(0x4001);
    address internal noCo = address(0x4002);
    address internal yesCur = address(0x4003);
    address internal noCur = address(0x4004);
    uint256 internal anchor;

    function setUp() public {
        vm.warp(1_800_000_000);
        ctf = new MockCTF();
        resolver = new FAOTwapResolver(72 hours, 24 hours, IConditionalTokensLike(address(ctf)));
        resolver.setOrchestrator(ORCH);
        proposal = new MockProposal(QID, yesCo, noCo, yesCur, noCur);
        // History of only 20 minutes: far shorter than the 24-hour window.
        yesPool = new ShortHistoryPool(yesCo, yesCur, 100, 20 minutes);
        noPool = new ShortHistoryPool(noCo, noCur, 50, 20 minutes);
        anchor = block.timestamp;
        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            uint48(anchor)
        );
    }

    function _accepted() internal view returns (bool) {
        uint256[] memory payouts = ctf.reportedFor(QID);
        return payouts[0] == 1;
    }

    function test_withoutACheckpointLostHistoryResolvesNo() public {
        vm.warp(anchor + 72 hours);
        resolver.resolve(address(proposal));
        assertFalse(_accepted()); // YES was higher, but the history is gone
    }

    function test_checkpointMakesTheDecisionIndependentOfPoolHistory() public {
        vm.warp(anchor + 48 hours);
        resolver.checkpointWindowStart(address(proposal));
        vm.warp(anchor + 72 hours);
        resolver.resolve(address(proposal));
        assertTrue(_accepted());
    }

    function test_checkpointCannotBeTakenEarlyOrTwice() public {
        vm.warp(anchor + 48 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOTwapResolver.TooEarly.selector, address(proposal), anchor + 48 hours
            )
        );
        resolver.checkpointWindowStart(address(proposal));
        vm.warp(anchor + 48 hours);
        resolver.checkpointWindowStart(address(proposal));
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.AlreadyCheckpointed.selector, address(proposal))
        );
        resolver.checkpointWindowStart(address(proposal));
    }

    function test_lateCheckpointDelaysResolutionByAFullWindow() public {
        vm.warp(anchor + 60 hours); // 12 hours late
        resolver.checkpointWindowStart(address(proposal));
        assertFalse(resolver.isReadyToResolve(address(proposal)));
        vm.warp(anchor + 72 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOTwapResolver.TooEarly.selector, address(proposal), anchor + 84 hours
            )
        );
        resolver.resolve(address(proposal));
        vm.warp(anchor + 84 hours);
        assertTrue(resolver.isReadyToResolve(address(proposal)));
        resolver.resolve(address(proposal));
        assertTrue(_accepted());
    }

    function test_onlyPricesInsideTheWindowCount() public {
        // YES trades far above NO before the window, then below it for the whole window.
        yesPool.setTick(5000);
        vm.warp(anchor + 48 hours);
        resolver.checkpointWindowStart(address(proposal));
        yesPool.setTick(40);
        vm.warp(anchor + 72 hours);
        resolver.resolve(address(proposal));
        assertFalse(_accepted());
    }

    function test_meanIsTimeWeightedAcrossTheWindow() public {
        vm.warp(anchor + 48 hours);
        resolver.checkpointWindowStart(address(proposal));
        // YES: 6 hours at 100, then 18 hours at 20 -> mean 40, below NO's 50.
        vm.warp(anchor + 54 hours);
        yesPool.setTick(20);
        vm.warp(anchor + 72 hours);
        resolver.resolve(address(proposal));
        assertFalse(_accepted());
    }

    function test_orientationIsNormalisedForBothPools() public {
        // Same market, but the company wrapper is token1 in the YES pool: its raw tick is negated.
        ShortHistoryPool flipped = new ShortHistoryPool(yesCur, yesCo, -100, 20 minutes);
        MockProposal other = new MockProposal(bytes32(uint256(0xBEEF)), yesCo, noCo, yesCur, noCur);
        vm.prank(ORCH);
        resolver.bindProposal(
            address(other),
            address(flipped),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            uint48(block.timestamp)
        );
        vm.warp(block.timestamp + 48 hours);
        resolver.checkpointWindowStart(address(other));
        vm.warp(block.timestamp + 24 hours);
        resolver.resolve(address(other));
        assertEq(ctf.reportedFor(bytes32(uint256(0xBEEF)))[0], 1);
    }
}
