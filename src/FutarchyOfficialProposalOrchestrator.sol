// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FutarchyLiquidityManager} from "./FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "./FutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "./interfaces/IAlgebraFactoryLike.sol";
import {IAlgebraPoolLike} from "./interfaces/IAlgebraPoolLike.sol";
import {ISwaprAlgebraPositionManager} from "./interfaces/ISwaprAlgebraPositionManager.sol";

interface IFutarchyFactoryLike {
    struct CreateProposalParams {
        string marketName;
        address collateralToken1;
        address collateralToken2;
        string category;
        string lang;
        uint256 minBond;
        uint32 openingTime;
    }

    function createProposal(CreateProposalParams calldata params) external returns (address);
    function marketsCount() external view returns (uint256);
    function proposals(uint256) external view returns (address);
}

interface IFutarchyProposalViewLike {
    function collateralToken1() external view returns (address);
    function collateralToken2() external view returns (address);
    function wrappedOutcome(uint256 index) external view returns (address, bytes memory);
}

/// @notice Atomic official proposal creation + pool initialization + spot->conditional migration.
/// @dev This is intentionally "wiring-light": deploy it first, deploy the manager with this as
/// OFFICIAL_PROPOSER, then wire manager + proposalSource once.
contract FutarchyOfficialProposalOrchestrator {
    address public immutable ADMIN;
    IFutarchyFactoryLike public immutable FUTARCHY_FACTORY;
    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    ISwaprAlgebraPositionManager public immutable POSITION_MANAGER;

    FutarchyLiquidityManager public manager;
    FutarchyOfficialProposalSource public proposalSource;
    bool public wired;

    uint256 internal constant Q192 = 1 << 192;

    // How strictly we require conditional pool init to match spot price (ticks). For pools
    // initialized from the spot sqrtPriceX96, this should be ~0 (allowing tiny rounding).
    uint256 public constant MAX_INIT_TICK_DELTA = 2;

    error NotAdmin();
    error AlreadyWired();
    error NotWired();
    error InvalidSpotPool();
    error InvalidProposalTokens();
    error PriceInitMismatch();
    error InvalidSqrtPrice();
    error SyncDidNotMigrate();

    event Wired(address indexed manager, address indexed proposalSource);
    event CandidateProposalCreated(
        uint256 indexed proposalId, address indexed proposal, address indexed creator
    );
    event OfficialProposalPromotedAndMigrated(
        uint256 indexed proposalId, address indexed proposal, address indexed promoter
    );

    struct OutcomeTokens {
        address yesCompany;
        address noCompany;
        address yesCurrency;
        address noCurrency;
    }

    constructor(
        address admin,
        IFutarchyFactoryLike futarchyFactory,
        IAlgebraFactoryLike algebraFactory,
        ISwaprAlgebraPositionManager positionManager
    ) {
        if (admin == address(0)) revert NotAdmin();
        ADMIN = admin;
        FUTARCHY_FACTORY = futarchyFactory;
        ALGEBRA_FACTORY = algebraFactory;
        POSITION_MANAGER = positionManager;
    }

    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert NotAdmin();
        _;
    }

    function setWiring(
        FutarchyLiquidityManager newManager,
        FutarchyOfficialProposalSource newSource
    ) external onlyAdmin {
        if (wired) revert AlreadyWired();
        manager = newManager;
        proposalSource = newSource;
        wired = true;
        emit Wired(address(newManager), address(newSource));
    }

    function createOfficialProposalAndMigrate(
        string calldata marketName,
        string calldata category,
        string calldata lang,
        uint256 minBond,
        uint32 openingTime
    ) external onlyAdmin returns (uint256 proposalId, address proposal) {
        (proposalId, proposal) = createCandidateProposal(
            marketName, category, lang, minBond, openingTime
        );
        promoteToOfficialAndMigrate(proposalId);
    }

    /// @notice Permissionless creation of a candidate proposal. Does not make it official and
    /// does not migrate liquidity.
    function createCandidateProposal(
        string calldata marketName,
        string calldata category,
        string calldata lang,
        uint256 minBond,
        uint32 openingTime
    ) public returns (uint256 proposalId, address proposal) {
        if (!wired) revert NotWired();

        address fao = address(manager.FAO_TOKEN());
        address collateral = address(manager.WRAPPED_NATIVE());

        IFutarchyFactoryLike.CreateProposalParams memory createParams;
        createParams.marketName = marketName;
        createParams.collateralToken1 = fao;
        createParams.collateralToken2 = collateral;
        createParams.category = category;
        createParams.lang = lang;
        createParams.minBond = minBond;
        createParams.openingTime = openingTime;

        proposalId = FUTARCHY_FACTORY.marketsCount();
        proposal = FUTARCHY_FACTORY.createProposal(createParams);
        if (FUTARCHY_FACTORY.proposals(proposalId) != proposal) revert InvalidProposalTokens();

        // Ensure proposal wiring matches our FAO/collateral pair.
        IFutarchyProposalViewLike p = IFutarchyProposalViewLike(proposal);
        if (p.collateralToken1() != fao || p.collateralToken2() != collateral) {
            revert InvalidProposalTokens();
        }

        emit CandidateProposalCreated(proposalId, proposal, msg.sender);
    }

    /// @notice Admin-only promotion: initializes conditional pools at current spot price,
    /// sets the proposal as official, and migrates spot -> conditional liquidity atomically.
    function promoteToOfficialAndMigrate(uint256 proposalId)
        public
        onlyAdmin
        returns (address proposal)
    {
        if (!wired) revert NotWired();

        // Load proposal from the canonical factory mapping.
        // We do not accept an arbitrary proposal address here to avoid operator error.
        if (proposalId >= FUTARCHY_FACTORY.marketsCount()) revert InvalidProposalTokens();
        proposal = FUTARCHY_FACTORY.proposals(proposalId);
        if (proposal == address(0)) revert InvalidProposalTokens();

        _promoteAndMigrate(proposalId, proposal);
        emit OfficialProposalPromotedAndMigrated(proposalId, proposal, msg.sender);
    }

    function _promoteAndMigrate(uint256 proposalId, address proposal) internal {
        address fao = address(manager.FAO_TOKEN());
        address collateral = address(manager.WRAPPED_NATIVE());

        address spotPool = ALGEBRA_FACTORY.poolByPair(fao, collateral);
        if (spotPool == address(0)) revert InvalidSpotPool();

        // Read spot price in a canonical "collateral per FAO" orientation.
        (uint160 sqrtPriceQuotePerBaseX96, int24 spotTick) =
            _spotEconomicPrice(spotPool, fao, collateral);

        // Ensure proposal wiring matches our FAO/collateral pair.
        IFutarchyProposalViewLike p = IFutarchyProposalViewLike(proposal);
        if (p.collateralToken1() != fao || p.collateralToken2() != collateral) {
            revert InvalidProposalTokens();
        }

        OutcomeTokens memory outcomes;
        (outcomes.yesCompany,) = p.wrappedOutcome(0);
        (outcomes.noCompany,) = p.wrappedOutcome(1);
        (outcomes.yesCurrency,) = p.wrappedOutcome(2);
        (outcomes.noCurrency,) = p.wrappedOutcome(3);

        _initAndValidatePools(outcomes, sqrtPriceQuotePerBaseX96, spotTick);

        // Make it official (only callable by the official proposer configured on proposalSource).
        proposalSource.setOfficialProposalFromOfficialProposer(proposalId, proposal);

        // Migrate 80% spot liquidity into conditional markets in the same tx.
        FutarchyLiquidityManager.SyncParams memory params;
        FutarchyLiquidityManager.SyncAction action = manager.sync(params);
        if (action != FutarchyLiquidityManager.SyncAction.MigratedToConditional) {
            revert SyncDidNotMigrate();
        }
    }

    function _initAndValidatePools(
        OutcomeTokens memory outcomes,
        uint160 sqrtPriceQuotePerBaseX96,
        int24 spotTick
    ) internal {
        // Initialize the YES and NO pools at the spot price (economic parity).
        address yesPool = _createAndInitPoolAtSpotPrice(
            outcomes.yesCompany, outcomes.yesCurrency, sqrtPriceQuotePerBaseX96
        );
        address noPool = _createAndInitPoolAtSpotPrice(
            outcomes.noCompany, outcomes.noCurrency, sqrtPriceQuotePerBaseX96
        );

        // Verify both conditional pools match spot tick before making the proposal official.
        uint256 yesDelta = _absDiff(
            int256(_economicTick(yesPool, outcomes.yesCompany, outcomes.yesCurrency)),
            int256(spotTick)
        );
        if (yesDelta > MAX_INIT_TICK_DELTA) revert PriceInitMismatch();

        uint256 noDelta = _absDiff(
            int256(_economicTick(noPool, outcomes.noCompany, outcomes.noCurrency)), int256(spotTick)
        );
        if (noDelta > MAX_INIT_TICK_DELTA) revert PriceInitMismatch();
    }

    function _createAndInitPoolAtSpotPrice(
        address companyOutcome,
        address currencyOutcome,
        uint160 sqrtPriceQuotePerBaseX96
    ) internal returns (address pool) {
        (address token0, address token1) = _sortPair(companyOutcome, currencyOutcome);
        uint160 sqrtToInit =
            _sqrtForPair(token0, token1, companyOutcome, currencyOutcome, sqrtPriceQuotePerBaseX96);
        pool = POSITION_MANAGER.createAndInitializePoolIfNecessary(token0, token1, sqrtToInit);
    }

    function _spotEconomicPrice(address spotPool, address fao, address collateral)
        internal
        view
        returns (uint160 sqrtPriceQuotePerBaseX96, int24 economicTick)
    {
        IAlgebraPoolLike p = IAlgebraPoolLike(spotPool);
        address t0 = p.token0();
        address t1 = p.token1();
        (uint160 sqrtPriceX96, int24 tick,,,,,) = p.globalState();
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();

        // sqrtPriceX96 expresses sqrt(token1/token0). We want sqrt(collateral/fao) as "quote/base".
        if (t0 == fao && t1 == collateral) {
            sqrtPriceQuotePerBaseX96 = sqrtPriceX96;
            economicTick = tick;
            return (sqrtPriceQuotePerBaseX96, economicTick);
        }
        if (t0 == collateral && t1 == fao) {
            sqrtPriceQuotePerBaseX96 = _invertSqrtPriceX96(sqrtPriceX96);
            economicTick = -tick;
            return (sqrtPriceQuotePerBaseX96, economicTick);
        }

        revert InvalidSpotPool();
    }

    function _sqrtForPair(
        address token0,
        address token1,
        address base,
        address quote,
        uint160 sqrtQuotePerBaseX96
    ) internal pure returns (uint160) {
        if (token0 == base && token1 == quote) return sqrtQuotePerBaseX96;
        if (token0 == quote && token1 == base) return _invertSqrtPriceX96(sqrtQuotePerBaseX96);
        revert InvalidProposalTokens();
    }

    function _invertSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint160 inv) {
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        uint256 q = Q192 / uint256(sqrtPriceX96);
        if (q > type(uint160).max) revert InvalidSqrtPrice();
        inv = uint160(q);
    }

    function _economicTick(address pool, address base, address quote)
        internal
        view
        returns (int24)
    {
        IAlgebraPoolLike p = IAlgebraPoolLike(pool);
        address t0 = p.token0();
        address t1 = p.token1();
        (, int24 tick,,,,,) = p.globalState();
        if (t0 == base && t1 == quote) return tick;
        if (t0 == quote && t1 == base) return -tick;
        revert InvalidProposalTokens();
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        int256 d = a - b;
        return uint256(d < 0 ? -d : d);
    }

    function _sortPair(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA < tokenB) return (tokenA, tokenB);
        return (tokenB, tokenA);
    }
}
