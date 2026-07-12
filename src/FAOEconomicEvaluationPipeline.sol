// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {FAOTreasuryActions} from "./FAOTreasuryActions.sol";
import {IFutarchyArbitrationEvaluator} from "./IFutarchyArbitrationEvaluator.sol";
import {
    IFAOSiteEvaluationArbitration,
    IFAOSiteEvaluationConditionalTokens,
    IFAOSiteEvaluationOrchestrator,
    IFAOSiteEvaluationProposal,
    IFAOSiteEvaluationResolver
} from "./FAOSiteEvaluationPipeline.sol";
import {SXArbitrationExecutionStrategy} from "./SXArbitrationExecutionStrategy.sol";

/// @notice Immutable bridge from either EconGateway route to the Sepolia UniV3 futarchy stack.
/// @dev Callers provide only the payload already committed by the active arbitration id.
contract FAOEconomicEvaluationPipeline is IFutarchyArbitrationEvaluator {
    using Strings for uint256;

    struct TreasuryEvaluation {
        bytes32 kind;
        uint256 chainId;
        address vault;
        address target;
        uint256 value;
        bytes32 dataHash;
        bytes32 salt;
    }

    uint256 internal constant MAX_RELEASE_URI_BYTES = 256;
    uint256 internal constant TREASURY_PAYLOAD_BYTES = 7 * 32;

    bytes32 public constant KIND_SITE_RELEASE = keccak256("FAO_SX_SITE_RELEASE_V1");
    bytes32 public constant KIND_TREASURY = FAOTreasuryActions.KIND_TREASURY;

    address public immutable arbitrationContract;
    address public immutable vault;
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
    error InvalidTreasuryPayload();
    error NoActiveEvaluation();
    error PayloadHashMismatch(uint256 proposalId, bytes32 payloadHash);
    error WrongProposalId(uint256 expectedActive, uint256 provided);
    error WrongTreasuryChain(uint256 expected, uint256 provided);
    error WrongTreasuryVault(address expected, address provided);

    event EvaluationMarketCreated(
        uint256 indexed proposalId,
        uint256 indexed futarchyProposalId,
        address indexed futarchyProposal,
        bytes32 payloadKind,
        bytes32 payloadCommitment
    );
    event EvaluationResolved(
        uint256 indexed proposalId,
        address indexed futarchyProposal,
        bytes32 indexed conditionId,
        bool accepted
    );

    constructor(
        address arbitration_,
        address orchestrator_,
        address resolver_,
        address ctf_,
        address vault_
    ) {
        if (
            arbitration_.code.length == 0 || orchestrator_.code.length == 0
                || resolver_.code.length == 0 || ctf_.code.length == 0 || vault_ == address(0)
        ) revert InvalidConfig();

        arbitrationContract = arbitration_;
        orchestrator = IFAOSiteEvaluationOrchestrator(orchestrator_);
        resolver = IFAOSiteEvaluationResolver(resolver_);
        conditionalTokens = IFAOSiteEvaluationConditionalTokens(ctf_);
        vault = vault_;

        if (
            IFAOSiteEvaluationOrchestrator(orchestrator_).ADMIN() != address(this)
                || IFAOSiteEvaluationOrchestrator(orchestrator_).RESOLVER() != resolver_
                || IFAOSiteEvaluationResolver(resolver_).CTF() != ctf_
        ) revert InvalidConfig();
    }

    function arbitration() external view returns (address) {
        return arbitrationContract;
    }

    /// @notice Permissionlessly create the evaluation market for either active EconGateway item.
    function startEvaluation(uint256 proposalId, bytes calldata evaluationPayload) external {
        _assertActive(proposalId);
        if (futarchyProposalOf[proposalId] != address(0)) {
            revert EvaluationAlreadyStarted(proposalId);
        }

        bytes32 payloadHash = keccak256(evaluationPayload);
        if (uint256(payloadHash) != proposalId) {
            revert PayloadHashMismatch(proposalId, payloadHash);
        }

        bytes32 firstWord;
        if (evaluationPayload.length >= 32) {
            assembly ("memory-safe") {
                firstWord := calldataload(evaluationPayload.offset)
            }
        }

        string memory marketName;
        string memory description;
        bytes32 payloadKind;
        bytes32 payloadCommitment;

        if (firstWord == KIND_TREASURY) {
            if (evaluationPayload.length != TREASURY_PAYLOAD_BYTES) {
                revert InvalidTreasuryPayload();
            }
            TreasuryEvaluation memory action = abi.decode(evaluationPayload, (TreasuryEvaluation));
            if (action.chainId != block.chainid) {
                revert WrongTreasuryChain(block.chainid, action.chainId);
            }
            if (action.vault != vault) revert WrongTreasuryVault(vault, action.vault);
            if (action.target == address(0)) revert InvalidTreasuryPayload();

            marketName =
                string.concat("FAO treasury action to ", Strings.toHexString(action.target));
            description = string.concat(
                "chain=",
                action.chainId.toString(),
                "; vault=",
                Strings.toHexString(action.vault),
                "; target=",
                Strings.toHexString(action.target),
                "; value=",
                action.value.toString(),
                "; data-hash=",
                Strings.toHexString(uint256(action.dataHash), 32),
                "; salt=",
                Strings.toHexString(uint256(action.salt), 32)
            );
            payloadKind = KIND_TREASURY;
            payloadCommitment = action.dataHash;
        } else {
            SXArbitrationExecutionStrategy.SiteRelease memory release =
                abi.decode(evaluationPayload, (SXArbitrationExecutionStrategy.SiteRelease));
            uint256 uriLength = bytes(release.artifactURI).length;
            if (
                release.nonce == 0 || release.artifactDigest == bytes32(0) || uriLength == 0
                    || uriLength > MAX_RELEASE_URI_BYTES
            ) revert InvalidReleasePayload();

            marketName = string.concat("FAO site release #", release.nonce.toString());
            description = string.concat(
                "expected-current=",
                Strings.toHexString(uint256(release.expectedCurrentDigest), 32),
                "; artifact=",
                Strings.toHexString(uint256(release.artifactDigest), 32),
                "; uri=",
                release.artifactURI
            );
            payloadKind = KIND_SITE_RELEASE;
            payloadCommitment = release.artifactDigest;
        }

        (uint256 futarchyProposalId, address futarchyProposal) =
            orchestrator.createOfficialProposalAndMigrate(marketName, description, 0);
        if (futarchyProposal == address(0)) revert InvalidFutarchyProposal();

        futarchyProposalOf[proposalId] = futarchyProposal;
        emit EvaluationMarketCreated(
            proposalId, futarchyProposalId, futarchyProposal, payloadKind, payloadCommitment
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
