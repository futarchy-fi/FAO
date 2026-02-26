// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyTWAPOracle} from "../src/FutarchyTWAPOracle.sol";

import {MockAlgebraPoolTWAP, GasGriefingAlgebraPool} from "./mocks/MockAlgebraPoolTWAP.sol";

contract FutarchyTWAPOracleTest is Test {
    event ProposalBound(
        address indexed proposal, address yesPool, address noPool, uint48 startTime
    );
    event ProposalResolved(
        address indexed proposal, bool accepted, int56 yesAvgTick, int56 noAvgTick
    );
    event ConfigUpdated(uint32 tradingPeriod, uint32 twapWindow, int24 thresholdTicks);

    FutarchyTWAPOracle oracle;

    address dao = address(0xDA0);
    address binderAddr = address(0xB1);
    address proposal = address(0xCAFE);

    // Token addresses — ordering matters for normalization tests.
    address yesCompany = address(0x1);
    address noCompany = address(0x2);
    address yesCurrency = address(0x3);
    address noCurrency = address(0x4);

    MockAlgebraPoolTWAP yesPool;
    MockAlgebraPoolTWAP noPool;

    uint32 constant TRADING_PERIOD = 7 days;
    uint32 constant TWAP_WINDOW = 1 days;
    int24 constant THRESHOLD = 0;

    function setUp() public {
        oracle = new FutarchyTWAPOracle(dao, binderAddr, TRADING_PERIOD, TWAP_WINDOW, THRESHOLD);

        // YES pool: yesCompany < yesCurrency, so token0 = yesCompany.
        // Normal ordering: company is token0 → sign = +1.
        yesPool = new MockAlgebraPoolTWAP(yesCompany, yesCurrency);
        noPool = new MockAlgebraPoolTWAP(noCompany, noCurrency);
    }

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    function testConstructorSetsState() public view {
        assertEq(oracle.dao(), dao);
        assertEq(oracle.binder(), binderAddr);
        assertEq(oracle.tradingPeriod(), TRADING_PERIOD);
        assertEq(oracle.twapWindow(), TWAP_WINDOW);
        assertEq(oracle.thresholdTicks(), THRESHOLD);
    }

    function testConstructorRevertsZeroDAO() public {
        vm.expectRevert(FutarchyTWAPOracle.ZeroAddress.selector);
        new FutarchyTWAPOracle(address(0), binderAddr, TRADING_PERIOD, TWAP_WINDOW, THRESHOLD);
    }

    function testConstructorRevertsZeroBinder() public {
        vm.expectRevert(FutarchyTWAPOracle.ZeroAddress.selector);
        new FutarchyTWAPOracle(dao, address(0), TRADING_PERIOD, TWAP_WINDOW, THRESHOLD);
    }

    function testConstructorRevertsInvalidConfig() public {
        vm.expectRevert(abi.encodeWithSelector(FutarchyTWAPOracle.InvalidConfig.selector, 100, 200));
        new FutarchyTWAPOracle(dao, binderAddr, 100, 200, THRESHOLD);
    }

    function testConstructorRevertsZeroWindow() public {
        vm.expectRevert(abi.encodeWithSelector(FutarchyTWAPOracle.InvalidConfig.selector, 100, 0));
        new FutarchyTWAPOracle(dao, binderAddr, 100, 0, THRESHOLD);
    }

    // ═══════════════════════════════════════════════════════
    //  bind()
    // ═══════════════════════════════════════════════════════

    function testBindSucceeds() public {
        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        (address yp, address np, address yb, address nb, uint48 st, bool resolved, bool accepted) =
            oracle.proposals(proposal);
        assertEq(yp, address(yesPool));
        assertEq(np, address(noPool));
        assertEq(yb, yesCompany);
        assertEq(nb, noCompany);
        assertEq(st, uint48(block.timestamp));
        assertFalse(resolved);
        assertFalse(accepted);
    }

    function testBindEmitsEvent() public {
        vm.prank(binderAddr);
        vm.expectEmit(true, false, false, true);
        emit ProposalBound(proposal, address(yesPool), address(noPool), uint48(block.timestamp));
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );
    }

    function testBindRevertsFromNonBinder() public {
        vm.expectRevert(FutarchyTWAPOracle.NotBinder.selector);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );
    }

    function testBindRevertsIfAlreadyBound() public {
        vm.startPrank(binderAddr);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        vm.expectRevert(abi.encodeWithSelector(FutarchyTWAPOracle.AlreadyBound.selector, proposal));
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );
        vm.stopPrank();
    }

    function testBindRevertsZeroProposal() public {
        vm.prank(binderAddr);
        vm.expectRevert(FutarchyTWAPOracle.ZeroAddress.selector);
        oracle.bind(
            address(0),
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );
    }

    function testBindRevertsZeroYesPool() public {
        vm.prank(binderAddr);
        vm.expectRevert(FutarchyTWAPOracle.ZeroAddress.selector);
        oracle.bind(
            proposal, address(0), address(noPool), yesCompany, noCompany, uint48(block.timestamp)
        );
    }

    function testBindRevertsZeroNoPool() public {
        vm.prank(binderAddr);
        vm.expectRevert(FutarchyTWAPOracle.ZeroAddress.selector);
        oracle.bind(
            proposal, address(yesPool), address(0), yesCompany, noCompany, uint48(block.timestamp)
        );
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — basic
    // ═══════════════════════════════════════════════════════

    function testResolveRevertsIfNotBound() public {
        vm.expectRevert(abi.encodeWithSelector(FutarchyTWAPOracle.NotBound.selector, proposal));
        oracle.resolve(proposal);
    }

    function testResolveRevertsBeforeTradingEnds() public {
        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        uint256 deadline = block.timestamp + TRADING_PERIOD;
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyTWAPOracle.TradingNotEnded.selector, proposal, deadline, block.timestamp
            )
        );
        oracle.resolve(proposal);
    }

    function testResolveUsesBoundMarketStartTime() public {
        uint48 marketStartTime = uint48(block.timestamp + 3 days);

        vm.prank(binderAddr);
        oracle.bind(
            proposal, address(yesPool), address(noPool), yesCompany, noCompany, marketStartTime
        );

        uint256 deadline = uint256(marketStartTime) + TRADING_PERIOD;
        vm.warp(deadline - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyTWAPOracle.TradingNotEnded.selector, proposal, deadline, block.timestamp
            )
        );
        oracle.resolve(proposal);
    }

    function testResolveRevertsIfAlreadyResolved() public {
        _bindAndAdvance();

        // Set pool data for first resolution.
        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        oracle.resolve(proposal);

        vm.expectRevert(
            abi.encodeWithSelector(FutarchyTWAPOracle.AlreadyResolved.selector, proposal)
        );
        oracle.resolve(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — TWAP comparison
    // ═══════════════════════════════════════════════════════

    function testResolveYesWhenYesTickExceedsNo() public {
        _bindAndAdvance();

        // YES avg tick = 100, NO avg tick = 50
        // Both pools: company is token0 → sign = +1
        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertTrue(accepted);
    }

    function testResolveNoWhenNoTickExceedsYes() public {
        _bindAndAdvance();

        // YES avg tick = 50, NO avg tick = 100
        yesPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveNoOnExactTieWithZeroThreshold() public {
        _bindAndAdvance();

        // Both avg ticks = 100. With threshold=0, YES must EXCEED NO
        // (strict >), so tie → NO.
        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveNoAtThresholdBoundary() public {
        // Deploy oracle with threshold = 10
        FutarchyTWAPOracle oracleT =
            new FutarchyTWAPOracle(dao, binderAddr, TRADING_PERIOD, TWAP_WINDOW, 10);

        vm.prank(binderAddr);
        oracleT.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        vm.warp(block.timestamp + TRADING_PERIOD);

        // YES avg tick = 60, NO avg tick = 50. Diff = 10 = threshold.
        // YES must strictly EXCEED NO + threshold, so 60 > 50 + 10 is
        // false → NO.
        yesPool.setTickCumulatives(0, 60 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracleT.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveYesAboveThreshold() public {
        FutarchyTWAPOracle oracleT =
            new FutarchyTWAPOracle(dao, binderAddr, TRADING_PERIOD, TWAP_WINDOW, 10);

        vm.prank(binderAddr);
        oracleT.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        vm.warp(block.timestamp + TRADING_PERIOD);

        // YES avg tick = 61, NO avg tick = 50. Diff = 11 > threshold
        // (10) → YES.
        yesPool.setTickCumulatives(0, 61 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracleT.resolve(proposal);
        assertTrue(accepted);
    }

    function testResolveWithNegativeTicks() public {
        _bindAndAdvance();

        // YES avg tick = -50, NO avg tick = -100. YES > NO → accepted.
        yesPool.setTickCumulatives(0, -50 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, -100 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertTrue(accepted);
    }

    function testResolveEmitsEvent() public {
        _bindAndAdvance();

        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        vm.expectEmit(true, false, false, true);
        emit ProposalResolved(proposal, true, 100, 50);
        oracle.resolve(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — token ordering normalization
    // ═══════════════════════════════════════════════════════

    function testResolveInvertedTokenOrdering() public {
        // Create pools where company token is token1 (inverted).
        // Token addresses: currency < company so currency = token0.
        address companyHigh = address(0xFF);
        address currencyLow = address(0x01);

        MockAlgebraPoolTWAP invertedYesPool = new MockAlgebraPoolTWAP(currencyLow, companyHigh);
        MockAlgebraPoolTWAP invertedNoPool = new MockAlgebraPoolTWAP(currencyLow, companyHigh);

        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(invertedYesPool),
            address(invertedNoPool),
            companyHigh, // yesBase = token1 → sign = -1
            companyHigh, // noBase = token1 → sign = -1
            uint48(block.timestamp)
        );

        vm.warp(block.timestamp + TRADING_PERIOD);

        // Raw tick delta = -100 * window for YES.
        // Sign = -1 → economic avg tick = -(-100) = +100.
        // Raw tick delta = -50 * window for NO.
        // Sign = -1 → economic avg tick = -(-50) = +50.
        // YES (100) > NO (50) → accepted.
        invertedYesPool.setTickCumulatives(0, -100 * int56(int32(TWAP_WINDOW)));
        invertedNoPool.setTickCumulatives(0, -50 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertTrue(accepted);
    }

    function testResolveMixedOrdering() public {
        // YES pool: company is token0 (normal) → sign = +1
        // NO pool: company is token1 (inverted) → sign = -1
        address noCompanyHigh = address(0xFF);
        address noCurrencyLow = address(0x01);

        MockAlgebraPoolTWAP normalYesPool = new MockAlgebraPoolTWAP(yesCompany, yesCurrency);
        MockAlgebraPoolTWAP invertedNoPool2 = new MockAlgebraPoolTWAP(noCurrencyLow, noCompanyHigh);

        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(normalYesPool),
            address(invertedNoPool2),
            yesCompany, // token0 → sign = +1
            noCompanyHigh, // token1 → sign = -1
            uint48(block.timestamp)
        );

        vm.warp(block.timestamp + TRADING_PERIOD);

        // YES: raw delta = 80 * window, sign +1 → economic = 80
        // NO: raw delta = -60 * window, sign -1 → economic = 60
        // YES (80) > NO (60) → accepted.
        normalYesPool.setTickCumulatives(0, 80 * int56(int32(TWAP_WINDOW)));
        invertedNoPool2.setTickCumulatives(0, -60 * int56(int32(TWAP_WINDOW)));

        bool accepted = oracle.resolve(proposal);
        assertTrue(accepted);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — broken pool (gas griefing protection)
    // ═══════════════════════════════════════════════════════

    function testResolveSettlesNoOnBrokenYesPool() public {
        yesPool.setShouldRevert(true);
        _bindAndAdvance();

        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        // YES pool reverts → proposal defaults to rejected.
        bool accepted = oracle.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveSettlesNoOnBrokenNoPool() public {
        noPool.setShouldRevert(true);
        _bindAndAdvance();

        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));

        // NO pool reverts → proposal defaults to rejected.
        bool accepted = oracle.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveSettlesNoOnBothPoolsBroken() public {
        yesPool.setShouldRevert(true);
        noPool.setShouldRevert(true);
        _bindAndAdvance();

        bool accepted = oracle.resolve(proposal);
        assertFalse(accepted);
    }

    function testResolveRevertsInsufficientGasOnYesPool() public {
        // Use gas griefing pool that burns all gas.
        GasGriefingAlgebraPool gasPool = new GasGriefingAlgebraPool(yesCompany, yesCurrency);

        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(gasPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        vm.warp(block.timestamp + TRADING_PERIOD);
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        // With limited gas, the pool OOGs and the remaining gas is too
        // low → InsufficientGas revert.
        vm.expectRevert(FutarchyTWAPOracle.InsufficientGas.selector);
        oracle.resolve{gas: 100_000}(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  getDecision()
    // ═══════════════════════════════════════════════════════

    function testGetDecisionBeforeResolution() public {
        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );

        (bool resolved, bool accepted) = oracle.getDecision(proposal);
        assertFalse(resolved);
        assertFalse(accepted);
    }

    function testGetDecisionAfterResolution() public {
        _bindAndAdvance();

        yesPool.setTickCumulatives(0, 100 * int56(int32(TWAP_WINDOW)));
        noPool.setTickCumulatives(0, 50 * int56(int32(TWAP_WINDOW)));

        oracle.resolve(proposal);

        (bool resolved, bool accepted) = oracle.getDecision(proposal);
        assertTrue(resolved);
        assertTrue(accepted);
    }

    function testGetDecisionUnboundProposal() public view {
        (bool resolved, bool accepted) = oracle.getDecision(address(0xDEAD));
        assertFalse(resolved);
        assertFalse(accepted);
    }

    // ═══════════════════════════════════════════════════════
    //  setConfig()
    // ═══════════════════════════════════════════════════════

    function testSetConfigFromDAO() public {
        vm.prank(dao);
        oracle.setConfig(14 days, 2 days, 5);

        assertEq(oracle.tradingPeriod(), 14 days);
        assertEq(oracle.twapWindow(), 2 days);
        assertEq(oracle.thresholdTicks(), 5);
    }

    function testSetConfigEmitsEvent() public {
        vm.prank(dao);
        vm.expectEmit(false, false, false, true);
        emit ConfigUpdated(14 days, 2 days, 5);
        oracle.setConfig(14 days, 2 days, 5);
    }

    function testSetConfigRevertsFromNonDAO() public {
        vm.expectRevert(FutarchyTWAPOracle.NotDAO.selector);
        oracle.setConfig(14 days, 2 days, 5);
    }

    function testSetConfigRevertsInvalidWindow() public {
        vm.prank(dao);
        vm.expectRevert(
            abi.encodeWithSelector(FutarchyTWAPOracle.InvalidConfig.selector, 1 days, 2 days)
        );
        oracle.setConfig(1 days, 2 days, 5);
    }

    function testSetConfigRevertsZeroWindow() public {
        vm.prank(dao);
        vm.expectRevert(
            abi.encodeWithSelector(FutarchyTWAPOracle.InvalidConfig.selector, 1 days, 0)
        );
        oracle.setConfig(1 days, 0, 5);
    }

    // ═══════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════

    function _bindAndAdvance() internal {
        vm.prank(binderAddr);
        oracle.bind(
            proposal,
            address(yesPool),
            address(noPool),
            yesCompany,
            noCompany,
            uint48(block.timestamp)
        );
        vm.warp(block.timestamp + TRADING_PERIOD);
    }
}
