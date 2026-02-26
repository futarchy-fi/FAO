// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {IExecutionStrategy} from "../src/interfaces/IExecutionStrategy.sol";
import {Proposal, ProposalStatus, FinalizationStatus} from "../src/types.sol";

contract ArbitrationMock {
    mapping(uint256 => bool) public accepted;
    mapping(uint256 => bool) public settled;

    function settle(uint256 arbId, bool _accepted) external {
        settled[arbId] = true;
        accepted[arbId] = _accepted;
    }

    function setAccepted(uint256 arbId, bool ok) external {
        accepted[arbId] = ok;
    }

    function setSettled(uint256 arbId, bool ok) external {
        settled[arbId] = ok;
    }

    function isAccepted(uint256 arbId) external view returns (bool) {
        return accepted[arbId];
    }

    function isSettled(uint256 arbId) external view returns (bool) {
        return settled[arbId];
    }
}

contract MockInnerExecutionStrategy is IExecutionStrategy {
    ProposalStatus public status;
    bool public executed;

    constructor() {
        status = ProposalStatus.VotingPeriod;
    }

    function setStatus(ProposalStatus next) external {
        status = next;
    }

    function execute(uint256, Proposal memory, uint256, uint256, uint256, bytes memory)
        external
        override
    {
        executed = true;
    }

    function getProposalStatus(Proposal memory, uint256, uint256, uint256)
        external
        view
        override
        returns (ProposalStatus)
    {
        return status;
    }

    function getStrategyType() external pure override returns (string memory) {
        return "MockInnerExecutionStrategy";
    }
}

contract SXArbitrationExecutionStrategyTest is Test {
    ArbitrationMock internal arb;
    MockInnerExecutionStrategy internal inner;

    function setUp() public {
        arb = new ArbitrationMock();
        inner = new MockInnerExecutionStrategy();
    }

    function _proposal(bytes memory payload) internal view returns (Proposal memory p) {
        p.author = address(this);
        p.startBlockNumber = uint32(block.number);
        p.executionStrategy = IExecutionStrategy(address(inner));
        p.minEndBlockNumber = uint32(block.number);
        p.maxEndBlockNumber = uint32(block.number + 1);
        p.finalizationStatus = FinalizationStatus.Pending;
        p.executionPayloadHash = keccak256(payload);
        p.activeVotingStrategies = 0;
    }

    function _arbId(bytes memory payload) internal pure returns (uint256) {
        return uint256(keccak256(payload));
    }

    function testBinding_StatusVotingPeriodWhileUnsettled() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );

        bytes memory payload = abi.encodePacked("binding-test");
        Proposal memory p = _proposal(payload);

        assertEq(
            uint256(wrapper.getProposalStatus(p, 0, 0, 0)), uint256(ProposalStatus.VotingPeriod)
        );
    }

    function testBinding_AcceptedOnceArbitrationAccepts() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );

        bytes memory payload = abi.encodePacked("binding-accept");
        Proposal memory p = _proposal(payload);

        arb.settle(_arbId(payload), true);
        assertEq(uint256(wrapper.getProposalStatus(p, 0, 0, 0)), uint256(ProposalStatus.Accepted));
    }

    function testBinding_RejectedOnceArbitrationRejects() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );

        bytes memory payload = abi.encodePacked("binding-reject");
        Proposal memory p = _proposal(payload);

        arb.settle(_arbId(payload), false);
        assertEq(uint256(wrapper.getProposalStatus(p, 0, 0, 0)), uint256(ProposalStatus.Rejected));
    }

    function testBinding_ExecuteSucceedsWhenAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );

        bytes memory payload = abi.encodePacked("binding-exec");
        Proposal memory p = _proposal(payload);
        arb.settle(_arbId(payload), true);

        wrapper.execute(1, p, 1, 0, 0, payload);
        assertTrue(inner.executed());
    }

    function testBinding_ExecuteRevertsWhenNotAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.BINDING
        );

        bytes memory payload = abi.encodePacked("binding-noexec");
        Proposal memory p = _proposal(payload);
        uint256 id = _arbId(payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, id
            )
        );
        wrapper.execute(1, p, 1, 0, 0, payload);
    }

    function testVeto_VotingPeriodWhileUnsettled() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("veto-test");
        Proposal memory p = _proposal(payload);

        assertEq(
            uint256(wrapper.getProposalStatus(p, 0, 0, 0)), uint256(ProposalStatus.VotingPeriod)
        );
    }

    function testVeto_RejectedWhenBondsReject() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("veto-reject");
        Proposal memory p = _proposal(payload);

        arb.settle(_arbId(payload), false);
        assertEq(uint256(wrapper.getProposalStatus(p, 1, 0, 0)), uint256(ProposalStatus.Rejected));
    }

    function testVeto_DefersToInnerWhenBondsAccept() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("veto-defer");
        Proposal memory p = _proposal(payload);

        arb.settle(_arbId(payload), true);

        inner.setStatus(ProposalStatus.VotingPeriodAccepted);
        assertEq(
            uint256(wrapper.getProposalStatus(p, 1, 0, 0)),
            uint256(ProposalStatus.VotingPeriodAccepted)
        );

        inner.setStatus(ProposalStatus.Accepted);
        assertEq(uint256(wrapper.getProposalStatus(p, 1, 0, 0)), uint256(ProposalStatus.Accepted));
    }

    function testVeto_ExecuteRequiresBothBondsAndVotes() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("veto-exec");
        Proposal memory p = _proposal(payload);

        arb.settle(_arbId(payload), true);
        wrapper.execute(1, p, 1, 0, 0, payload);
        assertTrue(inner.executed());
    }

    function testVeto_ExecuteRevertsIfBondsNotAccepted() public {
        SXArbitrationExecutionStrategy wrapper = new SXArbitrationExecutionStrategy(
            address(arb), address(inner), SXArbitrationExecutionStrategy.Mode.VETO
        );

        bytes memory payload = abi.encodePacked("veto-noexec");
        Proposal memory p = _proposal(payload);
        uint256 id = _arbId(payload);

        vm.expectRevert(
            abi.encodeWithSelector(
                SXArbitrationExecutionStrategy.ArbitrationNotAccepted.selector, id
            )
        );
        wrapper.execute(1, p, 1, 0, 0, payload);
    }
}
