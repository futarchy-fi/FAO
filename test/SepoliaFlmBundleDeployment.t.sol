// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {UniswapV3LiquidityAdapter} from "flm/adapters/UniswapV3LiquidityAdapter.sol";
import {FutarchyLiquidityManager} from "flm/core/FutarchyLiquidityManager.sol";
import {UniV3PoolStabilityGuard} from "flm/oracles/UniV3PoolStabilityGuard.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "../lib/futarchy-liquidity-manager/test/mocks/MockUniswapV3NonfungiblePositionManager.sol";

import {FAOFlmProposalSourceRelay} from "../src/FAOFlmProposalSourceRelay.sol";
import {SepoliaFlmBundleDeployment} from "../src/SepoliaFlmBundleDeployment.sol";
import {FlmCodeHashes} from "../src/generated/FlmCodeHashes.sol";
import {
    FlmBundleArbitrationMock,
    FlmBundleDependencyMock,
    FlmBundleFutarchyFactoryMock,
    FlmBundleOrchestratorMock,
    FlmBundlePipelineMock,
    FlmBundlePoolMock,
    FlmBundleResolverMock,
    FlmBundleTokenMock,
    FlmBundleUniV3FactoryMock
} from "./mocks/FlmBundleMocks.sol";

contract SepoliaFlmBundleDeploymentTest is Test {
    uint256 private constant BOOT_COMPANY = 10 ether;
    uint256 private constant BOOT_WETH = 10 ether;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    FlmBundleTokenMock private company;
    FlmBundleTokenMock private weth;
    FlmBundleDependencyMock private ctf;
    FlmBundleDependencyMock private wrapped1155;
    FlmBundleArbitrationMock private arbitration;
    FlmBundleDependencyMock private proposalImplementation;
    FlmBundleUniV3FactoryMock private univ3Factory;
    MockUniswapV3NonfungiblePositionManager private positionManager;
    FlmBundlePoolMock private spotPool;
    FlmBundlePipelineMock private pipeline;
    FlmBundleOrchestratorMock private orchestrator;
    FlmBundleResolverMock private resolver;
    FlmBundleFutarchyFactoryMock private futarchyFactory;

    address private keeper;
    address private funder;

    function setUp() public {
        keeper = makeAddr("keeper");
        funder = makeAddr("funder");
        company = new FlmBundleTokenMock("Company", "COMP");
        weth = new FlmBundleTokenMock("Wrapped Ether", "WETH");
        ctf = new FlmBundleDependencyMock();
        wrapped1155 = new FlmBundleDependencyMock();
        arbitration = new FlmBundleArbitrationMock();
        proposalImplementation = new FlmBundleDependencyMock();
        univ3Factory = new FlmBundleUniV3FactoryMock();
        positionManager = new MockUniswapV3NonfungiblePositionManager();
        spotPool = new FlmBundlePoolMock(address(company), address(weth));
        pipeline = new FlmBundlePipelineMock();
        orchestrator = new FlmBundleOrchestratorMock();
        resolver = new FlmBundleResolverMock();
        futarchyFactory = new FlmBundleFutarchyFactoryMock();

        univ3Factory.setPool(address(company), address(weth), 500, address(spotPool));
        pipeline.wire(address(arbitration), address(orchestrator), address(resolver), address(ctf));
        resolver.wire(address(ctf), address(orchestrator));
        futarchyFactory.wire(
            address(ctf), address(wrapped1155), address(resolver), address(proposalImplementation)
        );
        orchestrator.wire(
            address(pipeline),
            address(futarchyFactory),
            address(univ3Factory),
            address(spotPool),
            address(company),
            address(weth),
            address(resolver)
        );
    }

    function test_permissionlessLoaderDeploysPredictedBundleAndConsumesEveryRole() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        bytes[] memory codes = _baseCodes();
        bytes memory callData = abi.encodeCall(receipt.deployAndBind, (codes));
        assertLt(callData.length, 100_000);

        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        receipt.deployAndBind(codes);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("sealed loader gas", gasUsed);
        assertLt(gasUsed, 15_000_000);

        assertTrue(receipt.isSealed());
        assertEq(receipt.relay(), _createAddress(address(receipt), 1));
        assertEq(receipt.spotAdapter(), _createAddress(address(receipt), 2));
        assertEq(receipt.conditionalAdapter(), _createAddress(address(receipt), 3));
        assertEq(receipt.guard(), _createAddress(address(receipt), 4));
        assertEq(receipt.router(), _createAddress(address(receipt), 5));
        assertEq(receipt.manager(), _createAddress(address(receipt), 6));

        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(receipt.manager()));
        assertEq(manager.owner(), DEAD);
        assertEq(manager.BOOTSTRAP_RECIPIENT(), address(receipt));
        assertEq(manager.OFFICIAL_PROPOSER(), receipt.relay());
        assertEq(address(manager.PROPOSAL_SOURCE()), receipt.relay());
        assertEq(address(manager.SPOT_ADAPTER()), receipt.spotAdapter());
        assertEq(address(manager.CONDITIONAL_ADAPTER()), receipt.conditionalAdapter());
        assertEq(address(manager.CONDITIONAL_ROUTER()), receipt.router());
        assertEq(address(manager.POOL_STABILITY_GUARD()), receipt.guard());
        assertEq(UniswapV3LiquidityAdapter(receipt.spotAdapter()).MANAGER(), address(manager));
        assertEq(
            UniswapV3LiquidityAdapter(receipt.conditionalAdapter()).MANAGER(), address(manager)
        );
        assertEq(address(FAOFlmProposalSourceRelay(receipt.relay()).MANAGER()), address(manager));

        vm.expectRevert(SepoliaFlmBundleDeployment.AlreadySealed.selector);
        receipt.deployAndBind(codes);
    }

    function test_hashGateRejectsMutationReorderingAndWrongCountThenRetriesDeterministically()
        public
    {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        bytes[] memory codes = _baseCodes();
        codes[0][0] = bytes1(uint8(codes[0][0]) ^ uint8(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                SepoliaFlmBundleDeployment.InvalidCodeHash.selector,
                uint256(0),
                FlmCodeHashes.RELAY,
                keccak256(codes[0])
            )
        );
        receipt.deployAndBind(codes);
        assertEq(_createAddress(address(receipt), 1).code.length, 0);

        codes = _baseCodes();
        (codes[1], codes[2]) = (codes[2], codes[1]);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepoliaFlmBundleDeployment.InvalidCodeHash.selector,
                uint256(1),
                FlmCodeHashes.ADAPTER,
                keccak256(codes[1])
            )
        );
        receipt.deployAndBind(codes);
        assertEq(_createAddress(address(receipt), 1).code.length, 0);

        bytes[] memory shortCodes = new bytes[](4);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepoliaFlmBundleDeployment.InvalidCodeBlobCount.selector, uint256(4)
            )
        );
        receipt.deployAndBind(shortCodes);

        receipt.deployAndBind(_baseCodes());
        assertEq(receipt.relay(), _createAddress(address(receipt), 1));
        assertEq(receipt.manager(), _createAddress(address(receipt), 6));
    }

    function test_loaderWaitsForZeroActiveEvaluationThenRetriesAtomically() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        arbitration.setActiveEvaluationProposalId(7);

        vm.expectRevert(
            abi.encodeWithSelector(SepoliaFlmBundleDeployment.ActiveEvaluation.selector, 7)
        );
        receipt.deployAndBind(_baseCodes());
        assertEq(_createAddress(address(receipt), 1).code.length, 0);
        assertFalse(receipt.isSealed());

        arbitration.setActiveEvaluationProposalId(0);
        receipt.deployAndBind(_baseCodes());
        assertEq(receipt.relay(), _createAddress(address(receipt), 1));
        assertEq(receipt.manager(), _createAddress(address(receipt), 6));
    }

    function test_exactBootstrapCannotBeDustedBurnsSeedAndOpensPublicDeposits() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        receipt.deployAndBind(_baseCodes());
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(receipt.manager()));

        company.mint(funder, BOOT_COMPANY - 1);
        weth.mint(funder, BOOT_WETH);
        vm.startPrank(funder);
        company.approve(address(receipt), type(uint256).max);
        weth.approve(address(receipt), type(uint256).max);
        vm.expectRevert();
        receipt.bootstrap();
        vm.stopPrank();
        assertFalse(receipt.bootstrapped());
        assertFalse(manager.initializedFromBootstrap());

        company.mint(address(receipt), 7);
        weth.mint(address(receipt), 11);
        company.mint(funder, 1);
        vm.prank(funder);
        receipt.bootstrap();

        assertTrue(receipt.bootstrapped());
        assertTrue(manager.initializedFromBootstrap());
        assertGt(manager.totalSupply(), 0);
        assertEq(manager.balanceOf(DEAD), manager.totalSupply());
        assertEq(manager.balanceOf(address(receipt)), 0);
        assertEq(company.balanceOf(address(receipt)), 0);
        assertEq(weth.balanceOf(address(receipt)), 0);
        assertEq(company.balanceOf(DEAD), 7);
        assertEq(weth.balanceOf(DEAD), 11);
        assertEq(company.allowance(address(receipt), address(manager)), 0);
        assertEq(weth.allowance(address(receipt), address(manager)), 0);

        vm.expectRevert(SepoliaFlmBundleDeployment.AlreadyBootstrapped.selector);
        vm.prank(funder);
        receipt.bootstrap();

        address depositor = makeAddr("depositor");
        company.mint(depositor, 2 ether);
        weth.mint(depositor, 2 ether);
        vm.startPrank(depositor);
        company.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        uint256 shares = manager.depositToSpot(2 ether, 2 ether);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(manager.balanceOf(depositor), shares);
    }

    function test_bootstrapRejectsSkewAndShortCardinalityWithoutPullingFunds() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        receipt.deployAndBind(_baseCodes());
        _fundAndApprove(funder, receipt);

        spotPool.configure(51, 120, 120);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepoliaFlmBundleDeployment.BootstrapPoolNotReady.selector, int24(51), uint16(120)
            )
        );
        vm.prank(funder);
        receipt.bootstrap();
        assertEq(company.balanceOf(funder), BOOT_COMPANY);
        assertEq(weth.balanceOf(funder), BOOT_WETH);

        spotPool.configure(0, 120, 119);
        vm.expectRevert(
            abi.encodeWithSelector(
                SepoliaFlmBundleDeployment.BootstrapPoolNotReady.selector, int24(0), uint16(119)
            )
        );
        vm.prank(funder);
        receipt.bootstrap();
        assertFalse(receipt.bootstrapped());

        spotPool.configure(0, 120, 120);
        vm.prank(funder);
        receipt.bootstrap();
        assertTrue(receipt.bootstrapped());
    }

    function test_bootstrapRequiresUsableStableTwapHistory() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        receipt.deployAndBind(_baseCodes());
        _fundAndApprove(funder, receipt);

        spotPool.configureTwap(0, false);
        vm.expectRevert(bytes("history"));
        vm.prank(funder);
        receipt.bootstrap();
        assertFalse(receipt.bootstrapped());

        spotPool.configureTwap(-51, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV3PoolStabilityGuard.UnstablePool.selector,
                address(spotPool),
                int24(0),
                int24(-51)
            )
        );
        vm.prank(funder);
        receipt.bootstrap();
        assertEq(company.balanceOf(funder), BOOT_COMPANY);
        assertEq(weth.balanceOf(funder), BOOT_WETH);

        spotPool.configureTwap(-50, true);
        vm.prank(funder);
        receipt.bootstrap();
        assertTrue(receipt.bootstrapped());
    }

    function test_managerCannotBeInitializedExceptThroughExactReceiptBootstrap() public {
        SepoliaFlmBundleDeployment receipt = _newReceipt();
        receipt.deployAndBind(_baseCodes());
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(receipt.manager()));

        company.mint(funder, BOOT_COMPANY);
        weth.mint(funder, BOOT_WETH);
        vm.startPrank(funder);
        company.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        vm.expectRevert(FutarchyLiquidityManager.OnlyBootstrapRecipient.selector);
        manager.initializeFromBootstrap(BOOT_COMPANY, BOOT_WETH);
        vm.stopPrank();
    }

    function test_receiptAndPerChildInitcodeStayUnderProtocolLimits() public {
        bytes memory encodedConfig = abi.encode(_config());
        assertLt(
            type(SepoliaFlmBundleDeployment).creationCode.length + encodedConfig.length, 49_152
        );
        assertLt(address(_newReceipt()).code.length, 24_576);
        bytes[] memory codes = _baseCodes();
        assertEq(keccak256(codes[0]), FlmCodeHashes.RELAY);
        assertEq(keccak256(codes[1]), FlmCodeHashes.ADAPTER);
        assertEq(keccak256(codes[2]), FlmCodeHashes.GUARD);
        assertEq(keccak256(codes[3]), FlmCodeHashes.ROUTER);
        assertEq(keccak256(codes[4]), FlmCodeHashes.MANAGER);

        assertLt(
            codes[0].length
                + abi.encode(
                    address(arbitration),
                    address(pipeline),
                    address(univ3Factory),
                    address(ctf),
                    uint24(500),
                    address(company),
                    address(weth)
                )
                .length,
            49_152
        );
        assertLt(
            codes[1].length
                + abi.encode(address(positionManager), int24(-887_270), int24(887_270)).length,
            49_152
        );
        assertLt(codes[2].length + abi.encode(address(univ3Factory), uint24(500)).length, 49_152);
        assertLt(codes[3].length + abi.encode(address(ctf), address(wrapped1155)).length, 49_152);

        address predictedRelay = _createAddress(address(_newReceipt()), 1);
        FutarchyLiquidityManager.LpTokenMetadata memory metadata =
            FutarchyLiquidityManager.LpTokenMetadata({name: "FAO Liquidity", symbol: "FAO-LP"});
        assertLt(
            codes[4].length
                + abi.encode(
                    address(this),
                    address(company),
                    address(weth),
                    predictedRelay,
                    predictedRelay,
                    address(1),
                    address(2),
                    address(3),
                    address(4),
                    DEAD,
                    metadata
                )
                .length,
            49_152
        );

        SepoliaFlmBundleDeployment receipt = _newReceipt();
        receipt.deployAndBind(codes);
        assertLt(receipt.relay().code.length, 24_576);
        assertLt(receipt.spotAdapter().code.length, 24_576);
        assertLt(receipt.conditionalAdapter().code.length, 24_576);
        assertLt(receipt.guard().code.length, 24_576);
        assertLt(receipt.router().code.length, 24_576);
        assertLt(receipt.manager().code.length, 24_576);
    }

    function _newReceipt() private returns (SepoliaFlmBundleDeployment) {
        return new SepoliaFlmBundleDeployment(_config());
    }

    function _config() private view returns (SepoliaFlmBundleDeployment.Config memory) {
        return SepoliaFlmBundleDeployment.Config({
            weth: _dependency(address(weth)),
            conditionalTokens: _dependency(address(ctf)),
            wrapped1155Factory: _dependency(address(wrapped1155)),
            uniswapV3Factory: _dependency(address(univ3Factory)),
            positionManager: _dependency(address(positionManager)),
            companyToken: _dependency(address(company)),
            spotPool: _dependency(address(spotPool)),
            arbitration: _dependency(address(arbitration)),
            pipeline: _dependency(address(pipeline)),
            orchestrator: _dependency(address(orchestrator)),
            resolver: _dependency(address(resolver)),
            futarchyFactory: _dependency(address(futarchyFactory)),
            bootstrapCompanyAmount: BOOT_COMPANY,
            bootstrapWethAmount: BOOT_WETH
        });
    }

    function _dependency(address target)
        private
        view
        returns (SepoliaFlmBundleDeployment.Dependency memory)
    {
        return SepoliaFlmBundleDeployment.Dependency({target: target, codehash: target.codehash});
    }

    function _baseCodes() private view returns (bytes[] memory codes) {
        codes = new bytes[](5);
        codes[0] = vm.readFileBinary("metadata/flm-creation-code/relay.bin");
        codes[1] = vm.readFileBinary("metadata/flm-creation-code/adapter.bin");
        codes[2] = vm.readFileBinary("metadata/flm-creation-code/guard.bin");
        codes[3] = vm.readFileBinary("metadata/flm-creation-code/router.bin");
        codes[4] = vm.readFileBinary("metadata/flm-creation-code/manager.bin");
    }

    function _fundAndApprove(address account, SepoliaFlmBundleDeployment receipt) private {
        company.mint(account, BOOT_COMPANY);
        weth.mint(account, BOOT_WETH);
        vm.startPrank(account);
        company.approve(address(receipt), type(uint256).max);
        weth.approve(address(receipt), type(uint256).max);
        vm.stopPrank();
    }

    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, bytes1(nonce)))))
            );
    }
}
