// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Space } from "sx/Space.sol";
import { VanillaAuthenticator } from "sx/authenticators/VanillaAuthenticator.sol";
import { VanillaVotingStrategy } from "sx/voting-strategies/VanillaVotingStrategy.sol";
import { VanillaExecutionStrategy } from "sx/execution-strategies/VanillaExecutionStrategy.sol";
import {
    VanillaProposalValidationStrategy
} from "sx/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import { Choice, Proposal, ProposalStatus, Strategy, IndexedStrategy, InitializeCalldata } from "sx/types.sol";

import { SXArbitrationExecutionStrategy } from "../src/SXArbitrationExecutionStrategy.sol";

contract ArbitrationMock {
    mapping(uint256 => bool) public accepted;

    function setAccepted(uint256 arbId, bool ok) external {
        accepted[arbId] = ok;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }
}

contract SXArbitrationExecutionStrategyTest is Test {
    bytes4 internal constant PROPOSE_SELECTOR = bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR = bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));

    Space internal masterSpace;
    Space internal space;

    VanillaVotingStrategy internal voting;
    VanillaAuthenticator internal auth;
    VanillaExecutionStrategy internal inner;
    VanillaProposalValidationStrategy internal pvs;

    ArbitrationMock internal arb;
    SXArbitrationExecutionStrategy internal wrapper;

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
        wrapper = new SXArbitrationExecutionStrategy(address(arb), address(inner));

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy(address(voting), new bytes(0));
        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "VanillaVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(auth);

        Strategy memory proposalValidationStrategy = Strategy(address(pvs), new bytes(0));

        space = Space(
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
                            "", // proposalValidationStrategyMetadataURI
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

        userVotingStrategies.push(IndexedStrategy(0, new bytes(0)));
    }

    function _createProposal(Strategy memory executionStrategy, bytes memory userProposalValidationParams)
        internal
        returns (uint256)
    {
        auth.authenticate(
            address(space),
            PROPOSE_SELECTOR,
            abi.encode(author, "proposalURI", executionStrategy, userProposalValidationParams)
        );
        return space.nextProposalId() - 1;
    }

    function _voteFor(uint256 proposalId) internal {
        auth.authenticate(
            address(space),
            VOTE_SELECTOR,
            abi.encode(voter, proposalId, Choice.For, userVotingStrategies, "")
        );
    }

    function testSpaceExecuteRevertsUnlessArbitrationAccepted() public {
        bytes memory executionPayload = abi.encodePacked("hello");
        uint256 proposalId = _createProposal(Strategy(address(wrapper), executionPayload), new bytes(0));
        _voteFor(proposalId);

        uint256 arbId = uint256(keccak256(executionPayload));

        vm.expectRevert(abi.encodeWithSelector(SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId));
        space.execute(proposalId, executionPayload);

        arb.setAccepted(arbId, true);
        space.execute(proposalId, executionPayload);
    }

    function testGetProposalStatusShowsVotingPeriodAcceptedWhenVoteAcceptedButArbNotAccepted() public {
        bytes memory executionPayload = abi.encodePacked("hello");
        uint256 proposalId = _createProposal(Strategy(address(wrapper), executionPayload), new bytes(0));
        _voteFor(proposalId);

        // During the voting period, VanillaExecutionStrategy returns VotingPeriodAccepted once quorum is reached.
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.VotingPeriodAccepted));

        // After voting ends, VanillaExecutionStrategy would return Accepted, but our wrapper should gate it behind
        // arbitration acceptance.
        (
            ,
            ,
            ,
            ,
            uint32 maxEndBlockNumber,
            ,
            ,
        ) = space.proposals(proposalId);
        vm.roll(maxEndBlockNumber);

        // Arbitration NOT accepted yet => wrapper must not surface Accepted.
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.VotingPeriodAccepted));

        uint256 arbId = uint256(keccak256(executionPayload));
        arb.setAccepted(arbId, true);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Accepted));
    }
}
