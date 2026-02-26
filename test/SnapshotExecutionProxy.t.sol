// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SnapshotExecutionProxy} from "../src/SnapshotExecutionProxy.sol";
import {ProposalStatus} from "src/types.sol";

import {MockSXSpace} from "./mocks/MockSXSpace.sol";
import {MockConditionalTokensFull} from "./mocks/MockConditionalTokensFull.sol";

/// @dev Minimal mock futarchy proposal that exposes questionId().
contract MockProposalForProxy {
    bytes32 public questionId;

    constructor(bytes32 _questionId) {
        questionId = _questionId;
    }
}

contract SnapshotExecutionProxyTest is Test {
    MockConditionalTokensFull ctf;
    MockSXSpace space;
    SnapshotExecutionProxy proxy;

    address binder;
    bytes32 constant QUESTION_ID = keccak256("test-question");

    function setUp() public {
        binder = address(this);
        ctf = new MockConditionalTokensFull();
        space = new MockSXSpace();
        proxy = new SnapshotExecutionProxy(address(ctf), binder);
    }

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    function testConstructorSetsImmutables() public view {
        assertEq(address(proxy.conditionalTokens()), address(ctf));
        assertEq(proxy.binder(), binder);
    }

    // ═══════════════════════════════════════════════════════
    //  bind()
    // ═══════════════════════════════════════════════════════

    function testBindSucceeds() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));

        proxy.bind(proposal, address(space), 42);

        (address boundSpace, uint256 boundId) = proxy.bindings(proposal);
        assertEq(boundSpace, address(space));
        assertEq(boundId, 42);
    }

    function testBindEmitsEvent() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));

        vm.expectEmit(true, true, false, true);
        emit SnapshotExecutionProxy.ProposalBound(proposal, address(space), 42);

        proxy.bind(proposal, address(space), 42);
    }

    function testBindRevertsIfNotBinder() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));

        vm.prank(address(0xDEAD));
        vm.expectRevert(SnapshotExecutionProxy.NotBinder.selector);
        proxy.bind(proposal, address(space), 42);
    }

    function testBindRevertsIfAlreadyBound() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));

        proxy.bind(proposal, address(space), 42);

        vm.expectRevert(
            abi.encodeWithSelector(SnapshotExecutionProxy.AlreadyBound.selector, proposal)
        );
        proxy.bind(proposal, address(space), 99);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — success cases
    // ═══════════════════════════════════════════════════════

    function testResolveExecutedReportsYes() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.Executed);

        proxy.resolve(proposal);

        assertEq(ctf.reportCount(), 1);
        assertEq(ctf.lastReportQuestionId(), QUESTION_ID);
        uint256[] memory payouts = ctf.getLastReportPayouts();
        assertEq(payouts[0], 1); // YES
        assertEq(payouts[1], 0); // NO
    }

    function testResolveRejectedReportsNo() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.Rejected);

        proxy.resolve(proposal);

        uint256[] memory payouts = ctf.getLastReportPayouts();
        assertEq(payouts[0], 0); // YES
        assertEq(payouts[1], 1); // NO
    }

    function testResolveCancelledReportsNo() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.Cancelled);

        proxy.resolve(proposal);

        uint256[] memory payouts = ctf.getLastReportPayouts();
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    function testResolveEmitsEvent() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);
        space.setProposalStatus(1, ProposalStatus.Executed);

        vm.expectEmit(true, true, false, true);
        emit SnapshotExecutionProxy.MarketSettled(proposal, QUESTION_ID, true);

        proxy.resolve(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — revert cases
    // ═══════════════════════════════════════════════════════

    function testResolveRevertsIfNotBound() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));

        vm.expectRevert(abi.encodeWithSelector(SnapshotExecutionProxy.NotBound.selector, proposal));
        proxy.resolve(proposal);
    }

    function testResolveRevertsIfVotingPeriod() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.VotingPeriod);

        vm.expectRevert(SnapshotExecutionProxy.NotFinal.selector);
        proxy.resolve(proposal);
    }

    function testResolveRevertsIfVotingDelay() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.VotingDelay);

        vm.expectRevert(SnapshotExecutionProxy.NotFinal.selector);
        proxy.resolve(proposal);
    }

    function testResolveRevertsIfAcceptedButNotExecuted() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.Accepted);

        vm.expectRevert(SnapshotExecutionProxy.NotFinal.selector);
        proxy.resolve(proposal);
    }

    function testResolveRevertsIfVotingPeriodAccepted() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);

        space.setProposalStatus(1, ProposalStatus.VotingPeriodAccepted);

        vm.expectRevert(SnapshotExecutionProxy.NotFinal.selector);
        proxy.resolve(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — broken execution strategy (auto-settles as NO)
    // ═══════════════════════════════════════════════════════

    function testResolveSettlesAsNoOnBrokenStrategy() public {
        RevertingSpace brokenSpace = new RevertingSpace();
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(brokenSpace), 1);

        proxy.resolve(proposal);

        // Should settle as NO (broken strategy = can't execute = rejected)
        assertEq(ctf.reportCount(), 1);
        uint256[] memory payouts = ctf.getLastReportPayouts();
        assertEq(payouts[0], 0); // YES
        assertEq(payouts[1], 1); // NO
    }

    function testResolveSettlesAsNoOnGasBombWithNormalGas() public {
        // With normal (high) gas, a gas bomb IS a genuinely broken strategy:
        // 1/64th of millions is still >> 100k, so the guard allows settlement.
        // This is correct — a strategy that consumes infinite gas can never execute.
        GasGuzzlerSpace gasSpace = new GasGuzzlerSpace();
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(gasSpace), 1);

        proxy.resolve(proposal);

        uint256[] memory payouts = ctf.getLastReportPayouts();
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    function testResolveRevertsOnGasGriefingAttack() public {
        // Gas griefing attack: attacker sends deliberately low gas so the Space
        // call OOGs, catch fires, but 1/64th of ~200k ≈ 3k < 100k.
        // The POST_CALL_GAS_FLOOR guard detects this and reverts.
        GasGuzzlerSpace gasSpace = new GasGuzzlerSpace();
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(gasSpace), 1);

        vm.expectRevert();
        proxy.resolve{gas: 200_000}(proposal);
    }

    function testResolveEmitsSpaceCallFailedOnBrokenStrategy() public {
        RevertingSpace brokenSpace = new RevertingSpace();
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(brokenSpace), 1);

        vm.expectEmit(true, true, false, true);
        emit SnapshotExecutionProxy.SpaceCallFailed(proposal, address(brokenSpace), 1);

        proxy.resolve(proposal);
    }

    // ═══════════════════════════════════════════════════════
    //  resolve() — permissionless
    // ═══════════════════════════════════════════════════════

    function testResolveIsPermissionless() public {
        address proposal = address(new MockProposalForProxy(QUESTION_ID));
        proxy.bind(proposal, address(space), 1);
        space.setProposalStatus(1, ProposalStatus.Executed);

        // Anyone can call resolve
        vm.prank(address(0xBEEF));
        proxy.resolve(proposal);

        assertEq(ctf.reportCount(), 1);
    }
}

/// @dev Mock space that always reverts on getProposalStatus (simulates broken execution strategy).
contract RevertingSpace {
    function getProposalStatus(uint256) external pure returns (ProposalStatus) {
        revert("execution strategy exploded");
    }
}

/// @dev Mock space that consumes all gas on getProposalStatus (simulates gas bomb strategy).
contract GasGuzzlerSpace {
    function getProposalStatus(uint256) external pure returns (ProposalStatus) {
        // Infinite loop — will consume all forwarded gas
        while (true) {}
        return ProposalStatus.VotingDelay; // unreachable, just for compiler
    }
}
