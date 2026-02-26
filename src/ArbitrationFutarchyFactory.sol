// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbitrationFutarchyProposal} from "./ArbitrationFutarchyProposal.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev Minimal ERC20 interface for reading symbol().
interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

/// @dev Minimal ConditionalTokens interface for condition lifecycle.
interface IConditionalTokensFactory {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256);

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
}

/// @dev Minimal Wrapped1155Factory interface for deploying ERC20 wrappers around CTF positions.
interface IWrapped1155FactoryLike {
    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address);
}

/// @title ArbitrationFutarchyFactory
/// @notice Fork of Seer's FutarchyFactory that replaces Reality.eth/Kleros with a configurable
/// CTF oracle. Creates futarchy proposal markets using the clone pattern with wrapped ERC20
/// position tokens.
///
/// Key differences from Seer's FutarchyFactory:
///   1. No Reality.eth: question IDs are derived from a sequential nonce instead of
///      posting on-chain questions.
///   2. Configurable oracle: the constructor takes an `oracle` address that becomes the
///      authorized CTF condition resolver (e.g., SnapshotExecutionProxy).
///   3. Uses ArbitrationFutarchyProposal as the clone template instead of FutarchyProposal.
///   4. CreateProposalParams is simplified — no category/lang/minBond/openingTime.
///
/// The oracle address is baked into the CTF conditionId hash:
///   conditionId = keccak256(oracle, questionId, outcomeSlotCount)
/// Only that oracle can call reportPayouts() for conditions created by this factory.
contract ArbitrationFutarchyFactory {
    using Clones for address;

    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

    struct CreateProposalParams {
        string marketName;
        address collateralToken1;
        address collateralToken2;
    }

    // ═══════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════

    /// @dev Template contract for proposal clones.
    address public immutable proposalTemplate;
    /// @dev The CTF oracle address. This is baked into conditionIds.
    address public immutable oracle;
    /// @dev Wrapped1155Factory for deploying ERC20 wrappers.
    IWrapped1155FactoryLike public immutable wrapped1155Factory;
    /// @dev Conditional Tokens Framework contract.
    IConditionalTokensFactory public immutable conditionalTokens;

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    /// @dev Proposals created by this factory.
    address[] public proposals;

    // ═══════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════

    event NewProposal(
        address indexed proposal, string marketName, bytes32 conditionId, bytes32 questionId
    );

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    /// @param _proposalTemplate Address of the ArbitrationFutarchyProposal template.
    /// @param _oracle The CTF oracle (e.g., SnapshotExecutionProxy).
    /// @param _wrapped1155Factory The Wrapped1155Factory for creating ERC20 wrappers.
    /// @param _conditionalTokens The Gnosis Conditional Tokens Framework contract.
    constructor(
        address _proposalTemplate,
        address _oracle,
        address _wrapped1155Factory,
        address _conditionalTokens
    ) {
        proposalTemplate = _proposalTemplate;
        oracle = _oracle;
        wrapped1155Factory = IWrapped1155FactoryLike(_wrapped1155Factory);
        conditionalTokens = IConditionalTokensFactory(_conditionalTokens);
    }

    // ═══════════════════════════════════════════════════════
    //  Proposal Creation
    // ═══════════════════════════════════════════════════════

    /// @notice Creates a futarchy proposal with wrapped ERC20 position tokens.
    /// @param params CreateProposalParams with market name and collateral tokens.
    /// @return The new proposal address.
    function createProposal(CreateProposalParams calldata params) external returns (address) {
        (string[] memory outcomes, string[] memory tokenNames) =
            _getOutcomesAndTokens(params.collateralToken1, params.collateralToken2);

        // Derive questionId from factory address + sequential nonce (no Reality.eth).
        bytes32 questionId_ = keccak256(abi.encodePacked(address(this), proposals.length));

        // Prepare the CTF condition with our oracle.
        bytes32 conditionId_ = _prepareCondition(questionId_, 2);

        // Deploy wrapped ERC20 position tokens.
        (address[] memory wrapped1155, bytes[] memory tokenData) = _deployERC20Positions(
            params.collateralToken1,
            params.collateralToken2,
            bytes32(0), // parentCollectionId
            conditionId_,
            tokenNames
        );

        // Clone and initialize the proposal.
        ArbitrationFutarchyProposal instance = ArbitrationFutarchyProposal(proposalTemplate.clone());

        ArbitrationFutarchyProposal.ProposalParams memory proposalParams =
            ArbitrationFutarchyProposal.ProposalParams({
                conditionId: conditionId_,
                collateralToken1: params.collateralToken1,
                collateralToken2: params.collateralToken2,
                parentCollectionId: bytes32(0),
                parentOutcome: 0,
                parentMarket: address(0),
                questionId: questionId_,
                wrapped1155: wrapped1155,
                tokenData: tokenData
            });

        instance.initialize(params.marketName, outcomes, proposalParams);

        emit NewProposal(address(instance), params.marketName, conditionId_, questionId_);

        proposals.push(address(instance));

        return address(instance);
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    function allMarkets() external view returns (address[] memory) {
        return proposals;
    }

    function marketsCount() external view returns (uint256) {
        return proposals.length;
    }

    // ═══════════════════════════════════════════════════════
    //  Internal Helpers
    // ═══════════════════════════════════════════════════════

    function _getOutcomesAndTokens(address collateralToken1, address collateralToken2)
        internal
        view
        returns (string[] memory outcomes, string[] memory tokenNames)
    {
        string memory sym1 = IERC20Symbol(collateralToken1).symbol();
        string memory sym2 = IERC20Symbol(collateralToken2).symbol();

        outcomes = new string[](4);
        outcomes[0] = string(abi.encodePacked("Yes-", sym1));
        outcomes[1] = string(abi.encodePacked("No-", sym1));
        outcomes[2] = string(abi.encodePacked("Yes-", sym2));
        outcomes[3] = string(abi.encodePacked("No-", sym2));

        tokenNames = new string[](4);
        tokenNames[0] = string(abi.encodePacked("YES_", sym1));
        tokenNames[1] = string(abi.encodePacked("NO_", sym1));
        tokenNames[2] = string(abi.encodePacked("YES_", sym2));
        tokenNames[3] = string(abi.encodePacked("NO_", sym2));
    }

    /// @dev Prepares the CTF condition and returns the conditionId.
    function _prepareCondition(bytes32 questionId_, uint256 outcomeSlotCount)
        internal
        returns (bytes32)
    {
        bytes32 conditionId_ =
            conditionalTokens.getConditionId(oracle, questionId_, outcomeSlotCount);

        if (conditionalTokens.getOutcomeSlotCount(conditionId_) == 0) {
            conditionalTokens.prepareCondition(oracle, questionId_, outcomeSlotCount);
        }

        return conditionId_;
    }

    /// @dev Wraps CTF ERC1155 positions to ERC20 tokens.
    /// Creates 4 tokens: YES/NO for each of the 2 collateral tokens.
    function _deployERC20Positions(
        address collateralToken1,
        address collateralToken2,
        bytes32 parentCollectionId,
        bytes32 conditionId_,
        string[] memory tokenNames
    ) internal returns (address[] memory wrapped1155, bytes[] memory data) {
        wrapped1155 = new address[](tokenNames.length);
        data = new bytes[](tokenNames.length);

        for (uint256 j = 0; j < 4; j++) {
            // YES/NO outcomes: indexSet 1 = YES (bit 0), indexSet 2 = NO (bit 1)
            // First two tokens are YES/NO for collateral1, last two for collateral2.
            bytes32 collectionId = conditionalTokens.getCollectionId(
                parentCollectionId, conditionId_, 1 << (j < 2 ? j : j - 2)
            );
            uint256 tokenId = conditionalTokens.getPositionId(
                j < 2 ? collateralToken1 : collateralToken2, collectionId
            );

            require(bytes(tokenNames[j]).length != 0, "Missing token name");

            bytes memory _data =
                abi.encodePacked(_toString31(tokenNames[j]), _toString31(tokenNames[j]), uint8(18));

            address _wrapped1155 =
                wrapped1155Factory.requireWrapped1155(address(conditionalTokens), tokenId, _data);

            wrapped1155[j] = _wrapped1155;
            data[j] = _data;
        }
    }

    /// @dev Encodes a short string (< 31 bytes) for Wrapped1155 token metadata.
    /// Ported from Seer's FutarchyFactory.toString31().
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
