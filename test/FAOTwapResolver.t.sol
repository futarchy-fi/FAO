// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {
    IFAOFutarchyOracle,
    IFutarchyRandomnessSource
} from "../src/interfaces/IFAOFutarchyOracle.sol";

contract MockVrfSource is IFutarchyRandomnessSource {
    uint256 public nonce;
    mapping(bytes32 => bool) public isFulfilled;
    mapping(bytes32 => bytes32) public words;

    function requestRandomness(bytes32 context) external returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(context, ++nonce));
    }

    function fulfill(bytes32 requestId, bytes32 word) external {
        isFulfilled[requestId] = true;
        words[requestId] = word;
    }

    function readRandomness(bytes32 requestId)
        external
        view
        returns (bool fulfilled, bytes32 randomWord)
    {
        return (isFulfilled[requestId], words[requestId]);
    }
}

// ─── mocks
// ──────────────────────────────────────────────────────────────────

contract MockCTF {
    mapping(bytes32 => uint256[]) public reported;
    bool public reverted;

    function reportPayouts(bytes32 questionId, uint256[] calldata p) external {
        require(!reverted, "ctf-fail");
        reported[questionId] = p;
    }

    function reportedFor(bytes32 questionId) external view returns (uint256[] memory) {
        return reported[questionId];
    }

    function setReverted(bool v) external {
        reverted = v;
    }
}

/// @notice Stub UniV3 pool returning a programmable constant tick cumulative slope.
contract MockUniV3PoolWithTwap is IUniswapV3PoolLike {
    address public _t0;
    address public _t1;
    int24 public constantTick;

    constructor(address t0_, address t1_, int24 tickPerSecond) {
        _t0 = t0_;
        _t1 = t1_;
        constantTick = tickPerSecond;
    }

    function setConstantTick(int24 tickPerSecond) external {
        constantTick = tickPerSecond;
    }

    function token0() external view returns (address) {
        return _t0;
    }

    function token1() external view returns (address) {
        return _t1;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1 << 96, 0, 0, 1, 200, 0, true);
    }
    function initialize(uint160) external pure {}
    function increaseObservationCardinalityNext(uint16) external pure {}

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    /// @dev Returns tickCumulatives such that the implied average tick equals `constantTick`.
    /// For secondsAgos = [older, newer], cums[1] - cums[0] = -constantTick * (older - newer)
    /// → avgTick = (cums[1] - cums[0]) / (older - newer) = -constantTick. Negate so avg =
    /// constantTick.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCums, uint160[] memory liqCums)
    {
        tickCums = new int56[](secondsAgos.length);
        liqCums = new uint160[](secondsAgos.length);
        // forge-lint: disable-next-line(unsafe-typecast)
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            // tickCumulative at time t is integral of tick dt from 0 to t.
            // For constant tick T, cumulative(t) = T * t. observe returns cumulative
            // values at "now - secondsAgos[i]". We model "now" as a large time so values
            // are positive. cumulative is unique; (cums[1] - cums[0]) gives the integral
            // over [start, end]. With constant tick: integral = T * (end - start) = T * (older -
            // newer). We want avgTick = T = (cums[1] - cums[0]) / (older - newer). secondsAgos[0]
            // >= secondsAgos[1].
            uint256 t = 1_000_000 - uint256(secondsAgos[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            tickCums[i] = int56(int256(constantTick) * int256(t));
        }
    }
}

contract RevertingUniV3Pool is IUniswapV3PoolLike {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1 << 96, 0, 0, 1, 100, 0, true);
    }
    function initialize(uint160) external pure {}
    function increaseObservationCardinalityNext(uint16) external pure {}

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function observe(uint32[] calldata)
        external
        pure
        virtual
        returns (int56[] memory, uint160[] memory)
    {
        revert("OLD");
    }
}

contract GasExhaustingUniV3Pool is RevertingUniV3Pool {
    constructor(address token0_, address token1_) RevertingUniV3Pool(token0_, token1_) {}

    function observe(uint32[] calldata)
        external
        pure
        override
        returns (int56[] memory, uint160[] memory)
    {
        assembly {
            for {} 1 {} {}
        }
    }
}

/// @notice Bare proposal mock that exposes wrappedOutcome + questionId only.
contract MockProposal {
    bytes32 public questionId;
    address[4] public wrappers;

    constructor(bytes32 qid, address yesCo, address noCo, address yesCur, address noCur) {
        questionId = qid;
        wrappers[0] = yesCo;
        wrappers[1] = noCo;
        wrappers[2] = yesCur;
        wrappers[3] = noCur;
    }

    function wrappedOutcome(uint256 i) external view returns (address, bytes memory) {
        return (wrappers[i], "");
    }
}

// ─── test suite
// ─────────────────────────────────────────────────────────────

contract FAOTwapResolverTest is Test {
    FAOTwapResolver resolver;
    MockCTF ctf;
    address constant ORCH = address(0xDEAD);

    address yesCo;
    address noCo;
    address yesCur;
    address noCur;
    MockProposal proposal;
    MockUniV3PoolWithTwap yesPool;
    MockUniV3PoolWithTwap noPool;
    bytes32 constant QID = bytes32(uint256(0xABCD));

    function setUp() public {
        ctf = new MockCTF();
        resolver = new FAOTwapResolver(2 hours, 1 hours, IConditionalTokensLike(address(ctf)));
        resolver.setOrchestrator(ORCH);

        yesCo = address(0x4001);
        noCo = address(0x4002);
        yesCur = address(0x4003);
        noCur = address(0x4004);
        proposal = new MockProposal(QID, yesCo, noCo, yesCur, noCur);
    }

    function _bind() internal {
        _bindPools(address(yesPool), address(noPool));
    }

    function _bindPools(address yesPool_, address noPool_) internal {
        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            yesPool_,
            noPool_,
            address(0xFA0),
            address(0xE7),
            uint48(block.timestamp),
            0
        );
    }

    // ─── decision margin
    // ────────────────────────────────────────────────────

    function _resolveWithMargin(int24 yesTick, int24 noTick, int24 marginTicks)
        internal
        returns (bool accepted)
    {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, yesTick);
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, noTick);
        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            uint48(block.timestamp),
            marginTicks
        );
        assertEq(resolver.decisionMarginTicks(address(proposal)), marginTicks);
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));
        (,,,,,,, accepted) = resolver.bindings(address(proposal));
        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], accepted ? 1 : 0, "YES payout slot");
        assertEq(payouts[1], accepted ? 0 : 1, "NO payout slot");
    }

    function test_margin_aLeadEqualToTheMarginIsRejected() public {
        assertFalse(_resolveWithMargin(150, 50, 100));
    }

    function test_margin_oneTickPastTheMarginPasses() public {
        assertTrue(_resolveWithMargin(151, 50, 100));
    }

    function test_margin_aSmallLeadThatWouldPassWithoutAMarginIsRejected() public {
        assertFalse(_resolveWithMargin(60, 50, 100));
    }

    function test_margin_zeroKeepsThePlainRule() public {
        assertTrue(_resolveWithMargin(51, 50, 0));
    }

    function test_margin_appliesWithNegativeTicks() public {
        assertFalse(_resolveWithMargin(-50, -150, 100));
    }

    function test_margin_mustBeWithinBounds() public {
        vm.startPrank(ORCH);
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.InvalidMargin.selector, int24(-1)));
        resolver.bindProposal(
            address(proposal), address(1), address(2), address(0xFA0), address(0xE7), 1, -1
        );
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.InvalidMargin.selector, int24(1001)));
        resolver.bindProposal(
            address(proposal), address(1), address(2), address(0xFA0), address(0xE7), 1, 1001
        );
        vm.stopPrank();
    }

    // ─── access control
    // ────────────────────────────────────────────────────

    function test_setOrchestrator_oneShot() public {
        FAOTwapResolver r =
            new FAOTwapResolver(2 hours, 1 hours, IConditionalTokensLike(address(ctf)));
        r.setOrchestrator(address(0x1));
        vm.expectRevert(FAOTwapResolver.OrchestratorAlreadySet.selector);
        r.setOrchestrator(address(0x2));
    }

    function test_bindProposal_revertsForNonOrchestrator() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        vm.expectRevert(FAOTwapResolver.NotOrchestrator.selector);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            uint48(block.timestamp),
            0
        );
    }

    function test_bindProposal_revertsOnDoubleBind() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();
        vm.prank(ORCH);
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.AlreadyBound.selector, address(proposal))
        );
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            uint48(block.timestamp),
            0
        );
    }

    // ─── timing
    // ────────────────────────────────────────────────────────────

    function test_resolve_revertsBeforeWindowEnd() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();

        // 2h - 1 second: still before windowEnd.
        vm.warp(block.timestamp + 2 hours - 1);
        vm.expectRevert();
        resolver.resolve(address(proposal));
    }

    function test_resolve_allowedExactlyAtWindowEnd() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));
        (,,,,,, bool resolved, bool accepted) = resolver.bindings(address(proposal));
        assertTrue(resolved);
        assertTrue(accepted, "yesTick(10) > noTick(5) -> accepted");
    }

    // ─── decision logic
    // ────────────────────────────────────────────────────

    function test_decision_yesGreaterThanNo_accepts() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(100));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(50));
        _bind();
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));

        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts.length, 2);
        assertEq(payouts[0], 1, "YES payout slot");
        assertEq(payouts[1], 0, "NO payout slot");
    }

    function test_decision_yesLessThanNo_rejects() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(50));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(100));
        _bind();
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));

        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], 0, "YES");
        assertEq(payouts[1], 1, "NO");
    }

    function test_genuineObserveFailureSafelyRejects() public {
        RevertingUniV3Pool brokenYes = new RevertingUniV3Pool(yesCo, yesCur);
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(100));
        _bindPools(address(brokenYes), address(noPool));
        vm.warp(block.timestamp + 2 hours);

        resolver.resolve(address(proposal));

        (,,,,,, bool resolved, bool accepted) = resolver.bindings(address(proposal));
        assertTrue(resolved);
        assertFalse(accepted);
        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    function test_lowGasObserveFailureRevertsWithoutSettlement() public {
        GasExhaustingUniV3Pool gasGriefer = new GasExhaustingUniV3Pool(yesCo, yesCur);
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(100));
        _bindPools(address(gasGriefer), address(noPool));
        vm.warp(block.timestamp + 2 hours);

        (bool ok, bytes memory reason) = address(resolver).call{gas: 1_000_000}(
            abi.encodeCall(FAOTwapResolver.resolve, (address(proposal)))
        );

        assertFalse(ok);
        assertEq(bytes4(reason), FAOTwapResolver.InsufficientGas.selector);
        (,,,,,, bool resolved,) = resolver.bindings(address(proposal));
        assertFalse(resolved);
        assertEq(ctf.reportedFor(QID).length, 0);
    }

    /// @notice Orientation: if a pool's token0 is the CURRENCY wrapper rather than the
    /// company wrapper, the raw tick is negated by the resolver. This test verifies that
    /// a yesPool with token0 = yesCurrency (currency-first ordering) is normalized.
    function test_orientation_invertedPoolTickIsNegated() public {
        // Make YES pool with currency-as-token0; constant tick = -100 raw → company side
        // sees +100 after inversion. NO pool unchanged at 50.
        yesPool = new MockUniV3PoolWithTwap(yesCur, yesCo, int24(-100));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(50));
        _bind();
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));
        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], 1, "YES wins after orientation normalization");
    }

    function test_resolve_revertsIfAlreadyResolved() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.AlreadyResolved.selector, address(proposal))
        );
        resolver.resolve(address(proposal));
    }

    function test_resolve_revertsIfNotBound() public {
        MockProposal other = new MockProposal(bytes32(uint256(0xBEEF)), yesCo, noCo, yesCur, noCur);
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.NotBound.selector, address(other)));
        resolver.resolve(address(other));
    }

    // ─── views
    // ─────────────────────────────────────────────────────────────

    function test_windowEndOf_reportsAnchorPlusTimeout() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        uint48 anchor = uint48(block.timestamp);
        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            address(0xFA0),
            address(0xE7),
            anchor,
            0
        );
        assertEq(resolver.windowEndOf(address(proposal)), uint256(anchor) + 2 hours);
    }

    function test_isReadyToResolve_falseBefore_trueAfter() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();
        assertFalse(resolver.isReadyToResolve(address(proposal)));
        vm.warp(block.timestamp + 2 hours);
        assertTrue(resolver.isReadyToResolve(address(proposal)));
        resolver.resolve(address(proposal));
        assertFalse(resolver.isReadyToResolve(address(proposal)), "false after resolve");
    }

    // ─── two-step Floor + 1/spread randomized NOOP policy
    // ─────────────────────────────────────────────────────────────

    function _bindRandom(
        address prop,
        address yp,
        address np,
        uint48 anchor,
        int24 marginTicks,
        uint16 floorBps,
        int24 scaleTicks
    ) internal {
        vm.startPrank(ORCH);
        resolver.bindProposal(prop, yp, np, address(0xFA0), address(0xE7), anchor, marginTicks);
        resolver.setNoopPolicy(prop, floorBps, scaleTicks);
        vm.stopPrank();
    }

    function test_random_rejectedBelowMarginResolvesInOneStepWithoutWaitingForDraw() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(150));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(50)); // spread = 100 == margin
        _bindRandom(
            address(proposal),
            address(yesPool),
            address(noPool),
            uint48(block.timestamp),
            100,
            1000,
            100
        );
        vm.warp(block.timestamp + 2 hours);
        resolver.resolve(address(proposal));

        (,,,,,, bool resolved, bool accepted) = resolver.bindings(address(proposal));
        assertTrue(resolved);
        assertFalse(accepted);
        assertFalse(resolver.twapPassed(address(proposal)));
        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    function test_random_passingTwapRequiresSealThenFutureBlockDrawAndFreezesTwap() public {
        // +2% spread (200 ticks vs margin 100, sigma = 100, floor = 10%) => p(NOOP) = 100/200 = 50%
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(250));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(50));
        _bindRandom(
            address(proposal),
            address(yesPool),
            address(noPool),
            uint48(block.timestamp),
            100,
            1000,
            100
        );
        vm.warp(block.timestamp + 2 hours);

        // Single-tx resolve without prior seal must revert DrawNotSealed.
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.DrawNotSealed.selector, address(proposal))
        );
        resolver.resolve(address(proposal));

        // Step 1: seal freezes ticks and sets drawBlock = block.number + 2.
        uint64 expectedDrawBlock = uint64(block.number) + 2;
        resolver.seal(address(proposal));
        assertTrue(resolver.twapPassed(address(proposal)));

        // Post-seal trades cannot alter the frozen TWAP ticks or twapPassed.
        yesPool.setConstantTick(int24(-5000));

        // Cannot resolve at drawBlock itself; needs block.number > drawBlock.
        vm.roll(expectedDrawBlock);
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.RandomnessNotReady.selector, address(proposal))
        );
        resolver.resolve(address(proposal));

        // Advance past drawBlock so blockhash(expectedDrawBlock) is committed.
        vm.roll(expectedDrawBlock + 1);
        assertTrue(resolver.isReadyToResolve(address(proposal)));
        resolver.resolve(address(proposal));

        (,,,,,, bool resolved, bool accepted) = resolver.bindings(address(proposal));
        (,,,, int24 frozenYes, int24 frozenNo,,) = resolver.sealedDecisions(address(proposal));
        assertEq(frozenYes, 250);
        assertEq(frozenNo, 50);
        assertTrue(resolved);
        assertTrue(
            resolver.twapPassed(address(proposal)), "TWAP verdict remains true regardless of coin"
        );
        uint256[] memory payouts = ctf.reportedFor(QID);
        assertEq(payouts[0], accepted ? 1 : 0);
        assertEq(payouts[1], accepted ? 0 : 1);
    }

    function test_random_floorAndOneOverSpreadProbabilitiesMatchTheoryWithExternalVrf() public {
        int24[3] memory spreads = [int24(200), int24(500), int24(2000)];
        uint256[3] memory expectedPassPct = [uint256(50), uint256(80), uint256(90)];

        for (uint256 k = 0; k < 3; ++k) {
            MockCTF localCtf = new MockCTF();
            MockVrfSource vrf = new MockVrfSource();
            FAOTwapResolver r =
                new FAOTwapResolver(2 hours, 1 hours, IConditionalTokensLike(address(localCtf)));
            r.setOrchestratorWithRandomness(ORCH, vrf);

            MockProposal mp = new MockProposal(bytes32(k + 1), yesCo, noCo, yesCur, noCur);
            MockUniV3PoolWithTwap yp = new MockUniV3PoolWithTwap(yesCo, yesCur, spreads[k]);
            MockUniV3PoolWithTwap np = new MockUniV3PoolWithTwap(noCo, noCur, int24(0));
            uint48 anchor = uint48(block.timestamp);
            vm.startPrank(ORCH);
            r.bindProposal(
                address(mp), address(yp), address(np), address(0xFA0), address(0xE7), anchor, 100
            );
            r.setNoopPolicy(address(mp), 1000, 100);
            vm.stopPrank();
            vm.warp(uint256(anchor) + 2 hours);
            r.seal(address(mp));
            (,,,,,,, bytes32 reqId) = r.sealedDecisions(address(mp));
            assertFalse(r.isReadyToResolve(address(mp)));

            uint256 snap = vm.snapshotState();
            uint256 acceptedCount;
            uint256 trials = 400;
            for (uint256 i = 0; i < trials; ++i) {
                vrf.fulfill(reqId, keccak256(abi.encode("trial", k, i)));
                assertTrue(r.isReadyToResolve(address(mp)));
                r.resolve(address(mp));
                (,,,,,,, bool acc) = r.bindings(address(mp));
                if (acc) acceptedCount++;
                vm.revertToState(snap);
            }
            uint256 expected = (trials * expectedPassPct[k]) / 100;
            assertApproxEqAbs(
                acceptedCount, expected, 28, "empirical pass rate matches max(eps, sigma/(sigma+x))"
            );
        }
    }

    function test_random_rearmExpiredDrawPreservesFrozenTicksAndBlocksEarlyRearm() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(300));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(50));
        _bindRandom(
            address(proposal),
            address(yesPool),
            address(noPool),
            uint48(block.timestamp),
            100,
            1000,
            100
        );
        vm.warp(block.timestamp + 2 hours);
        resolver.seal(address(proposal));
        (,,,, int24 frozenYes, int24 frozenNo, uint64 drawBlock,) =
            resolver.sealedDecisions(address(proposal));

        // Cannot rearm while blockhash is still within the serve window.
        vm.roll(drawBlock + 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOTwapResolver.DrawNotExpired.selector, address(proposal), drawBlock
            )
        );
        resolver.rearmExpiredDraw(address(proposal));

        // Advance past the 256-block window (no EIP-2935 code in local VM).
        vm.roll(uint256(drawBlock) + 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                FAOTwapResolver.DrawExpired.selector, address(proposal), drawBlock
            )
        );
        resolver.resolve(address(proposal));

        resolver.rearmExpiredDraw(address(proposal));
        (, bool twapOk,,, int24 yesAfter, int24 noAfter, uint64 newDrawBlock,) =
            resolver.sealedDecisions(address(proposal));
        assertTrue(twapOk);
        assertEq(yesAfter, frozenYes);
        assertEq(noAfter, frozenNo);
        assertEq(newDrawBlock, uint64(block.number) + 2);

        vm.roll(uint256(newDrawBlock) + 1);
        resolver.resolve(address(proposal));
        (,,,,,, bool resolved,) = resolver.bindings(address(proposal));
        assertTrue(resolved);
    }
}
