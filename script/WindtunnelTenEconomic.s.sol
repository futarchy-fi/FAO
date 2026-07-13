// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Script} from "forge-std/Script.sol";
import {ProxyFactory} from "lib/sx-evm/src/ProxyFactory.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "lib/sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {
    MockUniswapV3NonfungiblePositionManager
} from "../lib/futarchy-liquidity-manager/test/mocks/MockUniswapV3NonfungiblePositionManager.sol";
import {EconGateway} from "../src/EconGateway.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";
import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FaoGenesisRegistrar} from "../src/FaoGenesisRegistrar.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {EconomicDeploymentCodeHashes} from "../src/generated/EconomicDeploymentCodeHashes.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";

contract WindtunnelDependencyMock {}

contract WindtunnelTokenMock is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract WindtunnelFactoryMock is IUniswapV3FactoryLike {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }

    function createPool(address, address, uint24) external pure returns (address) {
        revert("wind tunnel has no spot pool");
    }
}

/// @notice Local-only full economic deployment driver used by tools.windtunnel.anvil_drill.
/// @dev Chain 31337 plus the Python driver's loopback-only RPC are load-bearing broadcast guards.
contract WindtunnelTenEconomic is Script {
    uint256 private constant LOCAL_CHAIN_ID = 31_337;
    uint256 private constant INSTANCE_COUNT = 10;
    uint256 private constant GRADUATION_THRESHOLD = 100 ether;
    uint256 private constant ACTIVATION_BOND = 1 ether;
    uint256 private constant TREASURY_BOND = 2 ether;

    error InvalidArtifact();
    error InvalidChain(uint256 chainId);

    function run() external {
        if (block.chainid != LOCAL_CHAIN_ID) revert InvalidChain(block.chainid);
        address sender = vm.envAddress("WINDTUNNEL_SENDER");
        if (sender == address(0)) revert InvalidArtifact();

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
                || keccak256(registrarCode) != EconomicDeploymentCodeHashes.REGISTRAR
                || keccak256(proposalCode) != EconomicDeploymentCodeHashes.PROPOSAL_IMPLEMENTATION
                || keccak256(stackCode) != EconomicDeploymentCodeHashes.STACK_DEPLOYER
        ) revert InvalidArtifact();

        vm.startBroadcast(sender);
        ProxyFactory proxyFactory = new ProxyFactory();
        Space spaceImplementation = new Space();
        VanillaProposalValidationStrategy validationStrategy =
            new VanillaProposalValidationStrategy();
        FAOSiteStackDeployer stackDeployer =
            FAOSiteStackDeployer(_deploy(abi.encodePacked(stackCode, abi.encode(false))));
        FAOFutarchyProposal proposalImplementation = FAOFutarchyProposal(_deploy(proposalCode));
        WindtunnelTokenMock weth = new WindtunnelTokenMock();
        WindtunnelDependencyMock ctf = new WindtunnelDependencyMock();
        WindtunnelDependencyMock wrapped1155 = new WindtunnelDependencyMock();
        WindtunnelFactoryMock univ3Factory = new WindtunnelFactoryMock();
        MockUniswapV3NonfungiblePositionManager positionManager =
            new MockUniswapV3NonfungiblePositionManager();
        FaoGenesisRegistrar registrar = FaoGenesisRegistrar(
            _deploy(
                abi.encodePacked(registrarCode, abi.encode(EconomicDeploymentCodeHashes.RECEIPT))
            )
        );
        weth.mint(sender, INSTANCE_COUNT * (GRADUATION_THRESHOLD + TREASURY_BOND * 2));

        GenesisVault.GrantConfig[] memory grants = _grants();
        FaoGenesisDeployment.FlmConfig memory flm = FaoGenesisDeployment.FlmConfig({
            positionManager: _dependency(address(positionManager))
        });
        bytes32 flmHash = keccak256(abi.encode(flm));

        for (uint256 i; i < INSTANCE_COUNT; ++i) {
            FaoGenesisDeployment.CoreConfig memory core = _coreConfig(
                i,
                proxyFactory,
                spaceImplementation,
                validationStrategy,
                stackDeployer,
                proposalImplementation,
                weth,
                ctf,
                wrapped1155,
                univ3Factory
            );
            bytes32 coreHash = keccak256(abi.encode(core, grants));
            FaoGenesisDeployment receipt =
                FaoGenesisDeployment(registrar.stage(coreHash, flmHash, receiptCode));
            receipt.deployCore(core, grants, coreCodes);
            receipt.deployFlm(flm, flmCodes);

            FAOTreasuryActions.TransferAction memory action = FAOTreasuryActions.TransferAction({
                asset: address(weth),
                recipient: address(uint160(0xBEEF + i)),
                amount: i + 1,
                salt: bytes32(i + 1)
            });
            uint256 proposalId = EconGateway(receipt.proposalGateway()).proposeTransfer(action);
            FutarchyArbitration arbitration = FutarchyArbitration(receipt.arbitration());
            weth.approve(address(arbitration), type(uint256).max);
            arbitration.placeYesBond(proposalId, TREASURY_BOND);
            arbitration.placeNoBond(proposalId);
            arbitration.placeYesBond(proposalId, GRADUATION_THRESHOLD);
            arbitration.startNextEvaluation();
        }
        vm.stopBroadcast();
    }

    function _coreConfig(
        uint256 ordinal,
        ProxyFactory proxyFactory,
        Space spaceImplementation,
        VanillaProposalValidationStrategy validationStrategy,
        FAOSiteStackDeployer stackDeployer,
        FAOFutarchyProposal proposalImplementation,
        WindtunnelTokenMock weth,
        WindtunnelDependencyMock ctf,
        WindtunnelDependencyMock wrapped1155,
        WindtunnelFactoryMock univ3Factory
    ) private view returns (FaoGenesisDeployment.CoreConfig memory config) {
        config = FaoGenesisDeployment.CoreConfig({
            proxyFactory: _dependency(address(proxyFactory)),
            spaceImplementation: _dependency(address(spaceImplementation)),
            proposalValidationStrategy: _dependency(address(validationStrategy)),
            stackDeployer: _dependency(address(stackDeployer)),
            proposalImplementation: _dependency(address(proposalImplementation)),
            weth: _dependency(address(weth)),
            conditionalTokens: _dependency(address(ctf)),
            wrapped1155Factory: _dependency(address(wrapped1155)),
            uniswapV3Factory: _dependency(address(univ3Factory)),
            graduationThreshold: GRADUATION_THRESHOLD,
            arbitrationTimeout: 3 days,
            siteMinActivationBond: ACTIVATION_BOND,
            treasuryMinActivationBond: TREASURY_BOND,
            assetPolicies: _assetPolicies(address(weth)),
            twapTimeout: 7 days,
            twapWindow: 1 days,
            spaceSaltNonce: ordinal + 1,
            daoURI: "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            metadataURI: "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            votingStrategyMetadataURI: "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
            proposalValidationStrategyMetadataURI: "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd",
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            saleEnd: uint64(block.timestamp + 7 days),
            bootstrapDeadline: uint64(block.timestamp + 8 days),
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

    function _grants() private pure returns (GenesisVault.GrantConfig[] memory grants) {
        grants = new GenesisVault.GrantConfig[](1);
        grants[0] = GenesisVault.GrantConfig({
            beneficiary: address(0xBEEF), start: 1, duration: uint64(365 days), amount: 10 ether
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
