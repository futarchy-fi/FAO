// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ArbitrationFutarchyFactory} from "../src/ArbitrationFutarchyFactory.sol";
import {ArbitrationFutarchyProposal} from "../src/ArbitrationFutarchyProposal.sol";

import {MockConditionalTokensFull} from "./mocks/MockConditionalTokensFull.sol";
import {MockWrapped1155Factory} from "./mocks/MockWrapped1155Factory.sol";
import {MockERC20Symbol} from "./mocks/MockERC20Symbol.sol";

contract ArbitrationFutarchyFactoryTest is Test {
    MockConditionalTokensFull ctf;
    MockWrapped1155Factory w1155;
    MockERC20Symbol faoToken;
    MockERC20Symbol wxdaiToken;

    ArbitrationFutarchyProposal template;
    ArbitrationFutarchyFactory factory;
    address oracle;

    function setUp() public {
        ctf = new MockConditionalTokensFull();
        w1155 = new MockWrapped1155Factory();
        faoToken = new MockERC20Symbol("FAO");
        wxdaiToken = new MockERC20Symbol("WXDAI");
        oracle = address(0xCAFE);

        template = new ArbitrationFutarchyProposal();
        factory =
            new ArbitrationFutarchyFactory(address(template), oracle, address(w1155), address(ctf));
    }

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    function testConstructorSetsImmutables() public view {
        assertEq(factory.proposalTemplate(), address(template));
        assertEq(factory.oracle(), oracle);
        assertEq(address(factory.wrapped1155Factory()), address(w1155));
        assertEq(address(factory.conditionalTokens()), address(ctf));
    }

    function testInitialMarketsCountIsZero() public view {
        assertEq(factory.marketsCount(), 0);
    }

    // ═══════════════════════════════════════════════════════
    //  createProposal
    // ═══════════════════════════════════════════════════════

    function testCreateProposalReturnsAddress() public {
        address proposal = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test Market",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertTrue(proposal != address(0));
    }

    function testCreateProposalIncrementsCount() public {
        factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Market 1",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertEq(factory.marketsCount(), 1);

        factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Market 2",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertEq(factory.marketsCount(), 2);
    }

    function testCreateProposalStoresInArray() public {
        address p1 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Market 1",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertEq(factory.proposals(0), p1);
    }

    function testAllMarketsReturnsAll() public {
        address p1 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M1",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );
        address p2 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M2",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        address[] memory all = factory.allMarkets();
        assertEq(all.length, 2);
        assertEq(all[0], p1);
        assertEq(all[1], p2);
    }

    function testCreateProposalEmitsEvent() public {
        // Pre-compute expected questionId and conditionId.
        bytes32 expectedQuestionId = keccak256(abi.encodePacked(address(factory), uint256(0)));
        bytes32 expectedConditionId =
            keccak256(abi.encodePacked(oracle, expectedQuestionId, uint256(2)));

        vm.expectEmit(false, false, false, true);
        emit ArbitrationFutarchyFactory.NewProposal(
            address(0), // we don't know the clone address yet
            "Test Market",
            expectedConditionId,
            expectedQuestionId
        );

        factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test Market",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );
    }

    // ═══════════════════════════════════════════════════════
    //  Proposal initialization
    // ═══════════════════════════════════════════════════════

    function testProposalIsInitialized() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test Market",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        ArbitrationFutarchyProposal proposal = ArbitrationFutarchyProposal(proposalAddr);

        assertTrue(proposal.initialized());
        assertEq(proposal.marketName(), "Test Market");
        assertEq(proposal.collateralToken1(), address(faoToken));
        assertEq(proposal.collateralToken2(), address(wxdaiToken));
        assertEq(proposal.numOutcomes(), 4);
    }

    function testProposalConditionIdMatchesExpected() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        bytes32 expectedQuestionId = keccak256(abi.encodePacked(address(factory), uint256(0)));
        bytes32 expectedConditionId =
            keccak256(abi.encodePacked(oracle, expectedQuestionId, uint256(2)));

        ArbitrationFutarchyProposal proposal = ArbitrationFutarchyProposal(proposalAddr);

        assertEq(proposal.conditionId(), expectedConditionId);
        assertEq(proposal.questionId(), expectedQuestionId);
    }

    function testProposalHasUniqueQuestionIds() public {
        address p1 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M1",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );
        address p2 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M2",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        bytes32 qId1 = ArbitrationFutarchyProposal(p1).questionId();
        bytes32 qId2 = ArbitrationFutarchyProposal(p2).questionId();

        assertTrue(qId1 != qId2);
    }

    function testProposalHas4WrappedOutcomes() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        ArbitrationFutarchyProposal proposal = ArbitrationFutarchyProposal(proposalAddr);

        // All 4 wrapped outcome tokens should be non-zero.
        for (uint256 i = 0; i < 4; i++) {
            (address wrapped, bytes memory data) = proposal.wrappedOutcome(i);
            assertTrue(wrapped != address(0), "Wrapped outcome is zero");
            assertTrue(data.length > 0, "Token data is empty");
        }
    }

    function testProposalOutcomeNames() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        ArbitrationFutarchyProposal proposal = ArbitrationFutarchyProposal(proposalAddr);

        assertEq(proposal.outcomes(0), "Yes-FAO");
        assertEq(proposal.outcomes(1), "No-FAO");
        assertEq(proposal.outcomes(2), "Yes-WXDAI");
        assertEq(proposal.outcomes(3), "No-WXDAI");
    }

    // ═══════════════════════════════════════════════════════
    //  CTF condition preparation
    // ═══════════════════════════════════════════════════════

    function testCtfConditionIsPrepared() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        bytes32 conditionId = ArbitrationFutarchyProposal(proposalAddr).conditionId();

        // The condition should have 2 outcome slots.
        assertEq(ctf.outcomeSlotCounts(conditionId), 2);
    }

    function testCtfConditionUsesConfiguredOracle() public {
        bytes32 expectedQuestionId = keccak256(abi.encodePacked(address(factory), uint256(0)));
        bytes32 expectedConditionId =
            keccak256(abi.encodePacked(oracle, expectedQuestionId, uint256(2)));

        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertEq(ArbitrationFutarchyProposal(proposalAddr).conditionId(), expectedConditionId);
    }

    // ═══════════════════════════════════════════════════════
    //  Clone uniqueness
    // ═══════════════════════════════════════════════════════

    function testEachProposalIsAUniqueClone() public {
        address p1 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M1",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );
        address p2 = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "M2",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        assertTrue(p1 != p2);
        assertTrue(p1 != address(template));
        assertTrue(p2 != address(template));
    }

    function testCloneCannotBeReinitialized() public {
        address proposalAddr = factory.createProposal(
            ArbitrationFutarchyFactory.CreateProposalParams({
                marketName: "Test",
                collateralToken1: address(faoToken),
                collateralToken2: address(wxdaiToken)
            })
        );

        ArbitrationFutarchyProposal proposal = ArbitrationFutarchyProposal(proposalAddr);

        string[] memory outcomes = new string[](0);
        ArbitrationFutarchyProposal.ProposalParams memory params;

        vm.expectRevert("Already initialized.");
        proposal.initialize("Evil", outcomes, params);
    }
}
