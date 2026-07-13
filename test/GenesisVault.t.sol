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
import {GenesisTreasuryExecutor} from "../src/GenesisTreasuryExecutor.sol";
import {
    GenesisArbitrationMock,
    GenesisAssetMock,
    GenesisBootstrapHookMock,
    GenesisFeeAssetMock,
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

    function testRejectsSuccessThresholdThatCannotSeedAnyCollateral() public {
        GenesisBootstrapHookMock hook = new GenesisBootstrapHookMock();
        GenesisVault.Config memory config = _config(hook);
        config.minimumRaise = 1;
        config.bootstrapBps = 1;
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);

        vm.expectRevert(GenesisVault.InvalidConfig.selector);
        new GenesisVault(config, grants);
    }

    function testRejectsDuplicateAssetPoliciesAndAcceptsEightUniquePolicies() public {
        GenesisBootstrapHookMock hook = new GenesisBootstrapHookMock();
        GenesisVault.Config memory config = _config(hook);
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);

        config.assetPolicies[1] = config.assetPolicies[0];
        vm.expectRevert(GenesisVault.InvalidAssetPolicy.selector);
        new GenesisVault(config, grants);

        config.assetPolicies = new GenesisVault.AssetPolicyConfig[](8);
        for (uint256 i; i < config.assetPolicies.length; ++i) {
            GenesisAssetMock asset = new GenesisAssetMock("POLICY");
            config.assetPolicies[i] = GenesisVault.AssetPolicyConfig({
                asset: address(asset), c1: 1, c2: 2, tapBudget: 3, tapBudgetMax: 4
            });
        }
        GenesisVault vault = new GenesisVault(config, grants);
        assertEq(vault.assetPolicyCount(), 8);

        config.assetPolicies = new GenesisVault.AssetPolicyConfig[](9);
        vm.expectRevert(GenesisVault.InvalidConfig.selector);
        new GenesisVault(config, grants);
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
        assertEq(manager.balanceOf(address(vault)), 0);
        assertGt(manager.balanceOf(address(vault.TREASURY_EXECUTOR())), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertGt(weth.balanceOf(address(vault.TREASURY_EXECUTOR())), 0);
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
        address treasury = address(vault.TREASURY_EXECUTOR());
        extra.mint(treasury, 900 ether);
        vm.deal(treasury, 3 ether);

        uint256 supply = vault.effectiveSupply();
        assertEq(supply, token.totalSupply() - GRANT_AMOUNT);
        uint256 amount = 100 ether;
        uint256 expectedWeth = weth.balanceOf(treasury) * amount / supply;
        uint256 expectedShares = manager.balanceOf(treasury) * amount / supply;
        uint256 expectedExtra = extra.balanceOf(treasury) * amount / supply;
        uint256 expectedNative = treasury.balance * amount / supply;
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
        address treasury = address(vault.TREASURY_EXECUTOR());
        vm.deal(treasury, 2 ether);
        uint256 amount = 100 ether;
        uint256 expected = treasury.balance * amount / vault.effectiveSupply();
        address[] memory extras = new address[](1);
        extras[0] = address(0);

        uint256 before = sink.balance;
        vm.prank(BUYER);
        vault.ragequit(amount, payable(address(forwarder)), extras);
        assertEq(sink.balance - before, expected);
        assertEq(address(forwarder).balance, 0);
    }

    function testRagequitRejectsInexactExtraTokenAtomically() public {
        (GenesisVault vault,) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vault.claim(BUYER);
        GenesisFeeAssetMock feeAsset = new GenesisFeeAssetMock();
        address treasury = address(vault.TREASURY_EXECUTOR());
        feeAsset.mint(treasury, 100 ether);
        address[] memory extras = new address[](1);
        extras[0] = address(feeAsset);

        vm.prank(BUYER);
        vm.expectRevert(GenesisVault.InvalidAssetTransfer.selector);
        vault.ragequit(100 ether, payable(RECIPIENT), extras);

        assertEq(token.balanceOf(BUYER), 400 ether);
        assertEq(feeAsset.balanceOf(treasury), 100 ether);
        assertEq(feeAsset.balanceOf(RECIPIENT), 0);
    }

    function testPermissionlessSweepMovesOnlyMisdirectedTreasuryAssets() public {
        (GenesisVault vault,) = _makeLive();
        GenesisAssetMock extra = new GenesisAssetMock("STRAY");
        address treasury = address(vault.TREASURY_EXECUTOR());
        extra.mint(address(vault), 3 ether);
        vm.deal(address(vault), 2 ether);

        assertEq(vault.sweepToExecutor(address(extra)), 3 ether);
        assertEq(vault.sweepToExecutor(address(0)), 2 ether);
        assertEq(extra.balanceOf(treasury), 3 ether);
        assertEq(treasury.balance, 2 ether);

        address companyToken = address(vault.COMPANY_TOKEN());
        vm.expectRevert(GenesisVault.InvalidExtraAsset.selector);
        vault.sweepToExecutor(companyToken);
        assertEq(vault.COMPANY_TOKEN().balanceOf(address(vault)), vault.totalUnclaimedSold());
    }

    function testClaimReserveGuardDetectsUndercollateralization() public {
        (GenesisVault vault,) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vm.prank(address(vault));
        token.transfer(RECIPIENT, 1);
        vm.expectRevert(GenesisVault.ClaimReserveUndercollateralized.selector);
        vault.effectiveSupply();
    }

    function testTimeoutTransfersArePerAssetTapBoundedAndResetAfterWindow() public {
        (GenesisVault vault,) = _makeLive();
        weth.mint(address(vault.TREASURY_EXECUTOR()), 1 ether);
        uint256 before = weth.balanceOf(RECIPIENT);

        for (uint256 i; i < 2; ++i) {
            FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
                asset: address(weth), recipient: RECIPIENT, amount: 0.1 ether, salt: bytes32(i + 1)
            });
            bytes32 actionHash = vault.transferActionHash(action);
            arbitration.setOutcome(uint256(actionHash), true, true, false);
            vault.queueTreasuryTransfer(action);
            vm.warp(block.timestamp + vault.TREASURY_GRACE());
            vault.executeTreasuryTransfer(action);
        }
        assertEq(weth.balanceOf(RECIPIENT) - before, 0.2 ether);
        (, uint192 spent) = vault.tapStates(address(weth));
        assertEq(spent, 0.2 ether);

        FAOTreasuryActions.TransferAction memory over = FAOTreasuryActions.TransferAction({
            asset: address(weth), recipient: RECIPIENT, amount: 1, salt: bytes32(uint256(3))
        });
        arbitration.setOutcome(uint256(vault.transferActionHash(over)), true, true, false);
        vault.queueTreasuryTransfer(over);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisVault.TapBudgetExceeded.selector, address(weth), uint256(1), uint256(0)
            )
        );
        vault.executeTreasuryTransfer(over);

        vm.warp(block.timestamp + vault.TAP_WINDOW());
        FAOTreasuryActions.TransferAction memory reset = FAOTreasuryActions.TransferAction({
            asset: address(weth), recipient: RECIPIENT, amount: 0.1 ether, salt: bytes32(uint256(4))
        });
        arbitration.setOutcome(uint256(vault.transferActionHash(reset)), true, true, false);
        vault.queueTreasuryTransfer(reset);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryTransfer(reset);
        (, spent) = vault.tapStates(address(weth));
        assertEq(spent, 0.1 ether);
    }

    function testMediumTransferRequiresEvaluationAndBypassesTap() public {
        (GenesisVault vault,) = _makeLive();
        weth.mint(address(vault.TREASURY_EXECUTOR()), 1 ether);
        FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
            asset: address(weth), recipient: RECIPIENT, amount: 0.5 ether, salt: bytes32("medium")
        });
        uint256 proposalId = uint256(vault.transferActionHash(action));
        arbitration.setOutcome(proposalId, true, true, false);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisVault.EvaluatedAcceptanceRequired.selector, proposalId)
        );
        vault.queueTreasuryTransfer(action);

        arbitration.setOutcome(proposalId, true, true, true);
        vault.queueTreasuryTransfer(action);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryTransfer(action);
        assertEq(weth.balanceOf(RECIPIENT), 0.5 ether);
        (, uint192 spent) = vault.tapStates(address(weth));
        assertEq(spent, 0);
    }

    function testTreasuryAcceptanceWindowIsAnchoredToSettlement() public {
        (GenesisVault vault,) = _makeLive();
        weth.mint(address(vault.TREASURY_EXECUTOR()), 1 ether);

        FAOTreasuryActions.TransferAction memory stale = FAOTreasuryActions.TransferAction({
            asset: address(weth),
            recipient: RECIPIENT,
            amount: 0.1 ether,
            salt: bytes32("stale-timeout")
        });
        arbitration.setOutcome(uint256(vault.transferActionHash(stale)), true, true, false);
        vm.warp(block.timestamp + vault.TREASURY_GRACE() + vault.TREASURY_EXPIRY() + 1);
        vm.expectRevert(GenesisVault.ActionExpired.selector);
        vault.queueTreasuryTransfer(stale);

        FAOTreasuryActions.TransferAction memory fresh = FAOTreasuryActions.TransferAction({
            asset: address(weth),
            recipient: RECIPIENT,
            amount: 0.5 ether,
            salt: bytes32("fresh-evaluated")
        });
        arbitration.setOutcome(uint256(vault.transferActionHash(fresh)), true, true, true);
        vm.warp(block.timestamp + vault.TREASURY_GRACE() + 1);
        vault.queueTreasuryTransfer(fresh);
        vault.executeTreasuryTransfer(fresh);
        assertEq(weth.balanceOf(RECIPIENT), 0.5 ether);

        FAOTreasuryActions.ParamAction memory staleParam = FAOTreasuryActions.ParamAction({
            key: vault.KEY_TAP_BUDGET(),
            asset: address(weth),
            value: 0.3 ether,
            salt: bytes32("stale-param")
        });
        arbitration.setOutcome(uint256(vault.paramActionHash(staleParam)), true, true, true);
        vm.warp(block.timestamp + vault.TREASURY_GRACE() + vault.TREASURY_EXPIRY() + 1);
        vm.expectRevert(GenesisVault.ActionExpired.selector);
        vault.queueTreasuryParam(staleParam);
    }

    function testEvaluatedParamMayChangeTapOnlyWithinGenesisMaximum() public {
        (GenesisVault vault,) = _makeLive();
        FAOTreasuryActions.ParamAction memory action = FAOTreasuryActions.ParamAction({
            key: vault.KEY_TAP_BUDGET(),
            asset: address(weth),
            value: 0.4 ether,
            salt: bytes32("tap")
        });
        uint256 proposalId = uint256(vault.paramActionHash(action));
        arbitration.setOutcome(proposalId, true, true, false);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisVault.EvaluatedAcceptanceRequired.selector, proposalId)
        );
        vault.queueTreasuryParam(action);

        arbitration.setOutcome(proposalId, true, true, true);
        vault.queueTreasuryParam(action);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryParam(action);
        (,, uint128 tapBudget,,) = vault.assetPolicies(address(weth));
        assertEq(tapBudget, 0.4 ether);

        action.value = 3 ether;
        arbitration.setOutcome(uint256(vault.paramActionHash(action)), true, true, true);
        vm.expectRevert(GenesisVault.InvalidAssetPolicy.selector);
        vault.queueTreasuryParam(action);
    }

    function testCriticalActionNeedsTwoEvaluationsCoolingAndExitWindow() public {
        (GenesisVault vault,) = _makeLive();
        GenesisTreasuryTargetMock target = new GenesisTreasuryTargetMock();
        vm.deal(address(vault.TREASURY_EXECUTOR()), 1 ether);
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(target),
            value: 0.25 ether,
            data: abi.encodeCall(target.perform, (bytes32("two-decisions"))),
            salt: bytes32("critical")
        });
        uint256 roundOne = vault.criticalActionProposalId(action, 1);
        arbitration.setOutcome(roundOne, true, true, false);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisVault.EvaluatedAcceptanceRequired.selector, roundOne)
        );
        vault.stageCriticalAction(action);

        arbitration.setOutcome(roundOne, true, true, true);
        bytes32 baseHash = vault.stageCriticalAction(action);
        uint256 roundTwo = vault.criticalActionProposalId(action, 2);
        arbitration.setOutcome(roundTwo, true, true, true);
        vm.warp(block.timestamp + vault.CRITICAL_INTERVAL() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisVault.CriticalRoundTwoTooEarly.selector, block.timestamp + 1
            )
        );
        vault.queueCriticalAction(action);
        vm.warp(block.timestamp + 1);
        vault.queueCriticalAction(action);

        vm.expectRevert(GenesisVault.ActionInGracePeriod.selector);
        vault.executeCriticalAction(action);
        vm.warp(block.timestamp + vault.CRITICAL_GRACE());
        bytes memory result = vault.executeCriticalAction(action);
        assertEq(abi.decode(result, (uint256)), 1);
        assertEq(target.payload(), bytes32("two-decisions"));
        assertEq(target.value(), 0.25 ether);
        assertEq(target.caller(), address(vault.TREASURY_EXECUTOR()));
        (,, bool executed,) = vault.queuedActions(baseHash);
        assertTrue(executed);
    }

    function testCriticalMutationCannotReuseStagingAndRagequitStaysLive() public {
        (GenesisVault vault,) = _makeLive();
        vault.claim(BUYER);
        GenesisTreasuryTargetMock target = new GenesisTreasuryTargetMock();
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(target),
            value: 0,
            data: abi.encodeCall(target.perform, (bytes32("original"))),
            salt: bytes32("critical")
        });
        arbitration.setOutcome(vault.criticalActionProposalId(action, 1), true, true, true);
        vault.stageCriticalAction(action);

        FAOTreasuryActions.CriticalAction memory changed = action;
        changed.data = abi.encodeCall(target.perform, (bytes32("changed")));
        arbitration.setOutcome(vault.criticalActionProposalId(changed, 2), true, true, true);
        vm.warp(block.timestamp + vault.CRITICAL_INTERVAL());
        bytes32 changedBaseHash = vault.criticalActionBaseHash(changed);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisVault.CriticalNotStaged.selector, changedBaseHash)
        );
        vault.queueCriticalAction(changed);

        address[] memory extras = new address[](0);
        vm.prank(BUYER);
        vault.ragequit(1 ether, payable(RECIPIENT), extras);
        assertEq(vault.COMPANY_TOKEN().balanceOf(BUYER), 399 ether);
    }

    function testCriticalCallsCannotUseSaleAllowanceOrHolderBurnAuthority() public {
        (GenesisVault vault,) = _makeLive();
        FaoToken token = vault.COMPANY_TOKEN();
        vault.claim(BUYER);

        uint256 buyerWeth = weth.balanceOf(BUYER);
        uint256 saleAllowance = weth.allowance(BUYER, address(vault));
        FAOTreasuryActions.CriticalAction memory collect = FAOTreasuryActions.CriticalAction({
            target: address(weth),
            value: 0,
            data: abi.encodeCall(weth.transferFrom, (BUYER, RECIPIENT, 1 ether)),
            salt: bytes32("sale-authority")
        });
        _acceptCritical(vault, collect);
        vm.expectRevert();
        vault.executeCriticalAction(collect);
        assertEq(weth.balanceOf(BUYER), buyerWeth);
        assertEq(weth.allowance(BUYER, address(vault)), saleAllowance);

        FAOTreasuryActions.CriticalAction memory burn = FAOTreasuryActions.CriticalAction({
            target: address(token),
            value: 0,
            data: abi.encodeCall(token.burnFromVault, (BUYER, 1 ether)),
            salt: bytes32("holder-burn")
        });
        _acceptCritical(vault, burn);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.CallFailed.selector,
                abi.encodeWithSelector(FaoToken.OnlyVault.selector)
            )
        );
        vault.executeCriticalAction(burn);
        assertEq(token.balanceOf(BUYER), 400 ether);

        vm.expectRevert(GenesisVault.UnauthorizedTokenBurn.selector);
        vault.consumeTokenBurnAuthorization(BUYER, 1 ether);
    }

    function testCriticalExecutorMayChangeOnlyDeclaredVaultParameters() public {
        (GenesisVault vault,) = _makeLive();
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(vault),
            value: 0,
            data: abi.encodeCall(
                vault.setAssetPolicy,
                (
                    address(weth),
                    uint128(0.2 ether),
                    uint128(1 ether),
                    uint128(0.3 ether),
                    uint128(2 ether)
                )
            ),
            salt: bytes32("vault-parameter")
        });
        _acceptCritical(vault, action);
        vault.executeCriticalAction(action);
        (uint128 c1,, uint128 tapBudget,,) = vault.assetPolicies(address(weth));
        assertEq(c1, 0.2 ether);
        assertEq(tapBudget, 0.3 ether);
    }

    function _acceptCritical(GenesisVault vault, FAOTreasuryActions.CriticalAction memory action)
        internal
    {
        arbitration.setOutcome(vault.criticalActionProposalId(action, 1), true, true, true);
        vault.stageCriticalAction(action);
        vm.warp(block.timestamp + vault.CRITICAL_INTERVAL());
        arbitration.setOutcome(vault.criticalActionProposalId(action, 2), true, true, true);
        vault.queueCriticalAction(action);
        vm.warp(block.timestamp + vault.CRITICAL_GRACE());
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
        vault = new GenesisVault(_config(hook), grantConfigs);
    }

    function _config(GenesisBootstrapHookMock hook)
        internal
        view
        returns (GenesisVault.Config memory config)
    {
        GenesisVault.AssetPolicyConfig[] memory policies = new GenesisVault.AssetPolicyConfig[](2);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: address(weth),
            c1: 0.1 ether,
            c2: 1 ether,
            tapBudget: 0.2 ether,
            tapBudgetMax: 2 ether
        });
        policies[1] = GenesisVault.AssetPolicyConfig({
            asset: address(0),
            c1: 0.1 ether,
            c2: 1 ether,
            tapBudget: 0.2 ether,
            tapBudgetMax: 2 ether
        });
        config = GenesisVault.Config({
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
            bootstrapBps: BOOTSTRAP_BPS,
            assetPolicies: policies
        });
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
