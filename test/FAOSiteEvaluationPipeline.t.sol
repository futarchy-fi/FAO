// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {FAOSiteEvaluationPipeline} from "../src/FAOSiteEvaluationPipeline.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

contract SiteEvaluationArbitrationMock {
    uint256 public activeEvaluationProposalId;
    bool public resolved;
    bool public accepted;

    function setActive(uint256 proposalId) external {
        activeEvaluationProposalId = proposalId;
    }

    function resolveActiveEvaluation(bool accepted_) external {
        resolved = true;
        accepted = accepted_;
        activeEvaluationProposalId = 0;
    }
}

contract SiteEvaluationConditionalTokensMock {
    struct Payout {
        uint256 denominator;
        uint256 yes;
        uint256 no;
    }

    mapping(bytes32 => Payout) public payouts;

    function setPayout(bytes32 conditionId, uint256 denominator, uint256 yes, uint256 no) external {
        payouts[conditionId] = Payout(denominator, yes, no);
    }

    function payoutDenominator(bytes32 conditionId) external view returns (uint256) {
        return payouts[conditionId].denominator;
    }

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256) {
        return index == 0 ? payouts[conditionId].yes : payouts[conditionId].no;
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata numerators) external {
        uint256 denominator = numerators[0] + numerators[1];
        payouts[questionId] = Payout(denominator, numerators[0], numerators[1]);
    }
}

contract SiteEvaluationProposalMock {
    bytes32 public immutable conditionId;
    bytes32 public immutable questionId;
    address[4] internal wrappers;

    constructor(bytes32 conditionId_) {
        conditionId = conditionId_;
        questionId = conditionId_;
        wrappers = [address(0xC01), address(0xC02), address(0xC03), address(0xC04)];
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (wrappers[index], "");
    }
}

contract SiteEvaluationBrokenPool is IUniswapV3PoolLike {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (1 << 96, 0, 0, 1, 100, 0, true);
    }
    function initialize(uint160) external pure {}
    function increaseObservationCardinalityNext(uint16) external pure {}

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function observe(uint32[] calldata) external pure returns (int56[] memory, uint160[] memory) {
        revert("OLD");
    }
}

contract SiteEvaluationBondToken is ERC20 {
    constructor() ERC20("Bond", "BOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SiteEvaluationBindingOrchestratorMock {
    address public ADMIN;
    address public immutable RESOLVER;
    address public immutable proposal;
    address public immutable yesPool;
    address public immutable noPool;

    constructor(address resolver_, address proposal_, address yesPool_, address noPool_) {
        RESOLVER = resolver_;
        proposal = proposal_;
        yesPool = yesPool_;
        noPool = noPool_;
    }

    function setAdmin(address admin_) external {
        ADMIN = admin_;
    }

    function createOfficialProposalAndMigrate(string calldata, string calldata, uint256)
        external
        payable
        returns (uint256, address)
    {
        FAOTwapResolver(RESOLVER)
            .bindProposal(
                proposal, yesPool, noPool, address(0xFA0), address(0xE7), uint48(block.timestamp)
            );
        return (0, proposal);
    }
}

contract SiteEvaluationResolverMock {
    address public immutable CTF;
    SiteEvaluationConditionalTokensMock internal immutable ctf;
    bytes32 public immutable conditionId;
    uint256 public resolveCalls;
    uint256 public denominator = 1;
    uint256 public yes = 1;
    uint256 public no;

    constructor(SiteEvaluationConditionalTokensMock ctf_, bytes32 conditionId_) {
        ctf = ctf_;
        CTF = address(ctf_);
        conditionId = conditionId_;
    }

    function setDecision(uint256 denominator_, uint256 yes_, uint256 no_) external {
        denominator = denominator_;
        yes = yes_;
        no = no_;
    }

    function resolve(address) external {
        resolveCalls++;
        ctf.setPayout(conditionId, denominator, yes, no);
    }
}

contract SiteEvaluationOrchestratorMock {
    address public immutable ADMIN;
    address public immutable RESOLVER;
    address public immutable proposal;

    uint256 public createCalls;
    string public lastMarketName;
    string public lastDescription;
    uint256 public lastBuilderTip;
    uint256 public lastValue;

    constructor(address admin_, address resolver_, address proposal_) {
        ADMIN = admin_;
        RESOLVER = resolver_;
        proposal = proposal_;
    }

    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata description,
        uint256 builderTip
    ) external payable returns (uint256 proposalId, address proposal_) {
        createCalls++;
        lastMarketName = marketName;
        lastDescription = description;
        lastBuilderTip = builderTip;
        lastValue = msg.value;
        return (createCalls - 1, proposal);
    }
}

contract FAOSiteEvaluationPipelineTest is Test {
    using Strings for uint256;

    bytes32 internal constant CONDITION_ID = keccak256("site-evaluation-condition");

    SiteEvaluationArbitrationMock internal arbitration;
    SiteEvaluationConditionalTokensMock internal ctf;
    SiteEvaluationProposalMock internal proposal;
    SiteEvaluationResolverMock internal resolver;
    SiteEvaluationOrchestratorMock internal orchestrator;
    FAOSiteEvaluationPipeline internal pipeline;

    function setUp() public {
        arbitration = new SiteEvaluationArbitrationMock();
        ctf = new SiteEvaluationConditionalTokensMock();
        proposal = new SiteEvaluationProposalMock(CONDITION_ID);
        resolver = new SiteEvaluationResolverMock(ctf, CONDITION_ID);

        address expectedPipeline =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        orchestrator = new SiteEvaluationOrchestratorMock(
            expectedPipeline, address(resolver), address(proposal)
        );
        pipeline = new FAOSiteEvaluationPipeline(
            address(arbitration), address(orchestrator), address(resolver), address(ctf)
        );
        assertEq(address(pipeline), expectedPipeline);
    }

    function testStartEvaluationDerivesAllMarketTextFromCommittedPayload() public {
        bytes32 currentDigest = keccak256("current");
        bytes32 artifactDigest = keccak256("artifact");
        string memory uri = "ipfs://site-artifact";
        bytes memory payload = _payload(7, currentDigest, artifactDigest, uri);
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);

        pipeline.startEvaluation(proposalId, payload);

        assertEq(pipeline.futarchyProposalOf(proposalId), address(proposal));
        assertEq(orchestrator.createCalls(), 1);
        assertEq(orchestrator.lastBuilderTip(), 0);
        assertEq(orchestrator.lastValue(), 0);
        assertEq(orchestrator.lastMarketName(), "FAO site release #7");
        assertEq(
            orchestrator.lastDescription(),
            string.concat(
                "expected-current=",
                Strings.toHexString(uint256(currentDigest), 32),
                "; artifact=",
                Strings.toHexString(uint256(artifactDigest), 32),
                "; uri=",
                uri
            )
        );
    }

    function testStartEvaluationRejectsCallerChosenPayloadForActiveId() public {
        bytes memory committed = _payload(1, bytes32(0), keccak256("one"), "ipfs://one");
        bytes memory substituted = _payload(1, bytes32(0), keccak256("two"), "ipfs://two");
        uint256 proposalId = uint256(keccak256(committed));
        arbitration.setActive(proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOSiteEvaluationPipeline.PayloadHashMismatch.selector,
                proposalId,
                keccak256(substituted)
            )
        );
        pipeline.startEvaluation(proposalId, substituted);
    }

    function testStartEvaluationRejectsInvalidStaticReleaseFields() public {
        bytes memory payload = _payload(0, bytes32(0), keccak256("artifact"), "ipfs://artifact");
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);

        vm.expectRevert(FAOSiteEvaluationPipeline.InvalidReleasePayload.selector);
        pipeline.startEvaluation(proposalId, payload);
    }

    function testStartEvaluationCannotRunTwice() public {
        bytes memory payload = _payload(1, bytes32(0), keccak256("artifact"), "ipfs://artifact");
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);
        pipeline.startEvaluation(proposalId, payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOSiteEvaluationPipeline.EvaluationAlreadyStarted.selector, proposalId
            )
        );
        pipeline.startEvaluation(proposalId, payload);
    }

    function testResolveCallsResolverAndAcceptsYes() public {
        uint256 proposalId = _start();

        assertTrue(pipeline.resolve(proposalId));

        assertEq(resolver.resolveCalls(), 1);
        assertTrue(arbitration.resolved());
        assertTrue(arbitration.accepted());
    }

    function testResolveRejectsWhenNoWins() public {
        resolver.setDecision(1, 0, 1);
        uint256 proposalId = _start();

        assertFalse(pipeline.resolve(proposalId));

        assertTrue(arbitration.resolved());
        assertFalse(arbitration.accepted());
    }

    function testResolveRejectsInvalidPayout() public {
        resolver.setDecision(2, 1, 1);
        uint256 proposalId = _start();

        vm.expectRevert(
            abi.encodeWithSelector(FAOSiteEvaluationPipeline.InvalidPayout.selector, 1, 1, 2)
        );
        pipeline.resolve(proposalId);
    }

    function testWrongActiveProposalCannotStartOrResolve() public {
        bytes memory payload = _payload(1, bytes32(0), keccak256("artifact"), "ipfs://artifact");
        uint256 proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOSiteEvaluationPipeline.WrongProposalId.selector, proposalId + 1, proposalId
            )
        );
        pipeline.startEvaluation(proposalId, payload);
    }

    function testObserveFailureRejectsAndClearsRealArbitrationQueue() public {
        SiteEvaluationBondToken bondToken = new SiteEvaluationBondToken();
        FutarchyArbitration realArbitration =
            new FutarchyArbitration(IERC20(address(bondToken)), 10 ether, 1 hours);
        realArbitration.setProposalGateway(address(this));

        SiteEvaluationConditionalTokensMock realCtf = new SiteEvaluationConditionalTokensMock();
        SiteEvaluationProposalMock realProposal = new SiteEvaluationProposalMock(CONDITION_ID);
        FAOTwapResolver realResolver =
            new FAOTwapResolver(30 minutes, 15 minutes, IConditionalTokensLike(address(realCtf)));
        SiteEvaluationBrokenPool brokenYes =
            new SiteEvaluationBrokenPool(address(0xC01), address(0xC03));
        SiteEvaluationBrokenPool unusedNo =
            new SiteEvaluationBrokenPool(address(0xC02), address(0xC04));
        SiteEvaluationBindingOrchestratorMock realOrchestrator = new SiteEvaluationBindingOrchestratorMock(
            address(realResolver), address(realProposal), address(brokenYes), address(unusedNo)
        );
        realResolver.setOrchestrator(address(realOrchestrator));

        address expectedPipeline =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        realOrchestrator.setAdmin(expectedPipeline);
        FAOSiteEvaluationPipeline realPipeline = new FAOSiteEvaluationPipeline(
            address(realArbitration),
            address(realOrchestrator),
            address(realResolver),
            address(realCtf)
        );
        assertEq(address(realPipeline), expectedPipeline);
        realArbitration.setEvaluator(address(realPipeline));

        bytes memory payload =
            _payload(1, bytes32(0), keccak256("broken-market"), "ipfs://broken-market");
        uint256 proposalId = uint256(keccak256(payload));
        realArbitration.createProposalWithId(proposalId, 1 ether);

        address yesBidder = makeAddr("real-yes-bidder");
        address noBidder = makeAddr("real-no-bidder");
        bondToken.mint(yesBidder, 11 ether);
        bondToken.mint(noBidder, 1 ether);
        vm.startPrank(yesBidder);
        bondToken.approve(address(realArbitration), type(uint256).max);
        realArbitration.placeYesBond(proposalId, 1 ether);
        vm.stopPrank();
        vm.startPrank(noBidder);
        bondToken.approve(address(realArbitration), type(uint256).max);
        realArbitration.placeNoBond(proposalId);
        vm.stopPrank();
        vm.prank(yesBidder);
        realArbitration.placeYesBond(proposalId, 10 ether);

        realArbitration.startNextEvaluation();
        realPipeline.startEvaluation(proposalId, payload);
        vm.warp(block.timestamp + 30 minutes);

        assertFalse(realPipeline.resolve(proposalId));
        assertEq(realArbitration.activeEvaluationProposalId(), 0);
        assertTrue(realArbitration.isSettled(proposalId));
        assertFalse(realArbitration.isAccepted(proposalId));
    }

    function _start() internal returns (uint256 proposalId) {
        bytes memory payload = _payload(1, bytes32(0), keccak256("artifact"), "ipfs://artifact");
        proposalId = uint256(keccak256(payload));
        arbitration.setActive(proposalId);
        pipeline.startEvaluation(proposalId, payload);
    }

    function _payload(
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
}
