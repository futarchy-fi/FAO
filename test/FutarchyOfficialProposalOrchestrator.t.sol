// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOToken} from "../src/FAOToken.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../src/FutarchyOfficialProposalSource.sol";
import {
    FutarchyOfficialProposalOrchestrator,
    IFutarchyFactoryLike
} from "../src/FutarchyOfficialProposalOrchestrator.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";

import {FAOSaleTestHarness} from "./mocks/FAOSaleTestHarness.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockAlgebraPoolLike} from "./mocks/MockAlgebraPoolLike.sol";
import {MockSwaprAlgebraPositionManager} from "./mocks/MockSwaprAlgebraPositionManager.sol";
import {MockFutarchyFactory} from "./mocks/MockFutarchyFactory.sol";

contract FutarchyOfficialProposalOrchestratorTest is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    FAOToken internal token;
    FAOSaleTestHarness internal sale;
    MockWrappedNative internal wrappedNative;
    MockAlgebraFactoryLike internal algebraFactory;
    MockAlgebraPoolLike internal spotPool;
    MockFutarchyFactory internal futarchyFactory;
    MockSwaprAlgebraPositionManager internal posManager;
    FutarchyOfficialProposalOrchestrator internal orchestrator;
    FutarchyOfficialProposalSource internal source;
    MockFutarchyLiquidityAdapter internal spotAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal conditionalRouter;
    FutarchyLiquidityManager internal manager;

    function setUp() public {
        // ---- Local sale stack ----
        token = new FAOToken(address(this));
        sale = new FAOSaleTestHarness(
            token, 1_000_000, 14 days, address(this), address(0), address(0)
        );
        token.grantRole(token.MINTER_ROLE(), address(sale));

        sale.startSale();
        address buyer = address(0xBEEF);
        vm.deal(buyer, 120 ether);
        vm.prank(buyer);
        sale.buy{value: 100 ether}(1_000_000);
        sale.forceFinalizeInitialPhaseForTests();

        // ---- Spot pool (used only for price reference in the orchestrator) ----
        wrappedNative = new MockWrappedNative();
        algebraFactory = new MockAlgebraFactoryLike();
        spotPool = new MockAlgebraPoolLike(address(token), address(wrappedNative));
        spotPool.setSqrtPriceX96(SQRT_PRICE_1_1);
        spotPool.setTick(0);
        algebraFactory.setPool(address(token), address(wrappedNative), address(spotPool));

        // ---- Futarchy + pool creation mocks ----
        futarchyFactory = new MockFutarchyFactory();
        posManager = new MockSwaprAlgebraPositionManager(algebraFactory);

        orchestrator = new FutarchyOfficialProposalOrchestrator(
            address(this),
            IFutarchyFactoryLike(address(futarchyFactory)),
            IAlgebraFactoryLike(address(algebraFactory)),
            ISwaprAlgebraPositionManager(address(posManager))
        );

        source = new FutarchyOfficialProposalSource(
            address(this), address(orchestrator), IAlgebraFactoryLike(address(algebraFactory))
        );

        spotAdapter = new MockFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        conditionalRouter = new MockConditionalRouter();

        manager = new FutarchyLiquidityManager(
            address(sale),
            token,
            IWrappedNative(address(wrappedNative)),
            address(orchestrator),
            source,
            spotAdapter,
            conditionalAdapter,
            conditionalRouter,
            address(this)
        );

        orchestrator.setWiring(manager, source);

        // Seed 100/100 into spot.
        sale.seedLiquidityManager(address(manager), 100 ether, 100 ether, "");
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalLiquidity(), 0);
        assertFalse(manager.inConditionalMode());
    }

    function test_orchestrator_creates_official_proposal_and_migrates_atomically() public {
        // Permissionless candidate creation.
        address proposer = address(0xCAFE);
        vm.prank(proposer);
        (uint256 proposalId, address proposal) = orchestrator.createCandidateProposal(
            "FAO test proposal", "fao,test", "en", 1 ether, uint32(block.timestamp + 1 days)
        );

        // Candidate creation does not affect liquidity.
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 100 ether);

        // Admin promotion migrates liquidity atomically.
        orchestrator.promoteToOfficialAndMigrate(proposalId);

        // Manager should now be in conditional mode with 80% migrated.
        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeProposalId(), proposalId);
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalLiquidity(), 80 ether);

        // Proposal source should have the orchestrator as creator (official proposer identity).
        IFutarchyOfficialProposalSource.OfficialProposalData memory d =
            source.officialProposalExtended();
        assertEq(d.proposalId, proposalId);
        assertEq(d.proposal, proposal);
        assertEq(d.creator, address(orchestrator));
        assertTrue(d.exists);
        assertEq(d.proposalToken, address(token));
        assertEq(d.collateralToken, address(wrappedNative));
    }
}
