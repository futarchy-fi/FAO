// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FAOToken} from "../../src/FAOToken.sol";
import {FAOSale} from "../../src/FAOSale.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../../src/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../../src/FutarchyOfficialProposalSource.sol";
import {
    FutarchyOfficialProposalOrchestrator,
    IFutarchyFactoryLike
} from "../../src/FutarchyOfficialProposalOrchestrator.sol";
import {FutarchyCtfSettlementOracle} from "../../src/FutarchyCtfSettlementOracle.sol";
import {SwaprAlgebraLiquidityAdapter} from "../../src/SwaprAlgebraLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";

interface IConditionalTokensLike {
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

interface IFutarchyProposalView {
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

interface IFutarchyProposalSettlementView {
    function conditionId() external view returns (bytes32);
    function questionId() external view returns (bytes32);
    function realityProxy() external view returns (address);
}

contract FutarchyLiquidityCycleForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant FUTARCHY_FACTORY = 0xa6cB18FCDC17a2B44E5cAd2d80a6D5942d30a345;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;
    address internal constant CONDITIONAL_TOKENS = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    FAOToken internal token;
    FAOSale internal sale;
    FutarchyOfficialProposalSource internal proposalSource;
    FutarchyLiquidityManager internal manager;
    FutarchyOfficialProposalOrchestrator internal orchestrator;
    FutarchyCtfSettlementOracle internal settlementOracle;
    address internal buyer;
    uint256 internal proposalId;
    address internal proposal;

    function testFork_e2e_seed_sync_settle_ragequit_redeem() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));
        _deployLocalStack();
        _seedManagerFromSale();
        _createCandidateAndPromoteOfficialProposal();
        _resolveViaCtfReportPayoutsAndSyncBack();
        _ragequitAndRedeemAsBuyer();
    }

    function _deployLocalStack() internal {
        token = new FAOToken(address(this));
        sale = new FAOSale(token, 10, 1 seconds, address(this), address(0), address(0));
        token.grantRole(token.MINTER_ROLE(), address(sale));
        token.grantRole(token.MINTER_ROLE(), address(this));
        sale.startSale();

        buyer = address(0xBEEF);
        vm.deal(buyer, 20 ether);

        uint256 initialPrice = sale.currentPriceWeiPerToken();
        vm.prank(buyer);
        sale.buy{value: initialPrice * 10_000}(10_000);
        vm.warp(block.timestamp + 2);
        vm.prank(buyer);
        sale.buy{value: sale.currentPriceWeiPerToken()}(1);

        orchestrator = new FutarchyOfficialProposalOrchestrator(
            address(this),
            IFutarchyFactoryLike(FUTARCHY_FACTORY),
            IAlgebraFactoryLike(ALGEBRA_FACTORY),
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER)
        );

        proposalSource = new FutarchyOfficialProposalSource(
            address(this), address(orchestrator), IAlgebraFactoryLike(ALGEBRA_FACTORY)
        );

        // Mark a proposal as "settled" only once the CTF condition has a winning outcome.
        settlementOracle =
            new FutarchyCtfSettlementOracle(IFutarchyConditionalRouter(FUTARCHY_ROUTER));
        proposalSource.setSettlementOracle(address(settlementOracle));

        SwaprAlgebraLiquidityAdapter spotAdapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );
        SwaprAlgebraLiquidityAdapter conditionalAdapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );

        manager = new FutarchyLiquidityManager(
            address(sale),
            token,
            IWrappedNative(GNOSIS_WXDAI),
            address(orchestrator),
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            IFutarchyConditionalRouter(FUTARCHY_ROUTER),
            address(this)
        );

        orchestrator.setWiring(manager, proposalSource);
    }

    function _seedManagerFromSale() internal {
        bytes memory spotAddData = abi.encode(
            SwaprAlgebraLiquidityAdapter.AddParams({
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                sqrtPriceX96: SQRT_PRICE_1_1
            })
        );
        sale.seedLiquidityManager(address(manager), 1000 ether, 0.5 ether, spotAddData);
        assertEq(manager.balanceOf(address(sale)), manager.totalSupply());
        assertTrue(sale.isRagequitToken(address(manager)));
        assertGt(manager.balanceOf(address(sale)), 0);
    }

    function _createCandidateAndPromoteOfficialProposal() internal {
        // Anyone can create the candidate proposal.
        vm.prank(address(0xCAFE));
        (proposalId, proposal) = orchestrator.createCandidateProposal(
            "FAO Fork E2E", "fao, test", "en", 1 ether, uint32(block.timestamp + 1 days)
        );

        // Admin promotes it atomically (init pools at spot price + set official + migrate).
        orchestrator.promoteToOfficialAndMigrate(proposalId);

        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeProposalId(), proposalId);
    }

    function _resolveViaCtfReportPayoutsAndSyncBack() internal {
        FutarchyLiquidityManager.SyncParams memory params;
        assertTrue(manager.inConditionalMode());

        // Resolve the underlying CTF condition via reportPayouts (YES wins).
        IFutarchyProposalSettlementView p = IFutarchyProposalSettlementView(proposal);
        bytes32 conditionId = p.conditionId();
        bytes32 questionId = p.questionId();
        address oracle = p.realityProxy();

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        IConditionalTokensLike(CONDITIONAL_TOKENS).reportPayouts(questionId, payouts);

        // Ensure router recognizes the winning outcome.
        bool[] memory winning =
            IFutarchyConditionalRouter(FUTARCHY_ROUTER).getWinningOutcomes(conditionId);
        assertEq(winning.length, 2);
        assertTrue(winning[0] && !winning[1], "winning outcome not set");

        // Now sync back to spot (requires CTF resolution + tick alignment).
        manager.sync(params);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.conditionalLiquidity(), 0);
        assertGt(manager.spotLiquidity(), 0);
    }

    function _ragequitAndRedeemAsBuyer() internal {
        uint256 buyerFlpBefore = manager.balanceOf(buyer);
        uint256 buyerFaoBefore = token.balanceOf(buyer);
        uint256 buyerEthBefore = buyer.balance;

        vm.startPrank(buyer);
        token.approve(address(sale), type(uint256).max);
        sale.ragequit(100);

        uint256 buyerFlpAfterRagequit = manager.balanceOf(buyer);
        assertGt(buyerFlpAfterRagequit, buyerFlpBefore);

        uint256 buyerFaoAfterRagequit = token.balanceOf(buyer);
        uint256 buyerEthAfterRagequit = buyer.balance;
        assertLt(buyerFaoAfterRagequit, buyerFaoBefore);
        assertGt(buyerEthAfterRagequit, buyerEthBefore);

        (uint256 faoOut, uint256 collateralOut) =
            manager.redeem(buyerFlpAfterRagequit, buyer, true, "", "");
        vm.stopPrank();

        assertEq(manager.balanceOf(buyer), 0);
        assertGt(faoOut + collateralOut, 0);
        assertGt(token.balanceOf(buyer), buyerFaoAfterRagequit);
        assertGt(buyer.balance, buyerEthAfterRagequit);
    }
}
