// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title AttackQueueStuff
/// @notice Phase-5 adversary that creates a proposal then immediately graduates
/// it (placing YES bond ≥ requiredYes(queueLen)) to fill the graduation queue
/// with throwaway proposals, blocking legitimate proposals.
///
/// THREAT MODEL: vector A6 in docs/onchain-futarchy-design.md §2.3.
///
/// EXPECTED RESULT: requiredYes(queueLen) doubles each slot
/// (requiredYes(n) = baseX * 2^n), so cost to occupy slot n is exponential.
/// With MAX_QUEUE=3 on testnet, occupying all slots costs
/// baseX * (1 + 2 + 4) = 7 * baseX = 0.007 WETH; on mainnet with
/// MAX_QUEUE=16, cost = baseX * 65535 = 65535 ETH — economically infeasible.
///
/// Required env:
///   PRIVATE_KEY      attacker EOA
///   ARBITRATION      deployed FutarchyArbitration
///   WETH             Sepolia WETH
///   PROPOSAL_KEY     bytes32 id passed to createProposal (random suffices)
///
/// Usage:
///   PROPOSAL_KEY=$(cast keccak "$RANDOM") forge script script/agents/AttackQueueStuff.s.sol \
///     --rpc-url $SEPOLIA_RPC --broadcast
contract AttackQueueStuff is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        FutarchyArbitration arb = FutarchyArbitration(vm.envAddress("ARBITRATION"));
        IERC20 weth = IERC20(vm.envAddress("WETH"));
        uint256 proposalId = vm.envUint("PROPOSAL_KEY");

        address attacker = vm.addr(pk);
        // Use a maximum estimate — requiredYes doubles per queue slot, so try a
        // large multiplier and let revert reveal too-high.
        uint256 attemptBond = arb.requiredYes(8); // baseX * 2^8 = 256 * baseX upper bound

        console2.log("[AttackQueueStuff] attacker=", attacker);
        console2.log("[AttackQueueStuff] attempt bond=", attemptBond);
        console2.log("[AttackQueueStuff] WETH balance=", weth.balanceOf(attacker));

        vm.startBroadcast(pk);
        weth.approve(address(arb), attemptBond);
        try arb.createProposal(proposalId) {
            console2.log("[AttackQueueStuff] proposal created");
        } catch Error(string memory reason) {
            console2.log("[AttackQueueStuff] createProposal failed:", reason);
        }
        try arb.placeYesBond(proposalId, attemptBond) {
            console2.log("[AttackQueueStuff] graduated");
        } catch Error(string memory reason) {
            console2.log("[AttackQueueStuff] graduation failed (likely queue full):", reason);
        }
        vm.stopBroadcast();
    }
}
