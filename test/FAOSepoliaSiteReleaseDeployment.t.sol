// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {ProxyFactory} from "lib/sx-evm/src/ProxyFactory.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "lib/sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {AlwaysZeroVotingStrategy} from "../src/AlwaysZeroVotingStrategy.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOSepoliaSiteReleaseDeployment} from "../src/FAOSepoliaSiteReleaseDeployment.sol";
import {FAOSiteEvaluationPipeline} from "../src/FAOSiteEvaluationPipeline.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "../src/SXProposalGateway.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {Choice, IndexedStrategy, InitializeCalldata, Strategy} from "src/types.sol";

contract SiteDeploymentTokenMock is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SiteDeploymentExternalDependencyMock {}

contract SiteDeploymentPoolMock is IUniswapV3PoolLike {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint160 public sqrtPriceX96 = uint160(1 << 96);

    constructor(address tokenA, address tokenB, uint24 fee_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 1, 1, 0, true);
    }

    function initialize(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function increaseObservationCardinalityNext(uint16) external {}

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (int56[] memory ticks, uint160[] memory liquidity)
    {
        ticks = new int56[](secondsAgos.length);
        liquidity = new uint160[](secondsAgos.length);
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract SiteDeploymentFactoryMock is IUniswapV3FactoryLike {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(address, address, uint24) external pure returns (address) {
        revert("not needed");
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract FAOSepoliaSiteReleaseDeploymentTest is Test {
    uint24 internal constant FEE = 500;
    uint16 internal constant CARDINALITY = 100;
    uint256 internal constant MIN_ACTIVATION_BOND = 1 ether;
    uint256 internal constant GRADUATION_THRESHOLD = 100 ether;
    uint256 internal constant ARBITRATION_TIMEOUT = 3 days;
    uint32 internal constant TWAP_TIMEOUT = 7 days;
    uint32 internal constant TWAP_WINDOW = 1 days;
    string internal constant DAO_URI =
        "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string internal constant SPACE_METADATA_URI =
        "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    string internal constant VOTING_STRATEGY_METADATA_URI =
        "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc";
    string internal constant PROPOSAL_VALIDATION_STRATEGY_METADATA_URI =
        "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd";

    ProxyFactory internal proxyFactory;
    Space internal spaceImplementation;
    VanillaProposalValidationStrategy internal validationStrategy;
    FAOSiteStackDeployer internal stackDeployer;
    FAOFutarchyProposal internal proposalImplementation;
    SiteDeploymentTokenMock internal bondToken;
    SiteDeploymentTokenMock internal companyToken;
    SiteDeploymentExternalDependencyMock internal ctf;
    SiteDeploymentExternalDependencyMock internal wrapped1155Factory;
    SiteDeploymentFactoryMock internal uniswapV3Factory;
    SiteDeploymentPoolMock internal spotPool;
    FAOSepoliaSiteReleaseDeployment internal deployment;

    function setUp() public {
        proxyFactory = new ProxyFactory();
        spaceImplementation = new Space();
        validationStrategy = new VanillaProposalValidationStrategy();
        stackDeployer = new FAOSiteStackDeployer(false);
        proposalImplementation = new FAOFutarchyProposal();
        bondToken = new SiteDeploymentTokenMock("Bond", "BOND");
        companyToken = new SiteDeploymentTokenMock("FAO Site", "FAOS");
        ctf = new SiteDeploymentExternalDependencyMock();
        wrapped1155Factory = new SiteDeploymentExternalDependencyMock();
        uniswapV3Factory = new SiteDeploymentFactoryMock();
        spotPool = new SiteDeploymentPoolMock(address(companyToken), address(bondToken), FEE);
        uniswapV3Factory.setPool(address(companyToken), address(bondToken), FEE, address(spotPool));

        deployment = new FAOSepoliaSiteReleaseDeployment(_config());
    }

    function testDeploysOfficialProxyFactorySpaceAndLocksEveryAuthority() public view {
        Space space = Space(deployment.space());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        SXArbitrationExecutionStrategy release =
            SXArbitrationExecutionStrategy(deployment.releaseStrategy());
        AlwaysZeroVotingStrategy zeroVoting = AlwaysZeroVotingStrategy(deployment.votingStrategy());
        FAOSiteEvaluationPipeline evaluator = FAOSiteEvaluationPipeline(deployment.evaluator());
        FAOOfficialProposalOrchestrator orchestrator =
            FAOOfficialProposalOrchestrator(deployment.orchestrator());
        FAOTwapResolver resolver = FAOTwapResolver(deployment.resolver());

        assertEq(space.owner(), address(0));
        assertEq(arbitration.owner(), address(0));
        assertEq(arbitration.pendingOwner(), address(0));
        assertEq(arbitration.proposalGateway(), address(gateway));
        assertEq(address(arbitration.evaluator()), address(evaluator));
        assertEq(space.authenticators(address(gateway)), 1);
        assertEq(space.authenticators(address(this)), 0);
        assertEq(space.votingDelay(), 0);
        assertEq(space.minVotingDuration(), 0);
        assertEq(space.maxVotingDuration(), 0);
        assertEq(space.activeVotingStrategies(), 1);
        assertEq(zeroVoting.getVotingPower(0, address(this), "", ""), 0);
        assertEq(address(gateway.space()), address(space));
        assertEq(address(gateway.executionStrategy()), address(release));
        assertEq(release.space(), address(space));
        assertEq(orchestrator.ADMIN(), address(evaluator));
        assertFalse(orchestrator.ADAPTER_REPLACEABLE());
        assertEq(address(orchestrator.adapter()), address(0));
        assertEq(resolver.orchestrator(), address(orchestrator));
        assertEq(evaluator.arbitrationContract(), address(arbitration));
        assertEq(address(evaluator.orchestrator()), address(orchestrator));
        assertEq(address(evaluator.resolver()), address(resolver));
    }

    function testLocksExactMetadataBeforeRenouncingSpaceOwnership() public {
        vm.recordLogs();
        FAOSepoliaSiteReleaseDeployment candidate = new FAOSepoliaSiteReleaseDeployment(_config());
        Vm.Log[] memory entries = vm.getRecordedLogs();

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy({addr: candidate.votingStrategy(), params: ""});
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = VOTING_STRATEGY_METADATA_URI;
        address[] memory authenticators = new address[](1);
        authenticators[0] = candidate.proposalGateway();
        InitializeCalldata memory input = InitializeCalldata({
            owner: address(candidate),
            votingDelay: 0,
            minVotingDuration: 0,
            maxVotingDuration: 0,
            proposalValidationStrategy: Strategy({addr: address(validationStrategy), params: ""}),
            proposalValidationStrategyMetadataURI: PROPOSAL_VALIDATION_STRATEGY_METADATA_URI,
            daoURI: DAO_URI,
            metadataURI: SPACE_METADATA_URI,
            votingStrategies: votingStrategies,
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: authenticators
        });

        bytes32 expectedDataHash = keccak256(abi.encode(candidate.space(), input));
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == candidate.space()
                    && keccak256(entries[i].data) == expectedDataHash
            ) found = true;
        }

        assertTrue(found);
        assertEq(Space(candidate.space()).daoURI(), DAO_URI);
        assertEq(Space(candidate.space()).owner(), address(0));
    }

    function testVotingIsPermanentlyUnreachable() public {
        bytes memory payload =
            _releasePayload(1, bytes32(0), keccak256("release"), "ipfs://release");
        vm.prank(makeAddr("proposer"));
        SXProposalGateway(deployment.proposalGateway()).propose("ipfs://proposal", payload, "");

        IndexedStrategy[] memory strategies = new IndexedStrategy[](1);
        strategies[0] = IndexedStrategy({index: 0, params: ""});
        address voter = makeAddr("voter");
        Space deployedSpace = Space(deployment.space());
        vm.expectRevert();
        deployedSpace.vote(voter, 1, Choice.For, strategies, "");
        assertEq(deployedSpace.votePower(1, Choice.For), 0);
    }

    function testOutsiderCannotInjectUnevaluableQueueEntry() public {
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        vm.expectRevert(FutarchyArbitration.NotProposalGateway.selector);
        vm.prank(makeAddr("queue-attacker"));
        arbitration.createProposal(MIN_ACTIVATION_BOND);

        assertEq(arbitration.activeEvaluationProposalId(), 0);
        assertEq(arbitration.nextProposalId(), 1);
    }

    function testMalformedPayloadCannotReserveQueueEntry() public {
        bytes memory malformed = hex"01";
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());

        vm.expectRevert();
        gateway.propose("ipfs://malformed", malformed, "");

        vm.expectRevert(FutarchyArbitration.ProposalNotFound.selector);
        arbitration.getProposal(uint256(keccak256(malformed)));
    }

    function testStaticInvalidPayloadsCannotReserveQueueEntries() public {
        _assertGatewayRejects(
            _releasePayload(0, bytes32(0), keccak256("release"), "ipfs://release")
        );
        _assertGatewayRejects(_releasePayload(1, bytes32(0), bytes32(0), "ipfs://release"));
        _assertGatewayRejects(_releasePayload(1, bytes32(0), keccak256("release"), ""));
        _assertGatewayRejects(
            _releasePayload(1, bytes32(0), keccak256("release"), string(new bytes(257)))
        );
    }

    function testUnchallengedYesTimeoutSelectsSiteReleaseWithZeroVotes() public {
        bytes32 digest = keccak256("timeout-release");
        bytes memory payload = _releasePayload(1, bytes32(0), digest, "ipfs://timeout-release");
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        vm.prank(makeAddr("proposer"));
        gateway.propose("ipfs://proposal", payload, "");

        uint256 arbitrationId = uint256(keccak256(payload));
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        address yesBidder = makeAddr("yes-bidder");
        bondToken.mint(yesBidder, MIN_ACTIVATION_BOND);
        vm.startPrank(yesBidder);
        bondToken.approve(address(arbitration), MIN_ACTIVATION_BOND);
        arbitration.placeYesBond(arbitrationId, MIN_ACTIVATION_BOND);
        vm.stopPrank();

        vm.warp(block.timestamp + ARBITRATION_TIMEOUT);
        arbitration.finalizeByTimeout(arbitrationId);
        Space(deployment.space()).execute(1, payload);

        SXArbitrationExecutionStrategy release =
            SXArbitrationExecutionStrategy(deployment.releaseStrategy());
        assertTrue(arbitration.isAccepted(arbitrationId));
        assertEq(release.releaseNonce(), 1);
        assertEq(release.releaseDigest(), digest);
        assertEq(release.releaseURI(), "ipfs://timeout-release");
        assertEq(Space(deployment.space()).votePower(1, Choice.For), 0);
        assertEq(Space(deployment.space()).votePower(1, Choice.Against), 0);
        assertEq(Space(deployment.space()).votePower(1, Choice.Abstain), 0);
    }

    function testRejectsMutableStackDeployer() public {
        FAOSiteStackDeployer mutableStackDeployer = new FAOSiteStackDeployer(true);
        FAOSepoliaSiteReleaseDeployment.Config memory config = _config();
        config.stackDeployer = _dependency(address(mutableStackDeployer));

        vm.expectRevert(FAOSepoliaSiteReleaseDeployment.InvalidConfig.selector);
        new FAOSepoliaSiteReleaseDeployment(config);
    }

    function testRejectsMetadataThatWouldBeFrozenByRenunciation() public {
        FAOSepoliaSiteReleaseDeployment.Config memory config = _config();
        config.daoURI = "";
        _expectInvalidMetadata(config);

        config = _config();
        config.metadataURI = "https://example.com/space.json";
        _expectInvalidMetadata(config);

        config = _config();
        config.votingStrategyMetadataURI = "ipfs://";
        _expectInvalidMetadata(config);

        config = _config();
        config.proposalValidationStrategyMetadataURI = "VanillaProposalValidationStrategy";
        _expectInvalidMetadata(config);

        config = _config();
        config.daoURI = "ipfs://fao-site-dao";
        _expectInvalidMetadata(config);

        config = _config();
        config.metadataURI = "ipfs://fao-site-space";
        _expectInvalidMetadata(config);
    }

    function _config()
        internal
        view
        returns (FAOSepoliaSiteReleaseDeployment.Config memory config)
    {
        config = FAOSepoliaSiteReleaseDeployment.Config({
                proxyFactory: _dependency(address(proxyFactory)),
                spaceImplementation: _dependency(address(spaceImplementation)),
                proposalValidationStrategy: _dependency(address(validationStrategy)),
                stackDeployer: _dependency(address(stackDeployer)),
                proposalImplementation: _dependency(address(proposalImplementation)),
                bondToken: _dependency(address(bondToken)),
                conditionalTokens: _dependency(address(ctf)),
                wrapped1155Factory: _dependency(address(wrapped1155Factory)),
                uniswapV3Factory: _dependency(address(uniswapV3Factory)),
                companyToken: _dependency(address(companyToken)),
                spotPool: _dependency(address(spotPool)),
                graduationThreshold: GRADUATION_THRESHOLD,
                arbitrationTimeout: ARBITRATION_TIMEOUT,
                minActivationBond: MIN_ACTIVATION_BOND,
                feeTier: FEE,
                observationCardinality: CARDINALITY,
                twapTimeout: TWAP_TIMEOUT,
                twapWindow: TWAP_WINDOW,
                spaceSaltNonce: 1,
                daoURI: DAO_URI,
                metadataURI: SPACE_METADATA_URI,
                votingStrategyMetadataURI: VOTING_STRATEGY_METADATA_URI,
                proposalValidationStrategyMetadataURI: PROPOSAL_VALIDATION_STRATEGY_METADATA_URI
            });
    }

    function _expectInvalidMetadata(FAOSepoliaSiteReleaseDeployment.Config memory config) internal {
        vm.expectRevert(FAOSepoliaSiteReleaseDeployment.InvalidMetadataURI.selector);
        new FAOSepoliaSiteReleaseDeployment(config);
    }

    function _dependency(address target)
        internal
        view
        returns (FAOSepoliaSiteReleaseDeployment.Dependency memory)
    {
        return
            FAOSepoliaSiteReleaseDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _releasePayload(
        uint256 nonce,
        bytes32 expectedCurrentDigest,
        bytes32 artifactDigest,
        string memory artifactURI
    ) internal pure returns (bytes memory) {
        return abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: nonce,
                expectedCurrentDigest: expectedCurrentDigest,
                artifactDigest: artifactDigest,
                artifactURI: artifactURI
            })
        );
    }

    function _assertGatewayRejects(bytes memory payload) internal {
        SXProposalGateway gateway = SXProposalGateway(deployment.proposalGateway());
        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());

        vm.expectRevert(SXProposalGateway.InvalidExecutionPayload.selector);
        gateway.propose("ipfs://invalid", payload, "");

        vm.expectRevert(FutarchyArbitration.ProposalNotFound.selector);
        arbitration.getProposal(uint256(keccak256(payload)));
    }
}
