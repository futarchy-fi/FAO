// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ProxyFactory} from "lib/sx-evm/src/ProxyFactory.sol";
import {Space} from "lib/sx-evm/src/Space.sol";
import {
    VanillaProposalValidationStrategy
} from "lib/sx-evm/src/proposal-validation-strategies/VanillaProposalValidationStrategy.sol";

import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "../lib/futarchy-liquidity-manager/test/mocks/MockUniswapV3NonfungiblePositionManager.sol";

import {AlwaysZeroVotingStrategy} from "../src/AlwaysZeroVotingStrategy.sol";
import {EconGateway} from "../src/EconGateway.sol";
import {FAOEconomicEvaluationPipeline} from "../src/FAOEconomicEvaluationPipeline.sol";
import {FAOTreasuryActions} from "../src/FAOTreasuryActions.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOSiteStackDeployer} from "../src/FAOSiteStackDeployer.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FaoGenesisDeployment} from "../src/FaoGenesisDeployment.sol";
import {FutarchyArbitration} from "../src/FutarchyArbitration.sol";
import {GenesisVault, IGenesisArbitration, IGenesisBootstrapHook} from "../src/GenesisVault.sol";
import {SXArbitrationExecutionStrategy} from "../src/SXArbitrationExecutionStrategy.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";

interface IFaoGenesisCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external;
}

contract FaoGenesisDependencyMock {}

contract FaoGenesisTokenMock is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract FaoGenesisFactoryMock is IUniswapV3FactoryLike {
    mapping(bytes32 key => address pool) private pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(address, address, uint24) external pure returns (address) {
        revert("test config must install the predicted pool");
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

/// @dev Storage-backed so its runtime can be etched at the canonical CREATE2 address.
contract FaoGenesisPoolMock is IUniswapV3PoolLike {
    address public token0;
    address public token1;
    uint24 public fee;
    uint160 public sqrtPriceX96;
    uint16 public observationCardinalityNext;
    bool public hostileLiquidity;

    function configure(
        address tokenA,
        address tokenB,
        uint24 fee_,
        uint160 sqrtPriceX96_,
        bool hostileLiquidity_
    ) external {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        sqrtPriceX96 = sqrtPriceX96_;
        hostileLiquidity = hostileLiquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, observationCardinalityNext, 0, true);
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "initialized");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function increaseObservationCardinalityNext(uint16 requested) external {
        if (requested > observationCardinalityNext) observationCardinalityNext = requested;
    }

    function swap(address recipient, bool, int256, uint160 limit, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(recipient == msg.sender, "receipt recipient");
        if (hostileLiquidity) {
            IFaoGenesisCallback(msg.sender).uniswapV3SwapCallback(1, -1, "");
            return (1, -1);
        }
        IFaoGenesisCallback(msg.sender).uniswapV3SwapCallback(0, 0, "");
        sqrtPriceX96 = limit;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (int56[] memory ticks, uint160[] memory secondsPerLiquidity)
    {
        ticks = new int56[](secondsAgos.length);
        secondsPerLiquidity = new uint160[](secondsAgos.length);
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract FaoGenesisDeploymentTest is Test {
    uint256 private constant GRADUATION_THRESHOLD = 100 ether;
    uint256 private constant ACTIVATION_BOND = 1 ether;
    uint256 private constant TREASURY_BOND = 2 ether;
    string private constant DAO_URI =
        "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string private constant METADATA_URI =
        "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    string private constant VOTING_URI =
        "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc";
    string private constant VALIDATION_URI =
        "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd";

    ProxyFactory private proxyFactory;
    Space private spaceImplementation;
    VanillaProposalValidationStrategy private validationStrategy;
    FAOSiteStackDeployer private stackDeployer;
    FAOFutarchyProposal private proposalImplementation;
    FaoGenesisTokenMock private weth;
    FaoGenesisDependencyMock private ctf;
    FaoGenesisDependencyMock private wrapped1155;
    FaoGenesisFactoryMock private univ3Factory;
    MockUniswapV3NonfungiblePositionManager private positionManager;

    function setUp() public {
        proxyFactory = new ProxyFactory();
        spaceImplementation = new Space();
        validationStrategy = new VanillaProposalValidationStrategy();
        stackDeployer = new FAOSiteStackDeployer(false);
        proposalImplementation = new FAOFutarchyProposal();
        weth = new FaoGenesisTokenMock();
        ctf = new FaoGenesisDependencyMock();
        wrapped1155 = new FaoGenesisDependencyMock();
        univ3Factory = new FaoGenesisFactoryMock();
        positionManager = new MockUniswapV3NonfungiblePositionManager();
    }

    function test_stagedReceiptDeploysExactCoreAndFlmThenConsumesAllAuthority() public {
        FaoGenesisDeployment receipt = _newReceipt();
        bytes[] memory coreCodes = _coreCodes();

        uint256 gasBefore = gasleft();
        receipt.deployCore(_coreConfig(), _grants(), coreCodes);
        uint256 coreGas = gasBefore - gasleft();
        emit log_named_uint("economic core gas", coreGas);
        assertLt(coreGas, 27_000_000);

        assertTrue(receipt.coreSealed());
        assertEq(receipt.arbitration(), _createAddress(address(receipt), 1));
        assertEq(receipt.vault(), _createAddress(address(receipt), 2));
        assertEq(receipt.releaseStrategy(), _createAddress(address(receipt), 3));
        assertEq(receipt.votingStrategy(), _createAddress(address(receipt), 4));
        assertEq(receipt.proposalGateway(), _createAddress(address(receipt), 5));
        assertEq(receipt.evaluator(), _createAddress(address(receipt), 6));
        assertEq(receipt.companyToken(), _createAddress(receipt.vault(), 2));
        assertEq(GenesisVault(payable(receipt.vault())).grantCount(), 1);
        (address vestingWallet,,,) = GenesisVault(payable(receipt.vault())).grants(0);
        assertEq(vestingWallet, _createAddress(receipt.vault(), 1));
        assertEq(Space(receipt.space()).owner(), address(0));
        assertEq(FutarchyArbitration(receipt.arbitration()).owner(), address(0));
        assertEq(
            AlwaysZeroVotingStrategy(receipt.votingStrategy())
                .getVotingPower(0, address(this), "", ""),
            0
        );
        assertEq(FAOEconomicEvaluationPipeline(receipt.evaluator()).vault(), receipt.vault());
        assertEq(GenesisVault(payable(receipt.vault())).ASSEMBLER(), address(receipt));
        assertEq(address(GenesisVault(payable(receipt.vault())).BOOTSTRAP_HOOK()), address(receipt));
        _assertCoreWiring(receipt);

        bytes[] memory flmCodes = _flmCodes();
        gasBefore = gasleft();
        receipt.deployFlm(_flmConfig(), flmCodes);
        uint256 flmGas = gasBefore - gasleft();
        emit log_named_uint("economic FLM gas", flmGas);
        assertLt(flmGas, 15_000_000);

        assertTrue(receipt.flmSealed());
        assertEq(receipt.relay(), _createAddress(address(receipt), 7));
        assertEq(receipt.spotAdapter(), _createAddress(address(receipt), 8));
        assertEq(receipt.conditionalAdapter(), _createAddress(address(receipt), 9));
        assertEq(receipt.guard(), _createAddress(address(receipt), 10));
        assertEq(receipt.router(), _createAddress(address(receipt), 11));
        assertEq(receipt.manager(), _createAddress(address(receipt), 12));
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(receipt.manager()));
        assertEq(manager.owner(), receipt.DEAD());
        assertEq(manager.BOOTSTRAP_RECIPIENT(), receipt.vault());
        assertEq(address(GenesisVault(payable(receipt.vault())).manager()), address(manager));
    }

    function test_hashSealsRejectMutationsWithoutConsumingCreateNonce() public {
        FaoGenesisDeployment receipt = _newReceipt();
        FaoGenesisDeployment.CoreConfig memory changed = _coreConfig();
        changed.saleCap += 1;
        bytes32 actual = keccak256(abi.encode(changed, _grants()));
        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisDeployment.InvalidConfigHash.selector, receipt.CORE_CONFIG_HASH(), actual
            )
        );
        receipt.deployCore(changed, _grants(), _coreCodes());
        assertEq(_createAddress(address(receipt), 1).code.length, 0);

        bytes[] memory codes = _coreCodes();
        codes[1][0] = bytes1(uint8(codes[1][0]) ^ 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisDeployment.InvalidCodeHash.selector,
                uint256(1),
                receipt.VAULT_CODE_HASH(),
                keccak256(codes[1])
            )
        );
        receipt.deployCore(_coreConfig(), _grants(), codes);
        assertEq(_createAddress(address(receipt), 1).code.length, 0);

        receipt.deployCore(_coreConfig(), _grants(), _coreCodes());
        assertEq(receipt.arbitration(), _createAddress(address(receipt), 1));
    }

    function test_activeEvaluationCannotBlockTheFlmStage() public {
        FaoGenesisDeployment receipt = _newReceipt();
        receipt.deployCore(_coreConfig(), _grants(), _coreCodes());

        FAOTreasuryActions.TreasuryAction memory action = FAOTreasuryActions.TreasuryAction({
            target: address(0xBEEF), value: 0, data: "", salt: bytes32(uint256(1))
        });
        uint256 proposalId = EconGateway(receipt.proposalGateway()).proposeTreasuryAction(action);
        FutarchyArbitration arbitrationLike = FutarchyArbitration(receipt.arbitration());
        weth.mint(address(this), TREASURY_BOND * 2 + GRADUATION_THRESHOLD);
        weth.approve(address(arbitrationLike), type(uint256).max);
        arbitrationLike.placeYesBond(proposalId, TREASURY_BOND);
        arbitrationLike.placeNoBond(proposalId);
        arbitrationLike.placeYesBond(proposalId, GRADUATION_THRESHOLD);
        arbitrationLike.startNextEvaluation();
        assertEq(arbitrationLike.activeEvaluationProposalId(), proposalId);

        receipt.deployFlm(_flmConfig(), _flmCodes());
        assertTrue(receipt.flmSealed());
        assertEq(arbitrationLike.activeEvaluationProposalId(), proposalId);
    }

    function test_coreRejectsTerminalPriceOutsideRepresentablePoolDomainBeforeCreate() public {
        FaoGenesisDeployment.CoreConfig memory config = _coreConfig();
        config.initialPrice = type(uint256).max;
        config.slope = 0;
        FaoGenesisDeployment receipt = new FaoGenesisDeployment(
            keccak256(abi.encode(config, _grants())), keccak256(abi.encode(_flmConfig()))
        );

        vm.expectRevert();
        receipt.deployCore(config, _grants(), _coreCodes());
        assertEq(_createAddress(address(receipt), 1).code.length, 0);
    }

    function test_emptyPoolCanNormalizeAtZeroDeltaWithoutBuyerAssets() public {
        FaoGenesisDeployment receipt = _deployedReceipt();
        uint256 terminalPrice = 2e16;
        uint160 target = receipt.sqrtPriceX96(terminalPrice);
        FaoGenesisPoolMock pool = _installPool(receipt, target + 1, false);

        assertEq(weth.balanceOf(address(receipt)), 0);
        assertEq(IERC20(receipt.companyToken()).balanceOf(address(receipt)), 0);
        vm.prank(receipt.vault());
        receipt.prepareAndAssert(terminalPrice);

        assertEq(pool.sqrtPriceX96(), target);
        assertEq(pool.observationCardinalityNext(), receipt.OBSERVATION_CARDINALITY());
        assertEq(weth.balanceOf(address(receipt)), 0);
        assertEq(IERC20(receipt.companyToken()).balanceOf(address(receipt)), 0);
    }

    function test_nonzeroLiquidityCannotExtractEvenOneAtomAndPoolStateRollsBack() public {
        FaoGenesisDeployment receipt = _deployedReceipt();
        uint256 terminalPrice = 2e16;
        uint160 target = receipt.sqrtPriceX96(terminalPrice);
        FaoGenesisPoolMock pool = _installPool(receipt, target + 1, true);
        address vault_ = receipt.vault();

        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisDeployment.InvalidCallback.selector, address(pool), int256(1), int256(-1)
            )
        );
        vm.prank(vault_);
        receipt.prepareAndAssert(terminalPrice);
        assertEq(pool.sqrtPriceX96(), target + 1);
        assertEq(weth.balanceOf(address(receipt)), 0);
        assertEq(IERC20(receipt.companyToken()).balanceOf(address(receipt)), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                FaoGenesisDeployment.InvalidCallback.selector, address(pool), int256(0), int256(0)
            )
        );
        vm.prank(address(pool));
        receipt.uniswapV3SwapCallback(0, 0, "");
    }

    function test_receiptAndDominatingChildInitcodesRespectProtocolLimits() public {
        FaoGenesisDeployment receipt = _newReceipt();
        assertLt(type(FaoGenesisDeployment).creationCode.length + 64, 49_152);
        assertLt(address(receipt).code.length, 24_576);

        bytes[] memory coreCodes = _coreCodes();
        assertEq(keccak256(coreCodes[0]), receipt.ARBITRATION_CODE_HASH());
        assertEq(keccak256(coreCodes[1]), receipt.VAULT_CODE_HASH());
        assertEq(keccak256(coreCodes[2]), receipt.RELEASE_STRATEGY_CODE_HASH());
        assertEq(keccak256(coreCodes[3]), receipt.ZERO_VOTING_CODE_HASH());
        assertEq(keccak256(coreCodes[4]), receipt.ECON_GATEWAY_CODE_HASH());
        assertEq(keccak256(coreCodes[5]), receipt.ECON_EVALUATOR_CODE_HASH());
        assertLt(
            coreCodes[1].length + abi.encode(_vaultConfigShape(receipt), _grants()).length, 49_152
        );
        GenesisVault.GrantConfig[] memory maxGrants = new GenesisVault.GrantConfig[](32);
        for (uint256 i; i < maxGrants.length; ++i) {
            maxGrants[i] = GenesisVault.GrantConfig({
                beneficiary: vm.addr(i + 1), start: 1, duration: 1, amount: 1
            });
        }
        assertLt(
            coreCodes[1].length + abi.encode(_vaultConfigShape(receipt), maxGrants).length, 49_152
        );
    }

    function _deployedReceipt() private returns (FaoGenesisDeployment receipt) {
        receipt = _newReceipt();
        receipt.deployCore(_coreConfig(), _grants(), _coreCodes());
        receipt.deployFlm(_flmConfig(), _flmCodes());
    }

    function _assertCoreWiring(FaoGenesisDeployment receipt) private view {
        FaoGenesisDeployment.CoreConfig memory config = _coreConfig();
        Space spaceLike = Space(receipt.space());
        FutarchyArbitration arbitrationLike = FutarchyArbitration(receipt.arbitration());
        GenesisVault vaultLike = GenesisVault(payable(receipt.vault()));
        EconGateway gatewayLike = EconGateway(receipt.proposalGateway());
        SXArbitrationExecutionStrategy releaseLike =
            SXArbitrationExecutionStrategy(receipt.releaseStrategy());
        FAOEconomicEvaluationPipeline evaluatorLike =
            FAOEconomicEvaluationPipeline(receipt.evaluator());
        FAOOfficialProposalOrchestrator orchestratorLike =
            FAOOfficialProposalOrchestrator(receipt.orchestrator());
        FAOTwapResolver resolverLike = FAOTwapResolver(receipt.resolver());
        FAOFutarchyFactory factoryLike = FAOFutarchyFactory(receipt.futarchyFactory());
        (address votingAddress, bytes memory votingParams) = spaceLike.votingStrategies(0);
        (address validationAddress, bytes memory validationParams) =
            spaceLike.proposalValidationStrategy();

        assertEq(spaceLike.owner(), address(0));
        assertEq(spaceLike.authenticators(address(gatewayLike)), 1);
        assertEq(spaceLike.activeVotingStrategies(), 1);
        assertEq(votingAddress, receipt.votingStrategy());
        assertEq(votingParams.length, 0);
        assertEq(validationAddress, address(validationStrategy));
        assertEq(validationParams.length, 0);
        assertEq(spaceLike.votingDelay(), 0);
        assertEq(spaceLike.minVotingDuration(), 0);
        assertEq(spaceLike.maxVotingDuration(), 0);
        assertEq(spaceLike.daoURI(), DAO_URI);

        assertEq(arbitrationLike.owner(), address(0));
        assertEq(arbitrationLike.pendingOwner(), address(0));
        assertEq(arbitrationLike.proposalGateway(), address(gatewayLike));
        assertEq(address(arbitrationLike.evaluator()), address(evaluatorLike));
        assertEq(address(vaultLike.WETH()), address(weth));
        assertEq(address(vaultLike.COMPANY_TOKEN()), receipt.companyToken());
        assertEq(vaultLike.ASSEMBLER(), address(receipt));
        assertEq(address(vaultLike.ARBITRATION()), address(arbitrationLike));
        assertEq(address(vaultLike.BOOTSTRAP_HOOK()), address(receipt));
        assertEq(address(vaultLike.manager()), address(0));
        assertEq(vaultLike.assetPolicyCount(), 1);
        (uint128 c1, uint128 c2, uint128 tapBudget, uint128 tapBudgetMax, bool exists) =
            vaultLike.assetPolicies(address(weth));
        assertEq(c1, 0.1 ether);
        assertEq(c2, 1 ether);
        assertEq(tapBudget, 0.2 ether);
        assertEq(tapBudgetMax, 2 ether);
        assertTrue(exists);

        assertEq(address(gatewayLike.space()), address(spaceLike));
        assertEq(address(gatewayLike.executionStrategy()), address(releaseLike));
        assertEq(address(gatewayLike.arbitration()), address(arbitrationLike));
        assertEq(gatewayLike.vault(), address(vaultLike));
        assertEq(gatewayLike.minActivationBond(), ACTIVATION_BOND);
        assertEq(gatewayLike.treasuryMinActivationBond(), TREASURY_BOND);
        assertEq(releaseLike.space(), address(spaceLike));
        assertEq(address(releaseLike.arbitration()), address(arbitrationLike));

        assertEq(evaluatorLike.arbitrationContract(), address(arbitrationLike));
        assertEq(evaluatorLike.vault(), address(vaultLike));
        assertEq(address(evaluatorLike.orchestrator()), address(orchestratorLike));
        assertEq(address(evaluatorLike.resolver()), address(resolverLike));
        assertEq(address(evaluatorLike.conditionalTokens()), address(ctf));
        assertEq(orchestratorLike.ADMIN(), address(evaluatorLike));
        assertEq(address(orchestratorLike.FACTORY()), address(factoryLike));
        assertEq(address(orchestratorLike.UNIV3_FACTORY()), address(univ3Factory));
        assertEq(orchestratorLike.SPOT_POOL(), receipt.spotPool());
        assertEq(orchestratorLike.COMPANY_TOKEN(), receipt.companyToken());
        assertEq(orchestratorLike.CURRENCY_TOKEN(), address(weth));
        assertEq(orchestratorLike.FEE_TIER(), 500);
        assertEq(orchestratorLike.OBSERVATION_CARDINALITY(), 120);
        assertEq(address(orchestratorLike.RESOLVER()), address(resolverLike));
        assertFalse(orchestratorLike.ADAPTER_REPLACEABLE());
        assertEq(address(orchestratorLike.adapter()), address(0));
        assertEq(resolverLike.orchestrator(), address(orchestratorLike));
        assertEq(address(resolverLike.CTF()), address(ctf));
        assertEq(resolverLike.TIMEOUT(), config.twapTimeout);
        assertEq(resolverLike.TWAP_WINDOW(), config.twapWindow);
        assertEq(factoryLike.proposalImpl(), address(proposalImplementation));
        assertEq(address(factoryLike.conditionalTokens()), address(ctf));
        assertEq(address(factoryLike.wrapped1155Factory()), address(wrapped1155));
        assertEq(factoryLike.oracle(), address(resolverLike));
    }

    function _installPool(FaoGenesisDeployment receipt, uint160 price, bool hostile)
        private
        returns (FaoGenesisPoolMock pool)
    {
        FaoGenesisPoolMock template = new FaoGenesisPoolMock();
        address predicted = receipt.spotPool();
        vm.etch(predicted, address(template).code);
        pool = FaoGenesisPoolMock(predicted);
        pool.configure(receipt.companyToken(), address(weth), 500, price, hostile);
        univ3Factory.setPool(receipt.companyToken(), address(weth), 500, predicted);
    }

    function _newReceipt() private returns (FaoGenesisDeployment) {
        return new FaoGenesisDeployment(
            keccak256(abi.encode(_coreConfig(), _grants())), keccak256(abi.encode(_flmConfig()))
        );
    }

    function _coreConfig() private view returns (FaoGenesisDeployment.CoreConfig memory config) {
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
            assetPolicies: _assetPolicies(),
            twapTimeout: 7 days,
            twapWindow: 1 days,
            spaceSaltNonce: 1,
            daoURI: DAO_URI,
            metadataURI: METADATA_URI,
            votingStrategyMetadataURI: VOTING_URI,
            proposalValidationStrategyMetadataURI: VALIDATION_URI,
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

    function _flmConfig() private view returns (FaoGenesisDeployment.FlmConfig memory) {
        return
            FaoGenesisDeployment.FlmConfig({positionManager: _dependency(address(positionManager))});
    }

    function _dependency(address target)
        private
        view
        returns (FaoGenesisDeployment.Dependency memory)
    {
        return FaoGenesisDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _grants() private pure returns (GenesisVault.GrantConfig[] memory grants) {
        grants = new GenesisVault.GrantConfig[](1);
        grants[0] = GenesisVault.GrantConfig({
            beneficiary: address(0xBEEF), start: 1, duration: uint64(365 days), amount: 10 ether
        });
    }

    function _assetPolicies()
        private
        view
        returns (GenesisVault.AssetPolicyConfig[] memory policies)
    {
        policies = new GenesisVault.AssetPolicyConfig[](1);
        policies[0] = GenesisVault.AssetPolicyConfig({
            asset: address(weth),
            c1: 0.1 ether,
            c2: 1 ether,
            tapBudget: 0.2 ether,
            tapBudgetMax: 2 ether
        });
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

    function _createAddress(address deployer, uint256 nonce) private pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, bytes1(uint8(nonce))))))
        );
    }

    /// @dev Only used for an initcode-size assertion; values do not affect encoded length.
    function _vaultConfigShape(FaoGenesisDeployment receipt)
        private
        view
        returns (GenesisVault.Config memory)
    {
        FaoGenesisDeployment.CoreConfig memory config = _coreConfig();
        return GenesisVault.Config({
            tokenName: config.tokenName,
            tokenSymbol: config.tokenSymbol,
            weth: IERC20(address(weth)),
            assembler: address(receipt),
            arbitration: IGenesisArbitration(_createAddress(address(receipt), 1)),
            bootstrapHook: IGenesisBootstrapHook(address(receipt)),
            saleEnd: config.saleEnd,
            bootstrapDeadline: config.bootstrapDeadline,
            saleCap: config.saleCap,
            minimumRaise: config.minimumRaise,
            tokenMaxSupply: config.tokenMaxSupply,
            initialPrice: config.initialPrice,
            slope: config.slope,
            bootstrapBps: config.bootstrapBps,
            assetPolicies: config.assetPolicies
        });
    }
}
