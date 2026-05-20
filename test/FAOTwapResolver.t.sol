// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IFAOFutarchyOracle} from "../src/interfaces/IFAOFutarchyOracle.sol";

// ─── mocks ──────────────────────────────────────────────────────────────────

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

    function setReverted(bool v) external { reverted = v; }
}

/// @notice Stub UniV3 pool returning a programmable constant tick cumulative slope.
contract MockUniV3PoolWithTwap is IUniswapV3PoolLike {
    address public _t0;
    address public _t1;
    int24 public constantTick;

    constructor(address t0_, address t1_, int24 tickPerSecond) {
        _t0 = t0_; _t1 = t1_; constantTick = tickPerSecond;
    }

    function token0() external view returns (address) { return _t0; }
    function token1() external view returns (address) { return _t1; }
    function fee() external pure returns (uint24) { return 500; }
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1 << 96, 0, 0, 1, 200, 0, true);
    }
    function initialize(uint160) external pure {}
    function increaseObservationCardinalityNext(uint16) external pure {}
    function mint(address, int24, int24, uint128, bytes calldata) external pure returns (uint256, uint256) {
        return (0,0);
    }

    /// @dev Returns tickCumulatives such that the implied average tick equals `constantTick`.
    /// For secondsAgos = [older, newer], cums[1] - cums[0] = -constantTick * (older - newer)
    /// → avgTick = (cums[1] - cums[0]) / (older - newer) = -constantTick. Negate so avg = constantTick.
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
            // over [start, end]. With constant tick: integral = T * (end - start) = T * (older - newer).
            // We want avgTick = T = (cums[1] - cums[0]) / (older - newer). secondsAgos[0] >= secondsAgos[1].
            uint256 t = 1_000_000 - uint256(secondsAgos[i]);
            // forge-lint: disable-next-line(unsafe-typecast)
            tickCums[i] = int56(int256(constantTick) * int256(t));
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

// ─── test suite ─────────────────────────────────────────────────────────────

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

        yesCo = address(0x4001); noCo = address(0x4002);
        yesCur = address(0x4003); noCur = address(0x4004);
        proposal = new MockProposal(QID, yesCo, noCo, yesCur, noCur);
    }

    function _bind() internal {
        vm.prank(ORCH);
        resolver.bindProposal(address(proposal), address(yesPool), address(noPool), address(0xFA0), address(0xE7), uint48(block.timestamp));
    }

    // ─── access control ────────────────────────────────────────────────────

    function test_setOrchestrator_oneShot() public {
        FAOTwapResolver r = new FAOTwapResolver(2 hours, 1 hours, IConditionalTokensLike(address(ctf)));
        r.setOrchestrator(address(0x1));
        vm.expectRevert(FAOTwapResolver.OrchestratorAlreadySet.selector);
        r.setOrchestrator(address(0x2));
    }

    function test_bindProposal_revertsForNonOrchestrator() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        vm.expectRevert(FAOTwapResolver.NotOrchestrator.selector);
        resolver.bindProposal(address(proposal), address(yesPool), address(noPool), address(0xFA0), address(0xE7), uint48(block.timestamp));
    }

    function test_bindProposal_revertsOnDoubleBind() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        _bind();
        vm.prank(ORCH);
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.AlreadyBound.selector, address(proposal)));
        resolver.bindProposal(address(proposal), address(yesPool), address(noPool), address(0xFA0), address(0xE7), uint48(block.timestamp));
    }

    // ─── timing ────────────────────────────────────────────────────────────

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
        (,, ,,, , bool resolved, bool accepted) = resolver.bindings(address(proposal));
        assertTrue(resolved);
        assertTrue(accepted, "yesTick(10) > noTick(5) -> accepted");
    }

    // ─── decision logic ────────────────────────────────────────────────────

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
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.AlreadyResolved.selector, address(proposal)));
        resolver.resolve(address(proposal));
    }

    function test_resolve_revertsIfNotBound() public {
        MockProposal other = new MockProposal(bytes32(uint256(0xBEEF)), yesCo, noCo, yesCur, noCur);
        vm.expectRevert(abi.encodeWithSelector(FAOTwapResolver.NotBound.selector, address(other)));
        resolver.resolve(address(other));
    }

    // ─── views ─────────────────────────────────────────────────────────────

    function test_windowEndOf_reportsAnchorPlusTimeout() public {
        yesPool = new MockUniV3PoolWithTwap(yesCo, yesCur, int24(10));
        noPool = new MockUniV3PoolWithTwap(noCo, noCur, int24(5));
        uint48 anchor = uint48(block.timestamp);
        vm.prank(ORCH);
        resolver.bindProposal(address(proposal), address(yesPool), address(noPool), address(0xFA0), address(0xE7), anchor);
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
}
