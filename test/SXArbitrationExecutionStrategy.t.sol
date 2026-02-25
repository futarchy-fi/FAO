// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Space} from "sx/Space.sol";
import {VanillaAuthenticator} from "sx/authenticators/VanillaAuthenticator.sol";
import {VanillaVotingStrategy} from "sx/voting-strategies/VanillaVotingStrategy.sol";
import {VanillaExecutionStrategy} from "sx/execution-strategies/VanillaExecutionStrategy.sol";
import {
    VanillaProposalValidationStrategy
} from "sx/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {
    Choice,
    Proposal,
    ProposalStatus,
    Strategy,
    IndexedStrategy,
    InitializeCalldata
} from "sx/types.sol";

import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";

contract ArbitrationMock {
    mapping(uint256 => bool) public accepted;
    mapping(uint256 => bool) public settled;

    function setAccepted(uint256 arbId, bool ok) external {
        accepted[arbId] = ok;
    }

    function setSettled(uint256 arbId, bool ok) external {
        settled[arbId] = ok;
    }

    /// @dev Convenience: settle with a result in one call.
    function settle(uint256 arbId, bool _accepted) external {
        settled[arbId] = true;
        accepted[arbId] = _accepted;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }

    function isSettled(uint256 arbId) external view returns (bool) {
        return settled[arbId];
    }
}

contract SXArbitrationExecutionStrategyTest is Test {
    bytes4 internal constant PROPOSE_SELECTOR =
        bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR =
        bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));

    Space internal masterSpace;

    VanillaVotingStrategy internal voting;
    VanillaAuthenticator internal auth;
    VanillaExecutionStrategy internal inner;
    VanillaProposalValidationStrategy internal pvs;

    ArbitrationMock internal arb;

    IndexedStrategy[] internal userVotingStrategies;

    address internal owner = address(this);
    address internal author;
    address internal voter;

    function setUp() public {
        author = makeAddr("author");
        voter = makeAddr("voter");

        masterSpace = new Space();

        voting = new VanillaVotingStrategy();
        auth = new VanillaAuthenticator();
        inner = new VanillaExecutionStrategy(owner, 1); // quorum=1
        pvs = new VanillaProposalValidationStrategy();

        arb = new ArbitrationMock();

        userVotingStrategies.push(IndexedStrategy(0, new bytes(0)));
    }

    // ─── Helpers ───

    function _deploySpace(address executionStrategy) internal returns (Space) {
        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy(address(voting), new bytes(0));
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "VanillaVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(auth);

        Strategy memory proposalValidationStrategy = Strategy(address(pvs), new bytes(0));

        return Space(
            address(
                new ERC1967Proxy(
                    address(masterSpace),
                    abi.encodeWithSelector(
                        Space.initialize.selector,
                        InitializeCalldata(
                            owner,
                            0, // votingDelay
                            0, // minVotingDuration
                            1000, // maxVotingDuration
                            proposalValidationStrategy,
                            "",
                            "daoURI",
                            "spaceURI",
                            votingStrategies,
                            votingStrategyMetadataURIs,
                            authenticators
                        )
                    )
                )
            )
        );
    }

    function _createProposal(Space space, Strategy memory executionStrategy)
        internal
        returns (uint256)
    {
        auth.authenticate(
            address(space),
            PROPOSE_SELECTOR,
            abi.encode(author, "proposalURI", executionStrategy, new bytes(0))
        );
        return space.nextProposalId() - 1;
    }

    function _voteFor(Space space, uint256 proposalId) internal {
        auth.authenticate(
            address(space),
            VOTE_SELECTOR,
            abi.encode(voter, proposalId, Choice.For, userVotingStrategies, "")
        );
    }

    function _arbId(bytes memory payload) internal pure returns (uint256) {
        return uint256(keccak256(payload));
    }

    // ═══════════════════════════════════════════════════════
    //  BINDING MODE — arbitration result is the decision
    // ═══════════════════════════════════════════════════════

    function testBinding_StatusVotingPeriodWhileUnsettled() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-test");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        // No vote needed in binding mode, but status should be VotingPeriod while unsettled
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.VotingPeriod)
        );
    }

    function testBinding_AcceptedOnceArbitrationAccepts() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-accept");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        // Arbitration accepts — status should be Accepted regardless of votes
        arb.settle(_arbId(payload), true);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Accepted)
        );
    }

    function testBinding_RejectedOnceArbitrationRejects() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-reject");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        // Arbitration rejects
        arb.settle(_arbId(payload), false);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected)
        );
    }

    function testBinding_ExecuteSucceedsWhenAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-exec");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));
        _voteFor(space, proposalId); // inner (VanillaExecutionStrategy) needs quorum for execute()

        arb.settle(_arbId(payload), true);
        space.execute(proposalId, payload);
    }

    function testBinding_ExecuteRevertsWhenNotAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-noexec");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));
        _voteFor(space, proposalId);

        uint256 id = _arbId(payload);
        vm.expectRevert(
            abi.encodeWithSelector(SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, id)
        );
        space.execute(proposalId, payload);
    }

    function testBinding_AcceptedWithoutAnyVotes() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("binding-novote");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        // No votes cast at all — binding mode doesn't care
        arb.settle(_arbId(payload), true);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Accepted)
        );
    }

    // ═══════════════════════════════════════════════════════
    //  VETO MODE — arbitration pre-filters, votes have veto
    // ═══════════════════════════════════════════════════════

    function testVeto_VotingPeriodWhileUnsettled() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("veto-test");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.VotingPeriod)
        );
    }

    function testVeto_RejectedWhenBondsReject() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("veto-reject");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));
        _voteFor(space, proposalId); // vote passes, but bonds reject

        arb.settle(_arbId(payload), false);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected)
        );
    }

    function testVeto_DefersToInnerWhenBondsAccept() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("veto-defer");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));

        // Bonds accept, but no vote yet — inner returns VotingPeriod
        arb.settle(_arbId(payload), true);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.VotingPeriod)
        );

        // Vote passes — inner returns VotingPeriodAccepted (during voting window)
        _voteFor(space, proposalId);
        assertEq(
            uint8(space.getProposalStatus(proposalId)),
            uint8(ProposalStatus.VotingPeriodAccepted)
        );

        // After voting period ends — inner returns Accepted
        (,,,, uint32 maxEndBlockNumber,,,) = space.proposals(proposalId);
        vm.roll(maxEndBlockNumber);
        assertEq(
            uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Accepted)
        );
    }

    function testVeto_ExecuteRequiresBothBondsAndVotes() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("veto-exec");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));
        _voteFor(space, proposalId);

        // Bonds accept + vote passed → can execute
        arb.settle(_arbId(payload), true);
        space.execute(proposalId, payload);
    }

    function testVeto_ExecuteRevertsIfBondsNotAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );
        Space space = _deploySpace(address(wrapper));

        bytes memory payload = abi.encodePacked("veto-noexec");
        uint256 proposalId = _createProposal(space, Strategy(address(wrapper), payload));
        _voteFor(space, proposalId);

        uint256 id = _arbId(payload);
        vm.expectRevert(
            abi.encodeWithSelector(SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, id)
        );
        space.execute(proposalId, payload);
    }
}
