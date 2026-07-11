// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";
import {SXArbitrationExecutionStrategy} from "./SXArbitrationExecutionStrategy.sol";

interface IFAOSiteEvaluationArbitration {
    function activeEvaluationProposalId() external view returns (uint256);
    function resolveActiveEvaluation(bool accepted) external;
}

interface IFAOSiteEvaluationOrchestrator {
    function ADMIN() external view returns (address);
    function RESOLVER() external view returns (address);

    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata description,
        uint256 builderTip
    ) external payable returns (uint256 proposalId, address proposal);
}

interface IFAOSiteEvaluationResolver {
    function CTF() external view returns (address);
    function resolve(address proposal) external;
}

interface IFAOSiteEvaluationProposal {
    function conditionId() external view returns (bytes32);
}

interface IFAOSiteEvaluationConditionalTokens {
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);
}

/// @notice Immutable bridge from a graduated site proposal to the Sepolia UniV3 futarchy stack.
/// @dev Callers provide the already-committed release payload, never market safety parameters.
contract FAOSiteEvaluationPipeline is IFutarchyArbitrationEvaluator {
    using Strings for uint256;

    uint256 internal constant MAX_RELEASE_URI_BYTES = 256;

    address public immutable arbitrationContract;
    IFAOSiteEvaluationOrchestrator public immutable orchestrator;
    IFAOSiteEvaluationResolver public immutable resolver;
    IFAOSiteEvaluationConditionalTokens public immutable conditionalTokens;

    mapping(uint256 proposalId => address futarchyProposal) public futarchyProposalOf;

    error EvaluationAlreadyStarted(uint256 proposalId);
    error EvaluationNotStarted(uint256 proposalId);
    error FutarchyNotResolved(bytes32 conditionId);
    error InvalidConfig();
    error InvalidFutarchyProposal();
    error InvalidPayout(uint256 yesNumerator, uint256 noNumerator, uint256 denominator);
    error InvalidReleasePayload();
    error NoActiveEvaluation();
    error PayloadHashMismatch(uint256 proposalId, bytes32 payloadHash);
    error WrongProposalId(uint256 expectedActive, uint256 provided);

    event EvaluationMarketCreated(
        uint256 indexed proposalId,
        uint256 indexed futarchyProposalId,
        address indexed futarchyProposal,
        bytes32 artifactDigest
    );
    event EvaluationResolved(
        uint256 indexed proposalId,
        address indexed futarchyProposal,
        bytes32 indexed conditionId,
        bool accepted
    );

    constructor(address arbitration_, address orchestrator_, address resolver_, address ctf_) {
        if (
            arbitration_.code.length == 0 || orchestrator_.code.length == 0
                || resolver_.code.length == 0 || ctf_.code.length == 0
        ) revert InvalidConfig();

        arbitrationContract = arbitration_;
        orchestrator = IFAOSiteEvaluationOrchestrator(orchestrator_);
        resolver = IFAOSiteEvaluationResolver(resolver_);
        conditionalTokens = IFAOSiteEvaluationConditionalTokens(ctf_);

        if (
            IFAOSiteEvaluationOrchestrator(orchestrator_).ADMIN() != address(this)
                || IFAOSiteEvaluationOrchestrator(orchestrator_).RESOLVER() != resolver_
                || IFAOSiteEvaluationResolver(resolver_).CTF() != ctf_
        ) revert InvalidConfig();
    }

    function arbitration() external view returns (address) {
        return arbitrationContract;
    }

    /// @notice Permissionlessly create the evaluation market for the active arbitration item.
    /// @dev Market text is derived from the payload whose hash is the arbitration id.
    function startEvaluation(uint256 proposalId, bytes calldata executionPayload) external {
        _assertActive(proposalId);
        if (futarchyProposalOf[proposalId] != address(0)) {
            revert EvaluationAlreadyStarted(proposalId);
        }

        bytes32 payloadHash = keccak256(executionPayload);
        if (uint256(payloadHash) != proposalId) {
            revert PayloadHashMismatch(proposalId, payloadHash);
        }

        SXArbitrationExecutionStrategy.SiteRelease memory release =
            abi.decode(executionPayload, (SXArbitrationExecutionStrategy.SiteRelease));
        uint256 uriLength = bytes(release.artifactURI).length;
        if (
            release.nonce == 0 || release.artifactDigest == bytes32(0) || uriLength == 0
                || uriLength > MAX_RELEASE_URI_BYTES
        ) revert InvalidReleasePayload();

        string memory marketName = string.concat("FAO site release #", release.nonce.toString());
        string memory description = string.concat(
            "expected-current=",
            Strings.toHexString(uint256(release.expectedCurrentDigest), 32),
            "; artifact=",
            Strings.toHexString(uint256(release.artifactDigest), 32),
            "; uri=",
            release.artifactURI
        );

        (uint256 futarchyProposalId, address futarchyProposal) =
            orchestrator.createOfficialProposalAndMigrate(marketName, description, 0);
        if (futarchyProposal == address(0)) revert InvalidFutarchyProposal();

        futarchyProposalOf[proposalId] = futarchyProposal;
        emit EvaluationMarketCreated(
            proposalId, futarchyProposalId, futarchyProposal, release.artifactDigest
        );
    }

    /// @notice Permissionlessly resolve the active evaluation once its fixed TWAP window ends.
    function resolve(uint256 proposalId) external returns (bool accepted) {
        _assertActive(proposalId);

        address futarchyProposal = futarchyProposalOf[proposalId];
        if (futarchyProposal == address(0)) revert EvaluationNotStarted(proposalId);

        bytes32 conditionId = IFAOSiteEvaluationProposal(futarchyProposal).conditionId();
        uint256 denominator = conditionalTokens.payoutDenominator(conditionId);
        if (denominator == 0) {
            resolver.resolve(futarchyProposal);
            denominator = conditionalTokens.payoutDenominator(conditionId);
        }
        if (denominator == 0) revert FutarchyNotResolved(conditionId);

        uint256 yesNumerator = conditionalTokens.payoutNumerators(conditionId, 0);
        uint256 noNumerator = conditionalTokens.payoutNumerators(conditionId, 1);
        if (yesNumerator + noNumerator != denominator || yesNumerator == noNumerator) {
            revert InvalidPayout(yesNumerator, noNumerator, denominator);
        }

        accepted = yesNumerator > noNumerator;
        IFAOSiteEvaluationArbitration(arbitrationContract).resolveActiveEvaluation(accepted);

        emit EvaluationResolved(proposalId, futarchyProposal, conditionId, accepted);
    }

    function _assertActive(uint256 proposalId) private view {
        uint256 active =
            IFAOSiteEvaluationArbitration(arbitrationContract).activeEvaluationProposalId();
        if (active == 0) revert NoActiveEvaluation();
        if (active != proposalId) revert WrongProposalId(active, proposalId);
    }
}
