// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";

/// @dev Minimal ERC20 installed at the canonical WETH address used by FutarchyArbitration.
contract WETHMock is IERC20 {
    string public constant name = "WETH";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;

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
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "ALLOW");
        allowance[from][msg.sender] = approved - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BAL");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

    contract FutarchyArbitrationHandler is Test {
        FutarchyArbitration public immutable ARB;

        uint256 internal constant MAX_INITIAL_BOND = 5e14;
        uint256 internal constant MAX_BOND_EXTRA = 1e15;
        uint256 internal constant TIMEOUT = 2 hours;

        address[] internal actors;
        uint256[] internal proposalIds;
        uint256[] internal settledProposalIds;

        mapping(uint256 => bool) internal settledObserved;
        mapping(uint256 => bool) public settledAccepted;

        uint256 public maxObservedNextProposalId;
        bool public sawNextProposalIdRegression;
        bool public sawAutoCreateStepViolation;
        bool public sawSettledRegression;

        constructor(FutarchyArbitration arb_, address[] memory actors_) {
            ARB = arb_;
            maxObservedNextProposalId = arb_.nextProposalId();

            for (uint256 i = 0; i < actors_.length; i++) {
                actors.push(actors_[i]);
            }
        }

        function createProposal(uint256 minActivationBondSeed) external {
            uint256 preNext = ARB.nextProposalId();
            uint256 minActivationBond = bound(minActivationBondSeed, 1, MAX_INITIAL_BOND);

            try ARB.createProposal(minActivationBond) returns (uint256 proposalId) {
                proposalIds.push(proposalId);

                uint256 postNext = ARB.nextProposalId();
                if (proposalId != preNext || postNext != preNext + 1) {
                    sawAutoCreateStepViolation = true;
                }

                _observeProposal(proposalId);
            } catch {}

            _observeNextProposalId();
            _observeSettledProposals();
        }

        function createExplicitProposal(uint256 proposalIdSeed, uint256 minActivationBondSeed)
            external
        {
            uint256 explicitId = ARB.nextProposalId() + 1 + (proposalIdSeed % 64);
            uint256 minActivationBond = bound(minActivationBondSeed, 1, MAX_INITIAL_BOND);

            try ARB.createProposalWithId(explicitId, minActivationBond) returns (
                uint256 proposalId
            ) {
                proposalIds.push(proposalId);
                _observeProposal(proposalId);
            } catch {}

            _observeNextProposalId();
            _observeSettledProposals();
        }

        function placeYesBond(uint256 proposalSeed, uint256 actorSeed, uint256 amountSeed)
            external
        {
            if (proposalIds.length == 0) return;

            uint256 proposalId = _proposalId(proposalSeed);
            FutarchyArbitration.Proposal memory p = _proposal(proposalId);

            uint256 amount;
            if (p.state == FutarchyArbitration.ProposalState.INACTIVE) {
                amount = bound(
                    amountSeed, p.minActivationBond, p.minActivationBond + MAX_BOND_EXTRA
                );
            } else if (p.state == FutarchyArbitration.ProposalState.NO) {
                uint256 minFlip = p.noBond.amount * 2;
                if (p.minActivationBond > minFlip) minFlip = p.minActivationBond;
                amount = bound(amountSeed, minFlip, minFlip + MAX_BOND_EXTRA);
            } else {
                return;
            }

            address actor = _actor(actorSeed);
            vm.prank(actor);
            try ARB.placeYesBond(proposalId, amount) {} catch {}

            _observeProposal(proposalId);
            _observeNextProposalId();
            _observeSettledProposals();
        }

        function placeNoBond(uint256 proposalSeed, uint256 actorSeed) external {
            if (proposalIds.length == 0) return;

            uint256 proposalId = _proposalId(proposalSeed);
            address actor = _actor(actorSeed);

            vm.prank(actor);
            try ARB.placeNoBond(proposalId) {} catch {}

            _observeProposal(proposalId);
            _observeNextProposalId();
            _observeSettledProposals();
        }

        function advanceTime(uint256 secondsSeed) external {
            uint256 dt = bound(secondsSeed, 0, 4 hours);
            vm.warp(block.timestamp + dt);

            _observeNextProposalId();
            _observeSettledProposals();
        }

        function finalizeByTimeout(uint256 proposalSeed) external {
            if (proposalIds.length == 0) return;

            uint256 proposalId = _proposalId(proposalSeed);
            try ARB.finalizeByTimeout(proposalId) {} catch {}

            _observeProposal(proposalId);
            _observeNextProposalId();
            _observeSettledProposals();
        }

        function settleYesByTimeout(uint256 actorSeed, uint256 minActivationBondSeed) external {
            if (ARB.safetyModeActive()) return;

            uint256 minActivationBond = bound(minActivationBondSeed, 1, MAX_INITIAL_BOND);
            uint256 proposalId;

            try ARB.createProposal(minActivationBond) returns (uint256 createdId) {
                proposalId = createdId;
                proposalIds.push(proposalId);
            } catch {
                _observeNextProposalId();
                _observeSettledProposals();
                return;
            }

            address actor = _actor(actorSeed);
            vm.prank(actor);
            try ARB.placeYesBond(proposalId, minActivationBond) {} catch {}

            vm.warp(block.timestamp + TIMEOUT);
            try ARB.finalizeByTimeout(proposalId) {} catch {}

            _observeProposal(proposalId);
            _observeNextProposalId();
            _observeSettledProposals();
        }

        function settleNoByTimeout(
            uint256 yesActorSeed,
            uint256 noActorSeed,
            uint256 minActivationBondSeed
        ) external {
            uint256 minActivationBond = bound(minActivationBondSeed, 1, MAX_INITIAL_BOND);
            uint256 proposalId;

            try ARB.createProposal(minActivationBond) returns (uint256 createdId) {
                proposalId = createdId;
                proposalIds.push(proposalId);
            } catch {
                _observeNextProposalId();
                _observeSettledProposals();
                return;
            }

            vm.prank(_actor(yesActorSeed));
            try ARB.placeYesBond(proposalId, minActivationBond) {} catch {}

            vm.prank(_actor(noActorSeed));
            try ARB.placeNoBond(proposalId) {} catch {}

            vm.warp(block.timestamp + TIMEOUT);
            try ARB.finalizeByTimeout(proposalId) {} catch {}

            _observeProposal(proposalId);
            _observeNextProposalId();
            _observeSettledProposals();
        }

        function withdraw(uint256 actorSeed) external {
            address actor = _actor(actorSeed);

            vm.prank(actor);
            try ARB.withdraw() {} catch {}

            _observeNextProposalId();
            _observeSettledProposals();
        }

        function proposalCount() external view returns (uint256) {
            return proposalIds.length;
        }

        function proposalIdAt(uint256 index) external view returns (uint256) {
            return proposalIds[index];
        }

        function settledCount() external view returns (uint256) {
            return settledProposalIds.length;
        }

        function settledIdAt(uint256 index) external view returns (uint256) {
            return settledProposalIds[index];
        }

        function actorCount() external view returns (uint256) {
            return actors.length;
        }

        function actorAt(uint256 index) external view returns (address) {
            return actors[index];
        }

        function _actor(uint256 seed) internal view returns (address) {
            return actors[seed % actors.length];
        }

        function _proposalId(uint256 seed) internal view returns (uint256) {
            return proposalIds[seed % proposalIds.length];
        }

        function _proposal(uint256 proposalId)
            internal
            view
            returns (FutarchyArbitration.Proposal memory)
        {
            return ARB.getProposal(proposalId);
        }

        function _observeNextProposalId() internal {
            uint256 current = ARB.nextProposalId();
            if (current < maxObservedNextProposalId) {
                sawNextProposalIdRegression = true;
            } else {
                maxObservedNextProposalId = current;
            }
        }

        function _observeProposal(uint256 proposalId) internal {
            FutarchyArbitration.Proposal memory p = ARB.getProposal(proposalId);
            if (p.settled && !settledObserved[proposalId]) {
                settledObserved[proposalId] = true;
                settledAccepted[proposalId] = p.accepted;
                settledProposalIds.push(proposalId);
            }
        }

        function _observeSettledProposals() internal {
            for (uint256 i = 0; i < settledProposalIds.length; i++) {
                uint256 proposalId = settledProposalIds[i];
                FutarchyArbitration.Proposal memory p = ARB.getProposal(proposalId);

                if (!p.settled || p.state != FutarchyArbitration.ProposalState.SETTLED) {
                    sawSettledRegression = true;
                }
                if (p.accepted != settledAccepted[proposalId]) {
                    sawSettledRegression = true;
                }
            }
        }
    }

    /// @custom:spec INV-ARB-001 — see audit/specs/INVARIANTS.md.
    contract FutarchyArbitrationInvariantTest is StdInvariant, Test {
        address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

        FutarchyArbitration internal arb;
        FutarchyArbitrationHandler internal handler;
        WETHMock internal weth;

        uint256 internal initialWethSupply;

        function setUp() public {
            WETHMock impl = new WETHMock();
            vm.etch(WETH, address(impl).code);
            weth = WETHMock(WETH);

            arb = new FutarchyArbitration();

            address[] memory actors = new address[](6);
            for (uint256 i = 0; i < actors.length; i++) {
                actors[i] = address(uint160(uint256(keccak256(abi.encode("arb-actor", i)))));
                weth.mint(actors[i], 1_000_000e18);

                vm.prank(actors[i]);
                weth.approve(address(arb), type(uint256).max);
            }
            initialWethSupply = weth.totalSupply();

            handler = new FutarchyArbitrationHandler(arb, actors);
            handler.settleNoByTimeout(0, 1, 1);
            handler.settleYesByTimeout(2, 1);
            targetContract(address(handler));

            bytes4[] memory selectors = new bytes4[](9);
            selectors[0] = FutarchyArbitrationHandler.createProposal.selector;
            selectors[1] = FutarchyArbitrationHandler.createExplicitProposal.selector;
            selectors[2] = FutarchyArbitrationHandler.placeYesBond.selector;
            selectors[3] = FutarchyArbitrationHandler.placeNoBond.selector;
            selectors[4] = FutarchyArbitrationHandler.advanceTime.selector;
            selectors[5] = FutarchyArbitrationHandler.finalizeByTimeout.selector;
            selectors[6] = FutarchyArbitrationHandler.settleYesByTimeout.selector;
            selectors[7] = FutarchyArbitrationHandler.settleNoByTimeout.selector;
            selectors[8] = FutarchyArbitrationHandler.withdraw.selector;
            targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        }

        /// @custom:spec INV-ARB-001 — nextProposalId is monotone and auto ids are contiguous.
        function invariant_INV_ARB_001_nextProposalIdMonotonic() public view {
            assertFalse(
                handler.sawNextProposalIdRegression(),
                "INV-ARB-001 violated: nextProposalId regressed"
            );
            assertFalse(
                handler.sawAutoCreateStepViolation(),
                "INV-ARB-001 violated: auto create did not advance exactly once"
            );

            uint256 nextProposalId = arb.nextProposalId();
            assertEq(
                nextProposalId,
                handler.maxObservedNextProposalId(),
                "INV-ARB-001 violated: handler observation stale"
            );

            for (uint256 proposalId = 1; proposalId < nextProposalId; proposalId++) {
                FutarchyArbitration.Proposal memory p = arb.getProposal(proposalId);
                assertTrue(p.exists, "INV-ARB-001 violated: auto id gap");
            }
        }

        /// @dev Existing closed-system sanity check retained for the arbitration handler.
        function invariant_WETH_conserved_across_actors_and_contract() public view {
            assertEq(weth.totalSupply(), initialWethSupply);

            uint256 sum = weth.balanceOf(address(arb));
            uint256 actorCount = handler.actorCount();
            for (uint256 i = 0; i < actorCount; i++) {
                sum += weth.balanceOf(handler.actorAt(i));
            }
            assertEq(sum, initialWethSupply);
        }

        /// @dev Existing weaker accounting check for INV-ARB-003 until the equality invariant
        /// lands.
        function invariant_contract_balance_equals_escrow_plus_withdrawable() public view {
            uint256 totalWithdrawable;
            uint256 actorCount = handler.actorCount();
            for (uint256 i = 0; i < actorCount; i++) {
                totalWithdrawable += arb.withdrawable(handler.actorAt(i));
            }

            assertGe(weth.balanceOf(address(arb)), totalWithdrawable);
        }
    }
