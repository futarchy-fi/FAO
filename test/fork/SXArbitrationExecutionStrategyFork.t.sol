// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Space} from "sx-evm/src/Space.sol";
import {VanillaAuthenticator} from "sx-evm/src/authenticators/VanillaAuthenticator.sol";
import {VanillaVotingStrategy} from "sx-evm/src/voting-strategies/VanillaVotingStrategy.sol";
import {
    VanillaExecutionStrategy
} from "sx-evm/src/execution-strategies/VanillaExecutionStrategy.sol";
import {
    VanillaProposalValidationStrategy
} from "sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {Choice, Strategy, IndexedStrategy, InitializeCalldata, ProposalStatus} from "sx/types.sol";

import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";

contract MockArbitration {
    mapping(uint256 => bool) public accepted;

    function setAccepted(uint256 arbId, bool ok) external {
        accepted[arbId] = ok;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }
}

contract SXArbitrationExecutionStrategyForkTest is Test {
    // Selectors copied from sx-evm test utils
    bytes4 internal constant PROPOSE_SELECTOR =
        bytes4(keccak256("propose(address,string,(address,bytes),bytes)"));
    bytes4 internal constant VOTE_SELECTOR =
        bytes4(keccak256("vote(address,uint256,uint8,(uint8,bytes)[],string)"));

    Space internal masterSpace;
    Space internal space;

    VanillaVotingStrategy internal vanillaVotingStrategy;
    VanillaAuthenticator internal vanillaAuthenticator;
    VanillaExecutionStrategy internal vanillaExecutionStrategy;
    VanillaProposalValidationStrategy internal vanillaProposalValidationStrategy;

    MockArbitration internal arb;
    SXArbitrationExecutionStrategy internal gated;

    address internal owner;
    address internal author;
    address internal voter;

    IndexedStrategy[] internal userVotingStrategies;

    function setUp() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        owner = address(this);
        author = vm.addr(1234);
        voter = vm.addr(5678);

        masterSpace = new Space();

        vanillaVotingStrategy = new VanillaVotingStrategy();
        vanillaAuthenticator = new VanillaAuthenticator();
        vanillaExecutionStrategy = new VanillaExecutionStrategy(owner, 1);
        vanillaProposalValidationStrategy = new VanillaProposalValidationStrategy();

        Strategy[] memory votingStrategies = new Strategy[](1);
        votingStrategies[0] = Strategy(address(vanillaVotingStrategy), new bytes(0));

        string[] memory votingStrategyMetadataURIs = new string[](1);
        votingStrategyMetadataURIs[0] = "VanillaVotingStrategy";

        address[] memory authenticators = new address[](1);
        authenticators[0] = address(vanillaAuthenticator);

        InitializeCalldata memory init = InitializeCalldata({
            owner: owner,
            votingDelay: 0,
            minVotingDuration: 0,
            maxVotingDuration: 1000,
            proposalValidationStrategy: Strategy(
                address(vanillaProposalValidationStrategy), new bytes(0)
            ),
            proposalValidationStrategyMetadataURI: "",
            daoURI: "dao",
            metadataURI: "space",
            votingStrategies: votingStrategies,
            votingStrategyMetadataURIs: votingStrategyMetadataURIs,
            authenticators: authenticators
        });

        space = Space(
            address(
                new ERC1967Proxy(
                    address(masterSpace), abi.encodeWithSelector(Space.initialize.selector, init)
                )
            )
        );

        userVotingStrategies.push(IndexedStrategy(0, new bytes(0)));

        arb = new MockArbitration();
        gated = new SXArbitrationExecutionStrategy(address(arb), address(vanillaExecutionStrategy));
    }

    function testFork_blocksExecuteUntilArbitrationAccepted_andStatusShowsVotingPeriodAccepted()
        public
    {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;

        bytes memory payload = abi.encodePacked("hello");
        Strategy memory execStrat = Strategy(address(gated), payload);

        uint256 proposalId = _createProposal(author, "p", execStrat);
        _vote(voter, proposalId, Choice.For);

        // Voting accepted, but arbitration not accepted: wrapper should expose
        // VotingPeriodAccepted.
        assertEq(
            uint256(space.getProposalStatus(proposalId)),
            uint256(ProposalStatus.VotingPeriodAccepted)
        );

        uint256 arbId = uint256(keccak256(payload));

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId
            )
        );
        space.execute(proposalId, payload);

        arb.setAccepted(arbId, true);

        space.execute(proposalId, payload);

        // Proposal already executed; a second execute should revert.
        vm.expectRevert();
        space.execute(proposalId, payload);
    }

    function _createProposal(
        address _author,
        string memory _metadataURI,
        Strategy memory _executionStrategy
    ) internal returns (uint256) {
        vanillaAuthenticator.authenticate(
            address(space),
            PROPOSE_SELECTOR,
            abi.encode(_author, _metadataURI, _executionStrategy, new bytes(0))
        );
        return space.nextProposalId() - 1;
    }

    function _vote(address _voter, uint256 _proposalId, Choice _choice) internal {
        vanillaAuthenticator.authenticate(
            address(space),
            VOTE_SELECTOR,
            abi.encode(_voter, _proposalId, _choice, userVotingStrategies, "vote")
        );
    }
}
