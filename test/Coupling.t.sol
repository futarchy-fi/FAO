// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

interface IFutarchyRegistryManifestView {
    function CTF() external view returns (address);
    function PROPOSAL_IMPL() external view returns (address);
    function STACK_DEPLOYER() external view returns (address);
    function TOKEN_ARB_DEPLOYER() external view returns (address);
    function UNIV3_FACTORY() external view returns (address);
    function W1155() external view returns (address);
    function WETH() external view returns (address);
}

contract CouplingTest is Test {
    string internal constant DEFAULT_SEPOLIA_RPC = "https://ethereum-sepolia.publicnode.com";

    function testFork_activeManifestContractAddressesContainBytecode() public {
        if (!_selectSepoliaFork()) return;

        string memory manifest = vm.readFile("deployments.json");

        _assertHasCode("active.registry", vm.parseJsonAddress(manifest, ".active.registry"));
        _assertHasCode(
            "active.proposal_impl_v5", vm.parseJsonAddress(manifest, ".active.proposal_impl_v5")
        );
        _assertHasCode(
            "active.token_arb_deployer", vm.parseJsonAddress(manifest, ".active.token_arb_deployer")
        );
        _assertHasCode(
            "active.futarchy_stack_deployer",
            vm.parseJsonAddress(manifest, ".active.futarchy_stack_deployer")
        );
        _assertHasCode(
            "active.uniswap_v3_liquidity_adapter",
            vm.parseJsonAddress(manifest, ".active.uniswap_v3_liquidity_adapter")
        );

        // `operator` is an EOA in deployments.schema.json and should not
        // silently become a contract without a manifest/test update.
        address operator = vm.parseJsonAddress(manifest, ".active.operator");
        assertEq(operator.code.length, 0, "active.operator should remain an EOA");
    }

    function testFork_activeRegistryWiringMatchesManifest() public {
        if (!_selectSepoliaFork()) return;

        string memory manifest = vm.readFile("deployments.json");
        IFutarchyRegistryManifestView registry = IFutarchyRegistryManifestView(
            vm.parseJsonAddress(manifest, ".active.registry")
        );

        assertEq(
            registry.PROPOSAL_IMPL(),
            vm.parseJsonAddress(manifest, ".active.proposal_impl_v5"),
            "registry PROPOSAL_IMPL != manifest"
        );
        assertEq(
            registry.TOKEN_ARB_DEPLOYER(),
            vm.parseJsonAddress(manifest, ".active.token_arb_deployer"),
            "registry TOKEN_ARB_DEPLOYER != manifest"
        );
        assertEq(
            registry.STACK_DEPLOYER(),
            vm.parseJsonAddress(manifest, ".active.futarchy_stack_deployer"),
            "registry STACK_DEPLOYER != manifest"
        );
        assertEq(registry.WETH(), vm.parseJsonAddress(manifest, ".shared.weth"), "registry WETH != manifest");
        assertEq(registry.CTF(), vm.parseJsonAddress(manifest, ".shared.ctf"), "registry CTF != manifest");
        assertEq(
            registry.W1155(),
            vm.parseJsonAddress(manifest, ".shared.w1155_factory"),
            "registry W1155 != manifest"
        );
        assertEq(
            registry.UNIV3_FACTORY(),
            vm.parseJsonAddress(manifest, ".shared.univ3_factory"),
            "registry UNIV3_FACTORY != manifest"
        );
    }

    function testFork_activeContractBytecodeMatchesLocalForgeArtifacts() public {
        if (!_selectSepoliaFork()) return;
        if (!vm.envOr("RUN_COUPLING_BYTECODE_FFI", false)) return;

        string[] memory command = new string[](2);
        command[0] = "node";
        command[1] = "scripts/check-coupling-bytecode.js";

        bytes memory result = vm.ffi(command);
        assertTrue(abi.decode(result, (bool)), "coupling bytecode checker failed");
    }

    function _selectSepoliaFork() internal returns (bool) {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return false;
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC", DEFAULT_SEPOLIA_RPC);
        vm.createSelectFork(rpcUrl);
        return true;
    }

    function _assertHasCode(string memory label, address target) internal view {
        assertGt(target.code.length, 0, string.concat(label, " has no bytecode"));
    }
}
