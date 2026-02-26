// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {FutarchyEvaluator} from "../../src/FutarchyEvaluator.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {IExecutionStrategy} from "../../src/interfaces/IExecutionStrategy.sol";
import {Proposal, ProposalStatus, FinalizationStatus} from "../../src/types.sol";

interface IConditionalTokensLikeE2E {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
}

interface IFutarchyProposalWithConditionLikeE2E {
    function conditionId() external view returns (bytes32);
}

contract ForkInnerMockEval is IExecutionStrategy {
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
        return "ForkInnerMockEval";
    }
}

contract SXArbitrationExecutionStrategyFutarchyEvaluatorE2EForkTest is Test {
    address internal constant DEFAULT_TEST_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;
    address internal constant GNOSIS_CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;

    function testFork_endToEnd_executeAfterFutarchyEvaluatorResolutionWhenCTFResolved() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        FutarchyArbitration arbitration = new FutarchyArbitration();
        FutarchyEvaluator evaluator =
            new FutarchyEvaluator(address(arbitration), GNOSIS_CTF, address(this));
        arbitration.setEvaluator(address(evaluator));

        ForkInnerMockEval inner = new ForkInnerMockEval();
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arbitration), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("hello");
        uint256 arbId = uint256(keccak256(payload));
        arbitration.createProposalWithId(arbId, arbitration.baseX());

        address proposalAddress = vm.envOr("TEST_FAO_PROPOSAL", DEFAULT_TEST_PROPOSAL);
        bytes32 conditionId = IFutarchyProposalWithConditionLikeE2E(proposalAddress).conditionId();
        evaluator.setFutarchyProposal(arbId, proposalAddress);

        _driveToEvaluation(arbitration, arbId);

        if (IConditionalTokensLikeE2E(GNOSIS_CTF).payoutDenominator(conditionId) == 0) {
            vm.expectRevert();
            evaluator.resolve(arbId);
            return;
        }

        bool accepted = evaluator.resolve(arbId);
        Proposal memory p = _proposal(payload, inner);

        if (!accepted) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId
                )
            );
            wrapper.execute(1, p, 1, 0, 0, payload);
            return;
        }

        wrapper.execute(1, p, 1, 0, 0, payload);
        assertTrue(inner.executed());
    }

    function _driveToEvaluation(FutarchyArbitration arbitration, uint256 arbId) internal {
        uint256 yesActivation = 25e18;
        uint256 noBond = yesActivation;
        uint256 yesFlipBond = arbitration.baseX();

        address bidder = makeAddr("bidder");
        deal(address(arbitration.WXDAI()), bidder, yesActivation + noBond + yesFlipBond);

        vm.startPrank(bidder);
        arbitration.WXDAI().approve(address(arbitration), type(uint256).max);
        arbitration.placeYesBond(arbId, yesActivation);
        arbitration.placeNoBond(arbId);
        arbitration.placeYesBond(arbId, yesFlipBond);
        vm.stopPrank();

        arbitration.startNextEvaluation();
    }

    function _proposal(bytes memory payload, ForkInnerMockEval inner)
        internal
        view
        returns (Proposal memory p)
    {
        p.author = address(this);
        p.startBlockNumber = uint32(block.number);
        p.executionStrategy = IExecutionStrategy(address(inner));
        p.minEndBlockNumber = uint32(block.number);
        p.maxEndBlockNumber = uint32(block.number + 1);
        p.finalizationStatus = FinalizationStatus.Pending;
        p.executionPayloadHash = keccak256(payload);
        p.activeVotingStrategies = 0;
    }
}
