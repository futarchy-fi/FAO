// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AlwaysZeroVotingStrategy} from "../src/AlwaysZeroVotingStrategy.sol";
import {EconGateway} from "../src/EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "../src/FAOEconomicEvaluationPipeline.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";

/// @notice Stages the ownerless, no-vote Sepolia economic FAO without moving buyer funds.
contract DeployFaoEconomicGenesis is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    address internal constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address internal constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address internal constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant NONFUNGIBLE_POSITION_MANAGER =
        0x1238536071E1c677A632429e3655c799b22cDA52;

    bytes32 internal constant SX_PROXY_FACTORY_CODEHASH =
        0x9d58d183bb98c199c270f0f2ba7c0abbda1a119caef4c136e137bbacca8c4035;
    bytes32 internal constant SX_SPACE_IMPLEMENTATION_CODEHASH =
        0x4f2f90c70374b7dcd468d351747e9c865efc0d47e606eb6fdaeb2a842c148d81;
    bytes32 internal constant SX_PROPOSAL_VALIDATION_CODEHASH =
        0xddd4560ead7f2c3de35f37de8d50c43e57f0173ad3eefd20098c3b6e08cba9d8;
    bytes32 internal constant WETH_CODEHASH =
        0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083;
    bytes32 internal constant CTF_CODEHASH =
        0x962883a35da553c2d46562f362ba99f68041dad91de30a143a785b2d169c7e81;
    bytes32 internal constant WRAPPED_1155_FACTORY_CODEHASH =
        0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6;
    bytes32 internal constant UNISWAP_V3_FACTORY_CODEHASH =
        0xacb5afea1f8877239fadd30358add13f2f9d4fb80175402c686d392295224fef;
    bytes32 internal constant NONFUNGIBLE_POSITION_MANAGER_CODEHASH =
        0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868;

    error InvalidChain(uint256 chainId);
    error InvalidConfig();
    error InvalidPinnedCode(address target, bytes32 expected, bytes32 actual);

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);
        _requirePinnedDependencies();

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        if (privateKey == 0 || deployer == address(0)) revert InvalidConfig();

        uint256 saleDuration = vm.envOr("SALE_DURATION", uint256(1 hours));
        uint256 bootstrapWindow = vm.envOr("BOOTSTRAP_WINDOW", uint256(1 days));
        if (
            saleDuration == 0 || bootstrapWindow == 0
                || block.timestamp + saleDuration + bootstrapWindow > type(uint64).max
        ) revert InvalidConfig();

        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        bytes[] memory coreCodes = _coreCodes();
        bytes[] memory flmCodes = _flmCodes();
        uint256 startNonce = vm.getNonce(deployer);

        vm.broadcast(privateKey);
        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        vm.broadcast(privateKey);
        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);

        uint256 saleCap = vm.envOr("SALE_CAP", uint256(100 ether));
        uint256 twapTimeout = vm.envOr("TWAP_TIMEOUT", uint256(30 minutes));
        uint256 twapWindow = vm.envOr("TWAP_WINDOW", uint256(15 minutes));
        uint256 bootstrapBps = vm.envOr("BOOTSTRAP_BPS", uint256(5000));
        if (
            twapTimeout > type(uint32).max || twapWindow > type(uint32).max
                || bootstrapBps > type(uint16).max || saleCap > (type(uint256).max - 1 ether) / 2
        ) revert InvalidConfig();
        FaoGenesisDeployment.CoreConfig memory core = FaoGenesisDeployment.CoreConfig({
            proxyFactory: _pinned(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH),
            spaceImplementation: _pinned(SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH),
            proposalValidationStrategy: _pinned(
                SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH
            ),
            stackDeployer: _dependency(address(stackDeployer)),
            proposalImplementation: _dependency(address(proposalImplementation)),
            weth: _pinned(WETH, WETH_CODEHASH),
            conditionalTokens: _pinned(CTF, CTF_CODEHASH),
            wrapped1155Factory: _pinned(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH),
            uniswapV3Factory: _pinned(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH),
            graduationThreshold: vm.envOr("GRADUATION_THRESHOLD", uint256(0.001 ether)),
            arbitrationTimeout: vm.envOr("ARBITRATION_TIMEOUT", uint256(30 minutes)),
            siteMinActivationBond: vm.envOr("SITE_MIN_ACTIVATION_BOND", uint256(0.0001 ether)),
            treasuryMinActivationBond: vm.envOr(
                "TREASURY_MIN_ACTIVATION_BOND", uint256(0.0001 ether)
            ),
            twapTimeout: uint32(twapTimeout),
            twapWindow: uint32(twapWindow),
            spaceSaltNonce: vm.envOr("SPACE_SALT_NONCE", uint256(block.timestamp)),
            daoURI: vm.envString("DAO_URI"),
            metadataURI: vm.envString("SPACE_METADATA_URI"),
            votingStrategyMetadataURI: vm.envString("VOTING_STRATEGY_METADATA_URI"),
            proposalValidationStrategyMetadataURI: vm.envString(
                "PROPOSAL_VALIDATION_STRATEGY_METADATA_URI"
            ),
            tokenName: vm.envOr("TOKEN_NAME", string("Futarchy Autonomous Organization")),
            tokenSymbol: vm.envOr("TOKEN_SYMBOL", string("FAO")),
            saleEnd: uint64(block.timestamp + saleDuration),
            bootstrapDeadline: uint64(block.timestamp + saleDuration + bootstrapWindow),
            saleCap: saleCap,
            minimumRaise: vm.envOr("MINIMUM_RAISE", uint256(0.0005 ether)),
            tokenMaxSupply: vm.envOr("TOKEN_MAX_SUPPLY", saleCap * 2 + 1 ether),
            initialPrice: vm.envOr("INITIAL_PRICE", uint256(0.000_01 ether)),
            slope: vm.envOr("SLOPE", uint256(0)),
            bootstrapBps: uint16(bootstrapBps)
        });
        FaoGenesisDeployment.FlmConfig memory flm = FaoGenesisDeployment.FlmConfig({
            positionManager: _pinned(
                NONFUNGIBLE_POSITION_MANAGER, NONFUNGIBLE_POSITION_MANAGER_CODEHASH
            )
        });

        bytes32 coreHash = keccak256(abi.encode(core, grants));
        bytes32 flmHash = keccak256(abi.encode(flm));
        vm.broadcast(privateKey);
        FaoGenesisDeployment receipt = new FaoGenesisDeployment(coreHash, flmHash);
        vm.broadcast(privateKey);
        receipt.deployCore(core, grants, coreCodes);
        vm.broadcast(privateKey);
        receipt.deployFlm(flm, flmCodes);

        console2.log("=== Hash-sealed economic FAO staged on Sepolia ===");
        console2.log("DEPLOYER=", deployer);
        console2.log("DEPLOYER_START_NONCE=", startNonce);
        console2.log("CORE_CONFIG_HASH=");
        console2.logBytes32(coreHash);
        console2.log("FLM_CONFIG_HASH=");
        console2.logBytes32(flmHash);
        console2.log("PROPOSAL_IMPLEMENTATION=", address(proposalImplementation));
        console2.log("STACK_DEPLOYER=", address(stackDeployer));
        console2.log("GENESIS_RECEIPT=", address(receipt));
        console2.log("SPACE=", receipt.space());
        console2.log("VAULT=", receipt.vault());
        console2.log("FAO_TOKEN=", receipt.companyToken());
        console2.log("SPOT_POOL=", receipt.spotPool());
        console2.log("ARBITRATION=", receipt.arbitration());
        console2.log("ECON_GATEWAY=", receipt.proposalGateway());
        console2.log("ECON_EVALUATOR=", receipt.evaluator());
        console2.log("FLM_MANAGER=", receipt.manager());
        console2.log("SALE_END=", uint256(core.saleEnd));
        console2.log("BOOTSTRAP_DEADLINE=", uint256(core.bootstrapDeadline));
    }

    function _requirePinnedDependencies() private view {
        _requireCodehash(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH);
        _requireCodehash(SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH);
        _requireCodehash(SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH);
        _requireCodehash(WETH, WETH_CODEHASH);
        _requireCodehash(CTF, CTF_CODEHASH);
        _requireCodehash(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH);
        _requireCodehash(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH);
        _requireCodehash(NONFUNGIBLE_POSITION_MANAGER, NONFUNGIBLE_POSITION_MANAGER_CODEHASH);
    }

    function _coreCodes() private pure returns (bytes[] memory codes) {
        codes = new bytes[](6);
        codes[0] = type(FutarchyArbitration).creationCode;
        codes[1] = type(GenesisVault).creationCode;
        codes[2] = type(SXArbitrationExecutionStrategy).creationCode;
        codes[3] = type(AlwaysZeroVotingStrategy).creationCode;
        codes[4] = type(EconGateway).creationCode;
        codes[5] = type(FAOEconomicEvaluationPipeline).creationCode;
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
        ) revert InvalidConfig();
    }

    function _dependency(address target)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _pinned(address target, bytes32 codehash)
        private
        pure
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: codehash});
    }

    function _requireCodehash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert InvalidPinnedCode(target, expected, actual);
    }
}
