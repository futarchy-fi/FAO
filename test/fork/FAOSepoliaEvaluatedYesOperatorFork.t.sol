// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {
    IOperatorConditionalTokens,
    IOperatorPoolLiquidity,
    IOperatorPositionManager,
    IOperatorSwapRouter
} from "../../script/OperateFAOSepoliaEvaluation.s.sol";
import {FAOFutarchyProposal} from "../../src/FAOFutarchyProposal.sol";
import {FAOSepoliaSiteReleaseDeployment} from "../../src/FAOSepoliaSiteReleaseDeployment.sol";
import {FAOSiteEvaluationPipeline} from "../../src/FAOSiteEvaluationPipeline.sol";
import {FAOSiteToken} from "../../src/FAOSiteToken.sol";
import {FAOTwapResolver} from "../../src/FAOTwapResolver.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {FAOSiteStackDeployer} from "../../src/FAOSiteStackDeployer.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {SXProposalGateway} from "../../src/SXProposalGateway.sol";
import {IConditionalTokensLike} from "../../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

interface IEvaluatedYesWETH9 {
    function deposit() external payable;
}

contract FAOSepoliaEvaluatedYesOperatorForkTest is Test {
    address internal constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address internal constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address internal constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address internal constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address internal constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address internal constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address internal constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;

    uint24 internal constant FEE = 500;
    uint256 internal constant SPOT_SEED = 0.001 ether;
    uint256 internal constant CONDITIONAL_SEED = 0.0001 ether;
    uint256 internal constant YES_MOVE = CONDITIONAL_SEED / 100;

    function testForkOperatorProducesEvaluatedYes() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia.publicnode.com");

        address operator = makeAddr("evaluated-yes-operator");
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);

        (FAOSiteToken token, FAOSepoliaSiteReleaseDeployment deployment) =
            _deployFreshStack(operator);
        (uint256 arbitrationId, address proposalAddress) = _startEvaluation(deployment);

        uint256 operationGasStart = gasleft();
        (uint256 yesNft, uint256 noNft, int24 noTick, int24 yesTickAfter) =
            _seedAndMove(deployment, token, proposalAddress, operator);
        uint256 operationGas = operationGasStart - gasleft();
        assertGt(yesNft, 0);
        assertGt(noNft, 0);
        assertGt(yesTickAfter, noTick);

        vm.warp(block.timestamp + 30 minutes);
        uint256 resolutionGasStart = gasleft();
        bool accepted = FAOSiteEvaluationPipeline(deployment.evaluator()).resolve(arbitrationId);
        uint256 resolutionGas = resolutionGasStart - gasleft();
        vm.stopPrank();

        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        assertTrue(accepted);
        assertEq(arbitration.activeEvaluationProposalId(), 0);
        assertTrue(arbitration.isSettled(arbitrationId));
        assertTrue(arbitration.isAccepted(arbitrationId));

        console2.log("conditional seed + bounded YES move gas", operationGas);
        console2.log("evaluated-YES resolution gas", resolutionGas);
        console2.log("yes economic tick", int256(yesTickAfter));
        console2.log("no economic tick", int256(noTick));
    }

    function _deployFreshStack(address operator)
        private
        returns (FAOSiteToken token, FAOSepoliaSiteReleaseDeployment deployment)
    {
        token = new FAOSiteToken(operator, 1_000_000 ether);
        IEvaluatedYesWETH9(WETH).deposit{value: 0.003 ether}();

        address spotPool =
            IUniswapV3FactoryLike(UNIV3_FACTORY).createPool(address(token), WETH, FEE);
        IUniswapV3PoolLike(spotPool).initialize(uint160(1 << 96));
        IUniswapV3PoolLike(spotPool).increaseObservationCardinalityNext(2);
        _mint(operator, spotPool, address(token), WETH, SPOT_SEED);

        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);
        deployment = new FAOSepoliaSiteReleaseDeployment(
            FAOSepoliaSiteReleaseDeployment.Config({
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
                spotPool: _dependency(spotPool),
                graduationThreshold: 0.001 ether,
                arbitrationTimeout: 30 minutes,
                minActivationBond: 0.0001 ether,
                feeTier: FEE,
                observationCardinality: 100,
                twapTimeout: 30 minutes,
                twapWindow: 15 minutes,
                spaceSaltNonce: 1,
                daoURI: "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                metadataURI: "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                votingStrategyMetadataURI: "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
                proposalValidationStrategyMetadataURI: "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd"
            })
        );
    }

    function _startEvaluation(FAOSepoliaSiteReleaseDeployment deployment)
        private
        returns (uint256 arbitrationId, address proposal)
    {
        bytes memory releasePayload = abi.encode(
            SXArbitrationExecutionStrategy.SiteRelease({
                nonce: 1,
                expectedCurrentDigest: bytes32(0),
                artifactDigest: keccak256("evaluated-yes-site-release"),
                artifactURI: "ipfs://evaluated-yes-site-release"
            })
        );
        SXProposalGateway(deployment.proposalGateway())
            .propose("ipfs://evaluated-yes-proposal", releasePayload, "");

        FutarchyArbitration arbitration = FutarchyArbitration(deployment.arbitration());
        IERC20(WETH).approve(address(arbitration), type(uint256).max);
        arbitrationId = uint256(keccak256(releasePayload));
        arbitration.placeYesBond(arbitrationId, 0.0001 ether);
        arbitration.placeNoBond(arbitrationId);
        arbitration.placeYesBond(arbitrationId, 0.001 ether);
        arbitration.startNextEvaluation();

        FAOSiteEvaluationPipeline evaluator = FAOSiteEvaluationPipeline(deployment.evaluator());
        evaluator.startEvaluation(arbitrationId, releasePayload);
        proposal = evaluator.futarchyProposalOf(arbitrationId);
    }

    function _seedAndMove(
        FAOSepoliaSiteReleaseDeployment deployment,
        FAOSiteToken token,
        address proposalAddress,
        address operator
    ) private returns (uint256 yesNft, uint256 noNft, int24 noTick, int24 yesTickAfter) {
        FAOFutarchyProposal proposal = FAOFutarchyProposal(proposalAddress);
        FAOTwapResolver resolver = FAOTwapResolver(deployment.resolver());
        (address yesPool, address noPool,,,,,,) = resolver.bindings(proposalAddress);
        assertEq(IOperatorPoolLiquidity(yesPool).liquidity(), 0);
        assertEq(IOperatorPoolLiquidity(noPool).liquidity(), 0);
        (address yesCompany, bytes memory yesCompanyData) = proposal.wrappedOutcome(0);
        (address noCompany, bytes memory noCompanyData) = proposal.wrappedOutcome(1);
        (address yesCurrency, bytes memory yesCurrencyData) = proposal.wrappedOutcome(2);
        (address noCurrency, bytes memory noCurrencyData) = proposal.wrappedOutcome(3);

        IConditionalTokensLike ctf = IConditionalTokensLike(CTF);
        _split(ctf, address(token), proposal.conditionId(), CONDITIONAL_SEED);
        _split(ctf, WETH, proposal.conditionId(), CONDITIONAL_SEED + YES_MOVE);
        _wrap(
            ctf,
            operator,
            address(token),
            proposal.conditionId(),
            1,
            yesCompanyData,
            CONDITIONAL_SEED
        );
        _wrap(
            ctf,
            operator,
            address(token),
            proposal.conditionId(),
            2,
            noCompanyData,
            CONDITIONAL_SEED
        );
        _wrap(
            ctf,
            operator,
            WETH,
            proposal.conditionId(),
            1,
            yesCurrencyData,
            CONDITIONAL_SEED + YES_MOVE
        );
        _wrap(
            ctf,
            operator,
            WETH,
            proposal.conditionId(),
            2,
            noCurrencyData,
            CONDITIONAL_SEED + YES_MOVE
        );

        (yesNft,) = _mint(operator, yesPool, yesCompany, yesCurrency, CONDITIONAL_SEED);
        (noNft,) = _mint(operator, noPool, noCompany, noCurrency, CONDITIONAL_SEED);
        assertGt(IOperatorPoolLiquidity(yesPool).liquidity(), 0);
        assertGt(IOperatorPoolLiquidity(noPool).liquidity(), 0);
        noTick = _economicTick(noPool, noCompany);

        IERC20(yesCurrency).approve(SWAP_ROUTER, YES_MOVE);
        uint160 limit = _boundedYesPriceLimit(yesPool, yesCompany);
        IOperatorSwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IOperatorSwapRouter.ExactInputSingleParams({
                tokenIn: yesCurrency,
                tokenOut: yesCompany,
                fee: FEE,
                recipient: operator,
                amountIn: YES_MOVE,
                amountOutMinimum: (YES_MOVE * 98) / 100,
                sqrtPriceLimitX96: limit
            })
            );
        yesTickAfter = _economicTick(yesPool, yesCompany);
        assertLe(uint256(uint24(yesTickAfter - noTick)), 500);
    }

    function _split(
        IConditionalTokensLike ctf,
        address collateral,
        bytes32 conditionId,
        uint256 amount
    ) private {
        IERC20(collateral).approve(address(ctf), amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        IOperatorConditionalTokens(address(ctf))
            .splitPosition(collateral, bytes32(0), conditionId, partition, amount);
    }

    function _wrap(
        IConditionalTokensLike ctf,
        address operator,
        address collateral,
        bytes32 conditionId,
        uint256 indexSet,
        bytes memory tokenData,
        uint256 amount
    ) private {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = ctf.getPositionId(collateral, collectionId);
        IOperatorConditionalTokens(address(ctf))
            .safeTransferFrom(operator, W1155, tokenId, amount, tokenData);
    }

    function _mint(address operator, address pool, address tokenA, address tokenB, uint256 amount)
        private
        returns (uint256 tokenId, uint128 liquidity)
    {
        address token0 = tokenA < tokenB ? tokenA : tokenB;
        address token1 = tokenA < tokenB ? tokenB : tokenA;
        IERC20(token0).approve(NPM, amount);
        IERC20(token1).approve(NPM, amount);
        (tokenId, liquidity,,) = IOperatorPositionManager(NPM)
            .mint(
                IOperatorPositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE,
                tickLower: -887_270,
                tickUpper: 887_270,
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: (amount * 99) / 100,
                amount1Min: (amount * 99) / 100,
                recipient: operator,
                deadline: block.timestamp + 10 minutes
            })
            );
        assertEq(IUniswapV3FactoryLike(UNIV3_FACTORY).getPool(token0, token1, FEE), pool);
    }

    function _boundedYesPriceLimit(address pool, address yesCompany)
        private
        view
        returns (uint160)
    {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        (uint160 current,,,,,,) = p.slot0();
        return p.token0() == yesCompany
            ? uint160(uint256(current) * 1024 / 1000)
            : uint160(uint256(current) * 1000 / 1024);
    }

    function _economicTick(address pool, address companyWrapper) private view returns (int24) {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        (, int24 tick,,,,,) = p.slot0();
        return p.token0() == companyWrapper ? tick : -tick;
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
