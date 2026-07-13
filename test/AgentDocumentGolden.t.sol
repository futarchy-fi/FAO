// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";

contract AgentDocumentGoldenTest is Test {
    function testPaymentEnvelopeMatchesPythonAndJavascriptGolden() public pure {
        bytes memory document =
            hex"7b22616d6f756e74223a22313135373932303839323337333136313935343233353730393835303038363837393037383533323639393834363635363430353634303339343537353834303037393133313239363339393335222c226173736574223a22307863636363636363636363636363636363636363636363636363636363636363636363636363636363222c22636861696e4964223a223131313535313131222c226b696e64223a2266616f2e7061796d656e74222c2272656365697074223a22307862633135636630316130393134303863313661623834333431613261656264613533343032623861333162343534333139396334643262313736643437336435222c22726563697069656e74223a22307864646464646464646464646464646464646464646464646464646464646464646464646464646464222c2273616c74223a22307865666566656665666566656665666566656665666566656665666566656665666566656665666566656665666566656665666566656665666566656665666566222c227461736b223a22307832336166653436316238643336653963306631633035303365316563316139386164373933373734383332346363343037333137343037386133306532333335222c2276223a2231222c227661756c74223a22307861616161616161616161616161616161616161616161616161616161616161616161616161616161227d";
        bytes32 envelopeDigest = 0x60fccea2c2617a6e1f35bb536e2a48b7384a8b6d91d3486075c1f77981eadc18;
        assertEq(keccak256(document), envelopeDigest);

        FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
            asset: address(uint160(0x00cccccccccccccccccccccccccccccccccccccccc)),
            recipient: address(uint160(0x00dddddddddddddddddddddddddddddddddddddddd)),
            amount: type(uint256).max,
            salt: envelopeDigest
        });
        bytes memory payload = FAOTreasuryActions.transferEvaluationPayload(
            11_155_111, address(uint160(0x00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)), action
        );
        assertEq(
            payload,
            hex"27e49851e3b79673e847d7c12acc52a3936006b8517243a42df902b3df4e902e0000000000000000000000000000000000000000000000000000000000aa36a7000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa000000000000000000000000cccccccccccccccccccccccccccccccccccccccc000000000000000000000000ddddddddddddddddddddddddddddddddddddddddffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff60fccea2c2617a6e1f35bb536e2a48b7384a8b6d91d3486075c1f77981eadc18"
        );
        bytes32 actionHash = FAOTreasuryActions.transferHash(
            11_155_111, address(uint160(0x00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)), action
        );
        assertEq(actionHash, 0x24a4125ae332e790e5fa9cbdc5d243b63a026e7b96fc9e796fd6d87706f2a87e);
        assertEq(
            uint256(actionHash),
            16_573_152_149_377_518_413_156_023_629_436_668_511_050_935_944_683_357_744_569_870_274_751_223_736_446
        );
    }

    function testAgentKindPreimagesMatchGolden() public pure {
        assertEq(
            keccak256("FAO_AGENT_TASK_V1"),
            0xa87c1f2bd1ee275d3f44c021b929709db51ad8a945c2c34a0857974e28595821
        );
        assertEq(
            keccak256("FAO_AGENT_RECEIPT_V1"),
            0xe2c91b1ce0f47a0ac033aec054b0ce8dd8a0ca22e4812f61776ed60835734da1
        );
        assertEq(
            keccak256("FAO_AGENT_PAYMENT_V1"),
            0x8161a6637134aa32b72dafb5032097de770b8555713c2415d800ea5af322c7bd
        );
    }
}
