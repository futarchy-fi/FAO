// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Optional verifiable randomness source (e.g. VRF v2.5 or threshold beacon adapter).
/// @dev When unset (`address(0)`), `FAOTwapResolver` uses a two-step future-blockhash draw
///      (with EIP-2935 historical blockhash fallback).
interface IFutarchyRandomnessSource {
    function requestRandomness(bytes32 context) external returns (bytes32 requestId);
    function readRandomness(bytes32 requestId)
        external
        view
        returns (bool fulfilled, bytes32 randomWord);
}

/// @notice Oracle interface used by FAOFutarchyProposal.resolve().
interface IFAOFutarchyOracle {
    function resolve(address proposal) external;
}

/// @notice Extension of IFAOFutarchyOracle for resolvers that need pool/anchor binding
/// at proposal promotion time (e.g. UniV3 TWAP resolver).
interface IFAOFutarchyTwapResolver is IFAOFutarchyOracle {
    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp,
        int24 marginTicks
    ) external;

    function setNoopPolicy(address proposal, uint16 noopFloorBps, int24 noopScaleTicks) external;
}
