// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";

contract SymbolicWETH is IERC20 {
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOW");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @custom:spec INV-ARB-001, INV-ARB-002, INV-ARB-004 — arbitration invariants.
/// Halmos-checkable symbolic tests for the invariants listed in
/// `audit/specs/INVARIANTS.md`.
contract FutarchyArbitrationSymbolic is Test {
    FutarchyArbitration internal arb;

    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CREATOR_ONE = address(0xA11CE);
    address internal constant CREATOR_TWO = address(0xB0B);
    address internal constant CREATOR_THREE = address(0xCAFE);
    address internal constant YES_BIDDER = address(0x1111);
    address internal constant NO_BIDDER = address(0x2222);
    address internal constant CALLER = address(0x3333);

    function setUp() public {
        SymbolicWETH wethImpl = new SymbolicWETH();
        vm.etch(WETH, address(wethImpl).code);

        arb = new FutarchyArbitration();

        SymbolicWETH(WETH).mint(YES_BIDDER, 10 ether);
        SymbolicWETH(WETH).mint(NO_BIDDER, 10 ether);

        vm.prank(YES_BIDDER);
        SymbolicWETH(WETH).approve(address(arb), type(uint256).max);
        vm.prank(NO_BIDDER);
        SymbolicWETH(WETH).approve(address(arb), type(uint256).max);
    }

    /// @custom:spec INV-ARB-001 — See audit/specs/INVARIANTS.md.
    /// `nextProposalId` is monotone and auto ids below it exist.
    function check_INV_ARB_001_idMonotone(
        uint16 firstMinBond,
        uint16 secondMinBond,
        uint16 explicitIdDelta
    ) public {
        vm.assume(firstMinBond >= 1 && firstMinBond <= 100);
        vm.assume(secondMinBond >= 1 && secondMinBond <= 100);
        vm.assume(explicitIdDelta >= 1 && explicitIdDelta <= 100);

        uint256 initialNext = arb.nextProposalId();

        vm.prank(CREATOR_ONE);
        uint256 firstId = arb.createProposal(uint256(firstMinBond));
        uint256 afterFirst = arb.nextProposalId();

        assertEq(firstId, initialNext);
        assertEq(afterFirst, initialNext + 1);
        assertGt(afterFirst, initialNext);

        FutarchyArbitration.Proposal memory first = arb.getProposal(firstId);
        assertTrue(first.exists);
        assertLt(firstId, afterFirst);

        vm.prank(CREATOR_TWO);
        uint256 secondId = arb.createProposal(uint256(secondMinBond));
        uint256 afterSecond = arb.nextProposalId();

        assertEq(secondId, afterFirst);
        assertEq(afterSecond, afterFirst + 1);
        assertGt(afterSecond, afterFirst);

        first = arb.getProposal(firstId);
        FutarchyArbitration.Proposal memory second = arb.getProposal(secondId);
        assertTrue(first.exists);
        assertTrue(second.exists);
        assertLt(firstId, afterSecond);
        assertLt(secondId, afterSecond);

        uint256 explicitId = afterSecond + uint256(explicitIdDelta);
        vm.prank(CREATOR_THREE);
        uint256 returnedId = arb.createProposalWithId(explicitId, uint256(firstMinBond));
        uint256 afterExplicit = arb.nextProposalId();

        assertEq(returnedId, explicitId);
        assertEq(afterExplicit, afterSecond);
        assertGe(afterExplicit, afterSecond);
        FutarchyArbitration.Proposal memory explicit = arb.getProposal(explicitId);
        assertTrue(explicit.exists);
    }

    /// @custom:spec INV-ARB-002 — See audit/specs/INVARIANTS.md.
    /// Once settlement is reached, state remains SETTLED and accepted is immutable.
    function check_INV_ARB_002_settledMonotone(uint16 minBond, bool settleNo) public {
        vm.assume(minBond >= 1 && minBond <= 100);

        vm.prank(CREATOR_ONE);
        uint256 proposalId = arb.createProposal(uint256(minBond));

        vm.prank(YES_BIDDER);
        arb.placeYesBond(proposalId, uint256(minBond));

        if (settleNo) {
            vm.prank(NO_BIDDER);
            arb.placeNoBond(proposalId);
        }

        vm.warp(block.timestamp + 2 hours);
        vm.prank(CALLER);
        arb.finalizeByTimeout(proposalId);

        FutarchyArbitration.Proposal memory settled = arb.getProposal(proposalId);
        bool acceptedAtSettlement = settled.accepted;
        assertTrue(settled.settled);
        assertEq(uint256(settled.state), uint256(FutarchyArbitration.ProposalState.SETTLED));
        assertEq(acceptedAtSettlement, !settleNo);

        vm.prank(CALLER);
        (bool finalizedAgain,) =
            address(arb).call(abi.encodeWithSignature("finalizeByTimeout(uint256)", proposalId));
        assertFalse(finalizedAgain);

        vm.prank(YES_BIDDER);
        (bool yesAgain,) = address(arb)
            .call(
                abi.encodeWithSignature(
                    "placeYesBond(uint256,uint256)", proposalId, uint256(minBond)
                )
            );
        assertFalse(yesAgain);

        vm.prank(NO_BIDDER);
        (bool noAgain,) =
            address(arb).call(abi.encodeWithSignature("placeNoBond(uint256)", proposalId));
        assertFalse(noAgain);

        vm.prank(CALLER);
        (bool tryGraduateAgain,) =
            address(arb).call(abi.encodeWithSignature("tryGraduate(uint256)", proposalId));
        assertFalse(tryGraduateAgain);

        vm.prank(CREATOR_TWO);
        arb.createProposal(uint256(minBond));

        FutarchyArbitration.Proposal memory afterWrites = arb.getProposal(proposalId);
        assertTrue(afterWrites.settled);
        assertEq(uint256(afterWrites.state), uint256(FutarchyArbitration.ProposalState.SETTLED));
        assertEq(afterWrites.accepted, acceptedAtSettlement);
    }

    /// @custom:spec INV-ARB-004 — See audit/specs/INVARIANTS.md.
    /// Every successful NO bond exactly matches the previous YES bond amount.
    function check_INV_ARB_004_matchedBondsCorrespond(uint16 yesUnits) public {
        vm.assume(yesUnits >= 1 && yesUnits <= 100);

        uint256 firstYes = uint256(yesUnits);
        uint256 replacementYes = firstYes * 2;

        vm.prank(CREATOR_ONE);
        uint256 proposalId = arb.createProposal(firstYes);

        vm.prank(YES_BIDDER);
        arb.placeYesBond(proposalId, firstYes);

        FutarchyArbitration.Proposal memory beforeFirstNo = arb.getProposal(proposalId);
        assertEq(beforeFirstNo.yesBond.amount, firstYes);

        vm.prank(NO_BIDDER);
        arb.placeNoBond(proposalId);

        FutarchyArbitration.Proposal memory afterFirstNo = arb.getProposal(proposalId);
        assertEq(afterFirstNo.noBond.amount, beforeFirstNo.yesBond.amount);
        assertEq(afterFirstNo.noBond.amount, firstYes);
        assertEq(uint256(afterFirstNo.state), uint256(FutarchyArbitration.ProposalState.NO));

        vm.prank(YES_BIDDER);
        arb.placeYesBond(proposalId, replacementYes);

        FutarchyArbitration.Proposal memory beforeSecondNo = arb.getProposal(proposalId);
        assertEq(beforeSecondNo.yesBond.amount, replacementYes);

        vm.prank(NO_BIDDER);
        arb.placeNoBond(proposalId);

        FutarchyArbitration.Proposal memory afterSecondNo = arb.getProposal(proposalId);
        assertEq(afterSecondNo.noBond.amount, beforeSecondNo.yesBond.amount);
        assertEq(afterSecondNo.noBond.amount, replacementYes);
        assertEq(uint256(afterSecondNo.state), uint256(FutarchyArbitration.ProposalState.NO));
    }
}
