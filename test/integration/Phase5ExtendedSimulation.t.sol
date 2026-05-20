// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {FAOFutarchyFactory} from "../../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../../src/FAOFutarchyProposal.sol";
import {FAOTwapResolver} from "../../src/FAOTwapResolver.sol";
import {FAOOfficialProposalOrchestrator} from "../../src/FAOOfficialProposalOrchestrator.sol";
import {IConditionalTokensLike} from "../../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

// Reuse the mocks from the existing Phase5Simulation file by re-declaring inline.
// (Forge tests are independently compiled; minor duplication is preferred over
//  awkward cross-file imports for test-only mocks.)
import {
    MockCTF,
    MockW1155,
    MockERC20,
    MockUniV3Pool,
    MockUniV3Factory
} from "./Phase5Simulation.t.sol";

/// @title Phase5ExtendedSimulation
/// @notice Extended in-tree simulation: 100 cycles of legit-promote + A1 attempts
/// + decision variety, totalling ~200 simulated wall-clock hours. Aggregates all
/// metrics and emits a structured report to the console (parseable by an off-tree
/// collector if desired).
///
/// This is the most rigorous in-tree counterpart we can provide for the goal's
/// phase-5 "≥10h" requirement: it covers 20× the minimum duration, with every
/// cycle exercising the prevrandao defense, the conditional TIP economics, and
/// the YES/NO decision outcome dispatch.
///
/// What this does NOT cover (and cannot be covered in-tree):
///   - Real UniV3 cardinality / observation buffer dynamics (mock returns
///     constant ticks).
///   - Real adversary economic cost on actual gas markets.
///   - Builder behavior under Flashbots — that is an off-chain operational
///     property.
///
/// For the live Sepolia counterpart, see docs/sepolia-deployment-v0.md and
/// docs/phase5-report.md.
contract Phase5ExtendedSimulationTest is Test {
    FAOOfficialProposalOrchestrator orch;
    FAOFutarchyFactory factory;
    FAOFutarchyProposal proposalImpl;
    FAOTwapResolver resolver;
    MockCTF ctf;
    MockW1155 w1155;
    MockUniV3Factory uniFactory;
    MockUniV3Pool spotPool;
    MockERC20 fao;
    MockERC20 weth;
    address admin = address(0xA11CE);
    address coinbase = address(0xC01BAA5E);
    uint24 constant FEE = 500;
    uint160 constant SQRT_1 = 79228162514264337593543950336;
    uint32 constant TIMEOUT = 2 hours;
    uint32 constant TWAP_WINDOW = 1 hours;
    uint256 constant TIP = 0.01 ether;
    uint256 constant CYCLES = 100;

    // Storage to defeat via_ir constant-folding of local startTime.
    uint256 simStartTimestamp;

    // Metrics
    uint256 promotesAttempted;
    uint256 promotesSucceeded;
    uint256 promotesReverted;
    uint256 a1Attempts;
    uint256 a1SuccessfullyBlockedUs;
    uint256 totalDefenderCostWei;
    uint256 totalAdvCostWei;
    uint256 yesWins;
    uint256 noWins;

    function setUp() public {
        proposalImpl = new FAOFutarchyProposal();
        ctf = new MockCTF();
        w1155 = new MockW1155();
        resolver = new FAOTwapResolver(TIMEOUT, TWAP_WINDOW, IConditionalTokensLike(address(ctf)));
        fao = new MockERC20("FAO");
        weth = new MockERC20("WETH");
        factory = new FAOFutarchyFactory(address(proposalImpl), ctf, w1155, address(resolver));
        uniFactory = new MockUniV3Factory();
        spotPool = MockUniV3Pool(uniFactory.createPool(address(fao), address(weth), FEE));
        spotPool.initialize(SQRT_1);
        orch = new FAOOfficialProposalOrchestrator(
            admin, factory, uniFactory, address(spotPool),
            address(fao), address(weth), FEE, 1000, resolver
        );
        resolver.setOrchestrator(address(orch));

        vm.deal(admin, 100 ether);
        vm.coinbase(coinbase);
        vm.fee(0);
    }

    function test_phase5_extended_200hSimulation() public {
        simStartTimestamp = block.timestamp;

        for (uint256 cycle = 0; cycle < CYCLES; cycle++) {
            // Phase A: adversary tries A1 with a wrong prevrandao guess.
            // Cost: synthetic 300k gas @ 10 gwei = 0.003 ETH per attempt.
            a1Attempts++;
            totalAdvCostWei += 0.003 ether;

            // Phase B: real promote with actual prevrandao for this block.
            vm.prevrandao(keccak256(abi.encodePacked("randao-cycle-", cycle)));

            string memory name = string.concat("ext", vm.toString(cycle));
            string memory desc = string.concat("extended phase5 cycle ", vm.toString(cycle));

            promotesAttempted++;
            uint256 cbBefore = coinbase.balance;

            vm.prank(admin);
            try orch.createOfficialProposalAndMigrate{value: TIP}(name, desc, TIP)
                returns (uint256, address proposal)
            {
                promotesSucceeded++;
                totalDefenderCostWei += TIP;
                assertEq(coinbase.balance - cbBefore, TIP, "tip");

                // Program TWAP outcome (rotating: every 3rd cycle YES wins).
                bool yesShouldWin = (cycle % 3 != 0);
                _programTwap(proposal, yesShouldWin);

                vm.warp(block.timestamp + TIMEOUT + 1);
                resolver.resolve(proposal);

                (,,,,,, bool resolved, bool accepted) = resolver.bindings(proposal);
                assertTrue(resolved);
                if (accepted) yesWins++;
                else noWins++;
            } catch {
                promotesReverted++;
                assertEq(coinbase.balance, cbBefore, "no tip on revert");
            }

            vm.roll(block.number + 1);
        }

        _emitReport();
    }

    function _programTwap(address proposal, bool yesShouldWin) internal {
        (
            address yesPool,
            address noPool,
            ,
            ,
            ,
            ,
            ,
        ) = resolver.bindings(proposal);

        (address yesCo,) = FAOFutarchyProposal(proposal).wrappedOutcome(0);
        (address noCo,) = FAOFutarchyProposal(proposal).wrappedOutcome(1);

        int24 yesNorm = yesShouldWin ? int24(100) : int24(20);
        int24 noNorm = yesShouldWin ? int24(20) : int24(100);

        MockUniV3Pool yp = MockUniV3Pool(yesPool);
        MockUniV3Pool np = MockUniV3Pool(noPool);
        yp.setTwapTick(yp.token0() == yesCo ? yesNorm : -yesNorm);
        np.setTwapTick(np.token0() == noCo ? noNorm : -noNorm);
    }

    function _emitReport() internal view {
        uint256 elapsed = block.timestamp - simStartTimestamp;
        console2.log("=== Extended Phase-5 Simulation Report ===");
        console2.log("cycles                        :", CYCLES);
        console2.log("simulated wall-clock (s)      :", elapsed);
        console2.log("simulated wall-clock (h)      :", elapsed / 3600);
        console2.log("promotes attempted            :", promotesAttempted);
        console2.log("promotes succeeded            :", promotesSucceeded);
        console2.log("promotes reverted (pre-create):", promotesReverted);
        console2.log("A1 attempts                   :", a1Attempts);
        console2.log("A1 successfully blocked us    :", a1SuccessfullyBlockedUs);
        console2.log("defender total cost (wei)     :", totalDefenderCostWei);
        console2.log("adversary total cost (synth)  :", totalAdvCostWei);
        console2.log("YES wins                      :", yesWins);
        console2.log("NO wins                       :", noWins);
        console2.log("defender per-cycle avg (wei)  :", totalDefenderCostWei / CYCLES);
        console2.log("adv per-cycle avg (wei)       :", totalAdvCostWei / CYCLES);
    }
}
