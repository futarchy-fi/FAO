// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IFutarchyOfficialProposalSource} from "flm/interfaces/IFutarchyOfficialProposalSource.sol";

import {
    FAOFlmProposalSourceRelay,
    IFAOFlmArbitrationView,
    IFAOFlmManagerView,
    IFAOFlmPipelineView
} from "../src/FAOFlmProposalSourceRelay.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";

contract RelayTokenMock {}

contract RelayArbitrationViewMock is IFAOFlmArbitrationView {
    uint256 public activeEvaluationProposalId;

    function setActive(uint256 proposalId) external {
        activeEvaluationProposalId = proposalId;
    }
}

contract RelayPipelineViewMock is IFAOFlmPipelineView {
    address public immutable arbitrationContract;
    mapping(uint256 => address) public futarchyProposalOf;

    constructor(address arbitration_) {
        arbitrationContract = arbitration_;
    }

    function setProposal(uint256 proposalId, address proposal) external {
        futarchyProposalOf[proposalId] = proposal;
    }
}

contract RelayUniV3FactoryMock {
    mapping(bytes32 => address) internal _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract RelayCtfViewMock {
    mapping(bytes32 => uint256) public payoutDenominator;

    function setPayoutDenominator(bytes32 conditionId, uint256 denominator) external {
        payoutDenominator[conditionId] = denominator;
    }
}

contract RelayProposalViewMock {
    address public immutable collateralToken1;
    address public immutable collateralToken2;
    bytes32 public immutable conditionId;
    address[4] internal _wrapped;

    constructor(
        address company,
        address currency,
        bytes32 conditionId_,
        address[4] memory wrapped
    ) {
        collateralToken1 = company;
        collateralToken2 = currency;
        conditionId = conditionId_;
        _wrapped = wrapped;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (_wrapped[index], "");
    }
}

contract RelayManagerViewMock is IFAOFlmManagerView {
    address public immutable COMPANY_TOKEN;
    address public immutable WRAPPED_NATIVE;
    address public immutable OFFICIAL_PROPOSER;
    address public immutable PROPOSAL_SOURCE;

    bool public inConditionalMode;
    uint256 public activeProposalId;
    address public activeProposal;
    address public activeYesCompanyToken;
    address public activeNoCompanyToken;
    address public activeYesCurrencyToken;
    address public activeNoCurrencyToken;

    constructor(address company, address currency, address relay) {
        COMPANY_TOKEN = company;
        WRAPPED_NATIVE = currency;
        OFFICIAL_PROPOSER = relay;
        PROPOSAL_SOURCE = relay;
    }

    function setConditional(
        bool enabled,
        uint256 proposalId,
        address proposal,
        address[4] memory wrapped
    ) external {
        inConditionalMode = enabled;
        activeProposalId = proposalId;
        activeProposal = proposal;
        activeYesCompanyToken = wrapped[0];
        activeNoCompanyToken = wrapped[1];
        activeYesCurrencyToken = wrapped[2];
        activeNoCurrencyToken = wrapped[3];
    }
}

contract FAOFlmProposalSourceRelayTest is Test {
    uint24 internal constant FEE = 500;
    bytes32 internal constant CONDITION_1 = keccak256("condition-1");
    bytes32 internal constant CONDITION_2 = keccak256("condition-2");

    RelayTokenMock internal company;
    RelayTokenMock internal currency;
    RelayArbitrationViewMock internal arbitration;
    RelayPipelineViewMock internal pipeline;
    RelayUniV3FactoryMock internal factory;
    RelayCtfViewMock internal ctf;
    RelayProposalViewMock internal proposal1;
    RelayProposalViewMock internal proposal2;
    RelayManagerViewMock internal manager;
    FAOFlmProposalSourceRelay internal relay;

    address[4] internal wrapped1;
    address[4] internal wrapped2;

    function setUp() public {
        company = new RelayTokenMock();
        currency = new RelayTokenMock();
        arbitration = new RelayArbitrationViewMock();
        pipeline = new RelayPipelineViewMock(address(arbitration));
        factory = new RelayUniV3FactoryMock();
        ctf = new RelayCtfViewMock();

        wrapped1 = [address(0x101), address(0x102), address(0x103), address(0x104)];
        wrapped2 = [address(0x201), address(0x202), address(0x203), address(0x204)];
        proposal1 =
            new RelayProposalViewMock(address(company), address(currency), CONDITION_1, wrapped1);
        proposal2 =
            new RelayProposalViewMock(address(company), address(currency), CONDITION_2, wrapped2);
        _setPools(wrapped1, address(0xA1), address(0xB1));
        _setPools(wrapped2, address(0xA2), address(0xB2));

        relay = new FAOFlmProposalSourceRelay(
            arbitration,
            pipeline,
            IUniswapV3FactoryLike(address(factory)),
            IConditionalTokensLike(address(ctf)),
            FEE,
            address(company),
            address(currency)
        );
        manager = new RelayManagerViewMock(address(company), address(currency), address(relay));
        relay.bindManager(manager);
    }

    function test_reportsTheActiveStartedEvaluationInSpotMode() public {
        arbitration.setActive(11);
        pipeline.setProposal(11, address(proposal1));

        IFutarchyOfficialProposalSource.OfficialProposalData memory p =
            relay.officialProposalExtended();

        assertEq(p.proposalId, 11);
        assertEq(p.proposal, address(proposal1));
        assertEq(p.creator, address(relay));
        assertTrue(p.exists);
        assertFalse(p.settled);
        assertEq(p.proposalToken, address(company));
        assertEq(p.collateralToken, address(currency));
        assertEq(p.yesCompanyToken, wrapped1[0]);
        assertEq(p.noCompanyToken, wrapped1[1]);
        assertEq(p.yesCurrencyToken, wrapped1[2]);
        assertEq(p.noCurrencyToken, wrapped1[3]);
        assertEq(p.yesPool, address(0xA1));
        assertEq(p.noPool, address(0xB1));
    }

    function test_settlementComesOnlyFromCtfPayouts() public {
        arbitration.setActive(11);
        pipeline.setProposal(11, address(proposal1));
        assertFalse(relay.officialProposalExtended().settled);

        ctf.setPayoutDenominator(CONDITION_1, 1);
        assertTrue(relay.officialProposalExtended().settled);
    }

    function test_identityStaysOnManagerProposalDuringEarlyNextEvaluation() public {
        arbitration.setActive(11);
        pipeline.setProposal(11, address(proposal1));
        manager.setConditional(true, 11, address(proposal1), wrapped1);

        arbitration.setActive(22);
        pipeline.setProposal(22, address(proposal2));
        ctf.setPayoutDenominator(CONDITION_1, 1);

        IFutarchyOfficialProposalSource.OfficialProposalData memory p =
            relay.officialProposalExtended();
        assertEq(p.proposalId, 11);
        assertEq(p.proposal, address(proposal1));
        assertTrue(p.settled);

        manager.setConditional(false, 0, address(0), wrapped1);
        p = relay.officialProposalExtended();
        assertEq(p.proposalId, 22);
        assertEq(p.proposal, address(proposal2));
        assertFalse(p.settled);
    }

    function test_noActiveOrNotStartedEvaluationReturnsNoProposal() public {
        IFutarchyOfficialProposalSource.OfficialProposalData memory p =
            relay.officialProposalExtended();
        assertFalse(p.exists);

        arbitration.setActive(11);
        p = relay.officialProposalExtended();
        assertFalse(p.exists);
    }

    function test_compactViewMatchesExtendedView() public {
        arbitration.setActive(11);
        pipeline.setProposal(11, address(proposal1));

        (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPool,
            address noPool
        ) = relay.officialProposal();
        assertEq(proposalId, 11);
        assertEq(creator, address(relay));
        assertTrue(exists);
        assertFalse(settled);
        assertEq(proposalToken, address(company));
        assertEq(collateralToken, address(currency));
        assertEq(yesPool, address(0xA1));
        assertEq(noPool, address(0xB1));
    }

    function test_bindingIsOneShotAndChecksManagerWiring() public {
        vm.expectRevert(FAOFlmProposalSourceRelay.ManagerAlreadyBound.selector);
        relay.bindManager(manager);

        FAOFlmProposalSourceRelay unbound = new FAOFlmProposalSourceRelay(
            arbitration,
            pipeline,
            IUniswapV3FactoryLike(address(factory)),
            IConditionalTokensLike(address(ctf)),
            FEE,
            address(company),
            address(currency)
        );
        RelayManagerViewMock wrong =
            new RelayManagerViewMock(address(company), address(currency), address(0xBAD));
        vm.expectRevert(FAOFlmProposalSourceRelay.InvalidConfig.selector);
        unbound.bindManager(wrong);
    }

    function test_wrongProposalCollateralFailsClosed() public {
        RelayTokenMock wrongCurrency = new RelayTokenMock();
        RelayProposalViewMock wrong = new RelayProposalViewMock(
            address(company), address(wrongCurrency), CONDITION_1, wrapped1
        );
        arbitration.setActive(11);
        pipeline.setProposal(11, address(wrong));

        vm.expectRevert(FAOFlmProposalSourceRelay.InvalidProposal.selector);
        relay.officialProposalExtended();
    }

    function _setPools(address[4] memory wrapped, address yesPool, address noPool) internal {
        factory.setPool(wrapped[0], wrapped[2], FEE, yesPool);
        factory.setPool(wrapped[1], wrapped[3], FEE, noPool);
    }
}
