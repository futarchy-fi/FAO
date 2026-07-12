// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {IFutarchyArbitrationEvaluator} from "../../src/IFutarchyArbitrationEvaluator.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {IExecutionStrategy} from "../../src/interfaces/IExecutionStrategy.sol";
import {Proposal, FinalizationStatus} from "../../src/types.sol";

contract ForkEvaluator is IFutarchyArbitrationEvaluator {
    address public immutable arbitration;
    bool public decision;

    constructor(address arbitration_) {
        arbitration = arbitration_;
    }

    function setDecision(uint256, bool accepted) external {
        decision = accepted;
    }

    function resolve(uint256) external returns (bool accepted) {
        accepted = decision;
        FutarchyArbitration(arbitration).resolveActiveEvaluation(accepted);
    }
}

contract SXArbitrationExecutionStrategyFutarchyArbForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

    function testFork_endToEnd_executeOnlyAfterFutarchyArbitrationAccepted() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        FutarchyArbitration arbitration =
            new FutarchyArbitration(IERC20(GNOSIS_WXDAI), 100e18, 72 hours);
        arbitration.setProposalGateway(address(this));
        ForkEvaluator evaluator = new ForkEvaluator(address(arbitration));
        arbitration.setEvaluator(address(evaluator));

        SXArbitrationExecutionStrategy wrapper =
            new SXArbitrationExecutionStrategy(address(this), address(arbitration));

        bytes32 digest = keccak256("evaluated-fork-release");
        bytes memory payload = abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: 1,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: digest,
                artifactURI: "ipfs://evaluated-fork-release"
            })
        );
        uint256 arbId = uint256(keccak256(payload));

        Proposal memory p = Proposal({
            author: address(this),
            startBlockNumber: uint32(block.number),
            executionStrategy: IExecutionStrategy(address(wrapper)),
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
        deal(address(arbitration.bondToken()), bidder, yesActivation + noBond + yesBond);

        vm.startPrank(bidder);
        arbitration.bondToken().approve(address(arbitration), type(uint256).max);
        arbitration.placeYesBond(arbId, yesActivation);
        arbitration.placeNoBond(arbId);
        arbitration.placeYesBond(arbId, yesBond);
        vm.stopPrank();

        arbitration.startNextEvaluation();
        evaluator.setDecision(arbId, true);
        evaluator.resolve(arbId);

        wrapper.execute(1, p, 1, 0, 0, payload);
        assertEq(wrapper.releaseDigest(), digest);
    }
}
