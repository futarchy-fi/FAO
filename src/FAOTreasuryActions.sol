// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

library FAOTreasuryActions {
    struct TreasuryAction {
        address target;
        uint256 value;
        bytes data;
        bytes32 salt;
    }

    bytes32 internal constant KIND_TREASURY = keccak256("FAO_ECON_GATEWAY_TREASURY_ACTION_V1");

    function evaluationPayload(uint256 chainId, address vault, TreasuryAction calldata action)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            KIND_TREASURY,
            chainId,
            vault,
            action.target,
            action.value,
            keccak256(action.data),
            action.salt
        );
    }

    function hash(uint256 chainId, address vault, TreasuryAction calldata action)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(evaluationPayload(chainId, vault, action));
    }
}
