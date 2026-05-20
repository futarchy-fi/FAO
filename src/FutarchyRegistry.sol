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
/// instance in one transaction. Shared chain-level infrastructure (CTF,
/// Wrapped1155Factory, UniV3 factory, proposal implementation, WETH) is
/// reused; per-instance contracts (governance token, arbitration, resolver,
/// proposal factory, orchestrator, spot pool) are freshly deployed and
/// returned via a single `FutarchyCreated` event.
///
/// Bond token for every instance is WETH — keeps escalation universal,
/// liquid, and predictable across orgs. Each instance picks its own
/// timeout / TWAP window / baseX.
///
/// @dev The actual `new` calls live in `FutarchyRegistryDeployers.sol` so this
/// contract's deployed bytecode stays under EIP-170 (24576 bytes). The two
/// sub-deployers are passed in at construction and immutable afterwards.
contract FutarchyRegistry {
    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

    struct FutarchyInstance {
        string name;
        string symbol;
        string description;
        address creator;
        address token;
        address arbitration;
        address resolver;
        address factory;
        address orchestrator;
        address spotPool;
        uint256 createdAt;
    }

    /// @dev Calldata bag for `createFutarchy` so we don't pay a per-arg stack slot.
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
    //  External
    // ═══════════════════════════════════════════════════════

    /// @notice Deploy a new futarchy instance and wire it end-to-end.
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
        if (bytes(name).length == 0) revert EmptyName();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        if (initialSqrtPriceX96 == 0) revert ZeroSqrtPrice();
        if (timeout == 0 || twapWindow == 0 || twapWindow > timeout) revert InvalidResolverConfig();
        if (baseBondX == 0) revert InvalidBaseBond();

        address creator = msg.sender;

        // Step 1: token (with full initial supply minted to creator).
        address token =
            TOKEN_ARB_DEPLOYER.deployToken(name, symbol, creator, initialTokenSupply);

        // Step 2: spot UniV3 pool (token / WETH at FEE_TIER).
        address spotPool = _createAndInitSpotPool(token, initialSqrtPriceX96);

        // Step 3: parameterized arbitration (creator is admin/owner).
        address arb = TOKEN_ARB_DEPLOYER.deployArbitration(
            creator, WETH, baseBondX, DEFAULT_MAX_QUEUE, timeout
        );

        // Step 4-6: resolver + proposal factory + orchestrator.
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

        // Step 7: lock resolver to orchestrator.
        FAOTwapResolver(stack.resolver).setOrchestrator(stack.orchestrator);

        // Step 8: store + emit.
        id = _instances.length;
        _instances.push(
            FutarchyInstance({
                name: name,
                symbol: symbol,
                description: description,
                creator: creator,
                token: token,
                arbitration: arb,
                resolver: stack.resolver,
                factory: stack.factory,
                orchestrator: stack.orchestrator,
                spotPool: spotPool,
                createdAt: block.timestamp
            })
        );

        emit FutarchyCreated(
            id,
            creator,
            name,
            symbol,
            token,
            arb,
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

    // ═══════════════════════════════════════════════════════
    //  Internals
    // ═══════════════════════════════════════════════════════

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
