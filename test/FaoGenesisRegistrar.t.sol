// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FaoGenesisRegistrar} from "../src/FaoGenesisRegistrar.sol";
import {EconomicDeploymentCodeHashes} from "../src/generated/EconomicDeploymentCodeHashes.sol";

contract FaoGenesisRegistrarTest is Test {
    bytes32 private constant CORE_HASH = keccak256("core");
    bytes32 private constant FLM_HASH = keccak256("flm");

    bytes private receiptBaseCode;
    FaoGenesisRegistrar private registrar;

    event GenesisStaged(
        address indexed receipt, bytes32 indexed coreHash, bytes32 indexed flmHash, address stager
    );

    function setUp() public {
        receiptBaseCode = vm.readFileBinary("metadata/economic-creation-code/receipt.bin");
        assertEq(keccak256(receiptBaseCode), EconomicDeploymentCodeHashes.RECEIPT);
        registrar = new FaoGenesisRegistrar(keccak256(receiptBaseCode));
    }

    function test_stageIsStatelessPredictableAndDeploysTheExactReceipt() public {
        address stager = makeAddr("stager");
        address predicted = registrar.predict(CORE_HASH, FLM_HASH, receiptBaseCode);
        address expected = _create2Address(CORE_HASH, FLM_HASH, receiptBaseCode);
        assertEq(predicted, expected);

        vm.expectEmit(true, true, true, true, address(registrar));
        emit GenesisStaged(predicted, CORE_HASH, FLM_HASH, stager);
        vm.prank(stager);
        address deployed = registrar.stage(CORE_HASH, FLM_HASH, receiptBaseCode);

        assertEq(deployed, predicted);
        FaoGenesisDeployment receipt = FaoGenesisDeployment(deployed);
        assertEq(receipt.CORE_CONFIG_HASH(), CORE_HASH);
        assertEq(receipt.FLM_CONFIG_HASH(), FLM_HASH);
        address direct = _deployDirect(receiptBaseCode, CORE_HASH, FLM_HASH);
        assertEq(deployed.code, direct.code);
        assertEq(vm.load(address(registrar), bytes32(0)), bytes32(0));
    }

    function test_rejectsBadInputsAndDuplicateConfig() public {
        vm.expectRevert(FaoGenesisRegistrar.InvalidConfig.selector);
        registrar.stage(bytes32(0), FLM_HASH, receiptBaseCode);
        vm.expectRevert(FaoGenesisRegistrar.InvalidConfig.selector);
        registrar.stage(CORE_HASH, bytes32(0), receiptBaseCode);

        bytes memory empty;
        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisRegistrar.InvalidReceiptCode.selector,
                keccak256(receiptBaseCode),
                keccak256(empty)
            )
        );
        registrar.stage(CORE_HASH, FLM_HASH, empty);

        bytes memory wrongCode = receiptBaseCode;
        wrongCode[0] = bytes1(uint8(wrongCode[0]) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisRegistrar.InvalidReceiptCode.selector,
                keccak256(receiptBaseCode),
                keccak256(wrongCode)
            )
        );
        registrar.stage(CORE_HASH, FLM_HASH, wrongCode);

        address first = registrar.stage(CORE_HASH, FLM_HASH, receiptBaseCode);
        vm.recordLogs();
        address repeated = registrar.stage(CORE_HASH, FLM_HASH, receiptBaseCode);
        assertEq(repeated, first);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_distinctHashesProduceDistinctReceipts() public {
        bytes32 otherCoreHash = keccak256("other core");
        address first = registrar.stage(CORE_HASH, FLM_HASH, receiptBaseCode);
        address second = registrar.stage(otherCoreHash, FLM_HASH, receiptBaseCode);
        assertNotEq(first, second);
        assertEq(FaoGenesisDeployment(second).CORE_CONFIG_HASH(), otherCoreHash);
    }

    function test_rejectsOversizedInitcode() public {
        bytes memory oversized = new bytes(registrar.MAX_INITCODE_SIZE() - 63);
        FaoGenesisRegistrar oversizedRegistrar = new FaoGenesisRegistrar(keccak256(oversized));
        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisRegistrar.InitcodeTooLarge.selector, registrar.MAX_INITCODE_SIZE() + 1
            )
        );
        oversizedRegistrar.stage(CORE_HASH, FLM_HASH, oversized);
    }

    function test_rejectsReceiptWithEmptyRuntime() public {
        bytes memory emptyRuntimeCreationCode = hex"60006000f3";
        FaoGenesisRegistrar emptyRuntimeRegistrar =
            new FaoGenesisRegistrar(keccak256(emptyRuntimeCreationCode));
        vm.expectRevert(FaoGenesisRegistrar.DeploymentFailed.selector);
        emptyRuntimeRegistrar.stage(CORE_HASH, FLM_HASH, emptyRuntimeCreationCode);
    }

    function test_gettersAndRuntimeStaySmall() public view {
        assertEq(registrar.RECEIPT_CREATION_CODE_HASH(), keccak256(receiptBaseCode));
        assertEq(registrar.MAX_INITCODE_SIZE(), 49_152);
        assertEq(registrar.salt(CORE_HASH, FLM_HASH), keccak256(abi.encode(CORE_HASH, FLM_HASH)));
        assertLt(address(registrar).code.length, 4096);
    }

    function _create2Address(bytes32 coreHash, bytes32 flmHash, bytes memory baseCode)
        private
        view
        returns (address)
    {
        bytes32 initcodeHash = keccak256(abi.encodePacked(baseCode, abi.encode(coreHash, flmHash)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(registrar),
                            keccak256(abi.encode(coreHash, flmHash)),
                            initcodeHash
                        )
                    )
                )
            )
        );
    }

    function _deployDirect(bytes memory baseCode, bytes32 coreHash, bytes32 flmHash)
        private
        returns (address deployed)
    {
        bytes memory initcode = abi.encodePacked(baseCode, abi.encode(coreHash, flmHash));
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertTrue(deployed.code.length != 0);
    }
}
