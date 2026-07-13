// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AgentWorkIndex} from "../src/AgentWorkIndex.sol";

contract AgentWorkToken {
    mapping(address => uint256) public balanceOf;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract ForceAgentWorkEther {
    constructor() payable {}

    function destroy(address payable recipient) external {
        selfdestruct(recipient);
    }
}

contract AgentWorkIndexTest is Test {
    event Published(
        bytes32 indexed kind,
        bytes32 indexed parentDigest,
        bytes32 indexed documentDigest,
        address publisher,
        bytes document
    );

    AgentWorkIndex internal index;

    function setUp() public {
        index = new AgentWorkIndex();
    }

    function testRejectsEmptyDocument() public {
        vm.expectRevert(AgentWorkIndex.EmptyDocument.selector);
        index.publish(bytes32(0), bytes32(0), "");
    }

    function testFuzzPublishesExactDigestAndEvent(
        bytes32 kind,
        bytes32 parentDigest,
        address publisher,
        bytes calldata rawDocument
    ) public {
        bytes memory document = rawDocument;
        vm.assume(publisher != address(0));
        vm.assume(document.length != 0 && document.length <= 4096);
        bytes32 digest = keccak256(document);

        vm.expectEmit(true, true, true, true, address(index));
        emit Published(kind, parentDigest, digest, publisher, document);
        vm.prank(publisher);
        assertEq(index.publish(kind, parentDigest, document), digest);
    }

    function testPublicationDoesNotWriteStorage() public {
        bytes32 slot = keccak256("arbitrary slot");
        assertEq(vm.load(address(index), slot), bytes32(0));
        index.publish(bytes32(0), bytes32(0), "document");
        assertEq(vm.load(address(index), slot), bytes32(0));
    }

    function testForcedAssetsCreateNoWithdrawalSeam() public {
        AgentWorkToken token = new AgentWorkToken();
        token.mint(address(index), 12 ether);
        ForceAgentWorkEther force = new ForceAgentWorkEther{value: 1 ether}();
        force.destroy(payable(address(index)));

        assertEq(token.balanceOf(address(index)), 12 ether);
        assertEq(address(index).balance, 1 ether);

        (bool success,) = address(index)
            .call(abi.encodeCall(token.transfer, (address(this), token.balanceOf(address(index)))));
        assertFalse(success);
        assertEq(token.balanceOf(address(index)), 12 ether);
        assertEq(address(index).balance, 1 ether);
    }
}
