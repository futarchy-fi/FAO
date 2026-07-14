// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {ProxyFactory} from "lib/sx-evm/src/ProxyFactory.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "lib/sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {
    MockUniswapV3NonfungiblePositionManager
} from "../lib/futarchy-liquidity-manager/test/mocks/MockUniswapV3NonfungiblePositionManager.sol";
import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FaoGenesisRegistrar} from "../src/FaoGenesisRegistrar.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {EconomicDeploymentCodeHashes} from "../src/generated/EconomicDeploymentCodeHashes.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";
import {FaoGenesisFactoryMock, FaoGenesisPoolMock} from "../test/mocks/FaoGenesisPoolMocks.sol";
import {WindtunnelDependencyMock, WindtunnelTokenMock} from "./WindtunnelTenEconomic.s.sol";

/// @dev Constructor-only event carrier so dependency discovery comes from a mined receipt.
contract RehearsalR0LocalManifest {
    event LocalDependencies(
        address indexed weth,
        address indexed factory,
        address indexed positionManager,
        address poolTemplate,
        address registrar
    );

    constructor(
        address weth,
        address factory,
        address positionManager,
        address poolTemplate,
        address registrar
    ) {
        emit LocalDependencies(weth, factory, positionManager, poolTemplate, registrar);
    }
}

/// @notice Local-only deployment half of the R0 S2 hero and failed-twin rehearsal.
/// @dev Python owns pool installation and every post-deployment economic call.
contract RehearsalR0Local is Script {
    uint256 private constant LOCAL_CHAIN_ID = 31_337;
    uint256 private constant GRADUATION_THRESHOLD = 100 ether;
    uint256 private constant ACTIVATION_BOND = 1 ether;
    uint256 private constant TREASURY_BOND = 2 ether;

    struct Dependencies {
        address proxyFactory;
        address spaceImplementation;
        address proposalValidationStrategy;
        address stackDeployer;
        address proposalImplementation;
        address weth;
        address conditionalTokens;
        address wrapped1155Factory;
        address uniswapV3Factory;
        address positionManager;
    }

    error InvalidArtifact();
    error InvalidChain(uint256 chainId);

    function run() external {
        if (block.chainid != LOCAL_CHAIN_ID) revert InvalidChain(block.chainid);
        address sender = vm.envAddress("REHEARSAL_R0_LOCAL_SENDER");
        if (sender == address(0)) revert InvalidArtifact();

        uint64 start = uint64(block.timestamp);
        uint64 saleEnd = start + uint64(1 days);
        uint64 bootstrapDeadline = start + uint64(2 days);
        bytes memory receiptCode = vm.readFileBinary("metadata/economic-creation-code/receipt.bin");
        bytes memory proposalCode =
            vm.readFileBinary("metadata/economic-creation-code/proposal_implementation.bin");
        bytes memory stackCode =
            vm.readFileBinary("metadata/economic-creation-code/stack_deployer.bin");
        bytes memory registrarCode =
            vm.readFileBinary("metadata/economic-creation-code/registrar.bin");
        bytes[] memory coreCodes = _coreCodes();
        bytes[] memory flmCodes = _flmCodes();
        if (
            keccak256(receiptCode) != EconomicDeploymentCodeHashes.RECEIPT
                || keccak256(proposalCode) != EconomicDeploymentCodeHashes.PROPOSAL_IMPLEMENTATION
                || keccak256(stackCode) != EconomicDeploymentCodeHashes.STACK_DEPLOYER
                || keccak256(registrarCode) != EconomicDeploymentCodeHashes.REGISTRAR
        ) revert InvalidArtifact();

        vm.startBroadcast(sender);
        Dependencies memory dependencies;
        dependencies.proxyFactory = address(new ProxyFactory());
        dependencies.spaceImplementation = address(new Space());
        dependencies.proposalValidationStrategy = address(new VanillaProposalValidationStrategy());
        dependencies.stackDeployer = _deploy(abi.encodePacked(stackCode, abi.encode(false)));
        dependencies.proposalImplementation = _deploy(proposalCode);
        dependencies.weth = address(new WindtunnelTokenMock());
        dependencies.conditionalTokens = address(new WindtunnelDependencyMock());
        dependencies.wrapped1155Factory = address(new WindtunnelDependencyMock());
        dependencies.uniswapV3Factory = address(new FaoGenesisFactoryMock());
        dependencies.positionManager = address(new MockUniswapV3NonfungiblePositionManager());
        address poolTemplate = address(new FaoGenesisPoolMock());
        FaoGenesisRegistrar registrar = FaoGenesisRegistrar(
            _deploy(
                abi.encodePacked(registrarCode, abi.encode(EconomicDeploymentCodeHashes.RECEIPT))
            )
        );
        new RehearsalR0LocalManifest(
            dependencies.weth,
            dependencies.uniswapV3Factory,
            dependencies.positionManager,
            poolTemplate,
            address(registrar)
        );

        GenesisVault.GrantConfig[] memory grants = _grants(start);
        FaoGenesisDeployment.FlmConfig memory flm = FaoGenesisDeployment.FlmConfig({
            positionManager: _dependency(dependencies.positionManager)
        });
        bytes32 flmHash = keccak256(abi.encode(flm));
        for (uint256 ordinal = 1; ordinal <= 2; ++ordinal) {
            FaoGenesisDeployment.CoreConfig memory core =
                _coreConfig(ordinal, saleEnd, bootstrapDeadline, dependencies);
            FaoGenesisDeployment receipt = FaoGenesisDeployment(
                registrar.stage(keccak256(abi.encode(core, grants)), flmHash, receiptCode)
            );
            receipt.deployCore(core, grants, coreCodes);
            receipt.deployFlm(flm, flmCodes);
        }
        vm.stopBroadcast();
    }

    function _coreConfig(
        uint256 ordinal,
        uint64 saleEnd,
        uint64 bootstrapDeadline,
        Dependencies memory dependencies
    ) private view returns (FaoGenesisDeployment.CoreConfig memory config) {
        config = FaoGenesisDeployment.CoreConfig({
            proxyFactory: _dependency(dependencies.proxyFactory),
            spaceImplementation: _dependency(dependencies.spaceImplementation),
            proposalValidationStrategy: _dependency(dependencies.proposalValidationStrategy),
            stackDeployer: _dependency(dependencies.stackDeployer),
            proposalImplementation: _dependency(dependencies.proposalImplementation),
            weth: _dependency(dependencies.weth),
            conditionalTokens: _dependency(dependencies.conditionalTokens),
            wrapped1155Factory: _dependency(dependencies.wrapped1155Factory),
            uniswapV3Factory: _dependency(dependencies.uniswapV3Factory),
            graduationThreshold: GRADUATION_THRESHOLD,
            arbitrationTimeout: 3 days,
            siteMinActivationBond: ACTIVATION_BOND,
            treasuryMinActivationBond: TREASURY_BOND,
            assetPolicies: _assetPolicies(dependencies.weth),
            twapTimeout: 7 days,
            twapWindow: 1 days,
            spaceSaltNonce: ordinal,
            daoURI: "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            metadataURI: "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            votingStrategyMetadataURI: "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
            proposalValidationStrategyMetadataURI: "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd",
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            saleEnd: saleEnd,
            bootstrapDeadline: bootstrapDeadline,
            saleCap: 100 ether,
            minimumRaise: 0.1 ether,
            tokenMaxSupply: 1000 ether,
            initialPrice: 0.01 ether,
            slope: 0.001 ether,
            bootstrapBps: 5000
        });
    }

    function _assetPolicies(address weth)
        private
        pure
        returns (GenesisVault.AssetPolicyConfig[] memory policies)
    {
        policies = new GenesisVault.AssetPolicyConfig[](1);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: weth, c1: 0.1 ether, c2: 1 ether, tapBudget: 0.2 ether, tapBudgetMax: 2 ether
        });
    }

    function _grants(uint64 start) private pure returns (GenesisVault.GrantConfig[] memory grants) {
        grants = new GenesisVault.GrantConfig[](1);
        grants[0] = GenesisVault.GrantConfig({
            beneficiary: 0x1000000000000000000000000000000000000002,
            start: start,
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
        if (
            keccak256(codes[0]) != FlmCodeHashes.RELAY
                || keccak256(codes[1]) != FlmCodeHashes.ADAPTER
                || keccak256(codes[2]) != FlmCodeHashes.GUARD
                || keccak256(codes[3]) != FlmCodeHashes.ROUTER
                || keccak256(codes[4]) != FlmCodeHashes.MANAGER
        ) revert InvalidArtifact();
    }

    function _dependency(address target)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _deploy(bytes memory initcode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (deployed == address(0)) revert InvalidArtifact();
    }
}
