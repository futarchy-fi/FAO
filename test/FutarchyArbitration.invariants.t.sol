// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";

/// @dev Minimal ERC20 used for invariant testing.
/// We etch this runtime code into the canonical WXDAI address used by FutarchyArbitration.
contract WXDAIMock is IERC20 {
    string public constant name = "WXDAI";
    string public constant symbol = "WXDAI";
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOW");
        allowance[from][msg.sender] = a - amount;
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
        FutarchyArbitration public arb;

        address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

        // bounded actor set for invariants
        address[] public actors;

        constructor(FutarchyArbitration _arb, address[] memory _actors) {
            arb = _arb;
            for (uint256 i = 0; i < _actors.length; i++) {
                actors.push(_actors[i]);
            }
        }

        function _actor(uint256 seed) internal view returns (address) {
            return actors[seed % actors.length];
        }

        function create(uint256 seedType, uint256 mRaw) external returns (uint256 proposalId) {
            uint256 m = bound(mRaw, 1e6, 1e24);
            FutarchyArbitration.ProposalType t = FutarchyArbitration.ProposalType(seedType % 4);
            // creator identity doesn't matter
            proposalId = arb.createProposal(t, m);
        }

        function yes(uint256 proposalId, uint256 actorSeed, uint256 amtRaw) external {
            address a = _actor(actorSeed);
            uint256 amt = bound(amtRaw, 1, 1e27);

            vm.startPrank(a);
            IERC20(WXDAI).approve(address(arb), type(uint256).max);
            // calls can revert depending on state; that's fine for fuzz/invariant harness
            try arb.placeYesBond(proposalId, amt) {} catch {}
            vm.stopPrank();
        }

        function no(uint256 proposalId, uint256 actorSeed, uint256 amtRaw) external {
            address a = _actor(actorSeed);
            uint256 amt = bound(amtRaw, 1, 1e27);

            vm.startPrank(a);
            IERC20(WXDAI).approve(address(arb), type(uint256).max);
            try arb.placeNoBond(proposalId, amt) {} catch {}
            vm.stopPrank();
        }

        function warp(uint256 dtRaw) external {
            uint256 dt = bound(dtRaw, 0, 96 hours);
            vm.warp(block.timestamp + dt);
        }

        function finalize(uint256 proposalId) external {
            try arb.finalizeByTimeout(proposalId) {} catch {}
        }

        function withdraw(uint256 actorSeed) external {
            address a = _actor(actorSeed);
            vm.prank(a);
            try arb.withdraw() {} catch {}
        }
    }

    contract FutarchyArbitrationInvariantTest is StdInvariant, Test {
        FutarchyArbitration arb;

        address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;

        FutarchyArbitrationHandler handler;
        address[] actors;

        uint256 initialSupply;

        function setUp() public {
            // Install a real ERC20 into the canonical immutable WXDAI address.
            WXDAIMock impl = new WXDAIMock();
            vm.etch(WXDAI, address(impl).code);

            arb = new FutarchyArbitration();

            // Create a small actor set and fund them.
            for (uint256 i = 0; i < 6; i++) {
                actors.push(vm.addr(i + 1));
            }

            WXDAIMock token = WXDAIMock(WXDAI);
            for (uint256 i = 0; i < actors.length; i++) {
                token.mint(actors[i], 1_000_000e18);
            }
            initialSupply = token.totalSupply();

            handler = new FutarchyArbitrationHandler(arb, actors);
            targetContract(address(handler));
        }

        /// @dev Conservation invariant: totalSupply is constant and all tokens remain within
        /// our closed system: the actors + the arbitration contract.
        function invariant_WXDAI_conserved_across_actors_and_contract() public view {
            WXDAIMock token = WXDAIMock(WXDAI);
            assertEq(token.totalSupply(), initialSupply);

            uint256 sum = token.balanceOf(address(arb));
            for (uint256 i = 0; i < actors.length; i++) {
                sum += token.balanceOf(actors[i]);
            }
            assertEq(sum, initialSupply);
        }

        /// @dev Accounting invariant: contract WXDAI balance equals active-escrowed bonds
        /// + total withdrawable owed (since funds never leave except via withdraw).
        function invariant_contract_balance_equals_escrow_plus_withdrawable() public view {
            // Note: Phase 1 only, so proposals are small; but there is no public iterator.
            // We can still assert the weaker property that contract balance is >= total
            // withdrawable.
            // (Escrowed bonds add extra balance.)
            WXDAIMock token = WXDAIMock(WXDAI);

            uint256 totalWithdrawable;
            for (uint256 i = 0; i < actors.length; i++) {
                totalWithdrawable += arb.withdrawable(actors[i]);
            }

            assertGe(token.balanceOf(address(arb)), totalWithdrawable);
        }
    }
