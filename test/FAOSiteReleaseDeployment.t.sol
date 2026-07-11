// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Space} from "sx/Space.sol";

import {AlwaysZeroVotingStrategy} from "../src/AlwaysZeroVotingStrategy.sol";
import {EvaluationPipeline} from "../src/EvaluationPipeline.sol";
import {FAOSiteReleaseDeployment} from "../src/FAOSiteReleaseDeployment.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {FutarchyCtfSettlementOracle} from "../src/FutarchyCtfSettlementOracle.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/FutarchyLiquidityManager.sol";
import {
    FutarchyOfficialProposalOrchestrator
} from "../src/FutarchyOfficialProposalOrchestrator.sol";
import {FutarchyOfficialProposalSource} from "../src/FutarchyOfficialProposalSource.sol";
import {FutarchyTWAPOracle} from "../src/FutarchyTWAPOracle.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "../src/SXProposalGateway.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {ISpaceErrors} from "../src/interfaces/space/ISpaceErrors.sol";
import {FinalizationStatus, InitializeCalldata, Strategy} from "../src/types.sol";

import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockAlgebraPoolLike} from "./mocks/MockAlgebraPoolLike.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockFutarchyFactory} from "./mocks/MockFutarchyFactory.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockSwaprAlgebraPositionManager} from "./mocks/MockSwaprAlgebraPositionManager.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract BondTokenMock is ERC20 {
    constructor() ERC20("Sepolia Bond", "BOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ExternalDependencyMock {}

contract ImmutableManagerWiringMock {
    IERC20 public immutable FAO_TOKEN;
    IWrappedNative public immutable WRAPPED_NATIVE;
    address public immutable SALE;
    address public immutable OFFICIAL_PROPOSER;
    IFutarchyOfficialProposalSource public immutable PROPOSAL_SOURCE;
    address public immutable SPOT_ADAPTER;
    address public immutable CONDITIONAL_ADAPTER;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;

    constructor(
        IERC20 faoToken,
        IWrappedNative wrappedNative,
        address sale,
        address officialProposer,
        IFutarchyOfficialProposalSource proposalSource,
        address spotAdapter,
        address conditionalAdapter,
        IFutarchyConditionalRouter conditionalRouter
    ) {
        FAO_TOKEN = faoToken;
        WRAPPED_NATIVE = wrappedNative;
        SALE = sale;
        OFFICIAL_PROPOSER = officialProposer;
        PROPOSAL_SOURCE = proposalSource;
        SPOT_ADAPTER = spotAdapter;
        CONDITIONAL_ADAPTER = conditionalAdapter;
        CONDITIONAL_ROUTER = conditionalRouter;
    }

    function sync(FutarchyLiquidityManager.SyncParams calldata)
        external
        pure
        returns (FutarchyLiquidityManager.SyncAction)
    {
        return FutarchyLiquidityManager.SyncAction.MigratedToConditional;
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    function pendingOwner() external pure returns (address) {
        return address(0);
    }

    function emergencyExitArmedAt() external pure returns (uint256) {
        return 0;
    }

    function emergencyExitExecuted() external pure returns (bool) {
        return false;
    }

    function inConditionalMode() external pure returns (bool) {
        return false;
    }

    function activeProposalId() external pure returns (uint256) {
        return 0;
    }

    function activeProposal() external pure returns (address) {
        return address(0);
    }
}

contract FAOSiteReleaseDeploymentTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MIN_ACTIVATION_BOND = 1e18;
    uint256 internal constant BASE_X = 100e18;
    uint256 internal constant TIMEOUT = 72 hours;
    uint32 internal constant TRADING_PERIOD = 7 days;
    uint32 internal constant TWAP_WINDOW = 1 days;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    Space internal implementation;
    BondTokenMock internal bondToken;
    MockWrappedNative internal wrappedNative;
    MockFutarchyFactory internal futarchyFactory;
    MockAlgebraFactoryLike internal algebraFactory;
    MockSwaprAlgebraPositionManager internal positionManager;
    MockAlgebraPoolLike internal spotPool;
    MockConditionalRouter internal conditionalRouter;
    FutarchyCtfSettlementOracle internal settlementOracle;
    ExternalDependencyMock internal sale;
    ExternalDependencyMock internal spotAdapter;
    ExternalDependencyMock internal conditionalAdapter;
    FutarchyOfficialProposalSource internal proposalSource;
    ImmutableManagerWiringMock internal manager;

    function setUp() public {
        implementation = new Space();
        bondToken = new BondTokenMock();
        wrappedNative = new MockWrappedNative();
        futarchyFactory = new MockFutarchyFactory();
        algebraFactory = new MockAlgebraFactoryLike();
        positionManager = new MockSwaprAlgebraPositionManager(algebraFactory);
        conditionalRouter = new MockConditionalRouter();
        settlementOracle =
            new FutarchyCtfSettlementOracle(IFutarchyConditionalRouter(address(conditionalRouter)));
        sale = new ExternalDependencyMock();
        spotAdapter = new ExternalDependencyMock();
        conditionalAdapter = new ExternalDependencyMock();

        spotPool = new MockAlgebraPoolLike(address(bondToken), address(wrappedNative));
        spotPool.setSqrtPriceX96(SQRT_PRICE_1_1);
        algebraFactory.setPool(address(bondToken), address(wrappedNative), address(spotPool));
    }

    function testDeploysWiresAndIrrevocablyLocksWorkingStackInOneTransaction() public {
        FAOSiteReleaseDeployment deployment = _deploy();
        _assertSpaceConfig(deployment);
        _assertWiring(deployment);
        _assertAuthoritiesLocked(deployment);
        _executeEvaluatedRelease(deployment);
    }

    function testRejectsMismatchedExternalDependencyCodehash() public {
        (FAOSiteReleaseDeployment.Config memory config,,) = _deploymentConfig();
        bytes32 actual = config.algebraFactory.codehash;
        bytes32 wrong = bytes32(uint256(actual) ^ 1);
        config.algebraFactory.codehash = wrong;

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOSiteReleaseDeployment.InvalidCodehash.selector,
                config.algebraFactory.target,
                wrong,
                actual
            )
        );
        new FAOSiteReleaseDeployment(address(implementation), config);
    }

    function _deploy() internal returns (FAOSiteReleaseDeployment deployment) {
        (
            FAOSiteReleaseDeployment.Config memory config,
            address predictedDeployment,
            address predictedOrchestrator
        ) = _deploymentConfig();
        deployment = new FAOSiteReleaseDeployment(address(implementation), config);
        assertEq(address(deployment), predictedDeployment);
        assertEq(deployment.orchestrator(), predictedOrchestrator);
    }

    function _deploymentConfig()
        internal
        returns (
            FAOSiteReleaseDeployment.Config memory config,
            address predictedDeployment,
            address predictedOrchestrator
        )
    {
        uint256 nextNonce = vm.getNonce(address(this));
        predictedDeployment = vm.computeCreateAddress(address(this), nextNonce + 2);
        predictedOrchestrator = vm.computeCreateAddress(predictedDeployment, 7);

        proposalSource = new FutarchyOfficialProposalSource(
            address(this), predictedOrchestrator, IAlgebraFactoryLike(address(algebraFactory))
        );
        proposalSource.setSettlementOracle(address(settlementOracle));
        proposalSource.renounceOwnership();
        manager = new ImmutableManagerWiringMock(
            IERC20(address(bondToken)),
            IWrappedNative(address(wrappedNative)),
            address(sale),
            predictedOrchestrator,
            IFutarchyOfficialProposalSource(address(proposalSource)),
            address(spotAdapter),
            address(conditionalAdapter),
            IFutarchyConditionalRouter(address(conditionalRouter))
        );

        config = FAOSiteReleaseDeployment.Config({
            spaceImplementationCodehash: address(implementation).codehash,
            bondToken: _dependency(address(bondToken)),
            graduationThreshold: BASE_X,
            arbitrationTimeout: TIMEOUT,
            minActivationBond: MIN_ACTIVATION_BOND,
            futarchyFactory: _dependency(address(futarchyFactory)),
            algebraFactory: _dependency(address(algebraFactory)),
            positionManager: _dependency(address(positionManager)),
            manager: _dependency(address(manager)),
            proposalSource: _dependency(address(proposalSource)),
            settlementOracle: _dependency(address(settlementOracle)),
            faoToken: _dependency(address(bondToken)),
            wrappedNative: _dependency(address(wrappedNative)),
            sale: _dependency(address(sale)),
            spotAdapter: _dependency(address(spotAdapter)),
            conditionalAdapter: _dependency(address(conditionalAdapter)),
            conditionalRouter: _dependency(address(conditionalRouter)),
            spotPool: _dependency(address(spotPool)),
            tradingPeriod: TRADING_PERIOD,
            twapWindow: TWAP_WINDOW,
            thresholdTicks: 0,
            evaluationMinBond: 1e18,
            marketOpeningDelay: 0,
            daoURI: "ipfs://fao-dao",
            metadataURI: "ipfs://fao-space"
        });
    }

    function _dependency(address target)
        internal
        view
        returns (FAOSiteReleaseDeployment.Dependency memory)
    {
        return FAOSiteReleaseDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _assertSpaceConfig(FAOSiteReleaseDeployment deployment) internal view {
        Space space = Space(deployment.space());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        AlwaysZeroVotingStrategy votingStrategy =
            AlwaysZeroVotingStrategy(deployment.votingStrategy());

        assertEq(deployment.spaceImplementation(), address(implementation));
        assertEq(space.owner(), address(0));
        assertEq(arbitration.owner(), address(0));
        assertEq(arbitration.pendingOwner(), address(0));
        assertEq(address(arbitration.bondToken()), address(bondToken));
        assertEq(arbitration.baseX(), BASE_X);
        assertEq(arbitration.timeout(), TIMEOUT);
        assertEq(space.votingDelay(), 0);
        assertEq(space.minVotingDuration(), 0);
        assertEq(space.maxVotingDuration(), 0);
        assertEq(space.daoURI(), "ipfs://fao-dao");
        assertEq(
            address(uint160(uint256(vm.load(address(space), IMPLEMENTATION_SLOT)))),
            address(implementation)
        );

        assertEq(space.authenticators(address(gateway)), 1);
        assertEq(space.authenticators(address(this)), 0);
        assertEq(space.nextVotingStrategyIndex(), 1);
        assertEq(space.activeVotingStrategies(), 1);
        (address storedVotingStrategy, bytes memory votingParams) = space.votingStrategies(0);
        assertEq(storedVotingStrategy, address(votingStrategy));
        assertEq(votingParams, bytes(""));
        assertEq(votingStrategy.getVotingPower(0, address(this), "", ""), 0);

        (address validationStrategy, bytes memory validationParams) =
            space.proposalValidationStrategy();
        assertEq(validationStrategy, deployment.proposalValidationStrategy());
        assertEq(validationParams, bytes(""));
    }

    function _assertWiring(FAOSiteReleaseDeployment deployment) internal view {
        Space space = Space(deployment.space());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        SXArbitrationExecutionStrategy releaseStrategy =
            SXArbitrationExecutionStrategy(deployment.releaseStrategy());
        EvaluationPipeline evaluator = EvaluationPipeline(deployment.evaluator());
        FutarchyOfficialProposalOrchestrator orchestrator =
            FutarchyOfficialProposalOrchestrator(deployment.orchestrator());
        FutarchyTWAPOracle twapOracle = FutarchyTWAPOracle(deployment.twapOracle());
        assertEq(address(gateway.space()), address(space));
        assertEq(address(gateway.executionStrategy()), address(releaseStrategy));
        assertEq(address(gateway.arbitration()), address(arbitration));
        assertEq(gateway.minActivationBond(), MIN_ACTIVATION_BOND);
        assertEq(releaseStrategy.space(), address(space));
        assertEq(address(releaseStrategy.arbitration()), address(arbitration));
        assertEq(arbitration.proposalGateway(), address(gateway));
        assertEq(address(arbitration.evaluator()), address(evaluator));
        assertEq(evaluator.arbitration(), address(arbitration));
        assertEq(address(evaluator.orchestrator()), address(orchestrator));
        assertEq(address(evaluator.twapOracle()), address(twapOracle));
        assertEq(address(evaluator.algebraFactory()), address(algebraFactory));
        assertEq(evaluator.evaluationMinBond(), 1e18);
        assertEq(evaluator.marketOpeningDelay(), 0);
        assertEq(orchestrator.ADMIN(), address(evaluator));
        assertTrue(orchestrator.wired());
        assertEq(address(orchestrator.FUTARCHY_FACTORY()), address(futarchyFactory));
        assertEq(address(orchestrator.ALGEBRA_FACTORY()), address(algebraFactory));
        assertEq(address(orchestrator.POSITION_MANAGER()), address(positionManager));
        assertEq(address(orchestrator.manager()), address(manager));
        assertEq(address(orchestrator.proposalSource()), address(proposalSource));
        assertEq(twapOracle.binder(), address(evaluator));
        assertEq(twapOracle.tradingPeriod(), TRADING_PERIOD);
        assertEq(twapOracle.twapWindow(), TWAP_WINDOW);
        assertEq(twapOracle.thresholdTicks(), 0);
        assertEq(address(manager.FAO_TOKEN()), address(bondToken));
        assertEq(address(manager.WRAPPED_NATIVE()), address(wrappedNative));
        assertEq(manager.SALE(), address(sale));
        assertEq(manager.SPOT_ADAPTER(), address(spotAdapter));
        assertEq(manager.CONDITIONAL_ADAPTER(), address(conditionalAdapter));
        assertEq(address(manager.CONDITIONAL_ROUTER()), address(conditionalRouter));
        assertEq(manager.owner(), address(0));
        assertEq(manager.pendingOwner(), address(0));
        assertEq(proposalSource.officialProposer(), address(orchestrator));
        assertEq(proposalSource.settlementOracle(), address(settlementOracle));
        assertEq(proposalSource.owner(), address(0));
        assertEq(proposalSource.pendingOwner(), address(0));
        assertEq(address(settlementOracle.ROUTER()), address(conditionalRouter));
        assertEq(
            algebraFactory.poolByPair(address(bondToken), address(wrappedNative)), address(spotPool)
        );
    }

    function _assertAuthoritiesLocked(FAOSiteReleaseDeployment deployment) internal {
        Space space = Space(deployment.space());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        SXArbitrationExecutionStrategy releaseStrategy =
            SXArbitrationExecutionStrategy(deployment.releaseStrategy());
        EvaluationPipeline evaluator = EvaluationPipeline(deployment.evaluator());
        FutarchyOfficialProposalOrchestrator orchestrator =
            FutarchyOfficialProposalOrchestrator(deployment.orchestrator());
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        space.upgradeTo(address(implementation));
        assertEq(
            address(uint160(uint256(vm.load(address(space), IMPLEMENTATION_SLOT)))),
            address(implementation)
        );
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        arbitration.setProposalGateway(address(this));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        arbitration.setEvaluator(address(evaluator));
        vm.expectRevert(FutarchyOfficialProposalOrchestrator.AlreadyWired.selector);
        vm.prank(address(evaluator));
        orchestrator.setWiring(FutarchyLiquidityManager(payable(address(manager))), proposalSource);
        _assertCannotReinitialize(space);
        vm.expectRevert(ISpaceErrors.AuthenticatorNotWhitelisted.selector);
        space.propose(
            address(this),
            "ipfs://unauthorized",
            Strategy({addr: address(releaseStrategy), params: ""}),
            ""
        );
    }

    function _assertCannotReinitialize(Space space) internal {
        Strategy[] memory noVotingStrategies = new Strategy[](0);
        string[] memory noVotingMetadata = new string[](0);
        address[] memory noAuthenticators = new address[](0);

        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        space.initialize(
            InitializeCalldata({
                owner: address(this),
                votingDelay: 0,
                minVotingDuration: 0,
                maxVotingDuration: 0,
                proposalValidationStrategy: Strategy({addr: address(0), params: ""}),
                proposalValidationStrategyMetadataURI: "",
                daoURI: "",
                metadataURI: "",
                votingStrategies: noVotingStrategies,
                votingStrategyMetadataURIs: noVotingMetadata,
                authenticators: noAuthenticators
            })
        );
    }

    function _executeEvaluatedRelease(FAOSiteReleaseDeployment deployment) internal {
        bytes32 digest = keccak256("production-site-release");
        string memory uri = "ipfs://production-site-release";
        bytes memory payload = abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: 1,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: digest,
                artifactURI: uri
            })
        );
        uint256 arbitrationId = _proposeAndGraduate(deployment, payload);
        _resolveEvaluation(deployment, arbitrationId);

        Space space = Space(deployment.space());
        space.execute(1, payload);
        SXArbitrationExecutionStrategy releaseStrategy =
            SXArbitrationExecutionStrategy(deployment.releaseStrategy());
        assertEq(releaseStrategy.releaseNonce(), 1);
        assertEq(releaseStrategy.releaseDigest(), digest);
        assertEq(releaseStrategy.releaseURI(), uri);
        (,,,,, FinalizationStatus status,,) = space.proposals(1);
        assertEq(uint256(status), uint256(FinalizationStatus.Executed));
    }

    function _proposeAndGraduate(FAOSiteReleaseDeployment deployment, bytes memory payload)
        internal
        returns (uint256 arbitrationId)
    {
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        vm.prank(makeAddr("proposer"));
        gateway.propose("ipfs://proposal", payload, "");

        arbitrationId = uint256(keccak256(payload));
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        assertTrue(arbitration.getProposal(arbitrationId).exists);
        address yesBidder = makeAddr("yes-bidder");
        bondToken.mint(yesBidder, BASE_X + (2 * MIN_ACTIVATION_BOND));
        vm.startPrank(yesBidder);
        bondToken.approve(address(arbitration), type(uint256).max);
        arbitration.placeYesBond(arbitrationId, MIN_ACTIVATION_BOND);
        arbitration.placeNoBond(arbitrationId);
        arbitration.placeYesBond(arbitrationId, BASE_X);
        vm.stopPrank();
        arbitration.startNextEvaluation();
    }

    function _resolveEvaluation(FAOSiteReleaseDeployment deployment, uint256 arbitrationId)
        internal
    {
        EvaluationPipeline evaluator = EvaluationPipeline(deployment.evaluator());
        evaluator.startEvaluation(arbitrationId, "FAO site release", "governance", "en");
        address futarchyProposal = evaluator.futarchyProposalOf(arbitrationId);
        _setWinningTicks(futarchyProposal);

        vm.warp(block.timestamp + TRADING_PERIOD);
        assertTrue(FutarchyTWAPOracle(deployment.twapOracle()).resolve(futarchyProposal));
        assertTrue(evaluator.resolve(arbitrationId));
        assertTrue(FutarchyArbitration(deployment.arbitration()).isAccepted(arbitrationId));
    }

    function _setWinningTicks(address futarchyProposal) internal {
        MockFutarchyProposalLike proposal = MockFutarchyProposalLike(futarchyProposal);
        (address yesCompany,) = proposal.wrappedOutcome(0);
        (address noCompany,) = proposal.wrappedOutcome(1);
        (address yesCurrency,) = proposal.wrappedOutcome(2);
        (address noCurrency,) = proposal.wrappedOutcome(3);
        MockAlgebraPoolLike yesPool =
            MockAlgebraPoolLike(algebraFactory.poolByPair(yesCompany, yesCurrency));
        MockAlgebraPoolLike noPool =
            MockAlgebraPoolLike(algebraFactory.poolByPair(noCompany, noCurrency));
        int56 yesDelta = 100 * int56(int32(TWAP_WINDOW));
        if (yesPool.token0() != yesCompany) yesDelta = -yesDelta;
        yesPool.setTickCumulatives(0, yesDelta);
        noPool.setTickCumulatives(0, 0);
    }
}
