// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {GenesisTreasuryExecutor} from "../src/GenesisTreasuryExecutor.sol";

contract ExecutorToken is ERC20 {
    constructor() ERC20("Executor Token", "EXEC") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract FeeExecutorToken is ExecutorToken {
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        super._transfer(sender, recipient, amount - 1);
        _burn(sender, 1);
    }
}

contract ExecutorTarget {
    error TargetFailure();

    address public lastSender;
    uint256 public lastNumber;

    function record(uint256 number) external payable returns (bytes32, address, uint256) {
        lastSender = msg.sender;
        lastNumber = number;
        return (keccak256("arbitrary return data"), msg.sender, msg.value);
    }

    function mutateThenRevert() external payable {
        lastNumber = 99;
        revert TargetFailure();
    }
}

contract NativeRecipient {
    address public sender;
    uint256 public amount;

    receive() external payable {
        sender = msg.sender;
        amount = msg.value;
    }
}

contract GenesisTreasuryExecutorTest is Test {
    GenesisTreasuryExecutor internal executor;
    ExecutorTarget internal target;
    ExecutorToken internal token;

    address internal constant ATTACKER = address(0xBAD);
    address payable internal constant RECIPIENT = payable(address(0xB0B));

    function setUp() public {
        executor = new GenesisTreasuryExecutor(address(this));
        target = new ExecutorTarget();
        token = new ExecutorToken();
    }

    function testRejectsZeroVault() public {
        vm.expectRevert(GenesisTreasuryExecutor.InvalidVault.selector);
        new GenesisTreasuryExecutor(address(0));
    }

    function testOnlyVaultCanExecute() public {
        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisTreasuryExecutor.Unauthorized.selector, ATTACKER)
        );
        executor.execute(address(target), 0, abi.encodeCall(target.record, (1)));
    }

    function testExecuteUsesExecutorIdentityAndReturnsData() public {
        vm.deal(address(executor), 1 ether);

        bytes memory result =
            executor.execute(address(target), 0.25 ether, abi.encodeCall(target.record, (42)));
        (bytes32 marker, address sender, uint256 value) =
            abi.decode(result, (bytes32, address, uint256));

        assertEq(marker, keccak256("arbitrary return data"));
        assertEq(sender, address(executor));
        assertEq(target.lastSender(), address(executor));
        assertEq(target.lastNumber(), 42);
        assertEq(value, 0.25 ether);
    }

    function testExecuteRevertIsTypedAndAtomic() public {
        vm.deal(address(executor), 1 ether);
        bytes memory targetReason = abi.encodeWithSelector(ExecutorTarget.TargetFailure.selector);

        vm.expectRevert(
            abi.encodeWithSelector(GenesisTreasuryExecutor.CallFailed.selector, targetReason)
        );
        executor.execute(
            address(target), 0.25 ether, abi.encodeWithSelector(target.mutateThenRevert.selector)
        );

        assertEq(target.lastNumber(), 0);
        assertEq(address(executor).balance, 1 ether);
        assertEq(address(target).balance, 0);
    }

    function testReleasesExactErc20Custody() public {
        token.mint(address(executor), 100 ether);

        executor.release(address(token), RECIPIENT, 40 ether);

        assertEq(token.balanceOf(address(executor)), 60 ether);
        assertEq(token.balanceOf(RECIPIENT), 40 ether);
    }

    function testRejectsInexactErc20ReleaseAtomically() public {
        FeeExecutorToken feeToken = new FeeExecutorToken();
        feeToken.mint(address(executor), 10);

        vm.expectRevert(
            abi.encodeWithSelector(
                GenesisTreasuryExecutor.InexactTokenTransfer.selector,
                address(feeToken),
                RECIPIENT,
                10,
                9
            )
        );
        executor.release(address(feeToken), RECIPIENT, 10);

        assertEq(feeToken.balanceOf(address(executor)), 10);
        assertEq(feeToken.balanceOf(RECIPIENT), 0);
    }

    function testReleasesNativeCustodyFromExecutor() public {
        NativeRecipient recipient = new NativeRecipient();
        vm.deal(address(executor), 1 ether);

        executor.release(address(0), payable(address(recipient)), 0.4 ether);

        assertEq(address(executor).balance, 0.6 ether);
        assertEq(address(recipient).balance, 0.4 ether);
        assertEq(recipient.sender(), address(executor));
        assertEq(recipient.amount(), 0.4 ether);
    }

    function testThirdPartyCannotReleaseCustody() public {
        token.mint(address(executor), 1 ether);

        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(GenesisTreasuryExecutor.Unauthorized.selector, ATTACKER)
        );
        executor.release(address(token), RECIPIENT, 1 ether);

        assertEq(token.balanceOf(address(executor)), 1 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }
}
