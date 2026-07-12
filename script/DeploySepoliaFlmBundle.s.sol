// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {SepoliaFlmBundleDeployment} from "../src/SepoliaFlmBundleDeployment.sol";

interface IW0SiteReleaseReceipt {
    function space() external view returns (address);
    function arbitration() external view returns (address);
    function proposalGateway() external view returns (address);
    function releaseStrategy() external view returns (address);
    function votingStrategy() external view returns (address);
    function evaluator() external view returns (address);
    function orchestrator() external view returns (address);
    function resolver() external view returns (address);
    function futarchyFactory() external view returns (address);
}

/// @notice Raises the W0 spot history capacity and seals its canonical Sepolia FLM bundle.
contract DeploySepoliaFlmBundle is Script {
    struct W0Deployment {
        address deploymentReceipt;
        address companyToken;
        address spotPool;
        address arbitration;
        address pipeline;
        address orchestrator;
        address resolver;
        address futarchyFactory;
        address deployer;
    }

    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    uint16 internal constant MIN_CARDINALITY_NEXT = 120;
    uint24 internal constant FEE_TIER = 500;
    address internal constant FORBIDDEN_OPERATOR = 0x693E3FB46Bb36eE43C702FE94f9463df0691b43d;

    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant NONFUNGIBLE_POSITION_MANAGER =
        0x1238536071E1c677A632429e3655c799b22cDA52;

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
    error InvalidDeployer(address deployer);
    error InvalidDeployerNonce(address deployer, uint64 nonce);
    error InvalidManifest();
    error InvalidPinnedCode(address target, bytes32 expected, bytes32 actual);
    error InvalidBootstrapConfig();
    error InvalidCardinality(uint256 cardinalityNext);
    error InvalidBaseCode(uint256 index, bytes32 expected, bytes32 actual);

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert InvalidChain(block.chainid);

        uint256 privateKey = vm.envUint("FLM_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        string memory manifestPath =
            vm.envOr("W0_DEPLOYMENT_MANIFEST", string("deployments/sepolia-site-release.json"));
        W0Deployment memory w0 = _loadW0Deployment(manifestPath);
        _requireFreshDeployer(privateKey, deployer, w0.deployer);
        _requirePinnedDependencies();

        uint256 bootstrapCompanyAmount = vm.envUint("FLM_BOOTSTRAP_COMPANY_AMOUNT");
        uint256 bootstrapWethAmount = vm.envUint("FLM_BOOTSTRAP_WETH_AMOUNT");
        if (bootstrapCompanyAmount == 0 || bootstrapWethAmount == 0) {
            revert InvalidBootstrapConfig();
        }

        uint256 requestedCardinality =
            vm.envOr("FLM_SPOT_CARDINALITY_NEXT", uint256(MIN_CARDINALITY_NEXT));
        if (requestedCardinality < MIN_CARDINALITY_NEXT || requestedCardinality > type(uint16).max)
        {
            revert InvalidCardinality(requestedCardinality);
        }
        uint16 cardinalityNext = uint16(requestedCardinality);
        bytes[] memory baseCodes = _baseCodes();
        _requireBaseCodeHashes(baseCodes);

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(w0.spotPool);
        (, int24 tickBefore,, uint16 cardinalityBefore, uint16 cardinalityNextBefore,,) =
            pool.slot0();

        SepoliaFlmBundleDeployment.Config memory config = SepoliaFlmBundleDeployment.Config({
            weth: _pinned(WETH, WETH_CODEHASH),
            conditionalTokens: _pinned(CTF, CTF_CODEHASH),
            wrapped1155Factory: _pinned(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH),
            uniswapV3Factory: _pinned(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH),
            positionManager: _pinned(
                NONFUNGIBLE_POSITION_MANAGER, NONFUNGIBLE_POSITION_MANAGER_CODEHASH
            ),
            companyToken: _dependency(w0.companyToken),
            spotPool: _dependency(w0.spotPool),
            arbitration: _dependency(w0.arbitration),
            pipeline: _dependency(w0.pipeline),
            orchestrator: _dependency(w0.orchestrator),
            resolver: _dependency(w0.resolver),
            futarchyFactory: _dependency(w0.futarchyFactory),
            bootstrapCompanyAmount: bootstrapCompanyAmount,
            bootstrapWethAmount: bootstrapWethAmount
        });

        // The cardinality call is separate from the receipt's two sealed-loader transactions.
        vm.broadcast(privateKey);
        pool.increaseObservationCardinalityNext(cardinalityNext);
        vm.broadcast(privateKey);
        SepoliaFlmBundleDeployment receipt = new SepoliaFlmBundleDeployment(config);
        vm.broadcast(privateKey);
        receipt.deployAndBind(baseCodes);

        (, int24 tickAfter,, uint16 cardinalityAfter, uint16 cardinalityNextAfter,,) = pool.slot0();
        if (cardinalityNextAfter < cardinalityNext) {
            revert InvalidCardinality(cardinalityNextAfter);
        }

        console2.log("=== Sealed Sepolia FLM bundle ===");
        console2.log("W0 manifest", manifestPath);
        console2.log("FLM deployer", deployer);
        console2.log("company token", w0.companyToken);
        console2.log("spot pool", w0.spotPool);
        console2.log("bootstrap company amount", bootstrapCompanyAmount);
        console2.log("bootstrap WETH amount", bootstrapWethAmount);
        console2.log("spot tick before");
        console2.logInt(tickBefore);
        console2.log("spot tick after");
        console2.logInt(tickAfter);
        console2.log("spot cardinality before", uint256(cardinalityBefore));
        console2.log("spot cardinalityNext before", uint256(cardinalityNextBefore));
        console2.log("spot cardinality after", uint256(cardinalityAfter));
        console2.log("spot cardinalityNext after", uint256(cardinalityNextAfter));
        console2.log("FLM_RECEIPT=", address(receipt));
        console2.log("FLM_RELAY=", receipt.relay());
        console2.log("FLM_SPOT_ADAPTER=", receipt.spotAdapter());
        console2.log("FLM_CONDITIONAL_ADAPTER=", receipt.conditionalAdapter());
        console2.log("FLM_GUARD=", receipt.guard());
        console2.log("FLM_ROUTER=", receipt.router());
        console2.log("FLM_MANAGER=", receipt.manager());
        console2.log("FLM_BOOTSTRAPPED=", receipt.bootstrapped());
    }

    function _loadW0Deployment(string memory path) internal view returns (W0Deployment memory w0) {
        string memory json = vm.readFile(path);
        if (
            vm.parseJsonUint(json, ".schemaVersion") != 1
                || keccak256(bytes(vm.parseJsonString(json, ".status")))
                    != keccak256(bytes("active"))
                || keccak256(bytes(vm.parseJsonString(json, ".network")))
                    != keccak256(bytes("sepolia"))
                || vm.parseJsonUint(json, ".chainId") != SEPOLIA_CHAIN_ID
                || vm.parseJsonAddress(json, ".currencyToken") != WETH
                || vm.parseJsonUint(json, ".feeTier") != FEE_TIER
                || vm.parseJsonBytes32(json, ".deploymentTransaction") == bytes32(0)
        ) revert InvalidManifest();

        uint256 deploymentBlock = vm.parseJsonUint(json, ".deploymentBlock");
        if (deploymentBlock == 0 || deploymentBlock > block.number) revert InvalidManifest();

        w0.deployer = vm.parseJsonAddress(json, ".deployer");
        w0.deploymentReceipt = vm.parseJsonAddress(json, ".contracts.deploymentReceipt");
        w0.companyToken = vm.parseJsonAddress(json, ".contracts.siteToken");
        w0.spotPool = vm.parseJsonAddress(json, ".contracts.spotPool");
        w0.arbitration = vm.parseJsonAddress(json, ".contracts.arbitration");
        w0.pipeline = vm.parseJsonAddress(json, ".contracts.evaluator");
        w0.orchestrator = vm.parseJsonAddress(json, ".contracts.orchestrator");
        w0.resolver = vm.parseJsonAddress(json, ".contracts.twapResolver");
        w0.futarchyFactory = vm.parseJsonAddress(json, ".contracts.futarchyFactory");

        address[] memory contracts_ = new address[](14);
        contracts_[0] = w0.deploymentReceipt;
        contracts_[1] = w0.companyToken;
        contracts_[2] = w0.spotPool;
        contracts_[3] = vm.parseJsonAddress(json, ".contracts.proposalImplementation");
        contracts_[4] = vm.parseJsonAddress(json, ".contracts.stackDeployer");
        contracts_[5] = vm.parseJsonAddress(json, ".contracts.space");
        contracts_[6] = w0.arbitration;
        contracts_[7] = vm.parseJsonAddress(json, ".contracts.proposalGateway");
        contracts_[8] = vm.parseJsonAddress(json, ".contracts.releaseStrategy");
        contracts_[9] = vm.parseJsonAddress(json, ".contracts.votingStrategy");
        contracts_[10] = w0.pipeline;
        contracts_[11] = w0.orchestrator;
        contracts_[12] = w0.resolver;
        contracts_[13] = w0.futarchyFactory;
        _requireCompleteContracts(contracts_);
        _requireReceiptIdentity(w0.deploymentReceipt, contracts_);
    }

    function _requireCompleteContracts(address[] memory contracts_) internal view {
        for (uint256 i; i < contracts_.length; ++i) {
            if (contracts_[i] == address(0) || contracts_[i].code.length == 0) {
                revert InvalidManifest();
            }
            for (uint256 j; j < i; ++j) {
                if (contracts_[i] == contracts_[j]) revert InvalidManifest();
            }
        }
    }

    function _requireReceiptIdentity(address deploymentReceipt, address[] memory contracts_)
        internal
        view
    {
        IW0SiteReleaseReceipt receipt = IW0SiteReleaseReceipt(deploymentReceipt);
        if (
            receipt.space() != contracts_[5] || receipt.arbitration() != contracts_[6]
                || receipt.proposalGateway() != contracts_[7]
                || receipt.releaseStrategy() != contracts_[8]
                || receipt.votingStrategy() != contracts_[9]
                || receipt.evaluator() != contracts_[10] || receipt.orchestrator() != contracts_[11]
                || receipt.resolver() != contracts_[12]
                || receipt.futarchyFactory() != contracts_[13]
        ) revert InvalidManifest();
    }

    function _requireFreshDeployer(uint256 privateKey, address deployer, address w0Deployer)
        internal
        view
    {
        if (
            privateKey == 0 || deployer == address(0) || deployer == FORBIDDEN_OPERATOR
                || deployer == w0Deployer
        ) revert InvalidDeployer(deployer);
        uint64 nonce = vm.getNonce(deployer);
        if (nonce != 0) revert InvalidDeployerNonce(deployer, nonce);
    }

    function _requirePinnedDependencies() internal view {
        _requirePinnedCode(WETH, WETH_CODEHASH);
        _requirePinnedCode(CTF, CTF_CODEHASH);
        _requirePinnedCode(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH);
        _requirePinnedCode(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH);
        _requirePinnedCode(NONFUNGIBLE_POSITION_MANAGER, NONFUNGIBLE_POSITION_MANAGER_CODEHASH);
    }

    function _requirePinnedCode(address target, bytes32 expected) internal view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert InvalidPinnedCode(target, expected, actual);
    }

    function _baseCodes() internal view returns (bytes[] memory codes) {
        codes = new bytes[](5);
        codes[0] = vm.readFileBinary("metadata/flm-creation-code/relay.bin");
        codes[1] = vm.readFileBinary("metadata/flm-creation-code/adapter.bin");
        codes[2] = vm.readFileBinary("metadata/flm-creation-code/guard.bin");
        codes[3] = vm.readFileBinary("metadata/flm-creation-code/router.bin");
        codes[4] = vm.readFileBinary("metadata/flm-creation-code/manager.bin");
    }

    function _requireBaseCodeHashes(bytes[] memory codes) internal pure {
        bytes32[5] memory expected = [
            FlmCodeHashes.RELAY,
            FlmCodeHashes.ADAPTER,
            FlmCodeHashes.GUARD,
            FlmCodeHashes.ROUTER,
            FlmCodeHashes.MANAGER
        ];
        for (uint256 i; i < expected.length; ++i) {
            bytes32 actual = keccak256(codes[i]);
            if (actual != expected[i]) revert InvalidBaseCode(i, expected[i], actual);
        }
    }

    function _dependency(address target)
        internal
        view
        returns (SepoliaFlmBundleDeployment.Dependency memory)
    {
        return SepoliaFlmBundleDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _pinned(address target, bytes32 codehash)
        internal
        pure
        returns (SepoliaFlmBundleDeployment.Dependency memory)
    {
        return SepoliaFlmBundleDeployment.Dependency({target: target, codehash: codehash});
    }
}
