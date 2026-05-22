// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

contract SymbolicCTF {
    bytes32 public lastQuestionId;
    uint256 public lastPayout0;
    uint256 public lastPayout1;

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        lastQuestionId = questionId;
        lastPayout0 = payouts[0];
        lastPayout1 = payouts[1];
    }
}

contract SymbolicTwapPool is IUniswapV3PoolLike {
    address internal immutable TOKEN0;
    address internal immutable TOKEN1;
    int24 internal immutable AVG_TICK;
    uint32 internal immutable EXPECTED_START_AGO;
    uint32 internal immutable EXPECTED_END_AGO;

    constructor(
        address token0_,
        address token1_,
        int24 avgTick_,
        uint32 expectedStartAgo_,
        uint32 expectedEndAgo_
    ) {
        TOKEN0 = token0_;
        TOKEN1 = token1_;
        AVG_TICK = avgTick_;
        EXPECTED_START_AGO = expectedStartAgo_;
        EXPECTED_END_AGO = expectedEndAgo_;
    }

    function token0() external view returns (address) {
        return TOKEN0;
    }

    function token1() external view returns (address) {
        return TOKEN1;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function slot0()
        external
        pure
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (uint160(1 << 96), 0, 0, 1, 2, 0, true);
    }

    function initialize(uint160) external pure {}

    function increaseObservationCardinalityNext(uint16) external pure {}

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        require(secondsAgos.length == 2, "LEN");
        require(secondsAgos[0] == EXPECTED_START_AGO, "START");
        require(secondsAgos[1] == EXPECTED_END_AGO, "END");

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] =
            int56(int256(AVG_TICK) * int256(uint256(secondsAgos[0] - secondsAgos[1])));
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return (0, 0);
    }
}

contract SymbolicProposal {
    bytes32 internal immutable QUESTION_ID_VALUE;
    address[4] internal wrappers;

    constructor(
        bytes32 questionId_,
        address yesCompany,
        address noCompany,
        address yesCurrency,
        address noCurrency
    ) {
        QUESTION_ID_VALUE = questionId_;
        wrappers[0] = yesCompany;
        wrappers[1] = noCompany;
        wrappers[2] = yesCurrency;
        wrappers[3] = noCurrency;
    }

    function questionId() external view returns (bytes32) {
        return QUESTION_ID_VALUE;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (wrappers[index], "");
    }
}

/// @custom:spec INV-TWAP-001 - resolver anchor monotonicity.
/// Halmos-checkable symbolic tests for the invariants listed in
/// `audit/specs/INVARIANTS.md`.
contract FAOTwapResolverSymbolic is Test {
    address internal constant ORCH = address(0xA11CE);
    address internal constant CALLER = address(0xB0B);
    address internal constant COMPANY_TOKEN = address(0x1000);
    address internal constant CURRENCY_TOKEN = address(0x2000);
    address internal constant YES_COMPANY = address(0x3000);
    address internal constant NO_COMPANY = address(0x3001);
    address internal constant YES_CURRENCY = address(0x4000);
    address internal constant NO_CURRENCY = address(0x4001);
    bytes32 internal constant QUESTION_ID = bytes32(uint256(0xABCD));
    uint32 internal constant TIMEOUT = 2 hours;
    uint32 internal constant TWAP_WINDOW = 1 hours;

    /// @custom:spec INV-TWAP-001 - See audit/specs/INVARIANTS.md.
    /// The anchor is written once, rebinding reverts, and resolve uses the anchored window.
    function check_INV_TWAP_001_anchorMonotone(
        uint16 anchorUnits,
        uint16 resolveDelayUnits,
        uint16 secondAnchorDelta
    ) public {
        vm.assume(anchorUnits >= 1 && anchorUnits <= 100);
        vm.assume(resolveDelayUnits >= 1 && resolveDelayUnits <= 100);
        vm.assume(secondAnchorDelta >= 1 && secondAnchorDelta <= 100);

        SymbolicCTF ctf = new SymbolicCTF();
        FAOTwapResolver resolver =
            new FAOTwapResolver(TIMEOUT, TWAP_WINDOW, IConditionalTokensLike(address(ctf)));

        vm.prank(ORCH);
        resolver.setOrchestrator(ORCH);

        uint48 anchor = uint48(anchorUnits);
        uint32 resolveDelay = uint32(resolveDelayUnits);
        uint32 expectedEndAgo = resolveDelay;
        uint32 expectedStartAgo = resolveDelay + TWAP_WINDOW;

        SymbolicTwapPool yesPool =
            new SymbolicTwapPool(YES_COMPANY, YES_CURRENCY, 10, expectedStartAgo, expectedEndAgo);
        SymbolicTwapPool noPool =
            new SymbolicTwapPool(NO_COMPANY, NO_CURRENCY, 5, expectedStartAgo, expectedEndAgo);
        SymbolicProposal proposal =
            new SymbolicProposal(QUESTION_ID, YES_COMPANY, NO_COMPANY, YES_CURRENCY, NO_CURRENCY);

        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            COMPANY_TOKEN,
            CURRENCY_TOKEN,
            anchor
        );

        (
            address boundYesPool,
            address boundNoPool,
            address boundCompany,
            address boundCurrency,
            bytes32 boundQuestionId,
            uint48 storedAnchor,
            bool resolved,
            bool accepted
        ) = resolver.bindings(address(proposal));
        assertEq(boundYesPool, address(yesPool));
        assertEq(boundNoPool, address(noPool));
        assertEq(boundCompany, COMPANY_TOKEN);
        assertEq(boundCurrency, CURRENCY_TOKEN);
        assertEq(boundQuestionId, QUESTION_ID);
        assertEq(storedAnchor, anchor);
        assertFalse(resolved);
        assertFalse(accepted);
        assertEq(resolver.windowEndOf(address(proposal)), uint256(anchor) + TIMEOUT);

        uint48 secondAnchor = anchor + uint48(secondAnchorDelta);
        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.AlreadyBound.selector, address(proposal))
        );
        vm.prank(ORCH);
        resolver.bindProposal(
            address(proposal),
            address(yesPool),
            address(noPool),
            COMPANY_TOKEN,
            CURRENCY_TOKEN,
            secondAnchor
        );

        (,,,,, storedAnchor, resolved, accepted) = resolver.bindings(address(proposal));
        assertEq(storedAnchor, anchor);
        assertFalse(resolved);
        assertFalse(accepted);

        vm.warp(uint256(anchor) + TIMEOUT + resolveDelay);
        assertTrue(resolver.isReadyToResolve(address(proposal)));

        vm.prank(CALLER);
        resolver.resolve(address(proposal));

        (,,,,, storedAnchor, resolved, accepted) = resolver.bindings(address(proposal));
        assertEq(storedAnchor, anchor);
        assertTrue(resolved);
        assertTrue(accepted);
        assertEq(resolver.windowEndOf(address(proposal)), uint256(anchor) + TIMEOUT);
        assertEq(ctf.lastQuestionId(), QUESTION_ID);
        assertEq(ctf.lastPayout0(), 1);
        assertEq(ctf.lastPayout1(), 0);

        vm.expectRevert(
            abi.encodeWithSelector(FAOTwapResolver.AlreadyResolved.selector, address(proposal))
        );
        vm.prank(CALLER);
        resolver.resolve(address(proposal));

        (,,,,, storedAnchor, resolved, accepted) = resolver.bindings(address(proposal));
        assertEq(storedAnchor, anchor);
        assertTrue(resolved);
        assertTrue(accepted);
    }
}
