// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {FAOFutarchyProposal} from "../../src/FAOFutarchyProposal.sol";
import {FAOOfficialProposalOrchestrator} from "../../src/FAOOfficialProposalOrchestrator.sol";
import {FAOSepoliaSiteReleaseDeployment} from "../../src/FAOSepoliaSiteReleaseDeployment.sol";
import {FAOSiteEvaluationPipeline} from "../../src/FAOSiteEvaluationPipeline.sol";
import {FAOSiteToken} from "../../src/FAOSiteToken.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {FAOSiteStackDeployer} from "../../src/FAOSiteStackDeployer.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "../../src/SXProposalGateway.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

interface IFreshBootstrapWETH9 {
    function deposit() external payable;
}

interface IFreshBootstrapNPM {
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

contract FAOSepoliaFreshBootstrapForkTest is Test {
    address internal constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address internal constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address internal constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;

    uint24 internal constant FEE = 500;
    uint256 internal constant SEED = 0.001 ether;

    function testForkFreshBootstrapAndAtomicDeployment() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia.publicnode.com");

        address operator = makeAddr("fresh-site-operator");
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);

        uint256 gasStart = gasleft();
        FAOSiteToken token = new FAOSiteToken(operator, 1_000_000 ether);
        uint256 tokenGas = gasStart - gasleft();
        IFreshBootstrapWETH9(WETH).deposit{value: SEED}();

        gasStart = gasleft();
        address pool = IUniswapV3FactoryLike(UNIV3_FACTORY).createPool(address(token), WETH, FEE);
        uint256 poolCreateGas = gasStart - gasleft();

        gasStart = gasleft();
        IUniswapV3PoolLike(pool).initialize(uint160(1 << 96));
        IUniswapV3PoolLike(pool).increaseObservationCardinalityNext(2);
        uint256 poolInitGas = gasStart - gasleft();

        IERC20(address(token)).approve(NPM, SEED);
        IERC20(WETH).approve(NPM, SEED);
        bool companyFirst = address(token) < WETH;
        gasStart = gasleft();
        (uint256 lpTokenId, uint128 spotLiquidity,,) = IFreshBootstrapNPM(NPM)
            .mint(
                IFreshBootstrapNPM.MintParams({
                token0: companyFirst ? address(token) : WETH,
                token1: companyFirst ? WETH : address(token),
                fee: FEE,
                tickLower: -887_270,
                tickUpper: 887_270,
                amount0Desired: SEED,
                amount1Desired: SEED,
                amount0Min: (SEED * 99) / 100,
                amount1Min: (SEED * 99) / 100,
                recipient: operator,
                deadline: block.timestamp + 10 minutes
            })
            );
        uint256 poolSeedGas = gasStart - gasleft();

        gasStart = gasleft();
        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        uint256 proposalImplementationGas = gasStart - gasleft();

        gasStart = gasleft();
        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);
        uint256 stackDeployerGas = gasStart - gasleft();

        FAOSepoliaSiteReleaseDeployment.Config memory config = FAOSepoliaSiteReleaseDeployment.Config({
            proxyFactory: _dependency(SX_PROXY_FACTORY),
            spaceImplementation: _dependency(SX_SPACE_IMPLEMENTATION),
            proposalValidationStrategy: _dependency(SX_PROPOSAL_VALIDATION),
            stackDeployer: _dependency(address(stackDeployer)),
            proposalImplementation: _dependency(address(proposalImplementation)),
            bondToken: _dependency(WETH),
            conditionalTokens: _dependency(CTF),
            wrapped1155Factory: _dependency(W1155),
            uniswapV3Factory: _dependency(UNIV3_FACTORY),
            companyToken: _dependency(address(token)),
            spotPool: _dependency(pool),
            graduationThreshold: 0.001 ether,
            arbitrationTimeout: 30 minutes,
            minActivationBond: 0.0001 ether,
            feeTier: FEE,
            observationCardinality: 100,
            twapTimeout: 30 minutes,
            twapWindow: 15 minutes,
            spaceSaltNonce: 1,
            daoURI: "ipfs://fao-site-dao",
            metadataURI: "ipfs://fao-site-space"
        });

        gasStart = gasleft();
        FAOSepoliaSiteReleaseDeployment deployment = new FAOSepoliaSiteReleaseDeployment(config);
        uint256 atomicDeploymentGas = gasStart - gasleft();

        assertGt(lpTokenId, 0);
        assertGt(spotLiquidity, 0);
        FAOOfficialProposalOrchestrator orchestrator =
            FAOOfficialProposalOrchestrator(deployment.orchestrator());
        assertEq(orchestrator.COMPANY_TOKEN(), address(token));
        assertEq(orchestrator.SPOT_POOL(), pool);

        bytes memory releasePayload = abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: 1,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: keccak256("fresh-site-release"),
                artifactURI: "ipfs://fresh-site-release"
            })
        );
        SXProposalGateway(deployment.proposalGateway())
            .propose("ipfs://fresh-site-proposal", releasePayload, "");

        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        IFreshBootstrapWETH9(WETH).deposit{value: 0.002 ether}();
        IERC20(WETH).approve(address(arbitration), type(uint256).max);
        uint256 arbitrationId = uint256(keccak256(releasePayload));
        arbitration.placeYesBond(arbitrationId, 0.0001 ether);
        arbitration.placeNoBond(arbitrationId);
        arbitration.placeYesBond(arbitrationId, 0.001 ether);
        arbitration.startNextEvaluation();

        gasStart = gasleft();
        FAOSiteEvaluationPipeline(deployment.evaluator())
            .startEvaluation(arbitrationId, releasePayload);
        uint256 marketCreationGas = gasStart - gasleft();
        vm.warp(block.timestamp + 30 minutes);

        gasStart = gasleft();
        bool accepted = FAOSiteEvaluationPipeline(deployment.evaluator()).resolve(arbitrationId);
        uint256 marketResolutionGas = gasStart - gasleft();
        vm.stopPrank();

        assertFalse(accepted);
        assertEq(arbitration.activeEvaluationProposalId(), 0);
        assertTrue(arbitration.isSettled(arbitrationId));
        assertFalse(arbitration.isAccepted(arbitrationId));

        console2.log("fresh token deploy gas", tokenGas);
        console2.log("UniV3 pool create gas", poolCreateGas);
        console2.log("pool init + cardinality gas", poolInitGas);
        console2.log("NPM seed gas", poolSeedGas);
        console2.log("proposal implementation gas", proposalImplementationGas);
        console2.log("stack helper gas", stackDeployerGas);
        console2.log("atomic site stack gas", atomicDeploymentGas);
        console2.log("official market creation gas", marketCreationGas);
        console2.log("no-trade market resolution gas", marketResolutionGas);
        console2.log(
            "total measured gas",
            tokenGas + poolCreateGas + poolInitGas + poolSeedGas + proposalImplementationGas
                + stackDeployerGas + atomicDeploymentGas
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
}
