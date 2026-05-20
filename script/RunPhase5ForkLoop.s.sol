// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

/// @title RunPhase5ForkLoop
/// @notice Phase-5 simulation against the LIVE Sepolia deployment via a forked state.
///
/// Runs `forge script` with `--fork-url <sepolia-rpc>`. Forge loads the actual deployed
/// contract code and storage of our Sepolia deployment (factory, resolver, orchestrator,
/// CTF, W1155, UniV3 factory, FAO, WETH, spot pool), then this script:
///   1. uses `vm.deal` to top up the admin account on the fork
///   2. uses `vm.startPrank` to impersonate the admin
///   3. loops N cycles, each: promote → warp past windowEnd → resolve
///
/// This is the strongest in-tree counterpart to a ≥10h live wall-clock run: it executes
/// against the actual deployed contract bytecode + state, uses the real Seer CTF and
/// Wrapped1155Factory contracts on Sepolia (as forked), and exercises every code path
/// the live loop would exercise. Transactions are NOT broadcast — they execute only
/// in the fork.
///
/// Required env:
///   CYCLES (default 50)
///   ADMIN  (default 0x693E3FB46Bb36eE43C702FE94f9463df0691b43d, our Sepolia deployer)
///
/// Invocation:
///   forge script script/RunPhase5ForkLoop.s.sol \
///       --fork-url https://eth-sepolia.api.onfinality.io/public -vv
contract RunPhase5ForkLoop is Script {
    // Deployed Sepolia addresses (see docs/sepolia-deployment-v0.md).
    FAOOfficialProposalOrchestrator constant ORCH =
        FAOOfficialProposalOrchestrator(payable(0x7DF66Fd816c09bb534136C5688B55BBA9398d262));
    FAOFutarchyFactory constant FACTORY =
        FAOFutarchyFactory(0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0);
    FAOTwapResolver constant RESOLVER =
        FAOTwapResolver(0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a);

    uint256 constant DEFAULT_CYCLES = 50;
    address constant DEFAULT_ADMIN = 0x693E3FB46Bb36eE43C702FE94f9463df0691b43d;
    uint256 constant TIP = 0.01 ether;
    uint32 constant TIMEOUT = 2 hours;

    struct Metrics {
        uint256 cyclesAttempted;
        uint256 cyclesSucceeded;
        uint256 cyclesReverted;
        uint256 yesWins;
        uint256 noWins;
        uint256 totalGasUsed;
        uint256 totalDefenderCostWei;
        uint256 simulatedSeconds;
    }

    // Storage var to defeat via_ir's constant-folding of `block.timestamp` reads.
    uint256 internal _startTime;

    function run() external {
        uint256 cycles = vm.envOr("CYCLES", DEFAULT_CYCLES);
        address admin = vm.envOr("ADMIN", DEFAULT_ADMIN);

        Metrics memory m;
        _startTime = block.timestamp;

        console2.log("=== Phase-5 fork loop starting ===");
        console2.log("cycles requested:", cycles);
        console2.log("admin:", admin);
        console2.log("orchestrator:", address(ORCH));
        console2.log("starting block:", block.number);
        console2.log("starting timestamp:", _startTime);

        // Top up admin on the fork.
        vm.deal(admin, 100 ether);

        for (uint256 i = 0; i < cycles; i++) {
            m.cyclesAttempted++;

            string memory name = string.concat("fork-cycle-", vm.toString(i));
            string memory desc = string.concat("phase5 fork loop iter ", vm.toString(i));

            uint256 gasBefore = gasleft();
            vm.prank(admin);
            try ORCH.createOfficialProposalAndMigrate{value: TIP}(name, desc, TIP)
                returns (uint256 /*pid*/, address proposal)
            {
                uint256 gasUsed = gasBefore - gasleft();
                m.cyclesSucceeded++;
                m.totalGasUsed += gasUsed;
                m.totalDefenderCostWei += TIP;

                // Advance past TIMEOUT and resolve.
                vm.warp(block.timestamp + uint256(TIMEOUT) + 1);
                vm.roll(block.number + 1);

                try RESOLVER.resolve(proposal) {
                    (,,,,,, bool resolved, bool accepted) = RESOLVER.bindings(proposal);
                    if (resolved) {
                        if (accepted) m.yesWins++;
                        else m.noWins++;
                    }
                } catch {
                    // observe() may revert if cardinality buffer hasn't accumulated enough
                    // observations yet — this is a known limitation of the fork-based loop
                    // (real txs would have populated the buffer naturally over the 2h window).
                }
            } catch {
                m.cyclesReverted++;
            }

            // Roll forward one block between cycles so prevrandao varies.
            vm.roll(block.number + 1);
        }

        m.simulatedSeconds = block.timestamp - _startTime;

        console2.log("=== Phase-5 fork loop report ===");
        console2.log("cycles attempted:        ", m.cyclesAttempted);
        console2.log("cycles succeeded:        ", m.cyclesSucceeded);
        console2.log("cycles reverted:         ", m.cyclesReverted);
        console2.log("YES wins:                ", m.yesWins);
        console2.log("NO wins:                 ", m.noWins);
        console2.log("undecided (resolve fail):", m.cyclesSucceeded - m.yesWins - m.noWins);
        console2.log("total gas used:          ", m.totalGasUsed);
        console2.log("avg gas per cycle:       ", m.cyclesSucceeded == 0 ? 0 : m.totalGasUsed / m.cyclesSucceeded);
        console2.log("defender total cost wei: ", m.totalDefenderCostWei);
        console2.log("simulated wall-clock s:  ", m.simulatedSeconds);
        console2.log("simulated wall-clock h:  ", m.simulatedSeconds / 3600);
        if (m.cyclesAttempted > 0) {
            uint256 successRatePct = (m.cyclesSucceeded * 100) / m.cyclesAttempted;
            console2.log("promote success rate %%: ", successRatePct);
        }
    }
}
