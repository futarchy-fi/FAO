// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOSepoliaSiteReleaseDeployment} from "../src/FAOSepoliaSiteReleaseDeployment.sol";
import {FAOSiteToken} from "../src/FAOSiteToken.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

interface ISiteReleasePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @notice Deploys fresh immutable market helpers, then atomically wires the site-release stack.
contract DeployFAOSepoliaSiteRelease is Script {
    address internal constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address internal constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address internal constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant NONFUNGIBLE_POSITION_MANAGER =
        0x1238536071E1c677A632429e3655c799b22cDA52;

    uint24 internal constant FEE_TIER = 500;
    int24 internal constant TICK_LOWER = -887_270;
    int24 internal constant TICK_UPPER = 887_270;
    uint160 internal constant SQRT_PRICE_1_TO_1 = uint160(1 << 96);

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
    error InvalidPinnedCode(address target, bytes32 expected, bytes32 actual);
    error InvalidBootstrapConfig();
    error InsufficientWeth(uint256 available, uint256 required);

    function run() external {
        if (block.chainid != 11_155_111) revert InvalidChain(block.chainid);
        _requireCodehash(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH);
        _requireCodehash(SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH);
        _requireCodehash(SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH);
        _requireCodehash(WETH, WETH_CODEHASH);
        _requireCodehash(CTF, CTF_CODEHASH);
        _requireCodehash(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH);
        _requireCodehash(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH);
        _requireCodehash(NONFUNGIBLE_POSITION_MANAGER, NONFUNGIBLE_POSITION_MANAGER_CODEHASH);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 initialSupply = vm.envOr("SITE_TOKEN_SUPPLY", uint256(1_000_000 ether));
        uint256 seedAmount = vm.envOr("SITE_POOL_SEED_AMOUNT", uint256(0.001 ether));
        uint16 spotCardinality = uint16(vm.envOr("SPOT_OBSERVATION_CARDINALITY", uint256(2)));
        uint256 graduationThreshold = vm.envOr("GRADUATION_THRESHOLD", uint256(0.001 ether));
        uint256 arbitrationTimeout = vm.envOr("ARBITRATION_TIMEOUT", uint256(30 minutes));
        uint256 minActivationBond = vm.envOr("MIN_ACTIVATION_BOND", uint256(0.0001 ether));
        uint16 observationCardinality = uint16(vm.envOr("OBSERVATION_CARDINALITY", uint256(100)));
        uint32 twapTimeout = uint32(vm.envOr("TWAP_TIMEOUT", uint256(30 minutes)));
        uint32 twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(15 minutes)));
        string memory daoURI = vm.envString("DAO_URI");
        string memory spaceMetadataURI = vm.envString("SPACE_METADATA_URI");
        string memory votingStrategyMetadataURI = vm.envString("VOTING_STRATEGY_METADATA_URI");
        string memory proposalValidationStrategyMetadataURI =
            vm.envString("PROPOSAL_VALIDATION_STRATEGY_METADATA_URI");
        if (initialSupply < seedAmount || seedAmount == 0 || spotCardinality < 2) {
            revert InvalidBootstrapConfig();
        }
        uint256 wethBalance = IERC20(WETH).balanceOf(deployer);
        if (wethBalance < seedAmount) revert InsufficientWeth(wethBalance, seedAmount);

        console2.log("=== Immutable deployment candidate ===");
        console2.log("deployer", deployer);
        console2.log("site token supply", initialSupply);
        console2.log("spot seed per token", seedAmount);
        console2.log("spot observation cardinality", uint256(spotCardinality));
        console2.log("graduation threshold", graduationThreshold);
        console2.log("arbitration timeout", arbitrationTimeout);
        console2.log("minimum activation bond", minActivationBond);
        console2.log("conditional observation cardinality", uint256(observationCardinality));
        console2.log("TWAP timeout", uint256(twapTimeout));
        console2.log("TWAP window", uint256(twapWindow));

        vm.startBroadcast(privateKey);
        (FAOSiteToken companyToken, address spotPool, uint256 lpTokenId, uint128 spotLiquidity) =
            _bootstrapCompanyMarket(deployer, initialSupply, seedAmount, spotCardinality);
        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);

        FAOSepoliaSiteReleaseDeployment.Config memory config = FAOSepoliaSiteReleaseDeployment.Config({
            proxyFactory: _pinned(SX_PROXY_FACTORY, SX_PROXY_FACTORY_CODEHASH),
            spaceImplementation: _pinned(SX_SPACE_IMPLEMENTATION, SX_SPACE_IMPLEMENTATION_CODEHASH),
            proposalValidationStrategy: _pinned(
                SX_PROPOSAL_VALIDATION, SX_PROPOSAL_VALIDATION_CODEHASH
            ),
            stackDeployer: _dependency(address(stackDeployer)),
            proposalImplementation: _dependency(address(proposalImplementation)),
            bondToken: _pinned(WETH, WETH_CODEHASH),
            conditionalTokens: _pinned(CTF, CTF_CODEHASH),
            wrapped1155Factory: _pinned(WRAPPED_1155_FACTORY, WRAPPED_1155_FACTORY_CODEHASH),
            uniswapV3Factory: _pinned(UNISWAP_V3_FACTORY, UNISWAP_V3_FACTORY_CODEHASH),
            companyToken: _dependency(address(companyToken)),
            spotPool: _dependency(spotPool),
            graduationThreshold: graduationThreshold,
            arbitrationTimeout: arbitrationTimeout,
            minActivationBond: minActivationBond,
            feeTier: FEE_TIER,
            observationCardinality: observationCardinality,
            twapTimeout: twapTimeout,
            twapWindow: twapWindow,
            spaceSaltNonce: vm.envOr("SPACE_SALT_NONCE", uint256(1)),
            daoURI: daoURI,
            metadataURI: spaceMetadataURI,
            votingStrategyMetadataURI: votingStrategyMetadataURI,
            proposalValidationStrategyMetadataURI: proposalValidationStrategyMetadataURI
        });

        FAOSepoliaSiteReleaseDeployment deployment = new FAOSepoliaSiteReleaseDeployment(config);
        vm.stopBroadcast();

        console2.log("SITE_TOKEN=", address(companyToken));
        console2.log("SPOT_POOL=", spotPool);
        console2.log("SPOT_LP_TOKEN_ID=", lpTokenId);
        console2.log("SPOT_LIQUIDITY=", uint256(spotLiquidity));
        console2.log("DEPLOYMENT_RECEIPT=", address(deployment));
        console2.log("SPACE=", deployment.space());
        console2.log("ARBITRATION=", deployment.arbitration());
        console2.log("PROPOSAL_GATEWAY=", deployment.proposalGateway());
        console2.log("RELEASE_STRATEGY=", deployment.releaseStrategy());
        console2.log("EVALUATOR=", deployment.evaluator());
        console2.log("ORCHESTRATOR=", deployment.orchestrator());
        console2.log("TWAP_RESOLVER=", deployment.resolver());
        console2.log("FUTARCHY_FACTORY=", deployment.futarchyFactory());
        console2.log("PROPOSAL_IMPLEMENTATION=", address(proposalImplementation));
        console2.log("STACK_DEPLOYER=", address(stackDeployer));
    }

    function _bootstrapCompanyMarket(
        address deployer,
        uint256 initialSupply,
        uint256 seedAmount,
        uint16 spotCardinality
    )
        private
        returns (FAOSiteToken companyToken, address spotPool, uint256 lpTokenId, uint128 liquidity)
    {
        companyToken = new FAOSiteToken(deployer, initialSupply);
        spotPool = IUniswapV3FactoryLike(UNISWAP_V3_FACTORY)
            .createPool(address(companyToken), WETH, FEE_TIER);
        IUniswapV3PoolLike(spotPool).initialize(SQRT_PRICE_1_TO_1);
        IUniswapV3PoolLike(spotPool).increaseObservationCardinalityNext(spotCardinality);

        IERC20(address(companyToken)).approve(NONFUNGIBLE_POSITION_MANAGER, seedAmount);
        IERC20(WETH).approve(NONFUNGIBLE_POSITION_MANAGER, seedAmount);

        bool companyFirst = address(companyToken) < WETH;
        uint256 amountMin = (seedAmount * 99) / 100;
        (lpTokenId, liquidity,,) = ISiteReleasePositionManager(NONFUNGIBLE_POSITION_MANAGER)
            .mint(
                ISiteReleasePositionManager.MintParams({
                    token0: companyFirst ? address(companyToken) : WETH,
                    token1: companyFirst ? WETH : address(companyToken),
                    fee: FEE_TIER,
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    amount0Desired: seedAmount,
                    amount1Desired: seedAmount,
                    amount0Min: amountMin,
                    amount1Min: amountMin,
                    recipient: deployer,
                    deadline: block.timestamp + 10 minutes
                })
            );
    }

    function _dependency(address target)
        private
        view
        returns (FAOSepoliaSiteReleaseDeployment.Dependency memory)
    {
        return
            FAOSepoliaSiteReleaseDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _pinned(address target, bytes32 codehash)
        private
        pure
        returns (FAOSepoliaSiteReleaseDeployment.Dependency memory)
    {
        return FAOSepoliaSiteReleaseDeployment.Dependency({target: target, codehash: codehash});
    }

    function _requireCodehash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert InvalidPinnedCode(target, expected, actual);
    }
}
