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
        address arbitration;
        address resolver;            // address(0) until Part2
        address factory;             // address(0) until Part2
        address orchestrator;        // address(0) until Part2
        address spotPool;            // address(0) until Part2
        uint256 createdAt;
        InstanceStatus status;
        // Cached params so Part2 doesn't need them as args.
        uint160 initialSqrtPriceX96;
        uint32 timeout;
        uint32 twapWindow;
    }

    /// @dev Calldata bag for `createFutarchy*` so we don't pay a per-arg stack slot.
    struct CreateParams {
        string name;
        string symbol;
        string description;
        uint256 initialTokenSupply;
        uint160 initialSqrtPriceX96;
        uint32 timeout;
        uint32 twapWindow;
        uint256 baseBondX;
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
        address arbitration,
        address resolver,
        address factory,
        address orchestrator,
        address spotPool
    );

    error EmptyName();
    error EmptySymbol();
    error ZeroSqrtPrice();
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

    /// @notice Phase 1: deploys token + arbitration + registers a pending slot.
    ///         After this call, the instance has token+arbitration but no
    ///         factory/resolver/orchestrator/spotPool yet. `status =
    ///         PENDING_PART2`. Caller MUST run `createFutarchyPart2(id)` next.
    /// @dev    Gas budget: ≤ 13M. Measured ~3.5M with current contracts.
    function createFutarchyPart1(
        string calldata name,
        string calldata symbol,
        string calldata description,
        uint256 initialTokenSupply,
        uint160 initialSqrtPriceX96,
        uint32 timeout,
        uint32 twapWindow,
        uint256 baseBondX
    ) external returns (uint256 id) {
        _validate(name, symbol, initialSqrtPriceX96, timeout, twapWindow, baseBondX);

        address creator = msg.sender;

        // Deploy token (with full initial supply minted to creator).
        address token =
            TOKEN_ARB_DEPLOYER.deployToken(name, symbol, creator, initialTokenSupply);

        // Deploy parameterized arbitration (creator is admin/owner).
        address arb = TOKEN_ARB_DEPLOYER.deployArbitration(
            creator, WETH, baseBondX, DEFAULT_MAX_QUEUE, timeout
        );

        // Reserve registry slot.
        id = _instances.length;
        _instances.push(
            FutarchyInstance({
                name: name,
                symbol: symbol,
                description: description,
                creator: creator,
                token: token,
                arbitration: arb,
                resolver: address(0),
                factory: address(0),
                orchestrator: address(0),
                spotPool: address(0),
                createdAt: block.timestamp,
                status: InstanceStatus.PENDING_PART2,
                initialSqrtPriceX96: initialSqrtPriceX96,
                timeout: timeout,
                twapWindow: twapWindow
            })
        );

        emit FutarchyPart1Created(id, creator, name, symbol, token, arb);
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
        uint160 initialSqrtPriceX96 = inst.initialSqrtPriceX96;

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
            inst.arbitration,
            stack.resolver,
            stack.factory,
            stack.orchestrator,
            spotPool
        );
    }

    // ═══════════════════════════════════════════════════════
    //  External — legacy one-shot (kept for callers without gas-cap issues)
    // ═══════════════════════════════════════════════════════

    /// @notice Deploy a new futarchy instance and wire it end-to-end in a
    ///         single tx. Combines Part1 + Part2.
    /// @dev    Convenience wrapper — uses the same code paths as Part1/Part2
    ///         so the resulting on-chain state is identical. ~18.8M gas on
    ///         mainnet/Sepolia; prefer the 2-phase flow if you're going
    ///         through a public RPC with a 16.7M `eth_estimateGas` cap.
    function createFutarchy(
        string calldata name,
        string calldata symbol,
        string calldata description,
        uint256 initialTokenSupply,
        uint160 initialSqrtPriceX96,
        uint32 timeout,
        uint32 twapWindow,
        uint256 baseBondX
    ) external returns (uint256 id) {
        // Part1 — inlined so msg.sender stays as the original caller and we
        // don't pay for an extra external call back into this contract.
        _validate(name, symbol, initialSqrtPriceX96, timeout, twapWindow, baseBondX);
        address creator = msg.sender;

        address token =
            TOKEN_ARB_DEPLOYER.deployToken(name, symbol, creator, initialTokenSupply);
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
                arbitration: arb,
                resolver: address(0),
                factory: address(0),
                orchestrator: address(0),
                spotPool: address(0),
                createdAt: block.timestamp,
                status: InstanceStatus.PENDING_PART2,
                initialSqrtPriceX96: initialSqrtPriceX96,
                timeout: timeout,
                twapWindow: twapWindow
            })
        );

        emit FutarchyPart1Created(id, creator, name, symbol, token, arb);

        // Part2 — delegate to the regular public entry so storage layout
        // changes only have to be maintained in one place.
        this.createFutarchyPart2(id);
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
        uint160 initialSqrtPriceX96,
        uint32 timeout,
        uint32 twapWindow,
        uint256 baseBondX
    ) internal pure {
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (initialSqrtPriceX96 == 0) revert ZeroSqrtPrice();
        if (timeout == 0 || twapWindow == 0 || twapWindow > timeout) revert InvalidResolverConfig();
        if (baseBondX == 0) revert InvalidBaseBond();
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
