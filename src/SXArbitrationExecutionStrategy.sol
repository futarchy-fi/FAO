// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IExecutionStrategy} from "./interfaces/IExecutionStrategy.sol";
import {FinalizationStatus, Proposal, ProposalStatus} from "./types.sol";

interface IFutarchyArbitrationLike {
    function isAccepted(uint256 proposalId) external view returns (bool);
    function isSettled(uint256 proposalId) external view returns (bool);
}

/// @title SXArbitrationExecutionStrategy
/// @notice Uses futarchy arbitration as the sole decision for a Snapshot X site release.
/// @dev The arbitration id is uint256(proposal.executionPayloadHash). Snapshot X verifies the
///      payload hash before calling execute, and this strategy only accepts calls from its Space.
contract SXArbitrationExecutionStrategy is IExecutionStrategy {
    struct SiteRelease {
        uint256 nonce;
        bytes32 expectedCurrentDigest;
        bytes32 artifactDigest;
        string artifactURI;
    }

    uint256 public constant MAX_RELEASE_URI_BYTES = 256;

    error ArbitrationNotAccepted(uint256 arbId);
    error InvalidReleaseDigest();
    error InvalidReleaseNonce(uint256 expected, uint256 provided);
    error InvalidReleaseURI(uint256 length);
    error OnlySpace(address caller);
    error UnexpectedCurrentRelease(bytes32 expected, bytes32 actual);
    error ZeroAddress();

    event SiteReleaseSelected(
        uint256 indexed sxProposalId,
        uint256 indexed arbitrationId,
        bytes32 indexed artifactDigest,
        uint256 nonce,
        bytes32 previousDigest,
        string artifactURI
    );

    address public immutable space;
    IFutarchyArbitrationLike public immutable arbitration;

    uint256 public releaseNonce;
    bytes32 public releaseDigest;
    string public releaseURI;

    constructor(address space_, address arbitration_) {
        if (space_ == address(0) || arbitration_ == address(0)) revert ZeroAddress();

        space = space_;
        arbitration = IFutarchyArbitrationLike(arbitration_);
    }

    function execute(
        uint256 proposalId,
        Proposal memory proposal,
        uint256,
        uint256,
        uint256,
        bytes memory payload
    ) external override {
        if (msg.sender != space) revert OnlySpace(msg.sender);

        uint256 arbId = uint256(proposal.executionPayloadHash);
        if (!_isSettled(arbId) || !_isAccepted(arbId)) revert ArbitrationNotAccepted(arbId);

        SiteRelease memory next = abi.decode(payload, (SiteRelease));
        uint256 expectedNonce = releaseNonce + 1;
        if (next.nonce != expectedNonce) {
            revert InvalidReleaseNonce(expectedNonce, next.nonce);
        }
        if (next.expectedCurrentDigest != releaseDigest) {
            revert UnexpectedCurrentRelease(next.expectedCurrentDigest, releaseDigest);
        }
        if (next.artifactDigest == bytes32(0)) revert InvalidReleaseDigest();

        uint256 uriLength = bytes(next.artifactURI).length;
        if (uriLength == 0 || uriLength > MAX_RELEASE_URI_BYTES) {
            revert InvalidReleaseURI(uriLength);
        }

        bytes32 previousDigest = releaseDigest;
        releaseNonce = next.nonce;
        releaseDigest = next.artifactDigest;
        releaseURI = next.artifactURI;

        emit SiteReleaseSelected(
            proposalId, arbId, next.artifactDigest, next.nonce, previousDigest, next.artifactURI
        );
    }

    function getProposalStatus(Proposal memory proposal, uint256, uint256, uint256)
        external
        view
        override
        returns (ProposalStatus)
    {
        if (proposal.finalizationStatus == FinalizationStatus.Executed) {
            return ProposalStatus.Executed;
        }
        if (proposal.finalizationStatus == FinalizationStatus.Cancelled) {
            return ProposalStatus.Cancelled;
        }

        uint256 arbId = uint256(proposal.executionPayloadHash);
        if (!_isSettled(arbId)) return ProposalStatus.VotingPeriod;
        return _isAccepted(arbId) ? ProposalStatus.Accepted : ProposalStatus.Rejected;
    }

    function getStrategyType() external pure override returns (string memory) {
        return "SXArbitrationExecutionStrategy";
    }

    function _isAccepted(uint256 arbId) internal view returns (bool accepted) {
        try arbitration.isAccepted(arbId) returns (bool ok) {
            accepted = ok;
        } catch {}
    }

    function _isSettled(uint256 arbId) internal view returns (bool settled) {
        try arbitration.isSettled(arbId) returns (bool ok) {
            settled = ok;
        } catch {}
    }
}
