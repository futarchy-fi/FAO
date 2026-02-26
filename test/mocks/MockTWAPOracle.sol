// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Mock TWAP oracle for EvaluationPipeline tests.
contract MockTWAPOracle {
    struct Binding {
        address yesPool;
        address noPool;
        address yesBase;
        address noBase;
    }

    mapping(address => Binding) public bindings;
    mapping(address => bool) public resolvedProposals;
    mapping(address => bool) public decisions;

    uint256 public bindCallCount;

    function bind(
        address proposal,
        address yesPool,
        address noPool,
        address yesBase,
        address noBase
    ) external {
        bindings[proposal] = Binding({
            yesPool: yesPool,
            noPool: noPool,
            yesBase: yesBase,
            noBase: noBase
        });
        bindCallCount++;
    }

    function setDecision(
        address proposal,
        bool resolved,
        bool accepted
    ) external {
        resolvedProposals[proposal] = resolved;
        decisions[proposal] = accepted;
    }

    function getDecision(address proposal)
        external
        view
        returns (bool resolved, bool accepted)
    {
        return (resolvedProposals[proposal], decisions[proposal]);
    }
}
