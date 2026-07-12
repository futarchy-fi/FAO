// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

import {
    GenesisVault,
    IGenesisArbitration,
    IGenesisBootstrapHook,
    IGenesisFlm
} from "../src/GenesisVault.sol";
import {FaoToken} from "../src/FaoToken.sol";
import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";
import {
    GenesisArbitrationMock,
    GenesisAssetMock,
    GenesisBootstrapHookMock,
    GenesisManagerMock,
    GenesisNativeForwarder,
    GenesisTreasuryTargetMock,
    GenesisWethMock
} from "./mocks/GenesisVaultMocks.sol";

contract GenesisVaultTest is Test {
    uint256 internal constant SALE_CAP = 1000 ether;
    uint256 internal constant MINIMUM_RAISE = 0.1 ether;
    uint256 internal constant GRANT_AMOUNT = 200 ether;
    uint256 internal constant INITIAL_PRICE = 0.001 ether;
    uint256 internal constant SLOPE = 0.000_001 ether;
    uint16 internal constant BOOTSTRAP_BPS = 5000;

    address internal constant BUYER = address(0xB0B);
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    GenesisWethMock internal weth;
    GenesisArbitrationMock internal arbitration;

    function setUp() public {
        vm.warp(1_000_000);
        weth = new GenesisWethMock();
        arbitration = new GenesisArbitrationMock();
    }

    function testCurveReserveDifferencesAreExactlySplitIndependent() public {
        GenesisVault oneShot = _deployVault();
        GenesisVault split = _deployVault();
        uint256 amount = 333 ether + 17;
        uint256 first = 111 ether + 5;

        _fundAndApprove(BUYER, address(oneShot), 10 ether);
        _fundAndApprove(BUYER, address(split), 10 ether);
        uint256 deadline = oneShot.SALE_END();
        vm.prank(BUYER);
        uint256 oneShotCost = oneShot.buy(amount, type(uint256).max, deadline);
        vm.startPrank(BUYER);
        uint256 firstCost = split.buy(first, type(uint256).max, deadline);
        uint256 secondCost = split.buy(amount - first, type(uint256).max, deadline);
        vm.stopPrank();

        assertEq(firstCost + secondCost, oneShotCost);
        assertEq(oneShotCost, oneShot.reserveAt(amount));
        assertEq(split.totalRaised(), split.reserveAt(amount));
        assertEq(address(oneShot.COMPANY_TOKEN()).code.length > 0, true);
        assertEq(oneShot.COMPANY_TOKEN().totalSupply(), 0);
    }

    function testUnderMinimumSaleFailsAndAnyoneRefundsBuyerExactly() public {
        GenesisVault vault = _deployVault();
        uint256 initialBalance = 10 ether;
        _fundAndApprove(BUYER, address(vault), initialBalance);
        uint256 deadline = vault.SALE_END();
        vm.prank(BUYER);
        uint256 cost = vault.buy(25 ether, type(uint256).max, deadline);
        assertEq(weth.balanceOf(BUYER), initialBalance - cost);

        vm.warp(vault.SALE_END());
        vault.fail();
        vault.refund(BUYER);

        assertEq(uint256(vault.phase()), uint256(GenesisVault.Phase.FAILED));
        assertEq(weth.balanceOf(BUYER), initialBalance);
        assertEq(vault.contribution(BUYER), 0);
        assertEq(vault.purchased(BUYER), 0);
        assertEq(vault.COMPANY_TOKEN().totalSupply(), 0);
    }

    function testRevertingBootstrapStaysSealingThenDeadlineEnablesRefunds() public {
        GenesisVault vault = _deployVault();
        _buy(vault, BUYER, 400 ether);
        vm.warp(vault.SALE_END());
        vault.seal();
        GenesisManagerMock manager = _bindManager(vault);
        manager.setRevertBootstrap(true);

        vm.expectRevert(bytes("POOL_NOT_READY"));
        vault.finalize();
        assertEq(uint256(vault.phase()), uint256(GenesisVault.Phase.SEALING));
        assertEq(vault.COMPANY_TOKEN().totalSupply(), 0);
        assertEq(manager.totalSupply(), 0);

        vm.warp(vault.BOOTSTRAP_DEADLINE());
        vault.fail();
        uint256 before = weth.balanceOf(BUYER);
        uint256 refund = vault.contribution(BUYER);
        vault.refund(BUYER);
        assertEq(weth.balanceOf(BUYER), before + refund);
    }

    function testRevertingPoolHookLeavesSealingAndEveryBootstrapBalanceUnchanged() public {
        GenesisVault vault = _deployVault();
        _buy(vault, BUYER, 400 ether);
        vm.warp(vault.SALE_END());
        vault.seal();
        GenesisManagerMock manager = _bindManager(vault);
        GenesisBootstrapHookMock hook = GenesisBootstrapHookMock(address(vault.BOOTSTRAP_HOOK()));
        uint256 wethBefore = weth.balanceOf(address(vault));
        hook.setShouldRevert(true);

        vm.expectRevert(bytes("POOL_PRICE_MISMATCH"));
        vault.finalize();
        assertEq(uint256(vault.phase()), uint256(GenesisVault.Phase.SEALING));
        assertEq(vault.COMPANY_TOKEN().totalSupply(), 0);
        assertEq(weth.balanceOf(address(vault)), wethBefore);
        assertEq(weth.balanceOf(address(manager)), 0);
        assertEq(manager.totalSupply(), 0);
        assertEq(hook.calls(), 0);

        vm.warp(vault.BOOTSTRAP_DEADLINE());
        vault.fail();
        vault.refund(BUYER);
        assertEq(weth.balanceOf(BUYER), 10 ether);
    }

    function testSuccessfulBootstrapClaimAndImmutableVestingDenominator() public {
        (GenesisVault vault, GenesisManagerMock manager) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        (address wallet, uint64 start, uint64 duration, uint256 grantAmount) = vault.grants(0);

        assertTrue(token.mintingFinished());
        assertEq(token.balanceOf(address(vault)), vault.totalUnclaimedSold());
        assertEq(token.balanceOf(wallet), GRANT_AMOUNT);
        assertGt(manager.balanceOf(address(vault)), 0);
        assertGt(token.balanceOf(address(manager)), 0);
        assertEq(vault.effectiveSupply(), token.totalSupply() - grantAmount);

        vault.claim(BUYER);
        assertEq(token.balanceOf(BUYER), 400 ether);
        assertEq(vault.totalUnclaimedSold(), 0);
        uint256 beforeDonation = vault.effectiveSupply();
        vm.prank(BUYER);
        token.transfer(wallet, 10 ether);
        assertEq(vault.effectiveSupply(), beforeDonation);

        vm.warp(uint256(start) + uint256(duration) / 2);
        uint256 expectedUnvested = grantAmount - grantAmount / 2;
        assertEq(vault.effectiveSupply(), token.totalSupply() - expectedUnvested);
        VestingWallet(payable(wallet)).release(address(token));
        assertGt(token.balanceOf(BENEFICIARY), 0);
        assertEq(vault.effectiveSupply(), token.totalSupply() - expectedUnvested);
    }

    function testRagequitPaysRawFlmWethNativeAndSortedExtraProRata() public {
        (GenesisVault vault, GenesisManagerMock manager) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vault.claim(BUYER);
        GenesisAssetMock extra = new GenesisAssetMock("EXTRA");
        extra.mint(address(vault), 900 ether);
        vm.deal(address(vault), 3 ether);

        uint256 supply = vault.effectiveSupply();
        assertEq(supply, token.totalSupply() - GRANT_AMOUNT);
        uint256 amount = 100 ether;
        uint256 expectedWeth = weth.balanceOf(address(vault)) * amount / supply;
        uint256 expectedShares = manager.balanceOf(address(vault)) * amount / supply;
        uint256 expectedExtra = extra.balanceOf(address(vault)) * amount / supply;
        uint256 expectedNative = address(vault).balance * amount / supply;
        address[] memory extras = new address[](2);
        extras[0] = address(0);
        extras[1] = address(extra);

        uint256 nativeBefore = RECIPIENT.balance;
        vm.prank(BUYER);
        vault.ragequit(amount, payable(RECIPIENT), extras);

        assertEq(token.balanceOf(BUYER), 300 ether);
        assertEq(weth.balanceOf(RECIPIENT), expectedWeth);
        assertEq(manager.balanceOf(RECIPIENT), expectedShares);
        assertEq(extra.balanceOf(RECIPIENT), expectedExtra);
        assertEq(RECIPIENT.balance - nativeBefore, expectedNative);
        assertEq(token.balanceOf(address(manager)) > 0, true);
    }

    function testRagequitRejectsUnsortedDuplicateAndImplicitExtras() public {
        (GenesisVault vault,) = _makeLive();
        vault.claim(BUYER);
        GenesisAssetMock first = new GenesisAssetMock("A");
        GenesisAssetMock second = new GenesisAssetMock("B");
        address low = address(first) < address(second) ? address(first) : address(second);
        address high = address(first) < address(second) ? address(second) : address(first);

        address[] memory extras = new address[](2);
        extras[0] = high;
        extras[1] = low;
        vm.prank(BUYER);
        vm.expectRevert(GenesisVault.ExtrasNotStrictlySorted.selector);
        vault.ragequit(1 ether, payable(RECIPIENT), extras);

        extras[0] = low;
        extras[1] = low;
        vm.prank(BUYER);
        vm.expectRevert(GenesisVault.ExtrasNotStrictlySorted.selector);
        vault.ragequit(1 ether, payable(RECIPIENT), extras);

        address[] memory implicitAsset = new address[](1);
        implicitAsset[0] = address(weth);
        vm.prank(BUYER);
        vm.expectRevert(GenesisVault.InvalidExtraAsset.selector);
        vault.ragequit(1 ether, payable(RECIPIENT), implicitAsset);
    }

    function testRagequitNativePayoutMayBeForwardedBySmartWallet() public {
        (GenesisVault vault,) = _makeLive();
        vault.claim(BUYER);
        address payable sink = payable(address(0xD00D));
        GenesisNativeForwarder forwarder = new GenesisNativeForwarder(sink);
        vm.deal(address(vault), 2 ether);
        uint256 amount = 100 ether;
        uint256 expected = address(vault).balance * amount / vault.effectiveSupply();
        address[] memory extras = new address[](1);
        extras[0] = address(0);

        uint256 before = sink.balance;
        vm.prank(BUYER);
        vault.ragequit(amount, payable(address(forwarder)), extras);
        assertEq(sink.balance - before, expected);
        assertEq(address(forwarder).balance, 0);
    }

    function testClaimReserveGuardDetectsUndercollateralization() public {
        (GenesisVault vault,) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vm.prank(address(vault));
        token.transfer(RECIPIENT, 1);
        vm.expectRevert(GenesisVault.ClaimReserveUndercollateralized.selector);
        vault.effectiveSupply();
    }

    function testTreasuryAcceptedActionQueuesWaitsExecutesAndCannotReplay() public {
        (GenesisVault vault,) = _makeLive();
        GenesisTreasuryTargetMock target = new GenesisTreasuryTargetMock();
        vm.deal(address(vault), 2 ether);
        FAOTreasuryActions.TreasuryAction memory action = FAOTreasuryActions.TreasuryAction({
            target: address(target),
            value: 1 ether,
            data: abi.encodeCall(target.perform, (bytes32("wild-dream"))),
            salt: bytes32(uint256(7))
        });
        bytes32 actionHash = vault.treasuryActionHash(action);

        vm.expectRevert(GenesisVault.ArbitrationNotAccepted.selector);
        vault.queueTreasuryAction(action);
        arbitration.setOutcome(uint256(actionHash), true, true);
        vault.queueTreasuryAction(action);

        vm.expectRevert(GenesisVault.ActionInGracePeriod.selector);
        vault.executeTreasuryAction(action);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        bytes memory result = vault.executeTreasuryAction(action);
        assertEq(abi.decode(result, (uint256)), 1);
        assertEq(target.calls(), 1);
        assertEq(target.value(), 1 ether);
        assertEq(target.payload(), bytes32("wild-dream"));

        vm.expectRevert(GenesisVault.ActionAlreadyQueued.selector);
        vault.executeTreasuryAction(action);
    }

    function testTreasuryActionExpires() public {
        (GenesisVault vault,) = _makeLive();
        GenesisTreasuryTargetMock target = new GenesisTreasuryTargetMock();
        FAOTreasuryActions.TreasuryAction memory action = FAOTreasuryActions.TreasuryAction({
            target: address(target),
            value: 0,
            data: abi.encodeCall(target.perform, (bytes32("expired"))),
            salt: bytes32(uint256(8))
        });
        bytes32 actionHash = vault.treasuryActionHash(action);
        arbitration.setOutcome(uint256(actionHash), true, true);
        vault.queueTreasuryAction(action);
        vm.warp(block.timestamp + vault.TREASURY_GRACE() + vault.TREASURY_EXPIRY() + 1);
        vault.expireTreasuryAction(action);
        vm.expectRevert(GenesisVault.ActionExpired.selector);
        vault.executeTreasuryAction(action);
    }

    function testAcceptedTreasuryActionMayTargetCompanyToken() public {
        (GenesisVault vault,) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vault.claim(BUYER);
        FAOTreasuryActions.TreasuryAction memory action = FAOTreasuryActions.TreasuryAction({
            target: address(token),
            value: 0,
            data: abi.encodeCall(token.burnFromVault, (BUYER, 1 ether)),
            salt: bytes32(uint256(9))
        });
        bytes32 actionHash = vault.treasuryActionHash(action);
        arbitration.setOutcome(uint256(actionHash), true, true);
        vault.queueTreasuryAction(action);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryAction(action);
        assertEq(token.balanceOf(BUYER), 399 ether);
    }

    function _deployVault() internal returns (GenesisVault vault) {
        GenesisBootstrapHookMock hook = new GenesisBootstrapHookMock();
        vault = _deployVaultWithHook(hook);
    }

    function _deployVaultWithHook(GenesisBootstrapHookMock hook)
        internal
        returns (GenesisVault vault)
    {
        GenesisVault.GrantConfig[] memory grantConfigs = new GenesisVault.GrantConfig[](1);
        grantConfigs[0] = GenesisVault.GrantConfig({
            beneficiary: BENEFICIARY,
            start: uint64(block.timestamp + 2 days),
            duration: uint64(10 days),
            amount: GRANT_AMOUNT
        });
        GenesisVault.Config memory config = GenesisVault.Config({
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            weth: weth,
            assembler: address(this),
            arbitration: IGenesisArbitration(address(arbitration)),
            bootstrapHook: IGenesisBootstrapHook(address(hook)),
            saleEnd: uint64(block.timestamp + 1 days),
            bootstrapDeadline: uint64(block.timestamp + 3 days),
            saleCap: SALE_CAP,
            minimumRaise: MINIMUM_RAISE,
            tokenMaxSupply: 5000 ether,
            initialPrice: INITIAL_PRICE,
            slope: SLOPE,
            bootstrapBps: BOOTSTRAP_BPS
        });
        vault = new GenesisVault(config, grantConfigs);
    }

    function _bindManager(GenesisVault vault) internal returns (GenesisManagerMock manager) {
        manager =
            new GenesisManagerMock(address(vault), address(vault.COMPANY_TOKEN()), address(weth));
        vault.bindManager(IGenesisFlm(address(manager)));
    }

    function _makeLive() internal returns (GenesisVault vault, GenesisManagerMock manager) {
        vault = _deployVault();
        _buy(vault, BUYER, 400 ether);
        vm.warp(vault.SALE_END());
        vault.seal();
        manager = _bindManager(vault);
        vault.finalize();
    }

    function _buy(GenesisVault vault, address buyer, uint256 amount) internal {
        _fundAndApprove(buyer, address(vault), 10 ether);
        uint256 deadline = vault.SALE_END();
        vm.prank(buyer);
        vault.buy(amount, type(uint256).max, deadline);
    }

    function _fundAndApprove(address buyer, address vault, uint256 amount) internal {
        weth.mint(buyer, amount);
        vm.prank(buyer);
        weth.approve(vault, type(uint256).max);
    }
}
