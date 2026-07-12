// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyProposal} from "./FAOFutarchyProposal.sol";
import {IFAOFutarchyOracle} from "./interfaces/IFAOFutarchyOracle.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title FAOFutarchyFactory
/// @notice Creates FAO v0 futarchy proposals: condition + 4 wrapped ERC20 outcome tokens.
///
/// Replaces Seer's FutarchyFactory in v0:
///   - No Reality.eth dependency.
///   - questionId is derived from block.prevrandao (+ a sequential nonce) so that the
///     deterministic chain conditionId → positionIds → wrapper addresses → UniV3 pool
///     addresses cannot be predicted before the slot in which the call lands.
///   - Oracle is a generic IFAOFutarchyOracle (FutarchyTwapResolver in v0), not a
///     FutarchyRealityProxy.
///
/// SECURITY: questionId derivation includes:
///   - keccak256(marketName, description) → identifies the proposal content.
///   - address(this), proposals.length → disambiguates same-block calls and factories.
///   - block.prevrandao → reduces adversary foresight to the proposing validator only.
///
/// See docs/onchain-futarchy-design.md §4.1 for the full rationale.
contract FAOFutarchyFactory {
    using Clones for address;

    struct CreateProposalParams {
        string marketName;
        string description;
        address collateralToken1; // typically FAO
        address collateralToken2; // typically WETH
    }

    /// @notice Conditional Tokens Framework deployment.
    IConditionalTokensLike public immutable conditionalTokens;

    /// @notice Gnosis Wrapped1155Factory deployment.
    IWrapped1155FactoryLike public immutable wrapped1155Factory;

    /// @notice The oracle that will report payouts to CTF (FutarchyTwapResolver in v0).
    address public immutable oracle;

    /// @notice FAOFutarchyProposal implementation cloned per proposal.
    address public immutable proposalImpl;

    /// @notice All proposals created by this factory, in creation order.
    address[] public proposals;

    event NewProposal(
        uint256 indexed proposalId,
        address indexed proposal,
        bytes32 conditionId,
        bytes32 questionId,
        bytes32 prevRandao
    );

    error MissingTokenName();
    error EmptyMarketName();
    error InvalidCollateral();

    constructor(
        address _proposalImpl,
        IConditionalTokensLike _conditionalTokens,
        IWrapped1155FactoryLike _wrapped1155Factory,
        address _oracle
    ) {
        proposalImpl = _proposalImpl;
        conditionalTokens = _conditionalTokens;
        wrapped1155Factory = _wrapped1155Factory;
        oracle = _oracle;
    }

    /// @notice Compute the questionId for a candidate call without state mutation.
    /// @dev Useful for orchestrator sanity-checking pre-creation in the same atomic tx.
    function computeQuestionId(
        string memory marketName,
        string memory description,
        uint256 proposalIndex
    ) public view returns (bytes32) {
        bytes32 contentHash = keccak256(abi.encodePacked(marketName, description));
        return
            keccak256(abi.encodePacked(contentHash, address(this), proposalIndex, block.prevrandao));
    }

    /// @notice Compute the conditionId for a given questionId.
    function computeConditionId(bytes32 questionId_) public view returns (bytes32) {
        return conditionalTokens.getConditionId(oracle, questionId_, 2);
    }

    /// @notice Permissionless: create a new futarchy proposal.
    function createProposal(CreateProposalParams memory params) external returns (address) {
        if (bytes(params.marketName).length == 0) revert EmptyMarketName();
        if (params.collateralToken1 == address(0) || params.collateralToken2 == address(0)) {
            revert InvalidCollateral();
        }

        uint256 proposalIndex = proposals.length;
        bytes32 questionId_ =
            computeQuestionId(params.marketName, params.description, proposalIndex);
        bytes32 conditionId_ = _prepareCondition(questionId_);

        (string[] memory outcomes, string[] memory tokenNames) =
            _outcomesAndTokenNames(params.collateralToken1, params.collateralToken2);

        (address[] memory wrapped1155, bytes[] memory tokenData) = _deployERC20Positions(
            params.collateralToken1, params.collateralToken2, conditionId_, tokenNames
        );

        FAOFutarchyProposal.FAOFutarchyProposalParams memory proposalParams =
            FAOFutarchyProposal.FAOFutarchyProposalParams({
                conditionId: conditionId_,
                questionId: questionId_,
                collateralToken1: params.collateralToken1,
                collateralToken2: params.collateralToken2,
                parentCollectionId: bytes32(0),
                parentOutcome: 0,
                parentMarket: address(0),
                wrapped1155: wrapped1155,
                tokenData: tokenData
            });

        FAOFutarchyProposal instance = FAOFutarchyProposal(proposalImpl.clone());
        instance.initialize(
            params.marketName,
            params.description,
            outcomes,
            proposalParams,
            IFAOFutarchyOracle(oracle)
        );

        proposals.push(address(instance));

        emit NewProposal(
            proposalIndex, address(instance), conditionId_, questionId_, bytes32(block.prevrandao)
        );

        return address(instance);
    }

    function marketsCount() external view returns (uint256) {
        return proposals.length;
    }

    function allMarkets() external view returns (address[] memory) {
        return proposals;
    }

    // ─── internals
    // ──────────────────────────────────────────────────────────

    function _prepareCondition(bytes32 questionId_) internal returns (bytes32) {
        bytes32 conditionId_ = conditionalTokens.getConditionId(oracle, questionId_, 2);
        if (conditionalTokens.getOutcomeSlotCount(conditionId_) == 0) {
            conditionalTokens.prepareCondition(oracle, questionId_, 2);
        }
        return conditionId_;
    }

    function _outcomesAndTokenNames(address collateralToken1, address collateralToken2)
        internal
        view
        returns (string[] memory outcomes, string[] memory tokenNames)
    {
        string memory symbol1 = _symbol(collateralToken1);
        string memory symbol2 = _symbol(collateralToken2);
        outcomes = new string[](4);
        outcomes[0] = string.concat("Yes-", symbol1);
        outcomes[1] = string.concat("No-", symbol1);
        outcomes[2] = string.concat("Yes-", symbol2);
        outcomes[3] = string.concat("No-", symbol2);
        tokenNames = new string[](4);
        tokenNames[0] = string.concat("YES_", symbol1);
        tokenNames[1] = string.concat("NO_", symbol1);
        tokenNames[2] = string.concat("YES_", symbol2);
        tokenNames[3] = string.concat("NO_", symbol2);
    }

    function _symbol(address token) internal view returns (string memory) {
        // Low-level call so non-conformant ERC20s can't brick proposal creation.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        if (ok && data.length >= 32) {
            return abi.decode(data, (string));
        }
        return "TKN";
    }

    function _deployERC20Positions(
        address collateralToken1,
        address collateralToken2,
        bytes32 conditionId_,
        string[] memory tokenNames
    ) internal returns (address[] memory wrapped1155, bytes[] memory data) {
        wrapped1155 = new address[](4);
        data = new bytes[](4);
        for (uint256 j = 0; j < 4; j++) {
            // Outcomes 0,1 are YES/NO for collateral1; 2,3 are YES/NO for collateral2.
            // Both YES and NO share the same indexSet position (1 << 0 for first collateral,
            // 1 << 1 for second). This matches Seer's encoding so split/merge interop works.
            uint256 indexSet = 1 << (j < 2 ? j : (j - 2));
            bytes32 collectionId =
                conditionalTokens.getCollectionId(bytes32(0), conditionId_, indexSet);
            address collateral = j < 2 ? collateralToken1 : collateralToken2;
            uint256 tokenId = conditionalTokens.getPositionId(collateral, collectionId);

            if (bytes(tokenNames[j]).length == 0) revert MissingTokenName();
            bytes memory tokenData = _encodeWrapperMetadata(tokenNames[j]);

            address wrapper = wrapped1155Factory.requireWrapped1155(
                address(conditionalTokens), tokenId, tokenData
            );
            wrapped1155[j] = wrapper;
            data[j] = tokenData;
        }
    }

    /// @dev Matches Seer's Wrapped1155 metadata encoding (name32 || symbol32 || uint8 decimals).
    function _encodeWrapperMetadata(string memory name) internal pure returns (bytes memory) {
        return abi.encodePacked(_toString31(name), _toString31(name), uint8(18));
    }

    /// @dev Encodes a short string (<32 bytes) as a Solidity-storage short string.
    /// Copied from Seer/Gnosis 1155-to-20.
    function _toString31(string memory value) internal pure returns (bytes32 encodedString) {
        uint256 length = bytes(value).length;
        require(length < 32, "string too long");

        assembly {
            encodedString := mload(add(value, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - length) << 3));
        encodedString = encodedString & mask;
        encodedString = encodedString | bytes32(length << 1);
    }
}
