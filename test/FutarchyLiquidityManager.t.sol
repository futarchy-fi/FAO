// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FAOToken} from "../src/FAOToken.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/FutarchyLiquidityManager.sol";
import {FAOSaleTestHarness} from "./mocks/FAOSaleTestHarness.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockOfficialProposalSource} from "./mocks/MockOfficialProposalSource.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {RevertingFutarchyLiquidityAdapter} from "./mocks/RevertingFutarchyLiquidityAdapter.sol";
import {RevertingLiquidityManager} from "./mocks/RevertingLiquidityManager.sol";

contract FutarchyLiquidityManagerTest is Test {
    FAOToken internal token;
    FAOSaleTestHarness internal sale;
    MockWrappedNative internal wrappedNative;
    MockFutarchyLiquidityAdapter internal spotAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockOfficialProposalSource internal proposalSource;
    MockConditionalRouter internal conditionalRouter;
    MockMintableERC20 internal yesCompanyToken;
    MockMintableERC20 internal noCompanyToken;
    MockMintableERC20 internal yesCurrencyToken;
    MockMintableERC20 internal noCurrencyToken;
    FutarchyLiquidityManager internal manager;

    address internal officialProposer = address(0x1111);
    address internal nonOfficialProposer = address(0x2222);
    address internal buyer = address(0xBEEF);
    address internal depositor = address(0xCAFE);

    uint256 internal constant SEED_FAO = 100 ether;
    uint256 internal constant SEED_NATIVE = 100 ether;
    uint256 internal proposalNonce;

    function setUp() public {
        token = new FAOToken(address(this));
        sale = new FAOSaleTestHarness(
            token, 1_000_000, 14 days, address(this), address(0), address(0)
        );
        token.grantRole(token.MINTER_ROLE(), address(sale));

        wrappedNative = new MockWrappedNative();
        spotAdapter = new MockFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        proposalSource = new MockOfficialProposalSource();
        conditionalRouter = new MockConditionalRouter();
        yesCompanyToken = new MockMintableERC20("YES_COMP", "YCOMP");
        noCompanyToken = new MockMintableERC20("NO_COMP", "NCOMP");
        yesCurrencyToken = new MockMintableERC20("YES_CURR", "YCURR");
        noCurrencyToken = new MockMintableERC20("NO_CURR", "NCURR");

        manager = new FutarchyLiquidityManager(
            address(sale),
            token,
            IWrappedNative(address(wrappedNative)),
            officialProposer,
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            conditionalRouter,
            address(this)
        );

        // Generate treasury balances in sale.
        sale.startSale();
        vm.deal(buyer, 120 ether);
        vm.prank(buyer);
        sale.buy{value: 100 ether}(1_000_000);
        sale.forceFinalizeInitialPhaseForTests();
    }

    function _createOfficialProposal(address creator, address yesPool, address noPool)
        internal
        returns (address proposal)
    {
        proposalNonce++;
        proposal = address(uint160(0xF000 + proposalNonce));

        proposalSource.createProposalExtended(
            proposal,
            creator,
            address(token),
            address(wrappedNative),
            address(yesCompanyToken),
            address(noCompanyToken),
            address(yesCurrencyToken),
            address(noCurrencyToken),
            yesPool,
            noPool
        );

        conditionalRouter.setOutcomeConfig(
            proposal, address(token), address(yesCompanyToken), address(noCompanyToken), true
        );
        conditionalRouter.setOutcomeConfig(
            proposal,
            address(wrappedNative),
            address(yesCurrencyToken),
            address(noCurrencyToken),
            true
        );
    }

    function test_seed_from_sale_and_migrate_80_percent_then_back() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        assertEq(manager.balanceOf(address(sale)), 100 ether);
        assertEq(manager.totalSupply(), 100 ether);
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalLiquidity(), 0);
        assertFalse(manager.inConditionalMode());

        _createOfficialProposal(officialProposer, address(0xAAA1), address(0xAAA2));

        FutarchyLiquidityManager.SyncParams memory params;
        FutarchyLiquidityManager.SyncAction action = manager.sync(params);
        assertEq(
            uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedToConditional)
        );

        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeProposalId(), 1);
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalLiquidity(), 80 ether);

        proposalSource.setSettled(true);
        action = manager.sync(params);
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));

        assertFalse(manager.inConditionalMode());
        assertEq(manager.activeProposalId(), 0);
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalLiquidity(), 0);

        // Idempotent once already back in spot.
        action = manager.sync(params);
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.None));
        assertEq(manager.spotLiquidity(), 100 ether);
    }

    function test_deposit_mints_proportional_shares() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(depositor, 50 ether);
        vm.deal(depositor, 50 ether);

        vm.startPrank(depositor);
        token.approve(address(manager), type(uint256).max);
        (uint128 liquidityMinted, uint256 sharesMinted) =
            manager.depositToSpot{value: 50 ether}(50 ether, "");
        vm.stopPrank();

        assertEq(liquidityMinted, 50 ether);
        assertEq(sharesMinted, 50 ether);
        assertEq(manager.balanceOf(depositor), 50 ether);
        assertEq(manager.balanceOf(address(sale)), 100 ether);
        assertEq(manager.totalSupply(), 150 ether);
        assertEq(manager.spotLiquidity(), 150 ether);
        assertEq(manager.conditionalLiquidity(), 0);
    }

    function test_redeem_burns_shares_and_returns_pro_rata_assets() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(depositor, 50 ether);
        vm.deal(depositor, 50 ether);
        vm.startPrank(depositor);
        token.approve(address(manager), type(uint256).max);
        manager.depositToSpot{value: 50 ether}(50 ether, "");
        vm.stopPrank();

        _createOfficialProposal(officialProposer, address(0xEEE1), address(0xEEE2));

        FutarchyLiquidityManager.SyncParams memory params;
        manager.sync(params);
        assertEq(manager.spotLiquidity(), 30 ether);
        assertEq(manager.conditionalLiquidity(), 120 ether);

        uint256 depositorEthBefore = depositor.balance;
        uint256 depositorFaoBefore = token.balanceOf(depositor);

        vm.prank(depositor);
        (uint256 faoOut, uint256 collateralOut) = manager.redeem(15 ether, depositor, true, "", "");

        assertEq(faoOut, 15 ether);
        assertEq(collateralOut, 15 ether);
        assertEq(token.balanceOf(depositor), depositorFaoBefore + 15 ether);
        assertEq(depositor.balance, depositorEthBefore + 15 ether);
        assertEq(manager.balanceOf(depositor), 35 ether);
        assertEq(manager.totalSupply(), 135 ether);
        assertEq(manager.spotLiquidity(), 27 ether);
        assertEq(manager.conditionalLiquidity(), 108 ether);
    }

    function test_ragequit_receives_flp_then_redeem_and_repeat_until_dust() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");
        assertTrue(sale.isRagequitToken(address(manager)));

        vm.startPrank(buyer);
        token.approve(address(sale), type(uint256).max);

        // First ragequit gets proportional fLP tokens from sale treasury.
        uint256 saleFlpBefore = manager.balanceOf(address(sale));
        uint256 effectiveSupplyBefore = token.totalSupply() - token.balanceOf(address(sale));
        sale.ragequit(500_000);
        uint256 flpRound1 = manager.balanceOf(buyer);
        uint256 expectedFlpRound1 = (saleFlpBefore * 500_000 ether) / effectiveSupplyBefore;
        assertEq(flpRound1, expectedFlpRound1);

        // Redeem fLP to retrieve underlying from LP (mixed FAO + xDAI-equivalent native).
        (uint256 faoOut1, uint256 collateralOut1) = manager.redeem(flpRound1, buyer, true, "", "");
        assertEq(faoOut1, flpRound1);
        assertEq(collateralOut1, flpRound1);

        // Isolate the FAO from LP redemption to show recursive ragequit behavior.
        uint256 buyerFaoBalance = token.balanceOf(buyer);
        token.transfer(address(0xD00D), buyerFaoBalance - faoOut1);
        assertEq(token.balanceOf(buyer), faoOut1);

        uint256 secondBurnTokens = faoOut1 / 1e18;
        assertGt(secondBurnTokens, 0);
        sale.ragequit(secondBurnTokens);
        uint256 flpRound2 = manager.balanceOf(buyer);
        assertGt(flpRound2, 0);

        (uint256 faoOut2, uint256 collateralOut2) = manager.redeem(flpRound2, buyer, true, "", "");

        // Because ragequit works on whole-token units, the next round quickly reaches dust.
        assertLt(faoOut2, 1 ether);
        assertLt(collateralOut2, 1 ether);
        assertLt(token.balanceOf(buyer), 1 ether);

        vm.expectRevert("Insufficient FAO balance");
        sale.ragequit(1);
        vm.stopPrank();
    }

    function test_seed_failure_keeps_funds_in_sale_and_ragequittable() public {
        RevertingLiquidityManager revertingManager = new RevertingLiquidityManager();

        uint256 saleEthBefore = address(sale).balance;
        uint256 saleFaoBefore = token.balanceOf(address(sale));
        uint256 buyerEthBefore = buyer.balance;

        vm.expectRevert("LP init failed");
        sale.seedLiquidityManager(address(revertingManager), SEED_FAO, SEED_NATIVE, "");

        // Failed seeding must not move funds out of FAOSale.
        assertEq(address(sale).balance, saleEthBefore);
        assertEq(token.balanceOf(address(sale)), saleFaoBefore);
        assertFalse(sale.isRagequitToken(address(revertingManager)));

        // Buyer can still ragequit and recover the full sale native balance.
        vm.startPrank(buyer);
        token.approve(address(sale), type(uint256).max);
        sale.ragequit(1_000_000);
        vm.stopPrank();

        assertEq(address(sale).balance, 0);
        assertEq(buyer.balance, buyerEthBefore + saleEthBefore);
    }

    function test_deposit_failure_does_not_lock_or_receive_user_funds() public {
        RevertingFutarchyLiquidityAdapter revertingSpot = new RevertingFutarchyLiquidityAdapter();
        FutarchyLiquidityManager failingManager = new FutarchyLiquidityManager(
            address(sale),
            token,
            IWrappedNative(address(wrappedNative)),
            officialProposer,
            proposalSource,
            revertingSpot,
            conditionalAdapter,
            conditionalRouter,
            address(this)
        );

        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(depositor, 10 ether);
        vm.deal(depositor, 10 ether);

        uint256 depositorFaoBefore = token.balanceOf(depositor);
        uint256 depositorEthBefore = depositor.balance;

        vm.startPrank(depositor);
        token.approve(address(failingManager), type(uint256).max);
        vm.expectRevert("LP add failed");
        failingManager.depositToSpot{value: 10 ether}(10 ether, "");
        vm.stopPrank();

        // Full atomic revert: depositor keeps funds, manager receives nothing.
        assertEq(token.balanceOf(depositor), depositorFaoBefore);
        assertEq(depositor.balance, depositorEthBefore);
        assertEq(token.balanceOf(address(failingManager)), 0);
        assertEq(wrappedNative.balanceOf(address(failingManager)), 0);
        assertEq(failingManager.totalSupply(), 0);
        assertEq(failingManager.totalManagedLiquidity(), 0);
    }

    function test_sweep_idle_to_sale_only_sale_and_no_fund_loss() public {
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(address(manager), 3 ether);

        vm.deal(address(this), 2 ether);
        wrappedNative.deposit{value: 2 ether}();
        wrappedNative.transfer(address(manager), 2 ether);
        vm.deal(address(manager), 1 ether);

        uint256 saleEthBefore = address(sale).balance;
        uint256 saleFaoBefore = token.balanceOf(address(sale));

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        manager.sweepIdleToSale(true);

        manager.sweepIdleToSale(true);

        assertEq(token.balanceOf(address(sale)), saleFaoBefore + 3 ether);
        assertEq(address(sale).balance, saleEthBefore + 3 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(wrappedNative.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
    }

    function test_emergency_arm_blocks_deposit_and_sync_but_redeem_works() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(depositor, 10 ether);
        vm.deal(depositor, 11 ether);

        vm.startPrank(depositor);
        token.approve(address(manager), type(uint256).max);
        manager.depositToSpot{value: 10 ether}(10 ether, "");
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        manager.armEmergencyExit();

        manager.armEmergencyExit();

        FutarchyLiquidityManager.SyncParams memory params;
        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.sync(params);

        vm.startPrank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.depositToSpot{value: 1 ether}(1 ether, "");

        uint256 depositorEthBefore = depositor.balance;
        (uint256 faoOut, uint256 collateralOut) = manager.redeem(5 ether, depositor, true, "", "");
        vm.stopPrank();

        assertEq(faoOut, 5 ether);
        assertEq(collateralOut, 5 ether);
        assertEq(depositor.balance, depositorEthBefore + 5 ether);
    }

    function test_emergency_disarm_restores_operations() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        manager.armEmergencyExit();

        FutarchyLiquidityManager.SyncParams memory params;
        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.sync(params);

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, depositor)
        );
        manager.disarmEmergencyExit();

        manager.disarmEmergencyExit();

        _createOfficialProposal(officialProposer, address(0xABCD1), address(0xABCD2));

        FutarchyLiquidityManager.SyncAction action = manager.sync(params);
        assertEq(
            uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedToConditional)
        );
    }

    function test_emergency_exit_requires_delay_and_moves_all_to_sale() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        _createOfficialProposal(officialProposer, address(0xFFF1), address(0xFFF2));

        FutarchyLiquidityManager.SyncParams memory params;
        manager.sync(params);
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalLiquidity(), 80 ether);

        uint256 saleEthBefore = address(sale).balance;
        uint256 saleFaoBefore = token.balanceOf(address(sale));

        manager.armEmergencyExit();

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        manager.armEmergencyExit();

        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitDelayActive.selector);
        manager.emergencyExitAllToSale(true, "", "");

        vm.warp(block.timestamp + manager.EMERGENCY_EXIT_DELAY());

        manager.emergencyExitAllToSale(true, "", "");
        assertEq(token.balanceOf(address(sale)), saleFaoBefore + 100 ether);
        assertEq(address(sale).balance, saleEthBefore + 100 ether);
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalLiquidity(), 0);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.activeProposalId(), 0);
        assertTrue(manager.emergencyExitExecuted());

        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitAlreadyExecuted.selector);
        manager.emergencyExitAllToSale(true, "", "");
    }

    function test_manager_owner_can_be_different_for_testing() public {
        address altOwner = address(0xA11CE);
        FutarchyLiquidityManager altManager = new FutarchyLiquidityManager(
            address(sale),
            token,
            IWrappedNative(address(wrappedNative)),
            officialProposer,
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            conditionalRouter,
            altOwner
        );

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        altManager.armEmergencyExit();

        vm.prank(altOwner);
        altManager.armEmergencyExit();
        assertEq(altManager.emergencyExitArmedAt(), block.timestamp);
    }

    function test_sync_ignores_non_official_proposer() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        _createOfficialProposal(nonOfficialProposer, address(0xBBB1), address(0xBBB2));

        FutarchyLiquidityManager.SyncParams memory params;
        FutarchyLiquidityManager.SyncAction action = manager.sync(params);
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.None));
        assertEq(manager.spotLiquidity(), 100 ether);
        assertFalse(manager.inConditionalMode());
    }

    function test_sync_reverts_on_official_proposal_with_wrong_tokens() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");

        proposalSource.createProposalExtended(
            address(0xDEAD1),
            officialProposer,
            address(0xDEAD),
            address(wrappedNative),
            address(yesCompanyToken),
            address(noCompanyToken),
            address(yesCurrencyToken),
            address(noCurrencyToken),
            address(0xCCC1),
            address(0xCCC2)
        );

        FutarchyLiquidityManager.SyncParams memory params;
        vm.expectRevert(FutarchyLiquidityManager.InvalidProposalConfig.selector);
        manager.sync(params);
    }

    function test_sync_compounds_active_venue() public {
        sale.seedLiquidityManager(address(manager), SEED_FAO, SEED_NATIVE, "");
        FutarchyLiquidityManager.SyncParams memory params;

        spotAdapter.setNextCompoundLiquidity(5 ether);
        manager.sync(params);
        assertEq(manager.spotLiquidity(), 105 ether);

        _createOfficialProposal(officialProposer, address(0xDDD1), address(0xDDD2));
        manager.sync(params);
        assertEq(manager.spotLiquidity(), 21 ether);
        assertEq(manager.conditionalLiquidity(), 84 ether);

        conditionalAdapter.setNextCompoundLiquidity(3 ether);
        manager.sync(params);
        assertEq(manager.conditionalYesLiquidity(), 87 ether);
        assertEq(manager.conditionalNoLiquidity(), 84 ether);
        assertEq(manager.conditionalLiquidity(), 85_500_000_000_000_000_000);
        assertEq(manager.spotLiquidity(), 21 ether);
    }

    function test_force_finalize_is_test_only_path() public {
        FAOSaleTestHarness anotherSale = new FAOSaleTestHarness(
            token, 1_000_000, 14 days, address(this), address(0), address(0)
        );
        token.grantRole(token.MINTER_ROLE(), address(anotherSale));
        anotherSale.startSale();
        anotherSale.forceFinalizeInitialPhaseForTests();

        assertTrue(anotherSale.initialPhaseFinalized());
    }
}
