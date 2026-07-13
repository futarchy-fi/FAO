// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {UniV3PoolStabilityGuard} from "flm/oracles/UniV3PoolStabilityGuard.sol";
import {Space} from "lib/sx-evm/src/Space.sol";

import {
    IOperatorPoolLiquidity,
    IOperatorSwapRouter
} from "../../script/OperateFAOSepoliaEvaluation.s.sol";
import {AlwaysZeroVotingStrategy} from "../../src/AlwaysZeroVotingStrategy.sol";
import {EconGateway} from "../../src/EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "../../src/FAOEconomicEvaluationPipeline.sol";
import {FAOFutarchyProposal} from "../../src/FAOFutarchyProposal.sol";
import {FAOTreasuryActions} from "../../src/FAOTreasuryActions.sol";
import {FaoGenesisDeployment} from "../../src/FaoGenesisDeployment.sol";
import {FaoGenesisRegistrar} from "../../src/FaoGenesisRegistrar.sol";
import {FAOSiteStackDeployer} from "../../src/FAOSiteStackDeployer.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {GenesisVault} from "../../src/GenesisVault.sol";
import {GenesisTreasuryExecutor} from "../../src/GenesisTreasuryExecutor.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {EconomicDeploymentCodeHashes} from "../../src/generated/EconomicDeploymentCodeHashes.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

interface IFaoGenesisForkWeth {
    function deposit() external payable;
}

contract Lane4ForkTarget {
    address public caller;
    bytes32 public payload;
    uint256 public value;

    function perform(bytes32 payload_) external payable returns (uint256) {
        caller = msg.sender;
        payload = payload_;
        value += msg.value;
        return value;
    }
}

contract FaoGenesisDeploymentForkTest is Test {
    address private constant SX_PROXY_FACTORY = 0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c;
    address private constant SX_SPACE_IMPLEMENTATION = 0xC3031A7d3326E47D49BfF9D374d74f364B29CE4D;
    address private constant SX_PROPOSAL_VALIDATION = 0x9A39194F870c410633C170889E9025fba2113c79;
    address private constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address private constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address private constant WRAPPED_1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    address private constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address private constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address private constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    bytes32 private constant SWAP_ROUTER_CODEHASH =
        0xe7f98ee73dfe6d5c96cbf8936920f496b1b82f24326d6a415b4144a2252271de;

    uint256 private constant BUY_AMOUNT = 0.1 ether;

    function testFork_stagedEconomicGenesisFinalizesAgainstCanonicalSepolia() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        (
            FaoGenesisDeployment receipt,
            FaoGenesisDeployment.CoreConfig memory coreConfig,
            uint256 coreGas,
            uint256 flmGas
        ) = _deployReceipt();

        GenesisVault vault = GenesisVault(payable(receipt.vault()));
        GenesisTreasuryExecutor treasury = vault.TREASURY_EXECUTOR();
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(receipt.manager()));
        address buyer = makeAddr("economic-genesis-buyer");
        uint256 cost = vault.reserveAt(BUY_AMOUNT);
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        IFaoGenesisForkWeth(WETH).deposit{value: cost}();
        IERC20(WETH).approve(address(vault), cost);
        assertEq(vault.buy(BUY_AMOUNT, cost, block.timestamp), cost);
        vm.stopPrank();

        vm.warp(coreConfig.saleEnd);
        vault.seal();
        assertEq(
            IUniswapV3FactoryLike(UNIV3_FACTORY).getPool(receipt.companyToken(), WETH, 500),
            address(0)
        );

        uint256 gasBefore = gasleft();
        uint256 shares = vault.finalize();
        uint256 finalizeGas = gasBefore - gasleft();

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(receipt.spotPool());
        (uint160 sqrtPriceX96,,,, uint16 cardinalityNext,,) = pool.slot0();
        assertEq(uint256(vault.phase()), uint256(GenesisVault.Phase.LIVE));
        assertEq(sqrtPriceX96, receipt.sqrtPriceX96(vault.terminalPrice()));
        assertGe(cardinalityNext, receipt.OBSERVATION_CARDINALITY());
        assertEq(
            IUniswapV3FactoryLike(UNIV3_FACTORY).getPool(receipt.companyToken(), WETH, 500),
            address(pool)
        );
        assertTrue(manager.initializedFromBootstrap());
        assertGt(manager.spotLiquidity(), 0);
        assertEq(manager.balanceOf(address(vault)), 0);
        assertEq(manager.balanceOf(address(treasury)), shares);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
        assertGt(IERC20(WETH).balanceOf(address(treasury)), 0);
        assertGt(shares, 0);
        assertEq(IERC20(receipt.companyToken()).allowance(address(vault), address(manager)), 0);
        assertEq(IERC20(WETH).allowance(address(vault), address(manager)), 0);
        assertEq(
            IERC20(receipt.companyToken()).allowance(address(manager), receipt.spotAdapter()), 0
        );
        assertEq(IERC20(WETH).allowance(address(manager), receipt.spotAdapter()), 0);

        assertEq(Space(receipt.space()).owner(), address(0));
        assertEq(FutarchyArbitration(receipt.arbitration()).owner(), address(0));
        assertEq(manager.owner(), receipt.DEAD());
        assertEq(Space(receipt.space()).activeVotingStrategies(), 1);
        (address votingStrategy, bytes memory votingParams) =
            Space(receipt.space()).votingStrategies(0);
        assertEq(votingStrategy, receipt.votingStrategy());
        assertEq(votingParams.length, 0);
        assertEq(AlwaysZeroVotingStrategy(votingStrategy).getVotingPower(0, buyer, "", ""), 0);

        assertEq(vault.purchased(buyer), BUY_AMOUNT);
        vault.claim(buyer);
        assertEq(IERC20(receipt.companyToken()).balanceOf(buyer), BUY_AMOUNT);
        assertEq(vault.purchased(buyer), 0);

        console2.log("economic core stage gas", coreGas);
        console2.log("economic FLM stage gas", flmGas);
        console2.log("economic atomic finalize gas", finalizeGas);
    }

    /// @dev No economic-genesis receipt is live on Sepolia yet: the predicted nonce-187 receipt
    /// has no code, while the deployed site-release pool uses a different token without this
    /// executor/burn path. This fresh fork composition therefore exercises the canonical pool.
    function testFork_realUniV3BuybackBurnsDiscountedFAO() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        (FaoGenesisDeployment receipt, FaoGenesisDeployment.CoreConfig memory coreConfig,,) =
            _deployReceipt();
        GenesisVault vault = GenesisVault(payable(receipt.vault()));
        GenesisTreasuryExecutor treasury = vault.TREASURY_EXECUTOR();
        address buyer = makeAddr("canonical-buyback-seller");
        uint256 cost = vault.reserveAt(BUY_AMOUNT);
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        IFaoGenesisForkWeth(WETH).deposit{value: cost}();
        IERC20(WETH).approve(address(vault), cost);
        vault.buy(BUY_AMOUNT, cost, block.timestamp);
        vm.stopPrank();

        vm.warp(coreConfig.saleEnd);
        vault.seal();
        vault.finalize();
        vault.claim(buyer);

        address company = receipt.companyToken();
        address pool = receipt.spotPool();
        assertEq(
            IUniswapV3FactoryLike(UNIV3_FACTORY).getPool(company, WETH, receipt.FEE_TIER()), pool
        );
        assertGt(IOperatorPoolLiquidity(pool).liquidity(), 0);
        assertGt(IERC20(WETH).balanceOf(address(treasury)), 0);
        assertEq(SWAP_ROUTER.codehash, SWAP_ROUTER_CODEHASH);
        assertEq(IOperatorSwapRouter(SWAP_ROUTER).factory(), UNIV3_FACTORY);

        vm.startPrank(buyer);
        IERC20(company).approve(SWAP_ROUTER, BUY_AMOUNT);
        uint256 wethOut = IOperatorSwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IOperatorSwapRouter.ExactInputSingleParams({
                    tokenIn: company,
                    tokenOut: WETH,
                    fee: receipt.FEE_TIER(),
                    recipient: buyer,
                    amountIn: BUY_AMOUNT,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();
        assertGt(wethOut, 0);
        assertEq(IERC20(company).balanceOf(buyer), 0);

        vm.warp(block.timestamp + 30 minutes);
        UniV3PoolStabilityGuard(receipt.guard()).assertStablePair(company, WETH);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(treasury));
        uint256 companyBefore = IERC20(company).balanceOf(address(treasury));
        uint256 supplyBefore = IERC20(company).totalSupply();
        vm.prank(makeAddr("permissionless-buyback-keeper"));
        (uint256 wethSpent, uint256 companyBurned) = vault.buyback();

        assertGt(wethSpent, 0);
        assertGt(companyBurned, 0);
        assertEq(wethBefore - IERC20(WETH).balanceOf(address(treasury)), wethSpent);
        assertEq(IERC20(company).balanceOf(address(treasury)), companyBefore);
        assertEq(supplyBefore - IERC20(company).totalSupply(), companyBurned);
        UniV3PoolStabilityGuard(receipt.guard()).assertStablePair(company, WETH);
    }

    function testFork_realEmptyPoolSwapNormalizesWithoutPayment() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        (FaoGenesisDeployment receipt,,,) = _deployReceipt();
        GenesisVault vault = GenesisVault(payable(receipt.vault()));
        uint256 terminalPrice = vault.terminalPrice();
        uint160 target = receipt.sqrtPriceX96(terminalPrice);
        address poolAddress = IUniswapV3FactoryLike(UNIV3_FACTORY)
            .createPool(receipt.companyToken(), WETH, receipt.FEE_TIER());
        assertEq(poolAddress, receipt.spotPool());
        IUniswapV3PoolLike(poolAddress).initialize(target + 1);

        assertEq(IERC20(receipt.companyToken()).balanceOf(address(receipt)), 0);
        assertEq(IERC20(WETH).balanceOf(address(receipt)), 0);
        uint256 gasBefore = gasleft();
        vm.prank(address(vault));
        receipt.prepareAndAssert(terminalPrice);
        uint256 normalizeGas = gasBefore - gasleft();

        (uint160 normalized,,,, uint16 cardinalityNext,,) = IUniswapV3PoolLike(poolAddress).slot0();
        assertEq(normalized, target);
        assertGe(cardinalityNext, receipt.OBSERVATION_CARDINALITY());
        assertEq(IERC20(receipt.companyToken()).balanceOf(address(receipt)), 0);
        assertEq(IERC20(WETH).balanceOf(address(receipt)), 0);
        console2.log("economic empty-pool normalization gas", normalizeGas);
    }

    function testFork_registrarRouteResumesPermissionlesslyAcrossCallers() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);
        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        FaoGenesisDeployment.CoreConfig memory coreConfig =
            _coreConfig(stackDeployer, proposalImplementation);
        FaoGenesisDeployment.FlmConfig memory flmConfig = _flmConfig();
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        bytes32 coreHash = keccak256(abi.encode(coreConfig, grants));
        bytes32 flmHash = keccak256(abi.encode(flmConfig));
        bytes memory receiptCode = vm.readFileBinary("metadata/economic-creation-code/receipt.bin");
        assertEq(keccak256(receiptCode), EconomicDeploymentCodeHashes.RECEIPT);

        FaoGenesisRegistrar registrar =
            new FaoGenesisRegistrar(EconomicDeploymentCodeHashes.RECEIPT);
        address predicted = registrar.predict(coreHash, flmHash, receiptCode);
        address stager = makeAddr("registrar-stager");
        vm.prank(stager);
        FaoGenesisDeployment receipt =
            FaoGenesisDeployment(registrar.stage(coreHash, flmHash, receiptCode));
        assertEq(address(receipt), predicted);

        vm.prank(makeAddr("mempool-copier"));
        assertEq(registrar.stage(coreHash, flmHash, receiptCode), predicted);
        vm.prank(makeAddr("core-completer"));
        receipt.deployCore(coreConfig, grants, _coreCodes());
        vm.prank(makeAddr("flm-completer"));
        receipt.deployFlm(flmConfig, _flmCodes());

        assertTrue(receipt.coreSealed());
        assertTrue(receipt.flmSealed());
        assertEq(Space(receipt.space()).owner(), address(0));
        assertEq(FutarchyArbitration(receipt.arbitration()).owner(), address(0));
        assertEq(FutarchyLiquidityManager(payable(receipt.manager())).owner(), receipt.DEAD());
        GenesisVault vault = GenesisVault(payable(receipt.vault()));
        assertEq(vault.TREASURY_EXECUTOR().VAULT(), address(vault));
    }

    function testFork_lane4CompressedTreasuryLifecycle() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        vm.createSelectFork("https://ethereum-sepolia-rpc.publicnode.com");

        (FaoGenesisDeployment receipt, FaoGenesisDeployment.CoreConfig memory coreConfig,,) =
            _deployReceipt();
        GenesisVault vault = GenesisVault(payable(receipt.vault()));
        GenesisTreasuryExecutor treasury = vault.TREASURY_EXECUTOR();
        FutarchyArbitration arbitration = FutarchyArbitration(receipt.arbitration());
        EconGateway gateway = EconGateway(receipt.proposalGateway());

        address buyer = makeAddr("lane4-buyer");
        uint256 cost = vault.reserveAt(BUY_AMOUNT);
        vm.deal(buyer, 1 ether);
        vm.startPrank(buyer);
        IFaoGenesisForkWeth(WETH).deposit{value: cost}();
        IERC20(WETH).approve(address(vault), type(uint256).max);
        vault.buy(BUY_AMOUNT, cost, block.timestamp);
        vm.stopPrank();
        vm.warp(coreConfig.saleEnd);
        vault.seal();
        vault.finalize();
        vault.claim(buyer);

        vm.deal(address(this), 1 ether);
        IFaoGenesisForkWeth(WETH).deposit{value: 0.2 ether}();
        IERC20(WETH).transfer(address(treasury), 0.05 ether);
        IERC20(WETH).approve(address(arbitration), type(uint256).max);
        address recipient = makeAddr("lane4-recipient");

        FAOTreasuryActions.TransferAction memory small = FAOTreasuryActions.TransferAction({
            asset: WETH, recipient: recipient, amount: 0.005 ether, salt: bytes32("fork-small")
        });
        uint256 smallId = gateway.proposeTransfer(small);
        arbitration.placeYesBond(smallId, 0.0001 ether);
        vm.warp(block.timestamp + 30 minutes);
        arbitration.finalizeByTimeout(smallId);
        vault.queueTreasuryTransfer(small);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryTransfer(small);
        assertEq(IERC20(WETH).balanceOf(recipient), small.amount);

        FAOTreasuryActions.TransferAction memory medium = FAOTreasuryActions.TransferAction({
            asset: WETH, recipient: recipient, amount: 0.02 ether, salt: bytes32("fork-medium")
        });
        uint256 mediumId = gateway.proposeTransfer(medium);
        _settleEvaluatedYes(arbitration, receipt.evaluator(), mediumId);
        vault.queueTreasuryTransfer(medium);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryTransfer(medium);
        assertEq(IERC20(WETH).balanceOf(recipient), small.amount + medium.amount);

        FAOTreasuryActions.ParamAction memory param = FAOTreasuryActions.ParamAction({
            key: vault.KEY_TAP_BUDGET(), asset: WETH, value: 0.02 ether, salt: bytes32("fork-param")
        });
        uint256 paramId = gateway.proposeParam(param);
        _settleEvaluatedYes(arbitration, receipt.evaluator(), paramId);
        vault.queueTreasuryParam(param);
        vm.warp(block.timestamp + vault.TREASURY_GRACE());
        vault.executeTreasuryParam(param);
        (,, uint128 tapBudget,,) = vault.assetPolicies(WETH);
        assertEq(tapBudget, param.value);

        Lane4ForkTarget target = new Lane4ForkTarget();
        (bool funded,) = payable(address(treasury)).call{value: 0.002 ether}("");
        assertTrue(funded);
        FAOTreasuryActions.CriticalAction memory critical = FAOTreasuryActions.CriticalAction({
            target: address(target),
            value: 0.001 ether,
            data: abi.encodeCall(target.perform, (bytes32("fork-critical"))),
            salt: bytes32("fork-critical")
        });
        uint256 roundOne = gateway.proposeCriticalRound(critical, 1);
        _settleEvaluatedYes(arbitration, receipt.evaluator(), roundOne);
        vault.stageCriticalAction(critical);
        vm.warp(block.timestamp + vault.CRITICAL_INTERVAL());
        uint256 roundTwo = gateway.proposeCriticalRound(critical, 2);
        _settleEvaluatedYes(arbitration, receipt.evaluator(), roundTwo);
        vault.queueCriticalAction(critical);

        address[] memory extras = new address[](0);
        vm.prank(buyer);
        vault.ragequit(0.01 ether, payable(buyer), extras);
        assertEq(IERC20(receipt.companyToken()).balanceOf(buyer), 0.09 ether);

        vm.warp(block.timestamp + vault.CRITICAL_GRACE());
        vault.executeCriticalAction(critical);
        assertEq(target.caller(), address(treasury));
        assertEq(target.payload(), bytes32("fork-critical"));
        assertEq(target.value(), critical.value);
    }

    function _settleEvaluatedYes(
        FutarchyArbitration arbitration,
        address evaluator,
        uint256 proposalId
    ) private {
        arbitration.placeYesBond(proposalId, 0.0001 ether);
        arbitration.placeNoBond(proposalId);
        arbitration.placeYesBond(proposalId, 0.01 ether);
        arbitration.startNextEvaluation();
        vm.prank(evaluator);
        arbitration.resolveActiveEvaluation(true);
    }

    function _deployReceipt()
        private
        returns (
            FaoGenesisDeployment receipt,
            FaoGenesisDeployment.CoreConfig memory coreConfig,
            uint256 coreGas,
            uint256 flmGas
        )
    {
        FAOSiteStackDeployer stackDeployer = new FAOSiteStackDeployer(false);
        FAOFutarchyProposal proposalImplementation = new FAOFutarchyProposal();
        coreConfig = _coreConfig(stackDeployer, proposalImplementation);
        FaoGenesisDeployment.FlmConfig memory flmConfig = _flmConfig();
        GenesisVault.GrantConfig[] memory grants = new GenesisVault.GrantConfig[](0);
        receipt = new FaoGenesisDeployment(
            keccak256(abi.encode(coreConfig, grants)), keccak256(abi.encode(flmConfig))
        );

        uint256 gasBefore = gasleft();
        receipt.deployCore(coreConfig, grants, _coreCodes());
        coreGas = gasBefore - gasleft();
        gasBefore = gasleft();
        receipt.deployFlm(flmConfig, _flmCodes());
        flmGas = gasBefore - gasleft();
    }

    function _coreConfig(
        FAOSiteStackDeployer stackDeployer,
        FAOFutarchyProposal proposalImplementation
    ) private view returns (FaoGenesisDeployment.CoreConfig memory) {
        return FaoGenesisDeployment.CoreConfig({
            proxyFactory: _dependency(SX_PROXY_FACTORY),
            spaceImplementation: _dependency(SX_SPACE_IMPLEMENTATION),
            proposalValidationStrategy: _dependency(SX_PROPOSAL_VALIDATION),
            stackDeployer: _dependency(address(stackDeployer)),
            proposalImplementation: _dependency(address(proposalImplementation)),
            weth: _dependency(WETH),
            conditionalTokens: _dependency(CTF),
            wrapped1155Factory: _dependency(WRAPPED_1155),
            uniswapV3Factory: _dependency(UNIV3_FACTORY),
            graduationThreshold: 0.01 ether,
            arbitrationTimeout: 30 minutes,
            siteMinActivationBond: 0.0001 ether,
            treasuryMinActivationBond: 0.0001 ether,
            assetPolicies: _assetPolicies(),
            twapTimeout: 30 minutes,
            twapWindow: 15 minutes,
            spaceSaltNonce: 1,
            daoURI: "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            metadataURI: "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            votingStrategyMetadataURI: "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
            proposalValidationStrategyMetadataURI: "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd",
            tokenName: "Futarchy Autonomous Organization",
            tokenSymbol: "FAO",
            saleEnd: uint64(block.timestamp + 1 hours),
            bootstrapDeadline: uint64(block.timestamp + 2 hours),
            saleCap: 1 ether,
            minimumRaise: 0.001 ether,
            tokenMaxSupply: 4 ether,
            initialPrice: 0.01 ether,
            slope: 0.001 ether,
            bootstrapBps: 5000
        });
    }

    function _flmConfig() private view returns (FaoGenesisDeployment.FlmConfig memory) {
        return FaoGenesisDeployment.FlmConfig({positionManager: _dependency(NPM)});
    }

    function _assetPolicies()
        private
        pure
        returns (GenesisVault.AssetPolicyConfig[] memory policies)
    {
        policies = new GenesisVault.AssetPolicyConfig[](1);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: WETH,
            c1: 0.01 ether,
            c2: 0.1 ether,
            tapBudget: 0.01 ether,
            tapBudgetMax: 0.1 ether
        });
    }

    function _dependency(address target)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: target.codehash});
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
    }
}
