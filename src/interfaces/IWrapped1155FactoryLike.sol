// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Subset of Gnosis Wrapped1155Factory used by the FAO stack.
interface IWrapped1155FactoryLike {
    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address);
}
