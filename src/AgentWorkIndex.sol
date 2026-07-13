// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Ownerless publication log for agent-work documents.
/// @dev It has no storage, authority, or custody; FAO economics never read it.
contract AgentWorkIndex {
    error EmptyDocument();

    event Published(
        bytes32 indexed kind,
        bytes32 indexed parentDigest,
        bytes32 indexed documentDigest,
        address publisher,
        bytes document
    );

    function publish(bytes32 kind, bytes32 parentDigest, bytes calldata document)
        external
        returns (bytes32 documentDigest)
    {
        if (document.length == 0) revert EmptyDocument();
        documentDigest = keccak256(document);
        emit Published(kind, parentDigest, documentDigest, msg.sender, document);
    }
}
