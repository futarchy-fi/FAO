// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    GenesisManagerMock,
    GenesisTreasuryTargetMock,
    GenesisWethMock
} from "./mocks/GenesisVaultMocks.sol";

/// @dev The smallest faithful model of the FLM redemption surface used by the recursion property.
contract GenesisRedeemableManagerMock is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable BOOTSTRAP_RECIPIENT;
    address public immutable COMPANY_TOKEN;
    address public immutable WRAPPED_NATIVE;
    address public constant owner = address(0xdead);
    bool public initializedFromBootstrap;

    constructor(address vault, address companyToken, address weth) ERC20("FLM Share", "FLM") {
        BOOTSTRAP_RECIPIENT = vault;
        COMPANY_TOKEN = companyToken;
        WRAPPED_NATIVE = weth;
    }

    function initializeFromBootstrap(uint256 companyAmount, uint256 collateralAmount)
        external
        returns (uint128 shares)
    {
        require(msg.sender == BOOTSTRAP_RECIPIENT && !initializedFromBootstrap);
        require(companyAmount != 0 && companyAmount <= type(uint128).max);
        initializedFromBootstrap = true;
        IERC20(COMPANY_TOKEN).safeTransferFrom(msg.sender, address(this), companyAmount);
        IERC20(WRAPPED_NATIVE).safeTransferFrom(msg.sender, address(this), collateralAmount);
        shares = uint128(companyAmount);
        _mint(msg.sender, shares);
    }

    function redeem(uint256 shares, address recipient)
        external
        returns (uint256 companyOut, uint256 collateralOut)
    {
        uint256 supply = totalSupply();
        require(shares != 0 && shares <= balanceOf(msg.sender));
        companyOut = shares == supply
            ? IERC20(COMPANY_TOKEN).balanceOf(address(this))
            : Math.mulDiv(IERC20(COMPANY_TOKEN).balanceOf(address(this)), shares, supply);
        collateralOut = shares == supply
            ? IERC20(WRAPPED_NATIVE).balanceOf(address(this))
            : Math.mulDiv(IERC20(WRAPPED_NATIVE).balanceOf(address(this)), shares, supply);
        _burn(msg.sender, shares);
        IERC20(COMPANY_TOKEN).safeTransfer(recipient, companyOut);
        IERC20(WRAPPED_NATIVE).safeTransfer(recipient, collateralOut);
    }
}

abstract contract GenesisVaultInvariantHarness is Test {
    uint256 internal constant SALE_CAP = 1000 ether;
    uint256 internal constant INITIAL_PRICE = 0.001 ether;
    uint256 internal constant SLOPE = 0.000_001 ether;
    uint16 internal constant BOOTSTRAP_BPS = 5000;

    GenesisWethMock internal weth;
    GenesisArbitrationMock internal arbitration;

    function _setUpMocks() internal {
        vm.warp(1_000_000);
        weth = new GenesisWethMock();
        arbitration = new GenesisArbitrationMock();
    }

    function _deploy(uint256 minimumRaise) internal returns (GenesisVault vault) {
        GenesisBootstrapHookMock hook = new GenesisBootstrapHookMock();
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        GenesisVault.AssetPolicyConfig[] memory policies = new GenesisVault.AssetPolicyConfig[](1);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: address(weth),
            c1: 0.1 ether,
            c2: 1 ether,
            tapBudget: 0.2 ether,
            tapBudgetMax: 2 ether
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
            minimumRaise: minimumRaise,
            tokenMaxSupply: 3000 ether,
            initialPrice: INITIAL_PRICE,
            slope: SLOPE,
            bootstrapBps: BOOTSTRAP_BPS,
            assetPolicies: policies
        });
        vault = new GenesisVault(config, grants);
    }

    function _fundAndApprove(address buyer, GenesisVault vault) internal {
        weth.mint(buyer, 10 ether);
        vm.prank(buyer);
        weth.approve(address(vault), type(uint256).max);
    }

    function _buy(GenesisVault vault, address buyer, uint256 amount) internal returns (uint256) {
        uint256 deadline = vault.SALE_END();
        vm.prank(buyer);
        return vault.buy(amount, type(uint256).max, deadline);
    }

    function _bindAndFinalize(GenesisVault vault) internal returns (GenesisManagerMock manager) {
        vm.warp(vault.SALE_END());
        vault.seal();
        manager =
            new GenesisManagerMock(address(vault), address(vault.COMPANY_TOKEN()), address(weth));
        vault.bindManager(IGenesisFlm(address(manager)));
        vault.finalize();
    }

    function _acceptAndQueueCritical(
        GenesisVault vault,
        FAOTreasuryActions.CriticalAction memory action
    ) internal returns (bytes32 baseHash) {
        arbitration.setOutcome(vault.criticalActionProposalId(action, 1), true, true, true);
        baseHash = vault.stageCriticalAction(action);
        vm.warp(block.timestamp + vault.CRITICAL_INTERVAL());
        arbitration.setOutcome(vault.criticalActionProposalId(action, 2), true, true, true);
        vault.queueCriticalAction(action);
    }
}

contract GenesisVaultPropertyTest is GenesisVaultInvariantHarness {
    GenesisVault internal curveVault;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        _setUpMocks();
        curveVault = _deploy(2);
    }

    function testFuzz_CurveTelescopesAcrossAnyTwoPartitions(
        uint256 totalRaw,
        uint256 firstRaw,
        uint256 secondRaw
    ) public view {
        uint256 total = bound(totalRaw, 1, SALE_CAP);
        uint256 first = firstRaw % (total + 1);
        uint256 second = secondRaw % (total + 1);
        if (first > second) (first, second) = (second, first);

        uint256 threeWay = curveVault.reserveAt(first)
            + (curveVault.reserveAt(second) - curveVault.reserveAt(first))
            + (curveVault.reserveAt(total) - curveVault.reserveAt(second));
        uint256 alternate = curveVault.reserveAt(total - second)
            + (curveVault.reserveAt(total - first) - curveVault.reserveAt(total - second))
            + (curveVault.reserveAt(total) - curveVault.reserveAt(total - first));

        assertEq(threeWay, curveVault.reserveAt(total));
        assertEq(alternate, threeWay);
    }

    function testFuzz_FailedSaleRefundsConserveEveryContribution(
        uint96 aliceRaw,
        uint96 bobRaw,
        uint96 carolRaw,
        uint96 donationRaw
    ) public {
        GenesisVault vault = _deploy(1 ether);
        address[3] memory buyers = [ALICE, BOB, CAROL];
        uint256[3] memory amounts = [
            bound(uint256(aliceRaw), 1 ether, 100 ether),
            bound(uint256(bobRaw), 1 ether, 100 ether),
            bound(uint256(carolRaw), 1 ether, 100 ether)
        ];
        uint256[3] memory startingBalances;
        uint256 contributionSum;

        for (uint256 i; i < buyers.length; ++i) {
            _fundAndApprove(buyers[i], vault);
            startingBalances[i] = weth.balanceOf(buyers[i]);
            contributionSum += _buy(vault, buyers[i], amounts[i]);
        }

        uint256 donation = bound(uint256(donationRaw), 0, 1 ether);
        weth.mint(address(vault), donation);
        assertEq(vault.totalRaised(), vault.reserveAt(vault.totalSold()));
        assertEq(vault.totalRaised(), contributionSum);
        assertEq(weth.balanceOf(address(vault)), contributionSum + donation);

        vm.warp(vault.SALE_END());
        vault.fail();
        for (uint256 i; i < buyers.length; ++i) {
            vault.refund(buyers[i]);
            assertEq(weth.balanceOf(buyers[i]), startingBalances[i]);
            assertEq(vault.contribution(buyers[i]), 0);
            assertEq(vault.purchased(buyers[i]), 0);
        }

        assertEq(weth.balanceOf(address(vault)), donation);
        assertEq(vault.COMPANY_TOKEN().totalSupply(), 0);
    }

    function testFuzz_ClaimsAndShrinkingDenominatorSweepFinalHolderDust(
        uint96 aliceRaw,
        uint96 bobRaw,
        uint96 wethDonationRaw,
        uint96 extraDonationRaw,
        uint96 nativeDonationRaw
    ) public {
        GenesisVault vault = _deploy(2);
        uint256 aliceAmount = bound(uint256(aliceRaw), 1 ether, 400 ether);
        uint256 bobAmount = bound(uint256(bobRaw), 1 ether, 400 ether);
        _fundAndApprove(ALICE, vault);
        _fundAndApprove(BOB, vault);
        _buy(vault, ALICE, aliceAmount);
        _buy(vault, BOB, bobAmount);
        vm.warp(vault.SALE_END());
        vault.seal();
        GenesisRedeemableManagerMock manager = new GenesisRedeemableManagerMock(
            address(vault), address(vault.COMPANY_TOKEN()), address(weth)
        );
        vault.bindManager(IGenesisFlm(address(manager)));
        vault.finalize();
        vault.claim(ALICE);
        vault.claim(BOB);

        FaoToken token = vault.COMPANY_TOKEN();
        address executor = address(vault.TREASURY_EXECUTOR());
        uint256 managerShares = manager.balanceOf(executor);
        FAOTreasuryActions.CriticalAction memory redeemManager = FAOTreasuryActions.CriticalAction({
            target: address(manager),
            value: 0,
            data: abi.encodeCall(manager.redeem, (managerShares, executor)),
            salt: keccak256("redeem-manager-inventory-for-final-holder-test")
        });
        _acceptAndQueueCritical(vault, redeemManager);
        vm.warp(block.timestamp + vault.CRITICAL_GRACE());
        vault.executeCriticalAction(redeemManager);
        assertEq(manager.balanceOf(executor), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(vault.effectiveSupply(), aliceAmount + bobAmount);

        GenesisAssetMock extra = new GenesisAssetMock("EXTRA");
        uint256 wethDonation = bound(uint256(wethDonationRaw), 0, 10 ether);
        uint256 extraDonation = bound(uint256(extraDonationRaw), 0, 10_000 ether);
        uint256 nativeDonation = bound(uint256(nativeDonationRaw), 0, 10 ether);
        weth.mint(executor, wethDonation);
        extra.mint(executor, extraDonation);
        vm.deal(executor, nativeDonation);

        uint256 initialWeth = weth.balanceOf(executor);
        uint256 initialShares = manager.balanceOf(executor);
        uint256 supply = vault.effectiveSupply();
        uint256 expectedAliceWeth = initialWeth * aliceAmount / supply;
        uint256 expectedAliceShares = initialShares * aliceAmount / supply;
        uint256 expectedAliceExtra = extraDonation * aliceAmount / supply;
        uint256 expectedAliceNative = nativeDonation * aliceAmount / supply;
        address[] memory extras = new address[](2);
        extras[0] = address(0);
        extras[1] = address(extra);

        uint256 aliceWethBefore = weth.balanceOf(ALICE);
        uint256 aliceSharesBefore = manager.balanceOf(ALICE);
        uint256 aliceNativeBefore = ALICE.balance;
        vm.prank(ALICE);
        vault.ragequit(aliceAmount, payable(ALICE), extras);
        assertEq(weth.balanceOf(ALICE) - aliceWethBefore, expectedAliceWeth);
        assertEq(manager.balanceOf(ALICE) - aliceSharesBefore, expectedAliceShares);
        assertEq(extra.balanceOf(ALICE), expectedAliceExtra);
        assertEq(ALICE.balance - aliceNativeBefore, expectedAliceNative);

        uint256 bobWethBefore = weth.balanceOf(BOB);
        uint256 bobSharesBefore = manager.balanceOf(BOB);
        uint256 bobNativeBefore = BOB.balance;
        vm.prank(BOB);
        vault.ragequit(bobAmount, payable(BOB), extras);

        assertEq(weth.balanceOf(BOB) - bobWethBefore, initialWeth - expectedAliceWeth);
        assertEq(manager.balanceOf(BOB) - bobSharesBefore, initialShares - expectedAliceShares);
        assertEq(extra.balanceOf(BOB), extraDonation - expectedAliceExtra);
        assertEq(BOB.balance - bobNativeBefore, nativeDonation - expectedAliceNative);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(executor), 0);
        assertEq(manager.balanceOf(address(vault)), 0);
        assertEq(manager.balanceOf(executor), 0);
        assertEq(extra.balanceOf(address(vault)), 0);
        assertEq(extra.balanceOf(executor), 0);
        assertEq(address(vault).balance, 0);
        assertEq(executor.balance, 0);
        assertEq(token.totalSupply(), token.balanceOf(executor));
        assertEq(vault.effectiveSupply(), 0);
    }

    function testFuzz_RawFlmRedeemRagequitRecursionCannotExceedExternalEntitlement(
        uint40 aliceRaw,
        uint40 bobRaw,
        uint40 extraRaw
    ) public {
        GenesisVault vault = _deploy(2);
        uint256 aliceAmount = bound(uint256(aliceRaw), 100_000, 1_000_000);
        uint256 bobAmount = bound(uint256(bobRaw), 100_000, 1_000_000);
        _fundAndApprove(ALICE, vault);
        _fundAndApprove(BOB, vault);
        _buy(vault, ALICE, aliceAmount);
        _buy(vault, BOB, bobAmount);

        vm.warp(vault.SALE_END());
        vault.seal();
        GenesisRedeemableManagerMock manager = new GenesisRedeemableManagerMock(
            address(vault), address(vault.COMPANY_TOKEN()), address(weth)
        );
        vault.bindManager(IGenesisFlm(address(manager)));
        vault.finalize();
        vault.claim(ALICE);
        vault.claim(BOB);

        GenesisAssetMock extra = new GenesisAssetMock("EXTRA");
        uint256 initialExtra = bound(uint256(extraRaw), 1000, 1_000_000);
        address executor = address(vault.TREASURY_EXECUTOR());
        extra.mint(executor, initialExtra);
        uint256 initialCombinedWeth = weth.balanceOf(executor) + weth.balanceOf(address(manager));
        uint256 externalSupply = aliceAmount + bobAmount;
        uint256 maxAliceWeth = Math.mulDiv(initialCombinedWeth, aliceAmount, externalSupply);
        uint256 maxAliceExtra = Math.mulDiv(initialExtra, aliceAmount, externalSupply);
        uint256 aliceWethBefore = weth.balanceOf(ALICE);
        address[] memory extras = new address[](1);
        extras[0] = address(extra);

        uint256 cycles;
        for (; cycles < 128; ++cycles) {
            uint256 recoveredCompany = vault.COMPANY_TOKEN().balanceOf(ALICE);
            if (recoveredCompany == 0) break;
            vm.prank(ALICE);
            vault.ragequit(recoveredCompany, payable(ALICE), extras);

            uint256 recoveredShares = manager.balanceOf(ALICE);
            if (recoveredShares == 0) break;
            vm.prank(ALICE);
            manager.redeem(recoveredShares, ALICE);

            assertLe(weth.balanceOf(ALICE) - aliceWethBefore, maxAliceWeth);
            assertLe(extra.balanceOf(ALICE), maxAliceExtra);
        }

        assertLt(cycles, 128, "recursion did not converge");
        assertEq(vault.COMPANY_TOKEN().balanceOf(ALICE), 0);
        assertEq(manager.balanceOf(ALICE), 0);
        uint256 wethDust = maxAliceWeth - (weth.balanceOf(ALICE) - aliceWethBefore);
        uint256 extraDust = maxAliceExtra - extra.balanceOf(ALICE);
        assertLe(wethDust, cycles * 4 + 4);
        assertLe(extraDust, cycles * 4 + 4);
    }

    function test_TreasuryWindowsReplayAndFailedCallsAreTerminalOrAtomic() public {
        GenesisVault vault = _deploy(2);
        _fundAndApprove(ALICE, vault);
        _buy(vault, ALICE, 400 ether);
        GenesisManagerMock manager = _bindAndFinalize(vault);
        GenesisTreasuryTargetMock target = new GenesisTreasuryTargetMock();

        FAOTreasuryActions.CriticalAction memory atBoundary = FAOTreasuryActions.CriticalAction({
            target: address(target),
            value: 0,
            data: abi.encodeCall(target.perform, (bytes32("last-valid-second"))),
            salt: bytes32(uint256(1))
        });
        bytes32 boundaryHash = _acceptAndQueueCritical(vault, atBoundary);
        (, uint64 expiresAt,,) = vault.queuedActions(boundaryHash);
        vm.warp(expiresAt);
        vault.executeCriticalAction(atBoundary);
        vm.expectRevert(GenesisVault.ActionAlreadyQueued.selector);
        vault.executeCriticalAction(atBoundary);

        FAOTreasuryActions.CriticalAction memory expired = FAOTreasuryActions.CriticalAction({
            target: address(target),
            value: 0,
            data: abi.encodeCall(target.perform, (bytes32("expired"))),
            salt: bytes32(uint256(2))
        });
        bytes32 expiredHash = _acceptAndQueueCritical(vault, expired);
        (, uint64 secondExpiry,,) = vault.queuedActions(expiredHash);
        vm.warp(uint256(secondExpiry) + 1);
        vm.expectRevert(GenesisVault.ActionExpired.selector);
        vault.executeCriticalAction(expired);
        vault.expireQueuedAction(expiredHash);
        (,,, bool permanentlyExpired) = vault.queuedActions(expiredHash);
        assertTrue(permanentlyExpired);

        FaoToken token = vault.COMPANY_TOKEN();
        FAOTreasuryActions.CriticalAction memory failedCall = FAOTreasuryActions.CriticalAction({
            target: address(token),
            value: 0,
            data: abi.encodeCall(token.burnFromVault, (address(manager), 1)),
            salt: bytes32(uint256(3))
        });
        bytes32 badHash = _acceptAndQueueCritical(vault, failedCall);
        vm.warp(block.timestamp + vault.CRITICAL_GRACE());
        uint256 managerTokens = token.balanceOf(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.CallFailed.selector,
                abi.encodeWithSelector(FaoToken.OnlyVault.selector)
            )
        );
        vault.executeCriticalAction(failedCall);
        assertEq(token.balanceOf(address(manager)), managerTokens);
        (,, bool executed, bool isExpired) = vault.queuedActions(badHash);
        assertFalse(executed);
        assertFalse(isExpired);
    }
}

contract GenesisVaultHandler is Test {
    GenesisVault public immutable vault;
    GenesisWethMock public immutable weth;
    GenesisManagerMock public immutable manager;

    address[] internal actors;
    uint256 public refundedWeth;
    uint256 public refundedTokens;

    constructor(
        GenesisVault vault_,
        GenesisWethMock weth_,
        GenesisManagerMock manager_,
        address[] memory actors_
    ) {
        vault = vault_;
        weth = weth_;
        manager = manager_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function buy(uint256 actorSeed, uint256 amountRaw) external {
        if (
            vault.phase() != GenesisVault.Phase.FUNDING || block.timestamp >= vault.SALE_END()
                || vault.totalSold() == vault.SALE_CAP()
        ) return;
        uint256 remaining = vault.SALE_CAP() - vault.totalSold();
        uint256 minimum = remaining < 1 ether ? 1 : 1 ether;
        uint256 amount = _clamp(amountRaw, minimum, remaining);
        uint256 deadline = vault.SALE_END();
        vm.prank(_actor(actorSeed));
        try vault.buy(amount, type(uint256).max, deadline) {} catch {}
    }

    function advance(uint48 elapsedRaw) external {
        vm.warp(block.timestamp + _clamp(uint256(elapsedRaw), 0, 4 days));
    }

    function seal() external {
        try vault.seal() {} catch {}
    }

    function triggerFailure() external {
        try vault.fail() {} catch {}
    }

    function finalize() external {
        try vault.finalize() {} catch {}
    }

    function refund(uint256 actorSeed) external {
        address account = _actor(actorSeed);
        uint256 tokens = vault.purchased(account);
        try vault.refund(account) returns (uint256 amount) {
            refundedWeth += amount;
            refundedTokens += tokens;
        } catch {}
    }

    function claim(uint256 actorSeed) external {
        try vault.claim(_actor(actorSeed)) {} catch {}
    }

    function ragequit(uint256 actorSeed, uint256 amountRaw) external {
        address account = _actor(actorSeed);
        uint256 balance = vault.COMPANY_TOKEN().balanceOf(account);
        if (balance == 0) return;
        uint256 amount = _clamp(amountRaw, 1, balance);
        address[] memory noExtras = new address[](0);
        vm.prank(account);
        try vault.ragequit(amount, payable(account), noExtras) {} catch {}
    }

    function donateWeth(uint96 amountRaw) external {
        address recipient = vault.phase() == GenesisVault.Phase.LIVE
            ? address(vault.TREASURY_EXECUTOR())
            : address(vault);
        weth.mint(recipient, _clamp(uint256(amountRaw), 0, 1 ether));
    }

    function donateCompany(uint256 actorSeed, uint256 amountRaw) external {
        if (vault.phase() != GenesisVault.Phase.LIVE) return;
        address account = _actor(actorSeed);
        FaoToken token = vault.COMPANY_TOKEN();
        uint256 balance = token.balanceOf(account);
        if (balance == 0) return;
        vm.prank(account);
        token.transfer(address(vault), _clamp(amountRaw, 1, balance));
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _clamp(uint256 value, uint256 minimum, uint256 maximum)
        private
        pure
        returns (uint256)
    {
        return minimum == maximum ? minimum : minimum + value % (maximum - minimum + 1);
    }
}

contract GenesisVaultStatefulInvariantTest is StdInvariant, GenesisVaultInvariantHarness {
    GenesisVault internal vault;
    GenesisManagerMock internal manager;
    GenesisVaultHandler internal handler;
    address[] internal actors;

    function setUp() public {
        _setUpMocks();
        vault = _deploy(2);
        manager =
            new GenesisManagerMock(address(vault), address(vault.COMPANY_TOKEN()), address(weth));
        vault.bindManager(IGenesisFlm(address(manager)));

        for (uint256 i; i < 4; ++i) {
            address account = vm.addr(i + 1);
            actors.push(account);
            _fundAndApprove(account, vault);
        }
        handler = new GenesisVaultHandler(vault, weth, manager, actors);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.seal.selector;
        selectors[3] = handler.triggerFailure.selector;
        selectors[4] = handler.finalize.selector;
        selectors[5] = handler.refund.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.ragequit.selector;
        selectors[8] = handler.donateWeth.selector;
        selectors[9] = handler.donateCompany.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_CurveAndContributionAccountingNeverDrift() public view {
        assertLe(vault.totalSold(), vault.SALE_CAP());
        assertEq(vault.totalRaised(), vault.reserveAt(vault.totalSold()));

        uint256 contributions;
        for (uint256 i; i < actors.length; ++i) {
            contributions += vault.contribution(actors[i]);
        }
        assertEq(contributions + handler.refundedWeth(), vault.totalRaised());
    }

    function invariant_EntitlementsMatchTheLifecycle() public view {
        uint256 purchases;
        for (uint256 i; i < actors.length; ++i) {
            purchases += vault.purchased(actors[i]);
        }

        GenesisVault.Phase current = vault.phase();
        if (current == GenesisVault.Phase.FUNDING) {
            assertEq(purchases, vault.totalSold());
            assertEq(vault.totalUnclaimedSold(), 0);
        } else if (current == GenesisVault.Phase.SEALING || current == GenesisVault.Phase.LIVE) {
            assertEq(purchases, vault.totalUnclaimedSold());
        } else {
            assertEq(purchases + handler.refundedTokens(), vault.totalSold());
        }
    }

    function invariant_ClosedTokenSystemsConserveSupply() public view {
        FaoToken token = vault.COMPANY_TOKEN();
        address executor = address(vault.TREASURY_EXECUTOR());
        uint256 companyBalances = token.balanceOf(address(vault))
            + token.balanceOf(address(manager)) + token.balanceOf(executor);
        uint256 wethBalances = weth.balanceOf(address(vault)) + weth.balanceOf(address(manager))
            + weth.balanceOf(executor);
        uint256 shareBalances = manager.balanceOf(address(vault)) + manager.balanceOf(executor);
        for (uint256 i; i < actors.length; ++i) {
            companyBalances += token.balanceOf(actors[i]);
            wethBalances += weth.balanceOf(actors[i]);
            shareBalances += manager.balanceOf(actors[i]);
        }

        assertEq(companyBalances, token.totalSupply());
        assertEq(wethBalances, weth.totalSupply());
        assertEq(shareBalances, manager.totalSupply());
    }

    function invariant_PhaseGuardsGenesisAndClaimReserves() public view {
        FaoToken token = vault.COMPANY_TOKEN();
        GenesisVault.Phase current = vault.phase();
        if (current == GenesisVault.Phase.LIVE) {
            assertTrue(token.mintingFinished());
            assertTrue(manager.initializedFromBootstrap());
            assertGe(token.balanceOf(address(vault)), vault.totalUnclaimedSold());
            assertEq(weth.balanceOf(address(vault)), 0);
            assertEq(manager.balanceOf(address(vault)), 0);
            assertEq(token.allowance(address(vault), address(manager)), 0);
            assertEq(weth.allowance(address(vault), address(manager)), 0);
            vault.effectiveSupply();
        } else {
            assertEq(token.totalSupply(), 0);
            assertFalse(token.mintingFinished());
        }
    }
}
