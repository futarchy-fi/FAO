// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {
    GenesisVault,
    IGenesisArbitration,
    IGenesisBootstrapHook,
    IGenesisFlm
} from "../src/GenesisVault.sol";
import {GenesisTreasuryExecutor} from "../src/GenesisTreasuryExecutor.sol";
import {
    GenesisArbitrationMock,
    GenesisAssetMock,
    GenesisManagerMock,
    GenesisWethMock
} from "./mocks/GenesisVaultMocks.sol";

interface IBuybackCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external;
}

contract BuybackReceiptMock {
    address public spotPool;
    address public guard;

    function setBuybackDependencies(address pool_, address guard_) external {
        spotPool = pool_;
        guard = guard_;
    }

    function prepareAndAssert(uint256) external {}
}

contract BuybackFactoryMock {
    address public pool;
    address public token0;
    address public token1;
    uint24 public fee;

    function setPool(address tokenA, address tokenB, uint24 fee_, address pool_) external {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        pool = pool_;
    }

    function getPool(address tokenA, address tokenB, uint24 fee_) external view returns (address) {
        (address low, address high) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return low == token0 && high == token1 && fee_ == fee ? pool : address(0);
    }
}

contract BuybackPoolMock {
    using SafeERC20 for IERC20;

    uint24 public constant fee = 500;
    uint160 private constant Q96 = uint160(1) << 96;
    uint160 private constant UP_CURRENT = 1_451_404_646_985_709_758_556_457_135;
    uint160 private constant DOWN_CURRENT = 4_324_846_105_752_122_384_442_905_378_221;

    address public immutable token0;
    address public immutable token1;
    IERC20 public immutable company;
    IERC20 public immutable weth;
    bool public immutable companyIsToken0;

    uint160 public sqrtPriceX96;
    int24 public currentTick;
    int56 public twapDelta;
    uint16 public spendBps = 10_000;
    uint256 public outputOverride;
    bool public overOwe;
    bool public omitCallback;
    bool public secondCallback;
    uint160 public lastPriceLimit;

    constructor(IERC20 company_, IERC20 weth_) {
        company = company_;
        weth = weth_;
        companyIsToken0 = address(company_) < address(weth_);
        (token0, token1) = companyIsToken0
            ? (address(company_), address(weth_))
            : (address(weth_), address(company_));
        _setMeanTick(companyIsToken0 ? int24(-80_000) : int24(80_000));
    }

    function setMeanTick(int24 tick) external {
        _setMeanTick(tick);
    }

    function setTwapDelta(int56 delta) external {
        twapDelta = delta;
        currentTick = _meanTick();
    }

    function setSpendBps(uint16 value) external {
        spendBps = value;
    }

    function setOutputOverride(uint256 value) external {
        outputOverride = value;
    }

    function setAttack(bool overOwe_, bool omitCallback_, bool secondCallback_) external {
        overOwe = overOwe_;
        omitCallback = omitCallback_;
        secondCallback = secondCallback_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, currentTick, 0, 2, 2, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory ticks, uint160[] memory secondsPerLiquidity)
    {
        ticks = new int56[](secondsAgos.length);
        secondsPerLiquidity = new uint160[](secondsAgos.length);
        if (secondsAgos.length == 2) ticks[1] = twapDelta;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes calldata
    ) external returns (int256 amount0, int256 amount1) {
        require(recipient == msg.sender && amountSpecified > 0);
        require(zeroForOne == (address(weth) == token0));
        uint256 spend = uint256(amountSpecified) * spendBps / 10_000;
        uint256 output = outputOverride == 0 ? spend * 2000 : outputOverride;
        company.safeTransfer(recipient, output);

        uint256 owed = overOwe ? uint256(amountSpecified) + 1 : spend;
        (amount0, amount1) = address(weth) == token0
            ? (int256(owed), -int256(output))
            : (-int256(output), int256(owed));
        if (!omitCallback) {
            IBuybackCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
            if (secondCallback) {
                IBuybackCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, "");
            }
        }
        lastPriceLimit = limit;
        if (spend == uint256(amountSpecified)) {
            sqrtPriceX96 = limit;
            currentTick = companyIsToken0 ? _meanTick() + 50 : _meanTick() - 50;
        }
    }

    function initialize(uint160 value) external {
        sqrtPriceX96 = value;
    }

    function increaseObservationCardinalityNext(uint16) external {}

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function _setMeanTick(int24 tick) private {
        currentTick = tick;
        twapDelta = int56(tick) * int56(uint56(30 minutes));
        sqrtPriceX96 = companyIsToken0 ? UP_CURRENT : DOWN_CURRENT;
    }

    function _meanTick() private view returns (int24) {
        int56 divisor = int56(uint56(30 minutes));
        int56 mean = twapDelta / divisor;
        if (twapDelta < 0 && twapDelta % divisor != 0) mean--;
        return int24(mean);
    }
}

contract BuybackGuardMock {
    uint32 public constant TWAP_WINDOW = 30 minutes;
    int24 public constant MAX_TICK_DEVIATION = 50;
    BuybackFactoryMock public immutable FACTORY;
    uint24 public immutable FEE;
    bool public stable = true;

    constructor(BuybackFactoryMock factory, uint24 fee_) {
        FACTORY = factory;
        FEE = fee_;
    }

    function setStable(bool value) external {
        stable = value;
    }

    function assertStablePair(address tokenA, address tokenB) external view {
        require(stable);
        address poolAddress = FACTORY.getPool(tokenA, tokenB, FEE);
        require(poolAddress != address(0));
        BuybackPoolMock pool = BuybackPoolMock(poolAddress);
        (, int24 current,,,,,) = pool.slot0();
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        (int56[] memory cumulative,) = pool.observe(secondsAgos);
        int56 divisor = int56(uint56(TWAP_WINDOW));
        int56 mean = (cumulative[1] - cumulative[0]) / divisor;
        if (cumulative[1] - cumulative[0] < 0 && (cumulative[1] - cumulative[0]) % divisor != 0) {
            mean--;
        }
        int256 deviation = int256(current) - mean;
        if (deviation < 0) deviation = -deviation;
        require(deviation <= MAX_TICK_DEVIATION);
    }
}

contract BuybackVaultMock {
    IERC20 public immutable WETH;
    IERC20 public immutable COMPANY_TOKEN;
    address public immutable BOOTSTRAP_HOOK;
    GenesisTreasuryExecutor public immutable executor;
    uint256 public supply;

    constructor(IERC20 company, IERC20 weth, address receipt, uint256 supply_) {
        COMPANY_TOKEN = company;
        WETH = weth;
        BOOTSTRAP_HOOK = receipt;
        supply = supply_;
        executor = new GenesisTreasuryExecutor(address(this));
    }

    function effectiveSupply() external view returns (uint256) {
        return supply;
    }

    function buyback() external returns (uint256, uint256) {
        return executor.buyback();
    }

    function executeSelfBuyback() external returns (bytes memory) {
        return executor.execute(address(executor), 0, abi.encodeCall(executor.buyback, ()));
    }

    function executeSelfCallback() external returns (bytes memory) {
        return executor.execute(
            address(executor),
            0,
            abi.encodeCall(executor.uniswapV3SwapCallback, (int256(1), int256(-1), ""))
        );
    }

    function releaseWeth(address payable recipient, uint256 amount) external {
        executor.transferAsset(address(WETH), recipient, amount);
    }
}

contract GenesisBuybackTest is Test {
    using Math for uint256;

    uint160 private constant UP_LIMIT = 1_455_037_516_157_182_476_416_095_806;
    uint160 private constant DOWN_LIMIT = 4_314_048_033_596_260_902_551_972_864_829;

    struct BuybackCase {
        GenesisAssetMock company;
        GenesisAssetMock weth;
        BuybackReceiptMock receipt;
        BuybackFactoryMock factory;
        BuybackGuardMock guard;
        BuybackPoolMock pool;
        BuybackVaultMock vault;
        GenesisTreasuryExecutor executor;
    }

    function setUp() public {
        vm.warp(1_000_000);
    }

    function testBothTokenOrientationsClampToStableEnvelope() public {
        for (uint256 i; i < 2; ++i) {
            BuybackCase memory c = _case(i == 0, 1 ether, 1000 ether);
            (uint256 spent, uint256 bought) = c.vault.buyback();
            assertEq(spent, 0.01 ether);
            assertEq(bought, 20 ether);
            assertEq(c.pool.lastPriceLimit(), c.pool.companyIsToken0() ? UP_LIMIT : DOWN_LIMIT);
            c.guard.assertStablePair(address(c.company), address(c.weth));
        }
    }

    function testStrictTwapEqualityRefuses() public {
        BuybackCase memory c = _case(true, 1_052_631_578_947_368_422, 1 ether);
        c.pool.setMeanTick(0);
        vm.expectRevert(GenesisTreasuryExecutor.NothingToBuy.selector);
        c.vault.buyback();
    }

    function testNegativeFractionalMeanRoundsLikeGuard() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        c.pool.setTwapDelta(int56(-80_000) * int56(uint56(30 minutes)) - 1);
        c.vault.buyback();
        assertEq(c.pool.lastPriceLimit(), 1_454_964_769_737_310_643_440_511_823);
        c.guard.assertStablePair(address(c.company), address(c.weth));
    }

    function testPostconditionRejectsFeeRoundingLeakAndLeavesWindowUntouched() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        uint256 maxAllIn = 0.000_95 ether;
        uint256 minimumBought = Math.mulDiv(0.01 ether, 1 ether, maxAllIn, Math.Rounding.Up);
        c.pool.setOutputOverride(minimumBought - 1);

        vm.expectRevert(GenesisTreasuryExecutor.InvalidBuybackResult.selector);
        c.vault.buyback();
        assertEq(c.executor.buybackWindowStart(), 0);
        assertEq(c.executor.buybackWethSpent(), 0);
        assertEq(c.weth.balanceOf(address(c.executor)), 1 ether);

        c.pool.setOutputOverride(minimumBought);
        (uint256 spent, uint256 bought) = c.vault.buyback();
        assertEq(spent, 0.01 ether);
        assertEq(bought, minimumBought);
    }

    function testPartialFillAccountsActualSpendAndAnchoredReset() public {
        BuybackCase memory c = _case(false, 1 ether, 1000 ether);
        c.pool.setSpendBps(5000);
        (uint256 first,) = c.vault.buyback();
        assertEq(first, 0.005 ether);
        uint256 windowStart = c.executor.buybackWindowStart();
        assertEq(windowStart, block.timestamp);

        c.pool.setSpendBps(10_000);
        (uint256 second,) = c.vault.buyback();
        assertEq(second, 0.004_95 ether);
        assertEq(c.executor.buybackWethSpent(), first + second);
        assertEq(c.executor.buybackWindowStart(), windowStart);
        assertLe(c.executor.buybackWethSpent(), c.executor.BUYBACK_DAILY_CAP());

        vm.warp(windowStart + c.executor.BUYBACK_WINDOW() - 1);
        vm.expectRevert(GenesisTreasuryExecutor.NothingToBuy.selector);
        c.vault.buyback();
        vm.warp(windowStart + c.executor.BUYBACK_WINDOW());
        c.pool.setMeanTick(c.pool.companyIsToken0() ? int24(-80_000) : int24(80_000));
        (uint256 resetSpend,) = c.vault.buyback();
        assertEq(resetSpend, 0.009_900_5 ether);
        assertEq(c.executor.buybackWindowStart(), block.timestamp);
        assertEq(c.executor.buybackWethSpent(), resetSpend);
    }

    function testRawCapWinsAndSubHundredWeiTreasuryIsDisabled() public {
        BuybackCase memory capped = _case(true, 10 ether, 10_000 ether);
        (uint256 spent,) = capped.vault.buyback();
        assertEq(spent, capped.executor.BUYBACK_DAILY_CAP());
        assertEq(capped.executor.buybackWethSpent(), spent);

        BuybackCase memory dust = _case(true, 99, 100);
        vm.expectRevert(GenesisTreasuryExecutor.NothingToBuy.selector);
        dust.vault.buyback();
        assertEq(dust.executor.buybackWethSpent(), 0);
    }

    function testMidWindowDepositRaisesLiveCapOnlyUpToRawCap() public {
        BuybackCase memory c = _case(true, 0.4 ether, 1000 ether);
        c.pool.setOutputOverride(20 ether);
        (uint256 first,) = c.vault.buyback();
        assertEq(first, 0.004 ether);
        uint256 windowStart = c.executor.buybackWindowStart();

        c.weth.mint(address(c.executor), 10 ether);
        c.pool.setMeanTick(-80_000);
        (uint256 second,) = c.vault.buyback();
        assertEq(second, 0.006 ether);
        assertEq(c.executor.buybackWindowStart(), windowStart);
        assertEq(c.executor.buybackWethSpent(), c.executor.BUYBACK_DAILY_CAP());
    }

    function testMidWindowOutflowRefusesUntilAnchoredReset() public {
        BuybackCase memory c = _case(false, 1 ether, 1000 ether);
        c.pool.setSpendBps(5000);
        c.pool.setOutputOverride(20 ether);
        (uint256 first,) = c.vault.buyback();
        assertEq(first, 0.005 ether);
        uint256 windowStart = c.executor.buybackWindowStart();

        c.vault.releaseWeth(payable(address(0xCAFE)), 0.595 ether);
        assertEq(c.weth.balanceOf(address(c.executor)), 0.4 ether);
        c.pool.setMeanTick(80_000);
        c.pool.setSpendBps(10_000);
        vm.expectRevert(GenesisTreasuryExecutor.NothingToBuy.selector);
        c.vault.buyback();
        assertEq(c.executor.buybackWethSpent(), first);

        vm.warp(windowStart + c.executor.BUYBACK_WINDOW());
        (uint256 resetSpend,) = c.vault.buyback();
        assertEq(resetSpend, 0.004 ether);
        assertEq(c.executor.buybackWindowStart(), block.timestamp);
        assertEq(c.executor.buybackWethSpent(), resetSpend);
    }

    function testTrueZeroFillRollsBackEveryBalanceAndWindow() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        c.pool.setSpendBps(0);
        c.pool.setAttack(false, true, false);
        uint256 executorWeth = c.weth.balanceOf(address(c.executor));
        uint256 executorCompany = c.company.balanceOf(address(c.executor));
        uint256 poolCompany = c.company.balanceOf(address(c.pool));
        (uint160 poolPrice,,,,,,) = c.pool.slot0();

        vm.expectRevert(GenesisTreasuryExecutor.InvalidBuybackResult.selector);
        c.vault.buyback();
        assertEq(c.weth.balanceOf(address(c.executor)), executorWeth);
        assertEq(c.company.balanceOf(address(c.executor)), executorCompany);
        assertEq(c.company.balanceOf(address(c.pool)), poolCompany);
        (uint160 priceAfter,,,,,,) = c.pool.slot0();
        assertEq(priceAfter, poolPrice);
        assertEq(c.executor.buybackWindowStart(), 0);
        assertEq(c.executor.buybackWethSpent(), 0);
    }

    function testCallbackAndSelfCallCannotBypassVaultOrBudget() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.InvalidCallback.selector,
                address(this),
                int256(1),
                int256(-1)
            )
        );
        c.executor.uniswapV3SwapCallback(1, -1, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.CallFailed.selector,
                abi.encodeWithSelector(
                    GenesisTreasuryExecutor.Unauthorized.selector, address(c.executor)
                )
            )
        );
        c.vault.executeSelfBuyback();

        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.CallFailed.selector,
                abi.encodeWithSelector(
                    GenesisTreasuryExecutor.InvalidCallback.selector,
                    address(c.executor),
                    int256(1),
                    int256(-1)
                )
            )
        );
        c.vault.executeSelfCallback();

        c.pool.setAttack(true, false, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.InvalidCallback.selector,
                address(c.pool),
                -int256(20 ether),
                int256(0.01 ether + 1)
            )
        );
        c.vault.buyback();
        assertEq(c.executor.buybackWethSpent(), 0);

        c.pool.setAttack(false, true, false);
        vm.expectRevert(GenesisTreasuryExecutor.InvalidBuybackResult.selector);
        c.vault.buyback();
        assertEq(c.executor.buybackWethSpent(), 0);

        c.pool.setAttack(false, false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.InvalidCallback.selector,
                address(c.pool),
                -int256(20 ether),
                int256(0.01 ether)
            )
        );
        c.vault.buyback();
        assertEq(c.executor.buybackWethSpent(), 0);

        c.pool.setAttack(false, false, false);
        c.vault.buyback();
        assertGt(c.executor.buybackWethSpent(), 0);
    }

    function testGuardAndCanonicalPoolAreMandatory() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        c.guard.setStable(false);
        vm.expectRevert();
        c.vault.buyback();

        c.guard.setStable(true);
        c.factory.setPool(address(c.company), address(c.weth), 500, address(0xBAD));
        vm.expectRevert(GenesisTreasuryExecutor.InvalidBuybackPool.selector);
        c.vault.buyback();
    }

    function testWrongGuardFeeIsRejected() public {
        BuybackCase memory c = _case(true, 1 ether, 1000 ether);
        BuybackGuardMock wrongFee = new BuybackGuardMock(c.factory, 3000);
        c.receipt.setBuybackDependencies(address(c.pool), address(wrongFee));
        vm.expectRevert(GenesisTreasuryExecutor.InvalidBuybackPool.selector);
        c.vault.buyback();
        assertEq(c.executor.buybackWethSpent(), 0);
    }

    function testVaultBuybackBurnsOnlyOutputAndCoexistsWithRagequit() public {
        GenesisWethMock weth = new GenesisWethMock();
        GenesisArbitrationMock arbitration = new GenesisArbitrationMock();
        BuybackReceiptMock receipt = new BuybackReceiptMock();
        GenesisVault.AssetPolicyConfig[] memory policies = new GenesisVault.AssetPolicyConfig[](0);
        GenesisVault.Config memory config = GenesisVault.Config({
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            weth: weth,
            assembler: address(this),
            arbitration: IGenesisArbitration(address(arbitration)),
            bootstrapHook: IGenesisBootstrapHook(address(receipt)),
            saleEnd: uint64(block.timestamp + 1 days),
            bootstrapDeadline: uint64(block.timestamp + 3 days),
            saleCap: 1000 ether,
            minimumRaise: 0.1 ether,
            tokenMaxSupply: 5000 ether,
            initialPrice: 0.001 ether,
            slope: 0.000_001 ether,
            bootstrapBps: 5000,
            assetPolicies: policies
        });
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        GenesisVault vault = new GenesisVault(config, grants);
        address buyer = address(0xB0B);
        weth.mint(buyer, 10 ether);
        vm.startPrank(buyer);
        weth.approve(address(vault), type(uint256).max);
        vault.buy(400 ether, type(uint256).max, vault.SALE_END());
        vm.stopPrank();
        vm.warp(vault.SALE_END());
        vault.seal();
        GenesisManagerMock manager =
            new GenesisManagerMock(address(vault), address(vault.COMPANY_TOKEN()), address(weth));
        vault.bindManager(IGenesisFlm(address(manager)));
        vault.finalize();

        BuybackFactoryMock factory = new BuybackFactoryMock();
        BuybackPoolMock pool = new BuybackPoolMock(vault.COMPANY_TOKEN(), weth);
        BuybackGuardMock guard = new BuybackGuardMock(factory, 500);
        factory.setPool(address(vault.COMPANY_TOKEN()), address(weth), 500, address(pool));
        receipt.setBuybackDependencies(address(pool), address(guard));
        address executor = address(vault.TREASURY_EXECUTOR());
        vm.startPrank(address(manager));
        vault.COMPANY_TOKEN().transfer(address(pool), 50 ether);
        vault.COMPANY_TOKEN().transfer(executor, 2 ether);
        vm.stopPrank();

        uint256 executorCompanyBefore = vault.COMPANY_TOKEN().balanceOf(executor);
        uint256 supplyBefore = vault.COMPANY_TOKEN().totalSupply();
        manager.setConditionalMode(true);
        (uint256 spent, uint256 burned) = vault.buyback();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(vault.COMPANY_TOKEN().balanceOf(executor), executorCompanyBefore);
        assertEq(vault.COMPANY_TOKEN().totalSupply(), supplyBefore - burned);

        vault.claim(buyer);
        address[] memory extras = new address[](0);
        vm.prank(buyer);
        vault.ragequit(1 ether, payable(buyer), extras);
        assertEq(vault.COMPANY_TOKEN().balanceOf(buyer), 399 ether);
    }

    function testVaultBuybackIsLiveOnly() public {
        GenesisWethMock weth = new GenesisWethMock();
        GenesisArbitrationMock arbitration = new GenesisArbitrationMock();
        BuybackReceiptMock receipt = new BuybackReceiptMock();
        GenesisVault.AssetPolicyConfig[] memory policies = new GenesisVault.AssetPolicyConfig[](0);
        GenesisVault.Config memory config = GenesisVault.Config({
            tokenName: "FAO",
            tokenSymbol: "FAO",
            weth: weth,
            assembler: address(this),
            arbitration: IGenesisArbitration(address(arbitration)),
            bootstrapHook: IGenesisBootstrapHook(address(receipt)),
            saleEnd: uint64(block.timestamp + 1 days),
            bootstrapDeadline: uint64(block.timestamp + 2 days),
            saleCap: 1 ether,
            minimumRaise: 2,
            tokenMaxSupply: 3 ether,
            initialPrice: 1 ether,
            slope: 0,
            bootstrapBps: 5000,
            assetPolicies: policies
        });
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        GenesisVault vault = new GenesisVault(config, grants);
        vm.expectRevert(GenesisVault.InvalidPhase.selector);
        vault.buyback();
    }

    function _case(bool companyIsToken0, uint256 wethBalance, uint256 supply)
        private
        returns (BuybackCase memory c)
    {
        GenesisAssetMock first = new GenesisAssetMock("FIRST");
        GenesisAssetMock second = new GenesisAssetMock("SECOND");
        GenesisAssetMock low = address(first) < address(second) ? first : second;
        GenesisAssetMock high = address(first) < address(second) ? second : first;
        c.company = companyIsToken0 ? low : high;
        c.weth = companyIsToken0 ? high : low;
        c.receipt = new BuybackReceiptMock();
        c.factory = new BuybackFactoryMock();
        c.pool = new BuybackPoolMock(c.company, c.weth);
        c.guard = new BuybackGuardMock(c.factory, c.pool.fee());
        c.factory.setPool(address(c.company), address(c.weth), c.pool.fee(), address(c.pool));
        c.receipt.setBuybackDependencies(address(c.pool), address(c.guard));
        c.vault = new BuybackVaultMock(c.company, c.weth, address(c.receipt), supply);
        c.executor = c.vault.executor();
        c.weth.mint(address(c.executor), wethBalance);
        c.company.mint(address(c.pool), supply * 2);
    }
}
