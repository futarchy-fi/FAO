// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Stateless CREATE2 registrar for hash-sealed economic FAO receipts.
contract FaoGenesisRegistrar {
    uint256 public constant MAX_INITCODE_SIZE = 49_152;

    bytes32 public immutable RECEIPT_CREATION_CODE_HASH;

    error DeploymentFailed();
    error InitcodeTooLarge(uint256 size);
    error InvalidConfig();
    error InvalidReceiptCode(bytes32 expected, bytes32 actual);

    event GenesisStaged(
        address indexed receipt,
        bytes32 indexed coreConfigHash,
        bytes32 indexed flmConfigHash,
        address stager
    );

    constructor(bytes32 receiptBaseCodeHash) {
        if (receiptBaseCodeHash == bytes32(0)) revert InvalidReceiptCode(bytes32(0), bytes32(0));
        RECEIPT_CREATION_CODE_HASH = receiptBaseCodeHash;
    }

    function stage(bytes32 coreConfigHash, bytes32 flmConfigHash, bytes calldata receiptBaseCode)
        external
        returns (address receipt)
    {
        bytes memory initcode = _initcode(coreConfigHash, flmConfigHash, receiptBaseCode);
        bytes32 salt_ = salt(coreConfigHash, flmConfigHash);
        assembly ("memory-safe") {
            receipt := create2(0, add(initcode, 0x20), mload(initcode), salt_)
        }
        if (receipt == address(0) || receipt.code.length == 0) revert DeploymentFailed();
        emit GenesisStaged(receipt, coreConfigHash, flmConfigHash, msg.sender);
    }

    function predict(bytes32 coreConfigHash, bytes32 flmConfigHash, bytes calldata receiptBaseCode)
        external
        view
        returns (address)
    {
        bytes32 initcodeHash = keccak256(_initcode(coreConfigHash, flmConfigHash, receiptBaseCode));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt(coreConfigHash, flmConfigHash),
                            initcodeHash
                        )
                    )
                )
            )
        );
    }

    function salt(bytes32 coreConfigHash, bytes32 flmConfigHash) public pure returns (bytes32) {
        return keccak256(abi.encode(coreConfigHash, flmConfigHash));
    }

    function _initcode(
        bytes32 coreConfigHash,
        bytes32 flmConfigHash,
        bytes calldata receiptBaseCode
    ) private view returns (bytes memory) {
        if (coreConfigHash == bytes32(0) || flmConfigHash == bytes32(0)) revert InvalidConfig();
        if (receiptBaseCode.length > MAX_INITCODE_SIZE - 64) {
            revert InitcodeTooLarge(receiptBaseCode.length + 64);
        }
        bytes32 actualHash = keccak256(receiptBaseCode);
        if (actualHash != RECEIPT_CREATION_CODE_HASH) {
            revert InvalidReceiptCode(RECEIPT_CREATION_CODE_HASH, actualHash);
        }
        return abi.encodePacked(receiptBaseCode, abi.encode(coreConfigHash, flmConfigHash));
    }
}
