// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "../src/FAOFutarchyProposal.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOTwapResolver} from "../src/FAOTwapResolver.sol";
import {FutarchyRegistry} from "../src/FutarchyRegistry.sol";
import {
    FutarchyStackDeployer,
    TokenAndArbitrationDeployer
} from "../src/FutarchyRegistryDeployers.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";
import {ParameterizedArbitration} from "../src/ParameterizedArbitration.sol";
import {IConditionalTokensLike} from "../src/interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IWrapped1155FactoryLike} from "../src/interfaces/IWrapped1155FactoryLike.sol";

// ─── mocks (subset of Phase5Simulation mocks, scoped to registry needs) ────

contract MockCTF is IConditionalTokensLike {
    mapping(bytes32 => uint256) public slots;
    mapping(bytes32 => uint256[]) public payouts;
    mapping(bytes32 => uint256) public denom;

    function payoutNumerators(bytes32 cid, uint256 i) external view returns (uint256) {
        if (payouts[cid].length <= i) return 0;
        return payouts[cid][i];
    }

    function payoutDenominator(bytes32 cid) external view returns (uint256) { return denom[cid]; }

    function prepareCondition(address oracle, bytes32 qId, uint256 n) external {
        bytes32 cid = getConditionId(oracle, qId, n);
        require(slots[cid] == 0, "already prepared");
        slots[cid] = n;
    }

    function reportPayouts(bytes32 qId, uint256[] calldata p) external {
        bytes32 cid = getConditionId(msg.sender, qId, p.length);
        require(denom[cid] == 0, "already reported");
        uint256 s;
        for (uint256 i; i < p.length; i++) s += p[i];
        payouts[cid] = p;
        denom[cid] = s;
    }

    function getConditionId(address oracle, bytes32 qId, uint256 n) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(oracle, qId, n));
    }
    function getCollectionId(bytes32 parent, bytes32 cid, uint256 idx) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, cid, idx));
    }
    function getPositionId(address c, bytes32 col) external pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(c, col)));
    }
    function getOutcomeSlotCount(bytes32 cid) external view returns (uint256) { return slots[cid]; }
}

contract MockW1155 is IWrapped1155FactoryLike {
    mapping(bytes32 => address) public wrapped;
    function requireWrapped1155(address mt, uint256 id, bytes calldata data) external returns (address) {
        bytes32 s = keccak256(abi.encodePacked(mt, id, data));
        if (wrapped[s] == address(0)) {
            wrapped[s] = address(uint160(uint256(s)));
        }
        return wrapped[s];
    }
}

contract MockUniV3Pool is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96;
    address public t0_;
    address public t1_;
    uint24 internal _fee;
    uint16 public cardinality;

    constructor(address a, address b, uint24 f) { t0_ = a; t1_ = b; _fee = f; }

    function token0() external view returns (address) { return t0_; }
    function token1() external view returns (address) { return t1_; }
    function fee() external view returns (uint24) { return _fee; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 1, cardinality, 0, true);
    }
    function initialize(uint160 s) external { require(sqrtPriceX96 == 0, "init"); sqrtPriceX96 = s; }
    function increaseObservationCardinalityNext(uint16 n) external { cardinality = n; }
    function mint(address, int24, int24, uint128, bytes calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }
    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (int56[] memory cums, uint160[] memory liq)
    {
        cums = new int56[](secondsAgos.length);
        liq = new uint160[](secondsAgos.length);
    }
}

contract MockUniV3Factory is IUniswapV3FactoryLike {
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;
    function getPool(address a, address b, uint24 f) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[t0][t1][f];
    }
    function createPool(address a, address b, uint24 f) external returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(pools[t0][t1][f] == address(0), "exists");
        pool = address(new MockUniV3Pool(t0, t1, f));
        pools[t0][t1][f] = pool;
    }
}

// ─── tests ─────────────────────────────────────────────────────────────────

contract FutarchyRegistryTest is Test {
    FutarchyRegistry registry;
    FAOFutarchyProposal proposalImpl;
    MockCTF ctf;
    MockW1155 w1155;
    MockUniV3Factory uniFactory;
    TokenAndArbitrationDeployer tokenArbDeployer;
    FutarchyStackDeployer stackDeployer;

    address constant WETH = address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint24 constant FEE = 500;
    uint16 constant OBS_CARDINALITY = 100;
    uint160 constant SQRT_1 = 79228162514264337593543950336; // 1.0 in Q64.96
    uint32 constant TIMEOUT = 2 hours;
    uint32 constant TWAP_WINDOW = 1 hours;
    uint256 constant BASE_BOND = 0.001 ether;
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;

    event FutarchyCreated(
        uint256 indexed id,
        address indexed creator,
        string name,
        string symbol,
        address token,
        address arbitration,
        address resolver,
        address factory,
        address orchestrator,
        address spotPool
    );

    function setUp() public {
        proposalImpl = new FAOFutarchyProposal();
        ctf = new MockCTF();
        w1155 = new MockW1155();
        uniFactory = new MockUniV3Factory();
        tokenArbDeployer = new TokenAndArbitrationDeployer();
        stackDeployer = new FutarchyStackDeployer();

        registry = new FutarchyRegistry(
            address(proposalImpl),
            IConditionalTokensLike(address(ctf)),
            IWrapped1155FactoryLike(address(w1155)),
            IUniswapV3FactoryLike(address(uniFactory)),
            WETH,
            FEE,
            OBS_CARDINALITY,
            tokenArbDeployer,
            stackDeployer
        );
    }

    function _create(address creator, string memory name, string memory symbol)
        internal
        returns (uint256 id)
    {
        vm.prank(creator);
        return registry.createFutarchy(
            name,
            symbol,
            string.concat("Description for ", name),
            INITIAL_SUPPLY,
            SQRT_1,
            TIMEOUT,
            TWAP_WINDOW,
            BASE_BOND
        );
    }

    // ─── happy path properties ─────────────────────────────────────────────

    function test_createFutarchy_deploysAllSixContracts() public {
        uint256 id = _create(ALICE, "OrgOne", "OO1");
        FutarchyRegistry.FutarchyInstance memory inst = registry.instances(id);

        // All six core addresses must be non-zero and distinct.
        assertTrue(inst.token != address(0), "token");
        assertTrue(inst.arbitration != address(0), "arbitration");
        assertTrue(inst.resolver != address(0), "resolver");
        assertTrue(inst.factory != address(0), "factory");
        assertTrue(inst.orchestrator != address(0), "orchestrator");
        assertTrue(inst.spotPool != address(0), "spotPool");

        address[6] memory a = [
            inst.token, inst.arbitration, inst.resolver, inst.factory, inst.orchestrator, inst.spotPool
        ];
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = i + 1; j < 6; j++) {
                assertTrue(a[i] != a[j], "duplicate deployed address");
            }
        }
    }

    function test_createFutarchy_setsAdminToCreator() public {
        uint256 id = _create(ALICE, "OrgTwo", "OO2");
        FutarchyRegistry.FutarchyInstance memory inst = registry.instances(id);

        // Token admin role.
        GenericFutarchyToken tok = GenericFutarchyToken(inst.token);
        assertTrue(tok.hasRole(tok.DEFAULT_ADMIN_ROLE(), ALICE), "token admin");
        assertTrue(tok.hasRole(tok.MINTER_ROLE(), ALICE), "token minter");

        // Arbitration owner.
        assertEq(ParameterizedArbitration(inst.arbitration).owner(), ALICE, "arb owner");

        // Orchestrator admin.
        assertEq(FAOOfficialProposalOrchestrator(inst.orchestrator).ADMIN(), ALICE, "orch admin");
    }

    function test_createFutarchy_mintsInitialSupplyToCreator() public {
        uint256 id = _create(ALICE, "MintOrg", "MO");
        FutarchyRegistry.FutarchyInstance memory inst = registry.instances(id);
        GenericFutarchyToken tok = GenericFutarchyToken(inst.token);

        assertEq(tok.totalSupply(), INITIAL_SUPPLY);
        assertEq(tok.balanceOf(ALICE), INITIAL_SUPPLY);
    }

    function test_createFutarchy_emitsEvent() public {
        // Expect topic1 (id), topic2 (creator), and the name/symbol in the data field.
        // We can't predict the deployed addresses precisely, so use a loose match: just
        // assert id+creator (the indexed args), and confirm name/symbol arrive in data.
        vm.recordLogs();
        uint256 id = _create(ALICE, "EventOrg", "EVT");
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Search for the FutarchyCreated topic in the captured logs.
        bytes32 wanted = keccak256(
            "FutarchyCreated(uint256,address,string,string,address,address,address,address,address,address)"
        );
        bool seen;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length >= 3 && entries[i].topics[0] == wanted) {
                assertEq(uint256(entries[i].topics[1]), id, "event id");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), ALICE, "event creator");
                seen = true;
                break;
            }
        }
        assertTrue(seen, "FutarchyCreated must be emitted");
    }

    function test_createFutarchy_indexesByName_doesNotCollide_acrossInstances() public {
        // Two creates with the same display name should both succeed — name is metadata,
        // not a uniqueness key. They'll get distinct ids and distinct contract addresses.
        uint256 idA = _create(ALICE, "SameName", "SN1");
        uint256 idB = _create(BOB, "SameName", "SN2");

        assertEq(idA, 0);
        assertEq(idB, 1);

        FutarchyRegistry.FutarchyInstance memory ia = registry.instances(idA);
        FutarchyRegistry.FutarchyInstance memory ib = registry.instances(idB);

        assertEq(ia.name, "SameName");
        assertEq(ib.name, "SameName");
        assertTrue(ia.token != ib.token, "tokens distinct");
        assertTrue(ia.arbitration != ib.arbitration, "arbs distinct");
        assertTrue(ia.resolver != ib.resolver, "resolvers distinct");
        assertTrue(ia.factory != ib.factory, "factories distinct");
        assertTrue(ia.orchestrator != ib.orchestrator, "orchestrators distinct");
    }

    function test_allInstances_returnsAllRegistered() public {
        _create(ALICE, "A1", "A1");
        _create(ALICE, "A2", "A2");
        _create(BOB, "B1", "B1");

        assertEq(registry.instancesCount(), 3);
        FutarchyRegistry.FutarchyInstance[] memory all = registry.allInstances();
        assertEq(all.length, 3);
        assertEq(all[0].symbol, "A1");
        assertEq(all[0].creator, ALICE);
        assertEq(all[1].symbol, "A2");
        assertEq(all[1].creator, ALICE);
        assertEq(all[2].symbol, "B1");
        assertEq(all[2].creator, BOB);
    }

    function test_resolver_orchestrator_wiring_isCorrect() public {
        uint256 id = _create(ALICE, "WireOrg", "WO");
        FutarchyRegistry.FutarchyInstance memory inst = registry.instances(id);

        // Resolver must point at the orchestrator (set during createFutarchy).
        FAOTwapResolver resolver = FAOTwapResolver(inst.resolver);
        assertEq(resolver.orchestrator(), inst.orchestrator, "resolver->orchestrator");

        // Resolver must be locked (further setOrchestrator reverts).
        vm.expectRevert(FAOTwapResolver.OrchestratorAlreadySet.selector);
        resolver.setOrchestrator(BOB);

        // Orchestrator's RESOLVER immutable must point back at this resolver.
        FAOOfficialProposalOrchestrator orch = FAOOfficialProposalOrchestrator(inst.orchestrator);
        assertEq(address(orch.RESOLVER()), inst.resolver, "orch->resolver");

        // Orchestrator's FACTORY must match.
        assertEq(address(orch.FACTORY()), inst.factory, "orch->factory");

        // Factory's oracle is the resolver (FAOFutarchyFactory.oracle).
        FAOFutarchyFactory propFactory = FAOFutarchyFactory(inst.factory);
        assertEq(propFactory.oracle(), inst.resolver, "factory.oracle->resolver");

        // Orchestrator's COMPANY_TOKEN = new token, CURRENCY_TOKEN = WETH.
        assertEq(orch.COMPANY_TOKEN(), inst.token, "orch.company");
        assertEq(orch.CURRENCY_TOKEN(), WETH, "orch.currency");

        // Spot pool — orchestrator references the registry-created one.
        assertEq(orch.SPOT_POOL(), inst.spotPool, "orch.spotPool");

        // Arbitration: WETH is the bond token, baseX = BASE_BOND, TIMEOUT matches.
        ParameterizedArbitration arb = ParameterizedArbitration(inst.arbitration);
        assertEq(address(arb.WETH()), WETH, "arb.WETH");
        assertEq(arb.baseX(), BASE_BOND, "arb.baseX");
        assertEq(arb.TIMEOUT(), TIMEOUT, "arb.TIMEOUT");
    }

    // ─── validation / negative cases ───────────────────────────────────────

    function test_createFutarchy_revertsEmptyName() public {
        vm.expectRevert(FutarchyRegistry.EmptyName.selector);
        registry.createFutarchy("", "SYM", "desc", 0, SQRT_1, TIMEOUT, TWAP_WINDOW, BASE_BOND);
    }

    function test_createFutarchy_revertsEmptySymbol() public {
        vm.expectRevert(FutarchyRegistry.EmptySymbol.selector);
        registry.createFutarchy("Name", "", "desc", 0, SQRT_1, TIMEOUT, TWAP_WINDOW, BASE_BOND);
    }

    function test_createFutarchy_revertsZeroSqrtPrice() public {
        vm.expectRevert(FutarchyRegistry.ZeroSqrtPrice.selector);
        registry.createFutarchy("Name", "SYM", "desc", 0, 0, TIMEOUT, TWAP_WINDOW, BASE_BOND);
    }

    function test_createFutarchy_revertsBadResolverConfig() public {
        // twapWindow > timeout
        vm.expectRevert(FutarchyRegistry.InvalidResolverConfig.selector);
        registry.createFutarchy("N", "S", "d", 0, SQRT_1, 1 hours, 2 hours, BASE_BOND);

        // timeout == 0
        vm.expectRevert(FutarchyRegistry.InvalidResolverConfig.selector);
        registry.createFutarchy("N", "S", "d", 0, SQRT_1, 0, TWAP_WINDOW, BASE_BOND);

        // twapWindow == 0
        vm.expectRevert(FutarchyRegistry.InvalidResolverConfig.selector);
        registry.createFutarchy("N", "S", "d", 0, SQRT_1, TIMEOUT, 0, BASE_BOND);
    }

    function test_createFutarchy_revertsZeroBaseBond() public {
        vm.expectRevert(FutarchyRegistry.InvalidBaseBond.selector);
        registry.createFutarchy("N", "S", "d", 0, SQRT_1, TIMEOUT, TWAP_WINDOW, 0);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(FutarchyRegistry.InvalidConstructor.selector);
        new FutarchyRegistry(
            address(0),
            IConditionalTokensLike(address(ctf)),
            IWrapped1155FactoryLike(address(w1155)),
            IUniswapV3FactoryLike(address(uniFactory)),
            WETH,
            FEE,
            OBS_CARDINALITY,
            tokenArbDeployer,
            stackDeployer
        );

        vm.expectRevert(FutarchyRegistry.InvalidConstructor.selector);
        new FutarchyRegistry(
            address(proposalImpl),
            IConditionalTokensLike(address(ctf)),
            IWrapped1155FactoryLike(address(w1155)),
            IUniswapV3FactoryLike(address(uniFactory)),
            WETH,
            FEE,
            0, // observation cardinality
            tokenArbDeployer,
            stackDeployer
        );
    }

    function test_instances_revertsOnOutOfRange() public {
        vm.expectRevert(FutarchyRegistry.InvalidInstanceId.selector);
        registry.instances(0);

        _create(ALICE, "OneAndOnly", "OO");
        // Index 0 ok, 1 out of range.
        registry.instances(0);
        vm.expectRevert(FutarchyRegistry.InvalidInstanceId.selector);
        registry.instances(1);
    }

    function test_createFutarchy_storesProvidedDescription() public {
        vm.prank(ALICE);
        uint256 id = registry.createFutarchy(
            "DescOrg",
            "DO",
            "We hereby declare that everything is fine.",
            0,
            SQRT_1,
            TIMEOUT,
            TWAP_WINDOW,
            BASE_BOND
        );
        assertEq(
            registry.instances(id).description,
            "We hereby declare that everything is fine."
        );
    }
}

