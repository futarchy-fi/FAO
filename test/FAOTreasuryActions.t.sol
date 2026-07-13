// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";

contract FAOTreasuryActionsTest is Test {
    uint256 internal constant CHAIN_ID = 11_155_111;
    address internal constant VAULT = address(0xA11CE);

    function testTransferPayloadIsExactSevenWordEncoding() public pure {
        FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
            asset: address(0xA55E7),
            recipient: address(0xB0B),
            amount: 123 ether,
            salt: keccak256("transfer")
        });

        bytes memory payload = FAOTreasuryActions.transferEvaluationPayload(CHAIN_ID, VAULT, action);

        assertEq(payload.length, 7 * 32);
        assertEq(
            payload,
            abi.encode(
                keccak256("FAO_ECON_TREASURY_TRANSFER_V1"),
                CHAIN_ID,
                VAULT,
                action.asset,
                action.recipient,
                action.amount,
                action.salt
            )
        );
        assertEq(FAOTreasuryActions.transferHash(CHAIN_ID, VAULT, action), keccak256(payload));
    }

    function testParamPayloadIsExactSevenWordEncoding() public pure {
        FAOTreasuryActions.ParamAction memory action = FAOTreasuryActions.ParamAction({
            key: keccak256("monthly-tap"),
            asset: address(0xA55E7),
            value: 456 ether,
            salt: keccak256("param")
        });

        bytes memory payload = FAOTreasuryActions.paramEvaluationPayload(CHAIN_ID, VAULT, action);

        assertEq(payload.length, 7 * 32);
        assertEq(
            payload,
            abi.encode(
                keccak256("FAO_ECON_TREASURY_PARAM_V1"),
                CHAIN_ID,
                VAULT,
                action.key,
                action.asset,
                action.value,
                action.salt
            )
        );
        assertEq(FAOTreasuryActions.paramHash(CHAIN_ID, VAULT, action), keccak256(payload));
    }

    function testCriticalRoundsShareOneBaseAndHaveDistinctIds() public pure {
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(0xC0FFEE),
            value: 9 ether,
            data: hex"12345678aabbccdd",
            salt: keccak256("critical")
        });

        bytes memory expectedBase = abi.encode(
            keccak256("FAO_ECON_TREASURY_CRITICAL_V2"),
            CHAIN_ID,
            VAULT,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt
        );
        bytes memory roundOne =
            FAOTreasuryActions.criticalEvaluationPayload(CHAIN_ID, VAULT, action, 1);
        bytes memory roundTwo =
            FAOTreasuryActions.criticalEvaluationPayload(CHAIN_ID, VAULT, action, 2);

        assertEq(FAOTreasuryActions.criticalBasePayload(CHAIN_ID, VAULT, action), expectedBase);
        assertEq(
            FAOTreasuryActions.criticalBaseHash(CHAIN_ID, VAULT, action), keccak256(expectedBase)
        );
        assertEq(roundOne, bytes.concat(expectedBase, bytes32(uint256(1))));
        assertEq(roundTwo, bytes.concat(expectedBase, bytes32(uint256(2))));
        assertEq(roundOne.length, 8 * 32);
        assertEq(FAOTreasuryActions.criticalHash(CHAIN_ID, VAULT, action, 1), keccak256(roundOne));
        assertEq(FAOTreasuryActions.criticalHash(CHAIN_ID, VAULT, action, 2), keccak256(roundTwo));
        assertNotEq(keccak256(roundOne), keccak256(roundTwo));
    }

    function testCriticalDataCommitsByHash() public pure {
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(0xC0FFEE), value: 0, data: hex"010203", salt: bytes32(0)
        });

        bytes memory payload =
            FAOTreasuryActions.criticalEvaluationPayload(CHAIN_ID, VAULT, action, 1);
        (,,,,, bytes32 dataHash,, uint256 round) = abi.decode(
            payload, (bytes32, uint256, address, address, uint256, bytes32, bytes32, uint256)
        );

        assertEq(dataHash, keccak256(action.data));
        assertEq(round, 1);
    }

    function testCriticalRejectsEveryRoundExceptOneAndTwo() public {
        FAOTreasuryActions.CriticalAction memory action = FAOTreasuryActions.CriticalAction({
            target: address(1), value: 0, data: "", salt: bytes32(0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(FAOTreasuryActions.InvalidCriticalRound.selector, uint256(0))
        );
        this.criticalEvaluationPayload(action, 0);

        vm.expectRevert(
            abi.encodeWithSelector(FAOTreasuryActions.InvalidCriticalRound.selector, uint256(3))
        );
        this.criticalEvaluationPayload(action, 3);
    }

    function testDomainsBindChainAndVault() public pure {
        FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
            asset: address(1), recipient: address(2), amount: 3, salt: bytes32(uint256(4))
        });

        bytes32 expected = FAOTreasuryActions.transferHash(CHAIN_ID, VAULT, action);
        assertNotEq(expected, FAOTreasuryActions.transferHash(CHAIN_ID + 1, VAULT, action));
        assertNotEq(expected, FAOTreasuryActions.transferHash(CHAIN_ID, address(0xBEEF), action));
    }

    function criticalEvaluationPayload(
        FAOTreasuryActions.CriticalAction calldata action,
        uint256 round
    ) external pure returns (bytes memory) {
        return FAOTreasuryActions.criticalEvaluationPayload(CHAIN_ID, VAULT, action, round);
    }
}
