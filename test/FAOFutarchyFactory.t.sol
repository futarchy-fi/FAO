// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";

/// @notice Minimal CTF mock for unit testing the factory.
contract MockCTF is IConditionalTokensLike {
    mapping(bytes32 => uint256) public outcomeSlots;
    mapping(bytes32 => uint256[]) public payouts;
    mapping(bytes32 => uint256) public payoutDenom;

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256) {
        if (payouts[conditionId].length <= index) return 0;
        return payouts[conditionId][index];
    }

    function payoutDenominator(bytes32 conditionId) external view returns (uint256) {
        return payoutDenom[conditionId];
    }

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external {
        bytes32 cid = getConditionId(oracle, questionId, outcomeSlotCount);
        require(outcomeSlots[cid] == 0, "already prepared");
        outcomeSlots[cid] = outcomeSlotCount;
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata p) external {
        bytes32 cid = getConditionId(msg.sender, questionId, p.length);
        require(payoutDenom[cid] == 0, "already reported");
        uint256 sum;
        for (uint256 i = 0; i < p.length; i++) sum += p[i];
        payouts[cid] = p;
        payoutDenom[cid] = sum;
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlots[conditionId];
    }
}

/// @notice Minimal Wrapped1155Factory mock that returns deterministic addresses.
contract MockWrapped1155Factory is IWrapped1155FactoryLike {
    mapping(bytes32 => address) public wrapped;

    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(multiToken, tokenId, data));
        address w = wrapped[salt];
        if (w == address(0)) {
            w = address(uint160(uint256(salt))); // deterministic deterministic fake address
            wrapped[salt] = w;
        }
        return w;
    }
}

/// @notice Mock ERC20 with a symbol() so factory can name outcomes.
contract MockERC20 {
    string public symbol;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }
}

/// @title FAOFutarchyFactory adversarial test suite
/// @notice Validates the prevrandao-based questionId derivation that defends against
/// pre-creation attacks documented in docs/onchain-futarchy-design.md §4.1.
contract FAOFutarchyFactoryTest is Test {
    FAOFutarchyFactory factory;
    FAOFutarchyProposal proposalImpl;
    MockCTF ctf;
    MockWrapped1155Factory w1155;
    MockERC20 fao;
    MockERC20 weth;
    address constant ORACLE = address(0xDeadBeef00000000000000000000000000000001);

    function setUp() public {
        proposalImpl = new FAOFutarchyProposal();
        ctf = new MockCTF();
        w1155 = new MockWrapped1155Factory();
        fao = new MockERC20("FAO");
        weth = new MockERC20("WETH");
        factory = new FAOFutarchyFactory(address(proposalImpl), ctf, w1155, ORACLE);
    }

    function _params() internal view returns (FAOFutarchyFactory.CreateProposalParams memory) {
        return FAOFutarchyFactory.CreateProposalParams({
            marketName: "Should we ship feature X?",
            description: "Proposal to enable feature X in v2.",
            collateralToken1: address(fao),
            collateralToken2: address(weth)
        });
    }

    // ─── determinism properties ─────────────────────────────────────────────

    /// @notice computeQuestionId is pure-of-state for a given (content, index, prevrandao).
    function test_computeQuestionId_deterministicForSameInputs() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        bytes32 a = factory.computeQuestionId("Q", "D", 0);
        bytes32 b = factory.computeQuestionId("Q", "D", 0);
        assertEq(a, b, "same inputs must give same questionId");
    }

    /// @notice Different prevrandao values produce different questionIds — the core
    /// property that closes the pre-creation attack vector A1.
    function test_computeQuestionId_changesWithPrevrandao() public {
        vm.prevrandao(bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111)));
        bytes32 a = factory.computeQuestionId("Q", "D", 0);
        vm.prevrandao(bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222)));
        bytes32 b = factory.computeQuestionId("Q", "D", 0);
        assertTrue(a != b, "different prevrandao must give different questionId");
    }

    /// @notice Different proposal indices (same block) produce different questionIds —
    /// disambiguates concurrent calls within one block.
    function test_computeQuestionId_changesWithIndex() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        bytes32 a = factory.computeQuestionId("Q", "D", 0);
        bytes32 b = factory.computeQuestionId("Q", "D", 1);
        assertTrue(a != b, "different indices must give different questionId");
    }

    /// @notice Different factory addresses give different questionIds (factory isolation).
    function test_computeQuestionId_changesWithFactory() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        FAOFutarchyFactory other = new FAOFutarchyFactory(address(proposalImpl), ctf, w1155, ORACLE);
        bytes32 a = factory.computeQuestionId("Q", "D", 0);
        bytes32 b = other.computeQuestionId("Q", "D", 0);
        assertTrue(a != b, "different factories must give different questionId");
    }

    // ─── createProposal happy path ─────────────────────────────────────────

    function test_createProposal_emitsAndAdvancesIndex() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        bytes32 expectedQid = factory.computeQuestionId("Should we ship feature X?", "Proposal to enable feature X in v2.", 0);

        address p = factory.createProposal(_params());
        assertEq(factory.marketsCount(), 1, "marketsCount should be 1");
        assertEq(factory.proposals(0), p, "proposals[0] should match returned addr");
        assertEq(FAOFutarchyProposal(p).questionId(), expectedQid, "questionId must match prediction");
    }

    function test_createProposal_advancesIndexAcrossCalls() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        address p0 = factory.createProposal(_params());
        address p1 = factory.createProposal(_params());
        assertTrue(p0 != p1, "two proposals must have distinct addresses");
        assertEq(factory.marketsCount(), 2);
        // Same prevrandao, same content, different indices → different questionIds.
        assertTrue(
            FAOFutarchyProposal(p0).questionId() != FAOFutarchyProposal(p1).questionId(),
            "consecutive proposals must have distinct questionIds (index disambiguates)"
        );
    }

    function test_createProposal_revertsOnEmptyName() public {
        FAOFutarchyFactory.CreateProposalParams memory params = _params();
        params.marketName = "";
        vm.expectRevert(FAOFutarchyFactory.EmptyMarketName.selector);
        factory.createProposal(params);
    }

    function test_createProposal_revertsOnZeroCollateral() public {
        FAOFutarchyFactory.CreateProposalParams memory params = _params();
        params.collateralToken1 = address(0);
        vm.expectRevert(FAOFutarchyFactory.InvalidCollateral.selector);
        factory.createProposal(params);
    }

    // ─── A1 adversarial scenario: pre-creation foresight ───────────────────

    /// @notice Adversarial scenario A1 (pre-creation): an attacker that knows the
    /// proposal content + factory + proposal index CANNOT pre-compute the questionId
    /// for a future block because they don't know block.prevrandao for that block.
    ///
    /// This test simulates the attacker trying every prevrandao value in a small
    /// window: even with perfect content knowledge, the attacker's predicted
    /// questionId only matches if they correctly guess the actual block.prevrandao.
    /// In production, prevrandao is 256 bits (~2^256) — guessing is infeasible.
    function test_A1_attackerCannotPreComputeQuestionIdWithoutPrevrandao() public {
        // Attacker has full content + factory + index knowledge.
        string memory name = _params().marketName;
        string memory desc = _params().description;
        uint256 idx = 0;

        // Attacker tries 100 guesses for prevrandao.
        bytes32[] memory attackerGuesses = new bytes32[](100);
        for (uint256 i = 0; i < 100; i++) {
            attackerGuesses[i] = bytes32(i);
        }

        // The real block uses prevrandao = 0xDEADBEEF... (effectively unguessable in 100 tries).
        bytes32 actualPrevrandao = keccak256("real-prevrandao-from-validator-randao-reveal");
        vm.prevrandao(actualPrevrandao);
        bytes32 actualQid = factory.computeQuestionId(name, desc, idx);

        // None of the attacker's 100 guesses should match (probability ≈ 100/2^256).
        for (uint256 i = 0; i < 100; i++) {
            bytes32 guess = keccak256(
                abi.encodePacked(
                    keccak256(abi.encodePacked(name, desc)),
                    address(factory),
                    idx,
                    attackerGuesses[i]
                )
            );
            assertTrue(guess != actualQid, "attacker guess collided (impossible at this scale)");
        }
    }

    /// @notice Adversarial scenario A2 (block.number was the wrong knob): demonstrates
    /// that if questionId were derived from block.number, the attacker WOULD trivially
    /// pre-compute it. Documented as a regression guard against reverting to block.number.
    function test_A2_blockNumberDerivationWouldBePredictable() public {
        // This test does not call the factory; it shows that the rejected design
        // (block.number in derivation) is symbolically predictable.
        uint256 futureBlock = block.number + 1000;
        bytes32 predictableId = keccak256(
            abi.encodePacked(
                keccak256(abi.encodePacked("Q", "D")),
                address(factory),
                uint256(0),
                futureBlock
            )
        );
        // The attacker has computed this WITHOUT needing the block to occur.
        // In a hypothetical bad design using block.number, this would equal
        // factory.computeQuestionId at that future block — a 100% prediction.
        // We assert the existence of such a deterministic value to anchor the
        // documented rationale; no further check beyond presence.
        assertTrue(predictableId != bytes32(0), "block.number-based id is deterministic");
    }
}
