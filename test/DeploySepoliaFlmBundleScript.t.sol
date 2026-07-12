// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeploySepoliaFlmBundle} from "../script/DeploySepoliaFlmBundle.s.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";

contract DeploySepoliaFlmBundleHarness is DeploySepoliaFlmBundle {
    function baseCodes() external view returns (bytes[] memory) {
        return _baseCodes();
    }

    function requireFreshDeployer(uint256 privateKey, address deployer, address w0Deployer)
        external
        view
    {
        _requireFreshDeployer(privateKey, deployer, w0Deployer);
    }
}

contract DeploySepoliaFlmBundleScriptTest is Test {
    DeploySepoliaFlmBundleHarness private script;

    function setUp() public {
        address target = makeAddr("loader script");
        vm.etch(
            target,
            vm.getDeployedCode(
                "test/DeploySepoliaFlmBundleScript.t.sol:DeploySepoliaFlmBundleHarness"
            )
        );
        script = DeploySepoliaFlmBundleHarness(target);
    }

    function test_loaderReadsTheFivePinnedCreationBlobs() public view {
        bytes[] memory codes = script.baseCodes();
        assertEq(codes.length, 5);
        assertEq(keccak256(codes[0]), FlmCodeHashes.RELAY);
        assertEq(keccak256(codes[1]), FlmCodeHashes.ADAPTER);
        assertEq(keccak256(codes[2]), FlmCodeHashes.GUARD);
        assertEq(keccak256(codes[3]), FlmCodeHashes.ROUTER);
        assertEq(keccak256(codes[4]), FlmCodeHashes.MANAGER);
    }

    function test_loaderRejectsKnownOperatorAndReusedW0Deployer() public {
        address forbidden = 0x693E3FB46Bb36eE43C702FE94f9463df0691b43d;
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaFlmBundle.InvalidDeployer.selector, forbidden)
        );
        script.requireFreshDeployer(1, forbidden, address(0xB0));

        address reused = address(0xA11CE);
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaFlmBundle.InvalidDeployer.selector, reused)
        );
        script.requireFreshDeployer(1, reused, reused);
    }

    function test_loaderRequiresVirginDeployerNonce() public {
        address virgin = makeAddr("virgin FLM deployer");
        vm.setNonce(virgin, 0);
        script.requireFreshDeployer(1, virgin, address(0xB0));

        address used = makeAddr("used FLM deployer");
        vm.setNonce(used, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploySepoliaFlmBundle.InvalidDeployerNonce.selector, used, uint64(1)
            )
        );
        script.requireFreshDeployer(1, used, address(0xB0));
    }
}
