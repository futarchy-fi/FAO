// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOTwapResolver} from "./FAOTwapResolver.sol";
import {
    FutarchyStackDeployer,
    TokenAndArbitrationDeployer
} from "./FutarchyRegistryDeployers.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";

/// @dev Minimal view into InstanceSale — Part2 reads the immutable initial
/// price to compute the spot pool's sqrtPriceX96.
interface IInstanceSalePriceLike {
    function INITIAL_PRICE_WEI_PER_TOKEN() external view returns (uint256);
}

/// @title FutarchyRegistry
/// @notice Meta-factory that lets anyone spin up a fully-wired FAO futarchy
/// instance. Shared chain-level infrastructure (CTF, Wrapped1155Factory,
/// UniV3 factory, proposal implementation, WETH) is reused; per-instance
/// contracts (governance token, arbitration, resolver, proposal factory,
/// orchestrator, spot pool) are freshly deployed.
///
/// Bond token for every instance is WETH — keeps escalation universal,
/// liquid, and predictable across orgs. Each instance picks its own
/// timeout / TWAP window / baseX.
///
/// ─── Gas-cap-friendly 2-phase flow ────────────────────────────────────────
/// Public RPCs (notably MetaMask's default Sepolia endpoint at
/// `ethereum-sepolia-rpc.publicnode.com`) cap `eth_estimateGas` at
/// 16_777_216 (= 2^24). A single-tx deploy of all six contracts plus the
/// UniV3 spot pool crosses ~18.8M gas and is rejected client-side before it
/// reaches the chain. To stay below the cap we expose two phases:
///
///   1. `createFutarchyPart1(...)` deploys the per-instance ERC20 token and
///      the ParameterizedArbitration; reserves a registry slot in
///      `PENDING_PART2` status. ~3-4M gas.
///   2. `createFutarchyPart2(id)` deploys the resolver / proposal factory /
///      orchestrator, creates+initializes the UniV3 spot pool, warms its
///      observation buffer, locks the resolver to the orchestrator, and
///      flips status to `READY`. Anyone can call (useful if Part1 caller's
///      next tx fails). ~9-12M gas.
///
/// A convenience `createFutarchy(...)` runs both parts atomically — for
/// callers with no client-side gas cap (e.g. forge scripts on private RPCs).
///
/// @dev The actual `new` calls live in `FutarchyRegistryDeployers.sol` so this
/// contract's deployed bytecode stays under EIP-170 (24576 bytes). The two
/// sub-deployers are passed in at construction and immutable afterwards.
contract FutarchyRegistry {
    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

    /// @notice Lifecycle state of a registered instance.
    /// NONE         — slot is uninitialized (also returned for the implicit
    ///                zero entry when an id is out of range; callers should
    ///                use `instances(id)` which reverts instead).
    /// PENDING_PART2 — Part1 succeeded; resolver/factory/orchestrator/pool
    ///                not yet deployed. Caller must run Part2.
    /// READY        — both phases complete, fully usable.
    enum InstanceStatus { NONE, PENDING_PART2, READY }

    struct FutarchyInstance {
        string name;
        string symbol;
        string description;
        address creator;
        address token;
        address sale;                // InstanceSale that owns MINTER_ROLE on token
        address arbitration;
        address resolver;            // address(0) until Part2
        address factory;             // address(0) until Part2
        address orchestrator;        // address(0) until Part2
        address spotPool;            // address(0) until Part2
        uint256 createdAt;
        InstanceStatus status;
        // Cached params so Part2 doesn't need them as args. sqrtPriceX96 is
        // derived from `sale.INITIAL_PRICE_WEI_PER_TOKEN` inside Part2, so
        // the user can't pass an inconsistent value at create time.
        uint32 timeout;
        uint32 twapWindow;
    }


    // ═══════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════

    address public immutable PROPOSAL_IMPL;
    IConditionalTokensLike public immutable CTF;
    IWrapped1155FactoryLike public immutable W1155;
    IUniswapV3FactoryLike public immutable UNIV3_FACTORY;
    address public immutable WETH;
    uint24 public immutable FEE_TIER;
    uint16 public immutable OBSERVATION_CARDINALITY;

    TokenAndArbitrationDeployer public immutable TOKEN_ARB_DEPLOYER;
    FutarchyStackDeployer public immutable STACK_DEPLOYER;

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    FutarchyInstance[] internal _instances;

    // ═══════════════════════════════════════════════════════
    //  Events / Errors
    // ═══════════════════════════════════════════════════════

    /// @notice Emitted when Part1 (or the legacy atomic `createFutarchy`)
    /// successfully reserves an id and deploys token+arbitration. The
    /// resolver/factory/orchestrator/spotPool fields are address(0) here
    /// when fired from Part1 — they appear in `FutarchyPart2Created`.
    event FutarchyPart1Created(
        uint256 indexed id,
        address indexed creator,
        string name,
        string symbol,
        address token,
        address sale,
        address arbitration
    );

    /// @notice Emitted when Part2 completes for an instance.
    event FutarchyPart2Created(
        uint256 indexed id,
        address indexed creator,
        address resolver,
        address factory,
        address orchestrator,
        address spotPool
    );

    /// @notice Aggregate "instance is now READY" event, fired at the end of
    /// Part2 (or by the legacy atomic path). Existing indexers / the testnet
    /// site key off this event; the field layout matches the pre-2-phase
    /// version 1:1 so the site's ABI stays compatible.
    event FutarchyCreated(
        uint256 indexed id,
        address indexed creator,
        string name,
        string symbol,
        address token,
        address sale,
        address arbitration,
        address resolver,
        address factory,
        address orchestrator,
        address spotPool
    );

    error EmptyName();
    error EmptySymbol();
    error InvalidResolverConfig();
    error InvalidBaseBond();
    error InvalidConstructor();
    error InvalidInstanceId();
    error SpotPoolAlreadyExists();
    error NotInPendingPart2();
    error AlreadyReady();

    uint256 internal constant DEFAULT_MAX_QUEUE = 3;

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor(
        address proposalImpl,
        IConditionalTokensLike ctf,
        IWrapped1155FactoryLike w1155,
        IUniswapV3FactoryLike univ3Factory,
        address weth,
        uint24 feeTier,
        uint16 observationCardinality,
        TokenAndArbitrationDeployer tokenArbDeployer,
        FutarchyStackDeployer stackDeployer
    ) {
        if (
            proposalImpl == address(0) || address(ctf) == address(0) || address(w1155) == address(0)
                || address(univ3Factory) == address(0) || weth == address(0)
                || observationCardinality == 0 || address(tokenArbDeployer) == address(0)
                || address(stackDeployer) == address(0)
        ) revert InvalidConstructor();

        PROPOSAL_IMPL = proposalImpl;
        CTF = ctf;
        W1155 = w1155;
        UNIV3_FACTORY = univ3Factory;
        WETH = weth;
        FEE_TIER = feeTier;
        OBSERVATION_CARDINALITY = observationCardinality;
        TOKEN_ARB_DEPLOYER = tokenArbDeployer;
        STACK_DEPLOYER = stackDeployer;
    }

    // ═══════════════════════════════════════════════════════
    //  External — 2-phase flow
    // ═══════════════════════════════════════════════════════

    /// @notice Phase 1: deploys token + sale + arbitration + registers a
    ///         pending slot. Token starts at 0 supply; the sale holds
    ///         MINTER_ROLE so all supply originates from public buys.
    /// @dev    The spot pool's sqrtPriceX96 is NOT passed by the caller —
    ///         Part2 derives it from `sale.INITIAL_PRICE_WEI_PER_TOKEN` so
    ///         it can never disagree with the sale's economic price.
    function createFutarchyPart1(
        string calldata name,
        string calldata symbol,
        string calldata description,
        uint256 initialPriceWeiPerToken,
        uint256 minInitialPhaseSold,
        uint256 initialPhaseDuration,
        uint32 timeout,
        uint32 twapWindow,
        uint256 baseBondX
    ) external returns (uint256 id) {
        _validate(name, symbol, timeout, twapWindow, baseBondX);

        address creator = msg.sender;

        (address token, address sale) = TOKEN_ARB_DEPLOYER.deployTokenAndSale(
            name, symbol, creator,
            initialPriceWeiPerToken, minInitialPhaseSold, initialPhaseDuration
        );

        address arb = TOKEN_ARB_DEPLOYER.deployArbitration(
            creator, WETH, baseBondX, DEFAULT_MAX_QUEUE, timeout
        );

        id = _instances.length;
        _instances.push(
            FutarchyInstance({
                name: name,
                symbol: symbol,
                description: description,
                creator: creator,
                token: token,
                sale: sale,
                arbitration: arb,
                resolver: address(0),
                factory: address(0),
                orchestrator: address(0),
                spotPool: address(0),
                createdAt: block.timestamp,
                status: InstanceStatus.PENDING_PART2,
                timeout: timeout,
                twapWindow: twapWindow
            })
        );

        emit FutarchyPart1Created(id, creator, name, symbol, token, sale, arb);
    }

    /// @notice Phase 2: deploys resolver + factory + orchestrator + creates
    ///         and initializes the spot pool, then wires the resolver.
    /// @dev    Reverts if `id` wasn't created via Part1, or if Part2 already
    ///         ran for this id. Anyone can call — not restricted to original
    ///         Part1 creator. Gas budget: ≤ 13M. Measured ~9-12M.
    function createFutarchyPart2(uint256 id) external {
        if (id >= _instances.length) revert InvalidInstanceId();
        FutarchyInstance storage inst = _instances[id];
        if (inst.status == InstanceStatus.READY) revert AlreadyReady();
        if (inst.status != InstanceStatus.PENDING_PART2) revert NotInPendingPart2();

        // Snapshot fields onto the stack before any external calls / writes —
        // makes the event emission cheaper and the read pattern obvious.
        address token = inst.token;
        address creator = inst.creator;
        uint32 timeout = inst.timeout;
        uint32 twapWindow = inst.twapWindow;

        // Derive the pool's initial sqrtPriceX96 from the sale's economic
        // price. Single source of truth — the user can't pass a value that
        // disagrees with the sale and leave the pool degenerate at price=1.
        uint256 priceWei = IInstanceSalePriceLike(inst.sale).INITIAL_PRICE_WEI_PER_TOKEN();
        uint160 initialSqrtPriceX96 = _sqrtPriceX96FromWeiPrice(priceWei);

        // Spot UniV3 pool (token / WETH at FEE_TIER).
        address spotPool = _createAndInitSpotPool(token, initialSqrtPriceX96);

        // Resolver + proposal factory + orchestrator.
        FutarchyStackDeployer.Deployed memory stack = STACK_DEPLOYER.deployStack(
            PROPOSAL_IMPL,
            CTF,
            W1155,
            UNIV3_FACTORY,
            creator,
            token,
            WETH,
            spotPool,
            FEE_TIER,
            OBSERVATION_CARDINALITY,
            timeout,
            twapWindow
        );

        // Lock resolver to orchestrator.
        FAOTwapResolver(stack.resolver).setOrchestrator(stack.orchestrator);

        // Finalize storage.
        inst.resolver = stack.resolver;
        inst.factory = stack.factory;
        inst.orchestrator = stack.orchestrator;
        inst.spotPool = spotPool;
        inst.status = InstanceStatus.READY;

        emit FutarchyPart2Created(id, creator, stack.resolver, stack.factory, stack.orchestrator, spotPool);
        emit FutarchyCreated(
            id,
            creator,
            inst.name,
            inst.symbol,
            token,
            inst.sale,
            inst.arbitration,
            stack.resolver,
            stack.factory,
            stack.orchestrator,
            spotPool
        );
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    function instancesCount() external view returns (uint256) {
        return _instances.length;
    }

    function instances(uint256 id) external view returns (FutarchyInstance memory) {
        if (id >= _instances.length) revert InvalidInstanceId();
        return _instances[id];
    }

    function allInstances() external view returns (FutarchyInstance[] memory) {
        return _instances;
    }

    /// @notice Convenience: true iff this id exists and is still awaiting Part2.
    function isPendingPart2(uint256 id) external view returns (bool) {
        if (id >= _instances.length) return false;
        return _instances[id].status == InstanceStatus.PENDING_PART2;
    }

    // ═══════════════════════════════════════════════════════
    //  Internals
    // ═══════════════════════════════════════════════════════

    function _validate(
        string calldata name,
        string calldata symbol,
        uint32 timeout,
        uint32 twapWindow,
        uint256 baseBondX
    ) internal pure {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (timeout == 0 || twapWindow == 0 || twapWindow > timeout) revert InvalidResolverConfig();
        if (baseBondX == 0) revert InvalidBaseBond();
    }

    /// @dev sqrtPriceX96 = sqrt(priceWei / 1e18) * 2^96
    ///                  = sqrt(priceWei) * 2^96 / sqrt(1e18)
    ///                  = sqrt(priceWei) * 2^96 / 1e9    (since sqrt(1e18) = 1e9)
    /// `priceWei` is the sale's `INITIAL_PRICE_WEI_PER_TOKEN` — wei of ETH
    /// per 1 whole token (1e18 base units), so dividing by 1e18 converts to
    /// the dimensionless WETH/TOKEN ratio UniV3 stores. Uses an inline
    /// Babylonian sqrt to avoid an OZ import.
    function _sqrtPriceX96FromWeiPrice(uint256 priceWei) internal pure returns (uint160) {
        require(priceWei > 0, "priceWei=0");
        uint256 s = (_sqrt(priceWei) * (uint256(1) << 96)) / 1e9;
        require(s <= type(uint160).max, "sqrtPriceX96 overflow");
        require(s > 0, "sqrtPriceX96=0");
        return uint160(s);
    }

    /// @dev Integer sqrt via Babylonian iteration. Returns floor(sqrt(x)).
    /// Borrowed from Uniswap's `FullMath` flavour; precision loss at most
    /// 1 unit (off-by-one), which is fine for sqrtPriceX96 scaling.
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; r <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; r <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; r <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; r <<= 8; }
        if (xx >= 0x100) { xx >>= 8; r <<= 4; }
        if (xx >= 0x10) { xx >>= 4; r <<= 2; }
        if (xx >= 0x8) { r <<= 1; }
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return r < r1 ? r : r1;
    }

    /// @dev Create the (token, WETH, FEE_TIER) UniV3 pool, initialize it at
    /// `sqrtPriceX96` in its native orientation, and warm the observation
    /// buffer to `OBSERVATION_CARDINALITY` so resolvers can read TWAPs
    /// without waiting for the ring buffer to fill in.
    function _createAndInitSpotPool(address token, uint160 sqrtPriceX96)
        internal
        returns (address pool)
    {
        address existing = UNIV3_FACTORY.getPool(token, WETH, FEE_TIER);
        if (existing != address(0)) {
            (uint160 inited,,,,,,) = IUniswapV3PoolLike(existing).slot0();
            if (inited != 0) revert SpotPoolAlreadyExists();
            pool = existing;
        } else {
            pool = UNIV3_FACTORY.createPool(token, WETH, FEE_TIER);
        }

        // Translate "WETH per token" → native (token0/token1) orientation.
        uint160 sqrtToInit =
            token < WETH ? sqrtPriceX96 : _invertSqrtPriceX96(sqrtPriceX96);

        IUniswapV3PoolLike(pool).initialize(sqrtToInit);
        IUniswapV3PoolLike(pool).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);
    }

    function _invertSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint160) {
        uint256 inv = (uint256(1) << 192) / uint256(sqrtPriceX96);
        require(inv <= type(uint160).max, "invert overflow");
        return uint160(inv);
    }
}
