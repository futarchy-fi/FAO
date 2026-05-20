// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title AttackBondGrief
/// @notice Phase-5 adversary that flips an active proposal's bond from YES->NO
/// (or vice versa) to delay timeout settlement.
///
/// THREAT MODEL: vector A5 in docs/onchain-futarchy-design.md §2.3.
///
/// EXPECTED RESULT: each flip cost = 2x the previous opposing bond, so the
/// adversary's cost grows exponentially per round. Even an extremely well-funded
/// adversary can only delay timeout for a few rounds before bond size eats
/// their treasury.
///
/// Required env:
///   PRIVATE_KEY     attacker EOA (must hold sufficient WETH)
///   ARBITRATION     deployed FutarchyArbitration
///   WETH            Sepolia WETH
///   PROPOSAL_ID     uint256 id of target proposal
///   FLIP_DIRECTION  "YES" or "NO" (case sensitive)
///
/// Usage:
///   FLIP_DIRECTION=NO forge script script/agents/AttackBondGrief.s.sol \
///     --rpc-url $SEPOLIA_RPC --broadcast
contract AttackBondGrief is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        FutarchyArbitration arb = FutarchyArbitration(vm.envAddress("ARBITRATION"));
        IERC20 weth = IERC20(vm.envAddress("WETH"));
        uint256 proposalId = vm.envUint("PROPOSAL_ID");
        string memory direction = vm.envString("FLIP_DIRECTION");

        address attacker = vm.addr(pk);
        uint256 wethBalance = weth.balanceOf(attacker);
        console2.log("[AttackBondGrief] attacker=", attacker);
        console2.log("[AttackBondGrief] WETH balance=", wethBalance);
        console2.log("[AttackBondGrief] proposalId=", proposalId);
        console2.log("[AttackBondGrief] direction=", direction);

        vm.startBroadcast(pk);
        weth.approve(address(arb), type(uint256).max);
        if (keccak256(bytes(direction)) == keccak256(bytes("YES"))) {
            // Place YES bond. arb.placeYesBond will revert if amount < 2x current NO.
            // For phase-5 logging we attempt and let revert reveal the required amount.
            try arb.placeYesBond(proposalId, wethBalance) {
                console2.log("[AttackBondGrief] YES flip success at", wethBalance);
            } catch Error(string memory reason) {
                console2.log("[AttackBondGrief] YES flip failed:", reason);
            }
        } else {
            try arb.placeNoBond(proposalId) {
                console2.log("[AttackBondGrief] NO matches success");
            } catch Error(string memory reason) {
                console2.log("[AttackBondGrief] NO matches failed:", reason);
            }
        }
        vm.stopBroadcast();
    }
}
