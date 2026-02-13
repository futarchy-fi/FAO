// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FAOToken} from "../../src/FAOToken.sol";
import {FAOSale} from "../../src/FAOSale.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../../src/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../../src/FutarchyOfficialProposalSource.sol";
import {SwaprAlgebraLiquidityAdapter} from "../../src/SwaprAlgebraLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";

interface IFutarchyFactoryLike {
    struct CreateProposalParams {
        string marketName;
        address collateralToken1;
        address collateralToken2;
        string category;
        string lang;
        uint256 minBond;
        uint32 openingTime;
    }

    function createProposal(CreateProposalParams calldata params) external returns (address);
    function marketsCount() external view returns (uint256);
    function proposals(uint256) external view returns (address);
}

interface IFutarchyProposalView {
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

contract FutarchyLiquidityCycleForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant FUTARCHY_FACTORY = 0xa6cB18FCDC17a2B44E5cAd2d80a6D5942d30a345;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    FAOToken internal token;
    FAOSale internal sale;
    FutarchyOfficialProposalSource internal proposalSource;
    FutarchyLiquidityManager internal manager;
    address internal buyer;
    uint256 internal proposalId;

    function testFork_e2e_seed_sync_settle_ragequit_redeem() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));
        _deployLocalStack();
        _seedManagerFromSale();
        _createAndSetOfficialProposal();
        _syncIntoConditionalAndBack();
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

        proposalSource = new FutarchyOfficialProposalSource(
            address(this), address(this), IAlgebraFactoryLike(ALGEBRA_FACTORY)
        );
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
            address(this),
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            IFutarchyConditionalRouter(FUTARCHY_ROUTER),
            address(this)
        );
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
        sale.seedLiquidityManager(address(manager), 1_000 ether, 0.5 ether, spotAddData);
        assertEq(manager.balanceOf(address(sale)), manager.totalSupply());
        assertTrue(sale.isRagequitToken(address(manager)));
        assertGt(manager.balanceOf(address(sale)), 0);
    }

    function _createAndSetOfficialProposal() internal {
        IFutarchyFactoryLike factory = IFutarchyFactoryLike(FUTARCHY_FACTORY);
        factory.createProposal(
            IFutarchyFactoryLike.CreateProposalParams({
                marketName: "FAO Fork E2E",
                collateralToken1: address(token),
                collateralToken2: GNOSIS_WXDAI,
                category: "fao, test",
                lang: "en",
                minBond: 1 ether,
                openingTime: uint32(block.timestamp + 1 days)
            })
        );

        proposalId = factory.marketsCount() - 1;
        address proposal = factory.proposals(proposalId);
        _bootstrapConditionalPools(token, proposal);
        proposalSource.setOfficialProposal(proposalId, proposal, address(this));
    }

    function _syncIntoConditionalAndBack() internal {
        FutarchyLiquidityManager.SyncParams memory params;
        uint128 spotBefore = manager.spotLiquidity();

        manager.sync(params);
        assertTrue(manager.inConditionalMode());
        assertGt(manager.conditionalLiquidity(), 0);
        assertLt(manager.spotLiquidity(), spotBefore);
        assertEq(manager.activeProposalId(), proposalId);

        proposalSource.setManualSettled(true);
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

    function _bootstrapConditionalPools(FAOToken faoToken, address proposal) internal {
        IFutarchyProposalView p = IFutarchyProposalView(proposal);
        address yesCompany;
        address noCompany;
        address yesCurrency;
        address noCurrency;
        (yesCompany,) = p.wrappedOutcome(0);
        (noCompany,) = p.wrappedOutcome(1);
        (yesCurrency,) = p.wrappedOutcome(2);
        (noCurrency,) = p.wrappedOutcome(3);

        // Mint collateral locally and split through the real futarchy router.
        faoToken.mint(address(this), 2 ether);
        vm.deal(address(this), 2 ether);
        IWrappedNative(GNOSIS_WXDAI).deposit{value: 2 ether}();

        IERC20(address(faoToken)).approve(FUTARCHY_ROUTER, type(uint256).max);
        IERC20(GNOSIS_WXDAI).approve(FUTARCHY_ROUTER, type(uint256).max);
        IFutarchyConditionalRouter(FUTARCHY_ROUTER).splitPosition(
            proposal, address(faoToken), 2 ether
        );
        IFutarchyConditionalRouter(FUTARCHY_ROUTER).splitPosition(proposal, GNOSIS_WXDAI, 2 ether);

        _createPoolWithDustLiquidity(yesCompany, yesCurrency);
        _createPoolWithDustLiquidity(noCompany, noCurrency);

        address yesPool = IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(yesCompany, yesCurrency);
        address noPool = IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(noCompany, noCurrency);
        assertTrue(yesPool != address(0) && noPool != address(0), "conditional pools not created");
    }

    function _createPoolWithDustLiquidity(address tokenA, address tokenB) internal {
        (address token0, address token1, uint256 amount0, uint256 amount1) =
            _sortPairAndAmounts(tokenA, tokenB, 1e15, 1e15);

        IERC20(token0).approve(SWAPR_POSITION_MANAGER, type(uint256).max);
        IERC20(token1).approve(SWAPR_POSITION_MANAGER, type(uint256).max);

        ISwaprAlgebraPositionManager pm = ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER);
        pm.createAndInitializePoolIfNecessary(token0, token1, SQRT_PRICE_1_1);

        ISwaprAlgebraPositionManager.MintParams memory mintParams = ISwaprAlgebraPositionManager
            .MintParams({
            token0: token0,
            token1: token1,
            tickLower: FULL_RANGE_LOWER,
            tickUpper: FULL_RANGE_UPPER,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1 hours
        });

        (, uint128 liquidity,,) = pm.mint(mintParams);
        assertGt(liquidity, 0, "dust mint failed");
    }

    function _sortPairAndAmounts(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        internal
        pure
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        if (tokenA < tokenB) {
            return (tokenA, tokenB, amountA, amountB);
        }
        return (tokenB, tokenA, amountB, amountA);
    }
}
