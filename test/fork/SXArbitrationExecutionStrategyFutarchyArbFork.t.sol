// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {ManualEvaluator} from "../../src/ManualEvaluator.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {IExecutionStrategy} from "../../src/interfaces/IExecutionStrategy.sol";
import {Proposal, ProposalStatus, FinalizationStatus} from "../../src/types.sol";

contract ForkInnerMockArb is IExecutionStrategy {
    bool public executed;

    function execute(uint256, Proposal memory, uint256, uint256, uint256, bytes memory)
        external
        override
    {
        executed = true;
    }

    function getProposalStatus(Proposal memory, uint256, uint256, uint256)
        external
        pure
        override
        returns (ProposalStatus)
    {
        return ProposalStatus.Accepted;
    }

    function getStrategyType() external pure override returns (string memory) {
        return "ForkInnerMockArb";
    }
}

contract SXArbitrationExecutionStrategyFutarchyArbForkTest is Test {
    function testFork_endToEnd_executeOnlyAfterFutarchyArbitrationAccepted() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        FutarchyArbitration arbitration = new FutarchyArbitration();
        ManualEvaluator evaluator = new ManualEvaluator(address(arbitration), address(this));
        arbitration.setEvaluator(address(evaluator));

        ForkInnerMockArb inner = new ForkInnerMockArb();
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arbitration), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("hello");
        uint256 arbId = uint256(keccak256(payload));

        Proposal memory p = Proposal({
            author: address(this),
            startBlockNumber: uint32(block.number),
            executionStrategy: IExecutionStrategy(address(inner)),
            minEndBlockNumber: uint32(block.number),
            maxEndBlockNumber: uint32(block.number + 1),
            finalizationStatus: FinalizationStatus.Pending,
            executionPayloadHash: keccak256(payload),
            activeVotingStrategies: 0
        });

        arbitration.createProposalWithId(arbId, 1e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId
            )
        );
        wrapper.execute(1, p, 1, 0, 0, payload);

        uint256 yesActivation = 1e18;
        uint256 noBond = yesActivation;
        uint256 yesBond = arbitration.baseX();

        address bidder = makeAddr("bidder");
        deal(address(arbitration.WXDAI()), bidder, yesActivation + noBond + yesBond);

        vm.startPrank(bidder);
        arbitration.WXDAI().approve(address(arbitration), type(uint256).max);
        arbitration.placeYesBond(arbId, yesActivation);
        arbitration.placeNoBond(arbId);
        arbitration.placeYesBond(arbId, yesBond);
        vm.stopPrank();

        arbitration.startNextEvaluation();
        evaluator.setDecision(arbId, true);
        evaluator.resolve(arbId);

        wrapper.execute(1, p, 1, 0, 0, payload);
        assertTrue(inner.executed());
    }
}
