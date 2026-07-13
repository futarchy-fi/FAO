// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

library FAOTreasuryActions {
    struct TransferAction {
        address asset;
        address recipient;
        uint256 amount;
        bytes32 salt;
    }

    struct ParamAction {
        bytes32 key;
        address asset;
        uint256 value;
        bytes32 salt;
    }

    struct CriticalAction {
        address target;
        uint256 value;
        bytes data;
        bytes32 salt;
    }

    bytes32 internal constant KIND_TRANSFER = keccak256("FAO_ECON_TREASURY_TRANSFER_V1");
    bytes32 internal constant KIND_PARAM = keccak256("FAO_ECON_TREASURY_PARAM_V1");
    bytes32 internal constant KIND_CRITICAL = keccak256("FAO_ECON_TREASURY_CRITICAL_V2");

    error InvalidCriticalRound(uint256 round);

    function transferEvaluationPayload(uint256 chainId, address vault, TransferAction memory action)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            KIND_TRANSFER,
            chainId,
            vault,
            action.asset,
            action.recipient,
            action.amount,
            action.salt
        );
    }

    function transferHash(uint256 chainId, address vault, TransferAction memory action)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(transferEvaluationPayload(chainId, vault, action));
    }

    function paramEvaluationPayload(uint256 chainId, address vault, ParamAction memory action)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encode(
                KIND_PARAM, chainId, vault, action.key, action.asset, action.value, action.salt
            );
    }

    function paramHash(uint256 chainId, address vault, ParamAction memory action)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(paramEvaluationPayload(chainId, vault, action));
    }

    function criticalBasePayload(uint256 chainId, address vault, CriticalAction memory action)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            KIND_CRITICAL,
            chainId,
            vault,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt
        );
    }

    function criticalBaseHash(uint256 chainId, address vault, CriticalAction memory action)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(criticalBasePayload(chainId, vault, action));
    }

    function criticalEvaluationPayload(
        uint256 chainId,
        address vault,
        CriticalAction memory action,
        uint256 round
    ) internal pure returns (bytes memory) {
        if (round != 1 && round != 2) {
            revert InvalidCriticalRound(round);
        }
        return abi.encode(
            KIND_CRITICAL,
            chainId,
            vault,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt,
            round
        );
    }

    function criticalHash(
        uint256 chainId,
        address vault,
        CriticalAction memory action,
        uint256 round
    ) internal pure returns (bytes32) {
        return keccak256(criticalEvaluationPayload(chainId, vault, action, round));
    }
}
