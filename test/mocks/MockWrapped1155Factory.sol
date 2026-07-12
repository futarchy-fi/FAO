// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Mock Wrapped1155Factory that deploys trivial contracts as ERC20 wrappers.
contract MockWrapped1155Factory {
    uint256 internal _counter;

    function requireWrapped1155(
        address, /* multiToken */
        uint256, /* tokenId */
        bytes calldata /* data */
    )
        external
        returns (address)
    {
        // Deploy a minimal contract to get a unique address each time.
        _counter++;
        address wrapper = address(uint160(uint256(keccak256(abi.encodePacked(_counter)))));
        return wrapper;
    }
}
