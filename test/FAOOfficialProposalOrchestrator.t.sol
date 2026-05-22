// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    FAOOfficialProposalOrchestrator,
    IFAOLiquidityAdapter
} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IFAOFutarchyTwapResolver} from "../src/interfaces/IFAOFutarchyOracle.sol";

// ──────────────────────────────────────────────────────────────────────────
// Minimal mocks (kept inline to make the test self-contained)
// ──────────────────────────────────────────────────────────────────────────

contract MockCTF is IConditionalTokensLike {
    mapping(bytes32 => uint256) public slots;

    function payoutNumerators(bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function payoutDenominator(bytes32) external pure returns (uint256) {
        return 0;
    }

    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
    {
        bytes32 cid = getConditionId(oracle, questionId, outcomeSlotCount);
        require(slots[cid] == 0);
        slots[cid] = outcomeSlotCount;
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

contract MockW1155 is IWrapped1155FactoryLike {
    mapping(bytes32 => address) public wrapped;

    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(multiToken, tokenId, data));
        if (wrapped[salt] == address(0)) {
            // Fake but stable address based on hash.
            // forge-lint: disable-next-line(unsafe-typecast)
            wrapped[salt] = address(uint160(uint256(salt)));
        }
        return wrapped[salt];
    }
}

contract MockERC20 {
    string public symbol;

    constructor(string memory s) {
        symbol = s;
    }
}

contract MockUniV3Pool is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96;
    address public token0_;
    address public token1_;
    uint24 internal _fee;
    uint16 public cardinality;

    constructor(address _t0, address _t1, uint24 fee_) {
        token0_ = _t0;
        token1_ = _t1;
        _fee = fee_;
    }

    function fee() external view returns (uint24) {
        return _fee;
    }

    function token0() external view returns (address) {
        return token0_;
    }

    function token1() external view returns (address) {
        return token1_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 1, cardinality, 0, true);
    }

    function initialize(uint160 _sqrt) external {
        require(sqrtPriceX96 == 0, "already initialized");
        sqrtPriceX96 = _sqrt;
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        cardinality = next;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory, uint160[] memory)
    {
        int56[] memory tickCum = new int56[](secondsAgos.length);
        uint160[] memory liqCum = new uint160[](secondsAgos.length);
        return (tickCum, liqCum);
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract MockUniV3Factory is IUniswapV3FactoryLike {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[t0][t1][fee];
    }

    function createPool(address a, address b, uint24 fee) external returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(pools[t0][t1][fee] == address(0), "pool exists");
        pool = address(new MockUniV3Pool(t0, t1, fee));
        pools[t0][t1][fee] = pool;
    }

    /// @dev Test helper: pre-create + initialize a pool at a hostile price.
    function preCreateAndInitialize(address a, address b, uint24 fee, uint160 sqrtPriceX96)
        external
        returns (address)
    {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(pools[t0][t1][fee] == address(0), "pool exists");
        MockUniV3Pool pool = new MockUniV3Pool(t0, t1, fee);
        pool.initialize(sqrtPriceX96);
        pools[t0][t1][fee] = address(pool);
        return address(pool);
    }
}

contract MockResolver is IFAOFutarchyTwapResolver {
    struct Binding {
        address proposal;
        address yesPool;
        address noPool;
        address company;
        address currency;
        uint48 anchor;
    }
    mapping(address => Binding) public bindings;

    function resolve(address) external {}

    function bindProposal(
        address proposal,
        address yesPool,
        address noPool,
        address company,
        address currency,
        uint48 anchor
    ) external {
        bindings[proposal] = Binding(proposal, yesPool, noPool, company, currency, anchor);
    }
}

contract NoopAdapter is IFAOLiquidityAdapter {
    bool public migrated;

    function migrate(address, address, address, address, uint160) external {
        migrated = true;
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Test suite
// ──────────────────────────────────────────────────────────────────────────

contract FAOOrchestratorTest is Test {
    FAOOfficialProposalOrchestrator orch;
    FAOFutarchyFactory factory;
    FAOFutarchyProposal proposalImpl;
    MockCTF ctf;
    MockW1155 w1155;
    MockUniV3Factory uniFactory;
    MockUniV3Pool spotPool;
    MockResolver resolver;
    MockERC20 fao;
    MockERC20 weth;
    address admin = address(0xA11CE);
    uint24 constant FEE = 500;

    // sqrt(1) in X96 = 2**96
    uint160 constant SQRT_PRICE_1 = 79_228_162_514_264_337_593_543_950_336;

    function setUp() public {
        proposalImpl = new FAOFutarchyProposal();
        ctf = new MockCTF();
        w1155 = new MockW1155();
        resolver = new MockResolver();
        fao = new MockERC20("FAO");
        weth = new MockERC20("WETH");

        factory = new FAOFutarchyFactory(address(proposalImpl), ctf, w1155, address(resolver));

        uniFactory = new MockUniV3Factory();
        // Spot pool at sqrt(1) for the FAO/WETH pair.
        spotPool = MockUniV3Pool(uniFactory.createPool(address(fao), address(weth), FEE));
        spotPool.initialize(SQRT_PRICE_1);

        orch = _deployOrchestrator(true);
    }

    function _deployOrchestrator(bool adapterReplaceable)
        internal
        returns (FAOOfficialProposalOrchestrator)
    {
        return new FAOOfficialProposalOrchestrator(
            admin,
            factory,
            uniFactory,
            address(spotPool),
            address(fao),
            address(weth),
            FEE,
            100, // observation cardinality
            resolver,
            adapterReplaceable
        );
    }

    // ─── happy path
    // ─────────────────────────────────────────────────────────

    function test_happyPath_createsCondtionPoolsAndBinds() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        vm.prank(admin);
        (uint256 proposalId, address proposal) =
            orch.createOfficialProposalAndMigrate("test", "desc", 0);

        assertEq(proposalId, 0);
        assertTrue(proposal != address(0));

        // Resolver was bound.
        (
            address rProposal,
            address yesPool,
            address noPool,
            address company,
            address currency,
            uint48 anchor
        ) = resolver.bindings(proposal);

        assertEq(rProposal, proposal);
        assertTrue(yesPool != address(0));
        assertTrue(noPool != address(0));
        assertTrue(yesPool != noPool);
        assertEq(company, address(fao));
        assertEq(currency, address(weth));
        assertEq(anchor, uint48(block.timestamp));

        // Both pools initialized to non-zero sqrtPrice.
        (uint160 yesSqrt,,,,,,) = IUniswapV3PoolLike(yesPool).slot0();
        (uint160 noSqrt,,,,,,) = IUniswapV3PoolLike(noPool).slot0();
        assertTrue(yesSqrt != 0);
        assertTrue(noSqrt != 0);
    }

    // ─── A1: pool pre-creation defense
    // ─────────────────────────────────────

    /// @notice If an adversary somehow guesses prevrandao AND pre-creates+initializes
    /// the conditional pool at the predicted address, the orchestrator detects the
    /// non-zero slot0 and reverts. (In production, A1 is closed earlier by the
    /// prevrandao-derived questionId — see FAOFutarchyFactory tests. This is the
    /// last-line defense.)
    ///
    /// Test strategy: predict the wrappers for the next-index proposal by computing
    /// the same salt the mocks use, then pre-create and initialize the corresponding
    /// MockUniV3Pool. The orchestrator must revert with PreCreated.
    function test_A1_revertsIfConditionalPoolPreInitialized() public {
        vm.prevrandao(bytes32(uint256(0xBEEF)));

        // Compute the wrappers the factory would derive for marketsCount() == 0.
        uint256 idx = factory.marketsCount();
        bytes32 qId = factory.computeQuestionId("attack", "x", idx);
        bytes32 cId = ctf.getConditionId(address(resolver), qId, 2);

        address yesCompany = _predictWrapper(cId, address(fao), 0); // index 0 = YES_company
        address yesCurrency = _predictWrapper(cId, address(weth), 0); // index 2 = YES_currency same
        // indexSet

        // Adversary pre-creates the YES pool at a manipulated price.
        // forge-lint: disable-next-line(unsafe-typecast)
        address attackPool = uniFactory.preCreateAndInitialize(
            yesCompany, yesCurrency, FEE, uint160(SQRT_PRICE_1 * 2)
        );

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(FAOOfficialProposalOrchestrator.PreCreated.selector, attackPool)
        );
        orch.createOfficialProposalAndMigrate("attack", "x", 0);
    }

    /// @dev Replicates the mock W1155 + CTF derivation so tests can predict the wrapper
    /// address that will be generated for a given conditionId, collateral, and indexSet=1<<j.
    /// Outcome indices: 0 (YES_co), 1 (NO_co), 2 (YES_cur), 3 (NO_cur). Both YES and NO
    /// share indexSet 1<<0 for collateral1 and 1<<1 for collateral2.
    function _predictWrapper(bytes32 conditionId, address collateral, uint256 j)
        internal
        view
        returns (address)
    {
        uint256 indexSet = 1 << (j < 2 ? j : (j - 2));
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = ctf.getPositionId(collateral, collectionId);
        // Match mock W1155's wrapper-name encoding: name == symbol == YES_<sym> or NO_<sym>.
        string memory sym = collateral == address(fao) ? "FAO" : "WETH";
        string memory wrapperName =
            j == 0 || j == 2 ? string.concat("YES_", sym) : string.concat("NO_", sym);
        bytes memory data = _encodeWrapperMetadata(wrapperName);
        bytes32 salt = keccak256(abi.encodePacked(address(ctf), tokenId, data));
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(salt)));
    }

    function _encodeWrapperMetadata(string memory name) internal pure returns (bytes memory) {
        bytes32 n = _toString31(name);
        return abi.encodePacked(n, n, uint8(18));
    }

    function _toString31(string memory value) internal pure returns (bytes32 encodedString) {
        uint256 length = bytes(value).length;
        require(length < 32, "string too long");
        assembly { encodedString := mload(add(value, 0x20)) }
        bytes32 mask = bytes32(type(uint256).max << ((32 - length) << 3));
        encodedString = encodedString & mask;
        encodedString = encodedString | bytes32(length << 1);
    }

    // ─── conditional TIP behavior
    // ──────────────────────────────────────────

    function test_TIP_paidToCoinbaseOnSuccess() public {
        vm.fee(0);
        address coinbase = address(0xC01BAA5E);
        vm.coinbase(coinbase);
        vm.prevrandao(bytes32(uint256(0xCAFE)));

        uint256 tip = 0.01 ether;
        vm.deal(admin, 1 ether);
        uint256 before = coinbase.balance;

        vm.prank(admin);
        orch.createOfficialProposalAndMigrate{value: tip}("test", "desc", tip);

        assertEq(coinbase.balance - before, tip, "coinbase should receive tip");
    }

    function test_TIP_notPaidOnRevert() public {
        vm.prevrandao(bytes32(uint256(0xBEEF2)));

        // Pre-compute & pre-init the YES pool to force a revert.
        uint256 idx = factory.marketsCount();
        bytes32 qId = factory.computeQuestionId("rev", "x", idx);
        bytes32 cId = ctf.getConditionId(address(resolver), qId, 2);
        address yesCo = _predictWrapper(cId, address(fao), 0);
        address yesCur = _predictWrapper(cId, address(weth), 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        uniFactory.preCreateAndInitialize(yesCo, yesCur, FEE, uint160(SQRT_PRICE_1 * 2));

        address coinbase = address(0xC01BAA5E);
        vm.coinbase(coinbase);
        vm.deal(admin, 1 ether);
        uint256 before = coinbase.balance;

        vm.prank(admin);
        vm.expectRevert();
        orch.createOfficialProposalAndMigrate{value: 0.01 ether}("rev", "x", 0.01 ether);

        assertEq(coinbase.balance, before, "coinbase must NOT receive tip on revert");
    }

    // ─── adapter wiring
    // ─────────────────────────────────────────────────────

    function test_adapter_isInvokedWhenSet() public {
        NoopAdapter adapter = new NoopAdapter();
        vm.prank(admin);
        orch.setAdapter(adapter);

        vm.prevrandao(bytes32(uint256(0xCAFE)));
        vm.prank(admin);
        orch.createOfficialProposalAndMigrate("test", "desc", 0);

        assertTrue(adapter.migrated());
    }

    function test_adapter_isReplaceableByAdmin() public {
        assertTrue(orch.ADAPTER_REPLACEABLE(), "testnet mode");

        NoopAdapter a = new NoopAdapter();
        vm.prank(admin);
        orch.setAdapter(a);
        assertEq(address(orch.adapter()), address(a));

        NoopAdapter b = new NoopAdapter();
        vm.prank(admin);
        orch.setAdapter(b);
        assertEq(address(orch.adapter()), address(b), "admin can swap adapter");
    }

    function test_setAdapter_isOneShotWhenMainnetMode() public {
        FAOOfficialProposalOrchestrator mainnetOrch = _deployOrchestrator(false);
        assertFalse(mainnetOrch.ADAPTER_REPLACEABLE(), "mainnet mode");

        NoopAdapter a = new NoopAdapter();
        vm.prank(admin);
        mainnetOrch.setAdapter(a);
        assertEq(address(mainnetOrch.adapter()), address(a));

        NoopAdapter b = new NoopAdapter();
        vm.prank(admin);
        vm.expectRevert(FAOOfficialProposalOrchestrator.AdapterAlreadySet.selector);
        mainnetOrch.setAdapter(b);

        assertEq(address(mainnetOrch.adapter()), address(a), "adapter remains locked");
    }

    function test_setAdapter_revertsForNonAdmin() public {
        NoopAdapter a = new NoopAdapter();
        vm.expectRevert(FAOOfficialProposalOrchestrator.NotAdmin.selector);
        orch.setAdapter(a);
    }

    function test_onlyAdminCanCreateOfficialProposal() public {
        vm.prevrandao(bytes32(uint256(0xCAFE)));
        vm.expectRevert(FAOOfficialProposalOrchestrator.NotAdmin.selector);
        orch.createOfficialProposalAndMigrate("test", "desc", 0);
    }
}
