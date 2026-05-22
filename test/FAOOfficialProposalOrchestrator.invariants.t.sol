// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {
    FAOOfficialProposalOrchestrator,
    IFAOLiquidityAdapter
} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IFAOFutarchyTwapResolver} from "../src/interfaces/IFAOFutarchyOracle.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";

contract OrchestratorInvariantCTF is IConditionalTokensLike {
    mapping(bytes32 => uint256) public slots;
    uint256 public prepareCount;

    function payoutNumerators(bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function payoutDenominator(bytes32) external pure returns (uint256) {
        return 0;
    }

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
    {
        bytes32 conditionId = getConditionId(oracle, questionId, outcomeSlotCount);
        require(slots[conditionId] == 0, "condition exists");
        slots[conditionId] = outcomeSlotCount;
        prepareCount += 1;
    }

    function reportPayouts(bytes32, uint256[] calldata) external pure {}

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(bytes32 parent, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parent, conditionId, indexSet));
    }

    function getPositionId(address collateral, bytes32 collectionId)
        external
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(collateral, collectionId)));
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return slots[conditionId];
    }
}

contract OrchestratorInvariantWrapped1155 is IWrapped1155FactoryLike {
    mapping(bytes32 => address) public wrapped;
    uint256 public createCount;

    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(multiToken, tokenId, data));
        if (wrapped[salt] == address(0)) {
            wrapped[salt] = address(uint160(uint256(salt)));
            createCount += 1;
        }
        return wrapped[salt];
    }
}

contract OrchestratorInvariantERC20 {
    string public symbol;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}

contract OrchestratorInvariantUniV3Pool is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96;
    address internal immutable token0_;
    address internal immutable token1_;
    uint24 internal immutable fee_;
    uint16 public cardinality;

    constructor(address token0__, address token1__, uint24 fee__) {
        token0_ = token0__;
        token1_ = token1__;
        fee_ = fee__;
    }

    function token0() external view returns (address) {
        return token0_;
    }

    function token1() external view returns (address) {
        return token1_;
    }

    function fee() external view returns (uint24) {
        return fee_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 1, cardinality, 0, true);
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "already initialized");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external {
        cardinality = observationCardinalityNext;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract OrchestratorInvariantUniV3Factory is IUniswapV3FactoryLike {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;
    uint256 public poolCount;

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address token0, address token1) = _sort(tokenA, tokenB);
        return pools[token0][token1][fee];
    }

    function createPool(address tokenA, address tokenB, uint24 fee)
        external
        returns (address pool)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        require(pools[token0][token1][fee] == address(0), "pool exists");
        pool = address(new OrchestratorInvariantUniV3Pool(token0, token1, fee));
        pools[token0][token1][fee] = pool;
        poolCount += 1;
    }

    function ensurePreInitialized(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address pool)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        pool = pools[token0][token1][fee];
        if (pool == address(0)) {
            pool = address(new OrchestratorInvariantUniV3Pool(token0, token1, fee));
            pools[token0][token1][fee] = pool;
            poolCount += 1;
        }

        (uint160 existing,,,,,,) = OrchestratorInvariantUniV3Pool(pool).slot0();
        if (existing == 0) {
            OrchestratorInvariantUniV3Pool(pool).initialize(sqrtPriceX96);
        }
    }

    function _sort(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}

contract OrchestratorInvariantResolver is IFAOFutarchyTwapResolver {
    struct Binding {
        address proposal;
        address yesPool;
        address noPool;
        address company;
        address currency;
        uint48 anchor;
    }

    mapping(address => Binding) public bindings;
    uint256 public bindCount;

    function resolve(address) external pure {}

    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address companyToken,
        address currencyToken,
        uint48 anchorTimestamp
    ) external {
        bindings[proposal] = Binding({
            proposal: proposal,
            yesPool: yesPool,
            noPool: noPool,
            company: companyToken,
            currency: currencyToken,
            anchor: anchorTimestamp
        });
        bindCount += 1;
    }
}

contract OrchestratorInvariantNoopAdapter is IFAOLiquidityAdapter {
    uint256 public migrateCount;

    function migrate(address, address, address, address, uint160) external {
        migrateCount += 1;
    }
}

contract OrchestratorInvariantRevertingAdapter is IFAOLiquidityAdapter {
    uint256 public migrateCount;

    function migrate(address, address, address, address, uint160) external {
        migrateCount += 1;
        revert("ADAPTER_REVERT");
    }
}

contract FAOOfficialProposalOrchestratorHandler is Test {
    struct Snapshot {
        uint256 marketsCount;
        uint256 poolCount;
        uint256 prepareCount;
        uint256 wrapperCreateCount;
        uint256 bindCount;
        uint256 goodAdapterMigrateCount;
        uint256 revertingAdapterMigrateCount;
        uint256 coinbaseBalance;
        uint256 adminBalance;
        address adapter;
    }

    uint160 internal constant PREINIT_SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336;

    FAOOfficialProposalOrchestrator public immutable ORCH;
    FAOFutarchyFactory public immutable FACTORY;
    OrchestratorInvariantUniV3Factory public immutable UNI_FACTORY;
    OrchestratorInvariantCTF public immutable CTF;
    OrchestratorInvariantWrapped1155 public immutable WRAPPED_1155;
    OrchestratorInvariantResolver public immutable RESOLVER;
    OrchestratorInvariantNoopAdapter public immutable GOOD_ADAPTER;
    OrchestratorInvariantRevertingAdapter public immutable REVERTING_ADAPTER;

    address public immutable ADMIN;
    address public immutable COINBASE;
    address public immutable COMPANY_TOKEN;
    address public immutable CURRENCY_TOKEN;
    uint24 public immutable FEE_TIER;

    bool public sawRollbackViolation;
    bool public sawPreInitViolation;
    uint256 public successfulPromotions;
    uint256 public rollbackAttempts;
    uint256 public preInitAttempts;

    constructor(
        FAOOfficialProposalOrchestrator orch,
        FAOFutarchyFactory factory,
        OrchestratorInvariantUniV3Factory uniFactory,
        OrchestratorInvariantCTF ctf,
        OrchestratorInvariantWrapped1155 wrapped1155,
        OrchestratorInvariantResolver resolver,
        OrchestratorInvariantNoopAdapter goodAdapter,
        OrchestratorInvariantRevertingAdapter revertingAdapter,
        address admin,
        address coinbase,
        address companyToken,
        address currencyToken,
        uint24 feeTier
    ) {
        ORCH = orch;
        FACTORY = factory;
        UNI_FACTORY = uniFactory;
        CTF = ctf;
        WRAPPED_1155 = wrapped1155;
        RESOLVER = resolver;
        GOOD_ADAPTER = goodAdapter;
        REVERTING_ADAPTER = revertingAdapter;
        ADMIN = admin;
        COINBASE = coinbase;
        COMPANY_TOKEN = companyToken;
        CURRENCY_TOKEN = currencyToken;
        FEE_TIER = feeTier;
    }

    function promoteSuccess(uint256 randaoSeed) external {
        _setAdapter(GOOD_ADAPTER);
        vm.prevrandao(bytes32(uint256(keccak256(abi.encode("success", randaoSeed)))));

        uint256 preMarkets = FACTORY.marketsCount();
        vm.prank(ADMIN);
        try ORCH.createOfficialProposalAndMigrate("success", "desc", 0) returns (
            uint256 proposalId, address proposal
        ) {
            if (proposalId != preMarkets || proposal == address(0)) {
                sawRollbackViolation = true;
            }
            successfulPromotions += 1;
        } catch {
            sawRollbackViolation = true;
        }
    }

    function forceAdapterRevert(uint256 randaoSeed, uint256 tipSeed) external {
        _setAdapter(REVERTING_ADAPTER);
        vm.prevrandao(bytes32(uint256(keccak256(abi.encode("adapter-revert", randaoSeed)))));
        vm.coinbase(COINBASE);
        vm.deal(ADMIN, 100 ether);

        uint256 builderTip = _builderTip(tipSeed);
        Snapshot memory beforeState = _snapshot();
        rollbackAttempts += 1;

        vm.prank(ADMIN);
        try ORCH.createOfficialProposalAndMigrate{value: builderTip}(
            "adapter-revert", "desc", builderTip
        ) returns (
            uint256, address
        ) {
            sawRollbackViolation = true;
        } catch {}

        if (!_sameSnapshot(beforeState, _snapshot())) {
            sawRollbackViolation = true;
        }
    }

    function preInitializeThenPromote(uint256 randaoSeed, uint256 tipSeed) external {
        _setAdapter(GOOD_ADAPTER);
        vm.prevrandao(bytes32(uint256(keccak256(abi.encode("preinit", randaoSeed)))));
        vm.coinbase(COINBASE);
        vm.deal(ADMIN, 100 ether);

        (address yesCompany, address yesCurrency) = _predictYesPair("preinit", "desc");
        UNI_FACTORY.ensurePreInitialized(yesCompany, yesCurrency, FEE_TIER, PREINIT_SQRT_PRICE_X96);

        uint256 builderTip = _builderTip(tipSeed);
        Snapshot memory beforeState = _snapshot();
        preInitAttempts += 1;

        vm.prank(ADMIN);
        try ORCH.createOfficialProposalAndMigrate{value: builderTip}(
            "preinit", "desc", builderTip
        ) returns (
            uint256, address
        ) {
            sawPreInitViolation = true;
        } catch (bytes memory reason) {
            if (_selector(reason) != FAOOfficialProposalOrchestrator.PreCreated.selector) {
                sawPreInitViolation = true;
            }
        }

        if (!_sameSnapshot(beforeState, _snapshot())) {
            sawPreInitViolation = true;
        }
    }

    function _setAdapter(IFAOLiquidityAdapter adapter) internal {
        if (address(ORCH.adapter()) == address(adapter)) return;
        vm.prank(ADMIN);
        ORCH.setAdapter(adapter);
    }

    function _snapshot() internal view returns (Snapshot memory) {
        return Snapshot({
            marketsCount: FACTORY.marketsCount(),
            poolCount: UNI_FACTORY.poolCount(),
            prepareCount: CTF.prepareCount(),
            wrapperCreateCount: WRAPPED_1155.createCount(),
            bindCount: RESOLVER.bindCount(),
            goodAdapterMigrateCount: GOOD_ADAPTER.migrateCount(),
            revertingAdapterMigrateCount: REVERTING_ADAPTER.migrateCount(),
            coinbaseBalance: COINBASE.balance,
            adminBalance: ADMIN.balance,
            adapter: address(ORCH.adapter())
        });
    }

    function _sameSnapshot(Snapshot memory a, Snapshot memory b) internal pure returns (bool) {
        return a.marketsCount == b.marketsCount && a.poolCount == b.poolCount
            && a.prepareCount == b.prepareCount && a.wrapperCreateCount == b.wrapperCreateCount
            && a.bindCount == b.bindCount && a.goodAdapterMigrateCount == b.goodAdapterMigrateCount
            && a.revertingAdapterMigrateCount == b.revertingAdapterMigrateCount
            && a.coinbaseBalance == b.coinbaseBalance && a.adminBalance == b.adminBalance
            && a.adapter == b.adapter;
    }

    function _builderTip(uint256 seed) internal pure returns (uint256) {
        return seed % (0.01 ether + 1);
    }

    function _predictYesPair(string memory marketName, string memory description)
        internal
        view
        returns (address yesCompany, address yesCurrency)
    {
        uint256 proposalIndex = FACTORY.marketsCount();
        bytes32 questionId = FACTORY.computeQuestionId(marketName, description, proposalIndex);
        bytes32 conditionId = FACTORY.computeConditionId(questionId);
        yesCompany = _predictedWrapper(COMPANY_TOKEN, conditionId, 1, "YES_FAO");
        yesCurrency = _predictedWrapper(CURRENCY_TOKEN, conditionId, 1, "YES_WETH");
    }

    function _predictedWrapper(
        address collateral,
        bytes32 conditionId,
        uint256 indexSet,
        string memory tokenName
    ) internal view returns (address) {
        bytes32 collectionId = CTF.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = CTF.getPositionId(collateral, collectionId);
        bytes memory tokenData = _encodeWrapperMetadata(tokenName);
        bytes32 salt = keccak256(abi.encodePacked(address(CTF), tokenId, tokenData));
        return address(uint160(uint256(salt)));
    }

    function _encodeWrapperMetadata(string memory name) internal pure returns (bytes memory) {
        return abi.encodePacked(_toString31(name), _toString31(name), uint8(18));
    }

    function _toString31(string memory value) internal pure returns (bytes32 encodedString) {
        uint256 length = bytes(value).length;
        require(length < 32, "string too long");

        assembly {
            encodedString := mload(add(value, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - length) << 3));
        encodedString = encodedString & mask;
        encodedString = encodedString | bytes32(length << 1);
    }

    function _selector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}

/// @custom:spec INV-ORCH-001 — see audit/specs/INVARIANTS.md.
/// @custom:spec INV-ORCH-002 — see audit/specs/INVARIANTS.md.
contract FAOOfficialProposalOrchestratorInvariants is StdInvariant, Test {
    uint24 internal constant FEE = 500;
    uint16 internal constant OBSERVATION_CARDINALITY = 100;
    uint160 internal constant SQRT_PRICE_1 = 79_228_162_514_264_337_593_543_950_336;

    FAOOfficialProposalOrchestratorHandler internal handler;

    function setUp() public {
        vm.fee(0);

        address admin = address(0xA11CE);
        address coinbase = address(0xC01BAA5E);

        FAOFutarchyProposal proposalImpl = new FAOFutarchyProposal();
        OrchestratorInvariantCTF ctf = new OrchestratorInvariantCTF();
        OrchestratorInvariantWrapped1155 wrapped1155 = new OrchestratorInvariantWrapped1155();
        OrchestratorInvariantResolver resolver = new OrchestratorInvariantResolver();
        OrchestratorInvariantERC20 company = new OrchestratorInvariantERC20("FAO");
        OrchestratorInvariantERC20 currency = new OrchestratorInvariantERC20("WETH");

        FAOFutarchyFactory factory =
            new FAOFutarchyFactory(address(proposalImpl), ctf, wrapped1155, address(resolver));

        OrchestratorInvariantUniV3Factory uniFactory = new OrchestratorInvariantUniV3Factory();
        address spotPool = uniFactory.createPool(address(company), address(currency), FEE);
        OrchestratorInvariantUniV3Pool(spotPool).initialize(SQRT_PRICE_1);

        FAOOfficialProposalOrchestrator orch = new FAOOfficialProposalOrchestrator(
            admin,
            factory,
            uniFactory,
            spotPool,
            address(company),
            address(currency),
            FEE,
            OBSERVATION_CARDINALITY,
            resolver
        );

        OrchestratorInvariantNoopAdapter goodAdapter = new OrchestratorInvariantNoopAdapter();
        OrchestratorInvariantRevertingAdapter revertingAdapter =
            new OrchestratorInvariantRevertingAdapter();

        handler = new FAOOfficialProposalOrchestratorHandler(
            orch,
            factory,
            uniFactory,
            ctf,
            wrapped1155,
            resolver,
            goodAdapter,
            revertingAdapter,
            admin,
            coinbase,
            address(company),
            address(currency),
            FEE
        );

        handler.forceAdapterRevert(1, 0.001 ether);
        handler.preInitializeThenPromote(2, 0.002 ether);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FAOOfficialProposalOrchestratorHandler.promoteSuccess.selector;
        selectors[1] = FAOOfficialProposalOrchestratorHandler.forceAdapterRevert.selector;
        selectors[2] = FAOOfficialProposalOrchestratorHandler.preInitializeThenPromote.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @custom:spec INV-ORCH-001 — forced promote reverts roll back every touched phase.
    function invariant_INV_ORCH_001_atomicRollbackEnvelope() public view {
        assertGt(handler.rollbackAttempts(), 0, "INV-ORCH-001 not exercised");
        assertFalse(
            handler.sawRollbackViolation(), "INV-ORCH-001 violated: forced revert leaked state"
        );
    }

    /// @custom:spec INV-ORCH-002 — pre-initialized conditional pools are refused.
    function invariant_INV_ORCH_002_refusesPreInitializedPool() public view {
        assertGt(handler.preInitAttempts(), 0, "INV-ORCH-002 not exercised");
        assertFalse(
            handler.sawPreInitViolation(),
            "INV-ORCH-002 violated: pre-initialized pool was accepted or leaked state"
        );
    }
}
