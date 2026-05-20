// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {FAOFutarchyFactory} from "../../src/FAOFutarchyFactory.sol";

/// @title LegitProposer
/// @notice Forge-script agent for phase-5 validation. Submits a single legitimate
/// candidate proposal via FAOFutarchyFactory.createProposal with varied metadata.
///
/// Phase-5 driver (`script/agents/run_phase5.sh`) loops this script with random
/// SEED env var to generate a steady stream of proposals at chosen cadence.
///
/// Required env:
///   PRIVATE_KEY         submitter EOA
///   FUTARCHY_FACTORY    deployed FAOFutarchyFactory
///   FAO_TOKEN           collateralToken1
///   WETH                collateralToken2
///   SEED                uint256 used to vary marketName / description
///
/// Usage:
///   SEED=$RANDOM forge script script/agents/LegitProposer.s.sol \
///     --rpc-url $SEPOLIA_RPC --broadcast -vvv
contract LegitProposer is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory_ = vm.envAddress("FUTARCHY_FACTORY");
        address fao = vm.envAddress("FAO_TOKEN");
        address weth = vm.envAddress("WETH");
        uint256 seed = vm.envUint("SEED");

        string memory marketName = _name(seed);
        string memory description = _description(seed);

        vm.startBroadcast(pk);
        FAOFutarchyFactory.CreateProposalParams memory params = FAOFutarchyFactory.CreateProposalParams({
            marketName: marketName,
            description: description,
            collateralToken1: fao,
            collateralToken2: weth
        });
        address proposal = FAOFutarchyFactory(factory_).createProposal(params);
        vm.stopBroadcast();

        console2.log("[LegitProposer] proposal=", proposal);
        console2.log("[LegitProposer] name=", marketName);
        console2.log("[LegitProposer] description=", description);
    }

    function _name(uint256 seed) internal pure returns (string memory) {
        // 5 prototypical proposal subjects.
        string[5] memory prefixes = [
            "Should we deploy",
            "Should we deprecate",
            "Should we increase",
            "Should we acquire",
            "Should we rebrand"
        ];
        string[5] memory subjects = ["feature-x?", "module-y?", "rate-z?", "asset-w?", "product-v?"];
        return string.concat(prefixes[seed % 5], " ", subjects[(seed / 5) % 5]);
    }

    function _description(uint256 seed) internal view returns (string memory) {
        return string.concat(
            "Phase-5 randomized proposal seed=",
            vm.toString(seed),
            ". TWAP futarchy decision over 1h window starting 1h after promote."
        );
    }
}
