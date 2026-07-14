// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FaoGenesisRegistrar} from "../src/FaoGenesisRegistrar.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {EconomicDeploymentCodeHashes} from "../src/generated/EconomicDeploymentCodeHashes.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";

interface IRehearsalR0FactoryBound {
    function factory() external view returns (address);
}

/// @notice Fork-only deployment half of the R0 composed-loop rehearsal.
/// @dev Python owns the loopback Anvil fork and every post-deployment public call.
contract RehearsalR0 is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant FORK_BLOCK = 11_265_000;

    address public constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address public constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address public constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address public constant WRAPPED_1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address public constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address public constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address public constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

    bytes32 private constant SX_PROXY_FACTORY_CODEHASH =
        0x9d58d183bb98c199c270f0f2ba7c0abbda1a119caef4c136e137bbacca8c4035;
    bytes32 private constant SX_SPACE_IMPLEMENTATION_CODEHASH =
        0x4f2f90c70374b7dcd468d351747e9c865efc0d47e606eb6fdaeb2a842c148d81;
    bytes32 private constant SX_PROPOSAL_VALIDATION_CODEHASH =
        0xddd4560ead7f2c3de35f37de8d50c43e57f0173ad3eefd20098c3b6e08cba9d8;
    bytes32 private constant WETH_CODEHASH =
        0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083;
    bytes32 private constant CTF_CODEHASH =
        0x962883a35da553c2d46562f362ba99f68041dad91de30a143a785b2d169c7e81;
    bytes32 private constant WRAPPED_1155_CODEHASH =
        0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6;
    bytes32 private constant UNIV3_FACTORY_CODEHASH =
        0xacb5afea1f8877239fadd30358add13f2f9d4fb80175402c686d392295224fef;
    bytes32 private constant NPM_CODEHASH =
        0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868;
    bytes32 private constant SWAP_ROUTER_CODEHASH =
        0xe7f98ee73dfe6d5c96cbf8936920f496b1b82f24326d6a415b4144a2252271de;

    error DependencyMismatch(address target, bytes32 expected, bytes32 actual);
    error InvalidArtifact();
    error InvalidChain(uint256 chainId);
    error InvalidForkBlock(uint256 blockNumber);

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        if (block.number != FORK_BLOCK) revert InvalidForkBlock(block.number);
        address sender = vm.envAddress("REHEARSAL_R0_SENDER");
        if (sender == address(0)) revert InvalidArtifact();
        _requireDependencies();

        bytes memory receiptCode = vm.readFileBinary("metadata/economic-creation-code/receipt.bin");
        bytes memory proposalCode =
            vm.readFileBinary("metadata/economic-creation-code/proposal_implementation.bin");
        bytes memory stackCode =
            vm.readFileBinary("metadata/economic-creation-code/stack_deployer.bin");
        bytes memory registrarCode =
            vm.readFileBinary("metadata/economic-creation-code/registrar.bin");
        if (
            keccak256(receiptCode) != EconomicDeploymentCodeHashes.RECEIPT
                || keccak256(proposalCode) != EconomicDeploymentCodeHashes.PROPOSAL_IMPLEMENTATION
                || keccak256(stackCode) != EconomicDeploymentCodeHashes.STACK_DEPLOYER
                || keccak256(registrarCode) != EconomicDeploymentCodeHashes.REGISTRAR
        ) revert InvalidArtifact();

        vm.startBroadcast(sender);
        FAOSiteStackDeployer stackDeployer =
            FAOSiteStackDeployer(_deploy(abi.encodePacked(stackCode, abi.encode(false))));
        FAOFutarchyProposal proposalImplementation = FAOFutarchyProposal(_deploy(proposalCode));
        FaoGenesisRegistrar registrar = FaoGenesisRegistrar(
            _deploy(
                abi.encodePacked(registrarCode, abi.encode(EconomicDeploymentCodeHashes.RECEIPT))
            )
        );

        GenesisVault.GrantConfig[] memory grants = _grants();
        FaoGenesisDeployment.CoreConfig memory core =
            _coreConfig(stackDeployer, proposalImplementation);
        FaoGenesisDeployment.FlmConfig memory flm =
            FaoGenesisDeployment.FlmConfig({positionManager: _dependency(NPM, NPM_CODEHASH)});
        bytes32 coreHash = keccak256(abi.encode(core, grants));
        bytes32 flmHash = keccak256(abi.encode(flm));
        FaoGenesisDeployment receipt =
            FaoGenesisDeployment(registrar.stage(coreHash, flmHash, receiptCode));
        receipt.deployCore(core, grants, _coreCodes());
        receipt.deployFlm(flm, _flmCodes());
        vm.stopBroadcast();
    }

    function _coreConfig(
        FAOSiteStackDeployer stackDeployer,
        FAOFutarchyProposal proposalImplementation
    ) private view returns (FaoGenesisDeployment.CoreConfig memory config) {
        config = FaoGenesisDeployment.CoreConfig({
            proxyFactory: _dependency(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH),
            spaceImplementation: _dependency(
                SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH
            ),
            proposalValidationStrategy: _dependency(
                SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH
            ),
            stackDeployer: _dependency(address(stackDeployer), address(stackDeployer).codehash),
            proposalImplementation: _dependency(
                address(proposalImplementation), address(proposalImplementation).codehash
            ),
            weth: _dependency(WETH, WETH_CODEHASH),
            conditionalTokens: _dependency(CTF, CTF_CODEHASH),
            wrapped1155Factory: _dependency(WRAPPED_1155, WRAPPED_1155_CODEHASH),
            uniswapV3Factory: _dependency(UNIV3_FACTORY, UNIV3_FACTORY_CODEHASH),
            graduationThreshold: 100 ether,
            arbitrationTimeout: 3 days,
            siteMinActivationBond: 1 ether,
            treasuryMinActivationBond: 2 ether,
            assetPolicies: _assetPolicies(),
            twapTimeout: 7 days,
            twapWindow: 1 days,
            spaceSaltNonce: 1,
            daoURI: "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            metadataURI: "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            votingStrategyMetadataURI: "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
            proposalValidationStrategyMetadataURI: "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd",
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            saleEnd: uint64(block.timestamp + 1 days),
            bootstrapDeadline: uint64(block.timestamp + 2 days),
            saleCap: 100 ether,
            minimumRaise: 0.1 ether,
            tokenMaxSupply: 1000 ether,
            initialPrice: 0.01 ether,
            slope: 0.001 ether,
            bootstrapBps: 5000
        });
    }

    function _assetPolicies()
        private
        pure
        returns (GenesisVault.AssetPolicyConfig[] memory policies)
    {
        policies = new GenesisVault.AssetPolicyConfig[](1);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: WETH, c1: 0.1 ether, c2: 1 ether, tapBudget: 0.2 ether, tapBudgetMax: 2 ether
        });
    }

    function _grants() private view returns (GenesisVault.GrantConfig[] memory grants) {
        grants = new GenesisVault.GrantConfig[](1);
        grants[0] = GenesisVault.GrantConfig({
            beneficiary: 0x1000000000000000000000000000000000000002,
            start: uint64(block.timestamp),
            duration: uint64(365 days),
            amount: 10 ether
        });
    }

    function _coreCodes() private view returns (bytes[] memory codes) {
        codes = new bytes[](6);
        codes[0] = vm.readFileBinary("metadata/economic-creation-code/arbitration.bin");
        codes[1] = vm.readFileBinary("metadata/economic-creation-code/vault.bin");
        codes[2] = vm.readFileBinary("metadata/economic-creation-code/release_strategy.bin");
        codes[3] = vm.readFileBinary("metadata/economic-creation-code/zero_voting.bin");
        codes[4] = vm.readFileBinary("metadata/economic-creation-code/econ_gateway.bin");
        codes[5] = vm.readFileBinary("metadata/economic-creation-code/econ_evaluator.bin");
    }

    function _flmCodes() private view returns (bytes[] memory codes) {
        codes = new bytes[](5);
        codes[0] = vm.readFileBinary("metadata/flm-creation-code/relay.bin");
        codes[1] = vm.readFileBinary("metadata/flm-creation-code/adapter.bin");
        codes[2] = vm.readFileBinary("metadata/flm-creation-code/guard.bin");
        codes[3] = vm.readFileBinary("metadata/flm-creation-code/router.bin");
        codes[4] = vm.readFileBinary("metadata/flm-creation-code/manager.bin");
        bytes32[5] memory expected = [
            FlmCodeHashes.RELAY,
            FlmCodeHashes.ADAPTER,
            FlmCodeHashes.GUARD,
            FlmCodeHashes.ROUTER,
            FlmCodeHashes.MANAGER
        ];
        for (uint256 i; i < codes.length; ++i) {
            if (keccak256(codes[i]) != expected[i]) revert InvalidArtifact();
        }
    }

    function _dependency(address target, bytes32 expected)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        bytes32 actual = target.codehash;
        if (actual != expected) revert DependencyMismatch(target, expected, actual);
        return FaoGenesisDeployment.Dependency({target: target, codehash: expected});
    }

    function _requireDependencies() private view {
        _dependency(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH);
        _dependency(SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH);
        _dependency(SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH);
        _dependency(WETH, WETH_CODEHASH);
        _dependency(CTF, CTF_CODEHASH);
        _dependency(WRAPPED_1155, WRAPPED_1155_CODEHASH);
        _dependency(UNIV3_FACTORY, UNIV3_FACTORY_CODEHASH);
        _dependency(NPM, NPM_CODEHASH);
        _dependency(SWAP_ROUTER, SWAP_ROUTER_CODEHASH);
        if (
            IRehearsalR0FactoryBound(NPM).factory() != UNIV3_FACTORY
                || IRehearsalR0FactoryBound(SWAP_ROUTER).factory() != UNIV3_FACTORY
        ) revert DependencyMismatch(UNIV3_FACTORY, UNIV3_FACTORY_CODEHASH, bytes32(0));
    }

    function _deploy(bytes memory initcode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (deployed == address(0)) revert InvalidArtifact();
    }
}
