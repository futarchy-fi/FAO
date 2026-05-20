// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FAOFutarchyFactory} from "./FAOFutarchyFactory.sol";
import {FAOFutarchyProposal} from "./FAOFutarchyProposal.sol";
import {IFAOFutarchyTwapResolver} from "./interfaces/IFAOFutarchyOracle.sol";
import {IUniswapV3FactoryLike} from "./interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";

/// @notice Adapter responsible for moving liquidity from the spot pool into the
/// conditional pools after they are created and initialized.
/// @dev The orchestrator calls migrate() inside the atomic createOfficialProposalAndMigrate
/// flow. The adapter is granted the right to mint into the conditional pools (it implements
/// IUniswapV3MintCallback or equivalent). In v0 this is UniswapV3LiquidityAdapter.
interface IFAOLiquidityAdapter {
    function migrate(
        address proposal,
        address yesPool,
        address noPool,
        address spotPool,
        uint160 sqrtPriceX96
    ) external;
}

/// @title FAOOfficialProposalOrchestrator
/// @notice Atomic, MEV-resistant promotion of futarchy proposals to "official" status.
///
/// In a single transaction:
///   1. Read spot price from the canonical UniV3 FAO/WETH pool.
///   2. Create the CTF condition + Wrapped1155 outcome tokens via FAOFutarchyFactory.
///      (questionId derives from block.prevrandao — see FAOFutarchyFactory and
///      docs/onchain-futarchy-design.md §4.1.)
///   3. For each of the 2 conditional pools:
///      - if a pool exists at the deterministic (token0, token1, fee) address AND
///        is already initialized (slot0.sqrtPriceX96 != 0) → revert PreCreated.
///      - else: createPool, initialize at spot price.
///   4. Increase observation cardinality for TWAP window.
///   5. Migrate spot liquidity → conditional pools via the adapter.
///   6. Bind the resolver to (proposal, yesPool, noPool, anchorTimestamp).
///   7. (optional) block.coinbase.transfer(builderTip) — conditional payment.
///   8. emit OfficialProposalPromotedAndMigrated.
///
/// Reverts at any step roll back the whole tx (including TIP), so Flashbots bundles
/// with this call are dropped on revert and the defender pays nothing per failed attempt.
///
/// See docs/onchain-futarchy-design.md §3.2 for the full flow and §4 for the rationale.
contract FAOOfficialProposalOrchestrator {
    address public immutable ADMIN;
    FAOFutarchyFactory public immutable FACTORY;
    IUniswapV3FactoryLike public immutable UNIV3_FACTORY;
    address public immutable SPOT_POOL;
    address public immutable COMPANY_TOKEN; // typically FAO
    address public immutable CURRENCY_TOKEN; // typically WETH
    uint24 public immutable FEE_TIER;
    uint16 public immutable OBSERVATION_CARDINALITY;
    IFAOFutarchyTwapResolver public immutable RESOLVER;

    /// @notice Optional liquidity migration adapter. If unset, no liquidity migration
    /// happens at promote time (useful for early testnet runs where pools start empty).
    IFAOLiquidityAdapter public adapter;

    error NotAdmin();
    error PreCreated(address pool);
    error InvalidSpotPool();
    error InvalidProposalTokens();
    error AdapterAlreadySet();
    error InsufficientValueForTip();

    event AdapterSet(address indexed adapter);
    event OfficialProposalPromotedAndMigrated(
        uint256 indexed proposalId,
        address indexed proposal,
        address indexed promoter,
        bytes32 prevRandao,
        uint256 builderTip
    );

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAdmin();
        _;
    }

    constructor(
        address admin,
        FAOFutarchyFactory factory,
        IUniswapV3FactoryLike univ3Factory,
        address spotPool,
        address companyToken,
        address currencyToken,
        uint24 feeTier,
        uint16 observationCardinality,
        IFAOFutarchyTwapResolver resolver
    ) {
        if (admin == address(0)) revert NotAdmin();
        if (spotPool == address(0)) revert InvalidSpotPool();
        if (companyToken == address(0) || currencyToken == address(0)) revert InvalidProposalTokens();
        ADMIN = admin;
        FACTORY = factory;
        UNIV3_FACTORY = univ3Factory;
        SPOT_POOL = spotPool;
        COMPANY_TOKEN = companyToken;
        CURRENCY_TOKEN = currencyToken;
        FEE_TIER = feeTier;
        OBSERVATION_CARDINALITY = observationCardinality;
        RESOLVER = resolver;
    }

    /// @notice One-shot wiring: set the liquidity adapter. Immutable once set.
    function setAdapter(IFAOLiquidityAdapter newAdapter) external onlyAdmin {
        if (address(adapter) != address(0)) revert AdapterAlreadySet();
        adapter = newAdapter;
        emit AdapterSet(address(newAdapter));
    }

    /// @notice Atomic creation + promotion + (optional) migration + builder TIP.
    /// @param marketName Human-readable proposal name.
    /// @param description Free-form proposal body.
    /// @param builderTip Wei to forward to block.coinbase on success (0 to skip).
    /// @return proposalId Index assigned by FAOFutarchyFactory.
    /// @return proposal Address of the cloned FAOFutarchyProposal contract.
    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata description,
        uint256 builderTip
    ) external payable onlyAdmin returns (uint256 proposalId, address proposal) {
        if (msg.value < builderTip) revert InsufficientValueForTip();

        // Phase 1: read spot price + record anchor.
        (uint160 sqrtPriceX96, int24 spotTick) = _spotPriceAndTick();
        uint48 anchorTimestamp = uint48(block.timestamp);

        // Phase 2: deterministic factory call. questionId derives from block.prevrandao.
        proposalId = FACTORY.marketsCount();
        FAOFutarchyFactory.CreateProposalParams memory params = FAOFutarchyFactory.CreateProposalParams({
            marketName: marketName,
            description: description,
            collateralToken1: COMPANY_TOKEN,
            collateralToken2: CURRENCY_TOKEN
        });
        proposal = FACTORY.createProposal(params);

        // Phase 3: derive the 4 wrappers from the proposal.
        (address yesCompany, address noCompany, address yesCurrency, address noCurrency) =
            _readWrappers(proposal);

        // Phase 4: sanity check both conditional pools for pre-initialization.
        address yesPool = _maybeCreatePoolAndInit(yesCompany, yesCurrency, sqrtPriceX96, spotTick);
        address noPool = _maybeCreatePoolAndInit(noCompany, noCurrency, sqrtPriceX96, spotTick);

        // Phase 5: observation cardinality (so TWAP window has enough slots).
        IUniswapV3PoolLike(yesPool).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);
        IUniswapV3PoolLike(noPool).increaseObservationCardinalityNext(OBSERVATION_CARDINALITY);

        // Phase 6: bind resolver (sets anchor for TWAP window).
        RESOLVER.bindProposal(proposal, yesPool, noPool, COMPANY_TOKEN, CURRENCY_TOKEN, anchorTimestamp);

        // Phase 7: optional liquidity migration via adapter.
        if (address(adapter) != address(0)) {
            adapter.migrate(proposal, yesPool, noPool, SPOT_POOL, sqrtPriceX96);
        }

        // Phase 8: pay builder tip (conditional on full success — only opcode after this is emit).
        if (builderTip > 0) {
            // payable() cast is safe: block.coinbase is an EOA on Ethereum mainnet/Sepolia.
            // forge-lint: disable-next-line(unsafe-typecast)
            payable(block.coinbase).transfer(builderTip);
        }

        // Refund any excess msg.value.
        uint256 excess = msg.value - builderTip;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
        }

        emit OfficialProposalPromotedAndMigrated(
            proposalId, proposal, msg.sender, bytes32(block.prevrandao), builderTip
        );
    }

    // ─── views / helpers ────────────────────────────────────────────────────

    /// @notice Returns the spot pool's current sqrtPriceX96 in
    /// "currency per company" orientation.
    function _spotPriceAndTick() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        IUniswapV3PoolLike p = IUniswapV3PoolLike(SPOT_POOL);
        (uint160 raw, int24 rawTick,,,,,) = p.slot0();
        if (raw == 0) revert InvalidSpotPool();
        address t0 = p.token0();
        // UniV3 stores sqrt(token1/token0). Our convention: sqrt(currency/company).
        // If token0 == company, sqrt(currency/company) = raw. Else invert.
        if (t0 == COMPANY_TOKEN) {
            sqrtPriceX96 = raw;
            tick = rawTick;
        } else if (t0 == CURRENCY_TOKEN) {
            sqrtPriceX96 = _invertSqrtPriceX96(raw);
            tick = -rawTick;
        } else {
            revert InvalidSpotPool();
        }
    }

    /// @param companyWrap Wrapper derived from COMPANY_TOKEN side of the condition.
    /// @param currencyWrap Wrapper derived from CURRENCY_TOKEN side.
    function _maybeCreatePoolAndInit(
        address companyWrap,
        address currencyWrap,
        uint160 sqrtCurrencyPerCompanyX96,
        int24 /* spotTick */
    ) internal returns (address pool) {
        pool = UNIV3_FACTORY.getPool(companyWrap, currencyWrap, FEE_TIER);
        uint160 sqrtToInit = _sqrtForOrderedPair(companyWrap, currencyWrap, sqrtCurrencyPerCompanyX96);

        if (pool == address(0)) {
            pool = UNIV3_FACTORY.createPool(companyWrap, currencyWrap, FEE_TIER);
            IUniswapV3PoolLike(pool).initialize(sqrtToInit);
            return pool;
        }

        // Pool already exists. If un-initialized, we initialize ourselves.
        (uint160 existing,,,,,,) = IUniswapV3PoolLike(pool).slot0();
        if (existing == 0) {
            IUniswapV3PoolLike(pool).initialize(sqrtToInit);
            return pool;
        }

        // Pool exists AND is initialized — adversary win condition, refuse.
        revert PreCreated(pool);
    }

    /// @dev Translate "currency per company" sqrt price into the pool's native orientation.
    /// Pool token0/token1 is determined by address ordering: token0 = min(a,b).
    /// Pool sqrt is sqrt(token1/token0).
    function _sqrtForOrderedPair(address companyWrap, address currencyWrap, uint160 sqrtCurrencyPerCompanyX96)
        internal
        pure
        returns (uint160)
    {
        // If company sorts first → token0 = company, token1 = currency
        //   → pool sqrt = sqrt(currency/company) = sqrtCurrencyPerCompanyX96.
        // Else → token0 = currency → pool sqrt = sqrt(company/currency) = 1/sqrtPriceX96.
        if (companyWrap < currencyWrap) {
            return sqrtCurrencyPerCompanyX96;
        }
        return _invertSqrtPriceX96(sqrtCurrencyPerCompanyX96);
    }

    function _invertSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint160) {
        // 1 / sqrt(p) in X96: (2^96)^2 / sqrtPriceX96 = 2^192 / sqrtPriceX96.
        uint256 inv = uint256(1) << 192;
        inv = inv / uint256(sqrtPriceX96);
        require(inv <= type(uint160).max, "invert overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(inv);
    }

    function _readWrappers(address proposal)
        internal
        view
        returns (address yesCompany, address noCompany, address yesCurrency, address noCurrency)
    {
        FAOFutarchyProposal p = FAOFutarchyProposal(proposal);
        (yesCompany,) = p.wrappedOutcome(0);
        (noCompany,) = p.wrappedOutcome(1);
        (yesCurrency,) = p.wrappedOutcome(2);
        (noCurrency,) = p.wrappedOutcome(3);
    }
}
