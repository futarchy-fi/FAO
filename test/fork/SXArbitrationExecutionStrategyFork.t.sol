// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {IExecutionStrategy} from "../../src/interfaces/IExecutionStrategy.sol";
import {Proposal, FinalizationStatus} from "../../src/types.sol";

contract ForkArbMock {
    mapping(uint256 => bool) public accepted;
    mapping(uint256 => bool) public settled;

    function settle(uint256 arbId, bool ok) external {
        settled[arbId] = true;
        accepted[arbId] = ok;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }

    function isSettled(uint256 arbId) external view returns (bool) {
        return settled[arbId];
    }
}

contract SXArbitrationExecutionStrategyForkTest is Test {
    function testFork_blocksExecuteUntilArbitrationAccepted() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        ForkArbMock arb = new ForkArbMock();
        SXArbitrationExecutionStrategy wrapper =
            new SXArbitrationExecutionStrategy(address(this), address(arb));

        bytes32 digest = keccak256("fork-release");
        bytes memory payload = abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: 1,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: digest,
                artifactURI: "ipfs://fork-release"
            })
        );
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

        uint256 arbId = uint256(keccak256(payload));
        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, arbId
            )
        );
        wrapper.execute(1, p, 1, 0, 0, payload);

        arb.settle(arbId, true);
        wrapper.execute(1, p, 1, 0, 0, payload);
        assertEq(wrapper.releaseDigest(), digest);
    }
}
