// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";
import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {Space} from "lib/sx-evm/src/Space.sol";

import {AlwaysZeroVotingStrategy} from "../../src/AlwaysZeroVotingStrategy.sol";
import {EconGateway} from "../../src/EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "../../src/FAOEconomicEvaluationPipeline.sol";
import {FAOFutarchyProposal} from "../../src/FAOFutarchyProposal.sol";
import {FaoGenesisDeployment} from "../../src/FaoGenesisDeployment.sol";
import {FAOSiteStackDeployer} from "../../src/FAOSiteStackDeployer.sol";
import {FutarchyArbitration} from "../../src/FutarchyArbitration.sol";
import {GenesisVault} from "../../src/GenesisVault.sol";
import {SXArbitrationExecutionStrategy} from "../../src/SXArbitrationExecutionStrategy.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

interface IFaoGenesisForkWeth {
    function deposit() external payable;
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
        assertEq(manager.balanceOf(address(vault)), shares);
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

    function _dependency(address target)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: target.codehash});
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
    }
}
