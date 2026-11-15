// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployFaoEconomicGenesis} from "../../script/DeployFaoEconomicGenesis.s.sol";
import {DeployFaoIssuanceModules} from "../../script/DeployFaoIssuanceModules.s.sol";
import {FaoGenesisDeployment} from "../../src/FaoGenesisDeployment.sol";
import {FaoToken} from "../../src/FaoToken.sol";
import {GenesisVault} from "../../src/GenesisVault.sol";

/// @notice Runs the three deployment steps as scripts, in order, on a Sepolia fork.
contract FaoIssuanceModulesScriptForkTest is Test {
    function testFork_scriptsDeployModulesRunGenesisAndBind() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        uint256 key = uint256(keccak256("fao issuance modules script fork deployer"));
        address team = makeAddr("issuance-script-team");
        vm.deal(vm.addr(key), 10 ether);
        vm.setEnv("PRIVATE_KEY", vm.toString(key));
        vm.setEnv("OPTIONS_HOLDER", vm.toString(team));
        vm.setEnv("DAO_URI", "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        vm.setEnv(
            "SPACE_METADATA_URI",
            "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        vm.setEnv(
            "VOTING_STRATEGY_METADATA_URI",
            "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc"
        );
        vm.setEnv(
            "PROPOSAL_VALIDATION_STRATEGY_METADATA_URI",
            "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd"
        );

        // Step 1: the modules, with the curve bound to the vault that step 2 will create.
        DeployFaoIssuanceModules modulesScript = new DeployFaoIssuanceModules();
        DeployFaoIssuanceModules.Modules memory m = modulesScript.run();
        assertEq(m.curve.vault(), m.predictedVault);
        assertEq(m.predictedReceipt.code.length, 0);

        // Step 2: the economic genesis, naming the curve and the two issuers.
        vm.setEnv("SALE_CURVE", vm.toString(address(m.curve)));
        vm.setEnv("OPTION_ISSUER", vm.toString(address(m.options)));
        vm.setEnv("SHORT_ISSUER", vm.toString(address(m.shorts)));
        new DeployFaoEconomicGenesis().run();

        FaoGenesisDeployment receipt = FaoGenesisDeployment(m.predictedReceipt);
        assertTrue(receipt.coreSealed());
        assertTrue(receipt.flmSealed());
        assertEq(receipt.vault(), m.predictedVault);
        GenesisVault vault = GenesisVault(payable(m.predictedVault));
        assertEq(address(vault.CURVE()), address(m.curve));
        FaoToken token = FaoToken(receipt.companyToken());
        assertEq(token.vault(), m.predictedVault);
        assertEq(token.optionIssuer(), address(m.options));
        assertEq(token.shortIssuer(), address(m.shorts));

        // Step 3: the price record, options and short facility are bound to the vault.
        vm.setEnv("GENESIS_RECEIPT", vm.toString(m.predictedReceipt));
        vm.setEnv("PRICE_BEACON", vm.toString(address(m.beacon)));
        modulesScript.bindModules();
        assertEq(address(m.beacon.vault()), m.predictedVault);
        assertEq(m.beacon.token(), address(token));
        assertEq(address(m.options.vault()), m.predictedVault);
        assertEq(address(m.shorts.vault()), m.predictedVault);
        assertEq(m.options.holder(), team);
    }
}
