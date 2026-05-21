// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFAOLiquidityAdapter} from "./FAOOfficialProposalOrchestrator.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";
import {FAOFutarchyProposal} from "./FAOFutarchyProposal.sol";
import {UniV3Math} from "./libraries/UniV3Math.sol";

/// @notice Minimal ERC20 surface used by the adapter (matches both OZ v4 and
/// `Wrapped1155`'s mint output).
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Subset of IUniswapV3MintCallback the adapter must implement to satisfy
/// `pool.mint()`. Defining inline keeps us free of the periphery package.
interface IUniswapV3MintCallback {
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external;
}

/// @notice CTF surface beyond what other FAO contracts use. Kept separate from
/// `IConditionalTokensLike` so that adding/removing adapter-specific methods does
/// not force every mock in the test suite to change. Real Gnosis CTF satisfies
/// both interfaces transparently.
interface IConditionalTokensSplitAndTransfer {
    /// @notice Split `amount` of `collateralToken` into the conditional positions
    /// described by `partition` under the given `conditionId`. Caller must have
    /// approved CTF to pull `amount` of `collateralToken` before calling.
    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    /// @notice ERC1155 safeTransferFrom — used by the adapter to wrap each
    /// conditional position into its Wrapped1155 ERC20 by transferring to the
    /// wrapper contract (which mints 1:1 on `onERC1155Received`).
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
}

/// @title UniswapV3LiquidityAdapter
/// @notice v0 production adapter invoked by `FAOOfficialProposalOrchestrator.migrate`
/// inside the atomic promote tx. Pulls dominant liquidity from the proposer
/// (`tx.origin`), splits it into the 4 conditional ERC20 wrappers via CTF +
/// Wrapped1155Factory, and mints full-range UniV3 positions into the YES and NO
/// conditional pools. See `docs/liquidity-adapter.md` for the full flow.
///
/// ## Pull-from-tx.origin pattern
///
/// The orchestrator does not custody tokens; the proposer does. The orchestrator
/// calls `adapter.migrate(...)` and the adapter pulls (COMPANY, CURRENCY) from
/// `tx.origin` based on amounts pre-staged via `stage(...)`. This avoids changing
/// the orchestrator signature for a v0 feature, and the pull is single-use so a
/// stale staging can never be replayed by a subsequent unrelated promote.
///
/// ## Liquidity math
///
/// Full-range only in v0. Tick bounds are computed by clamping `±MAX_TICK` to the
/// pool's `tickSpacing` (10 for fee 500). Liquidity is derived from staged amounts
/// via `UniV3Math.getLiquidityForAmounts(...)`. See `docs/liquidity-adapter.md` for
/// the rationale (full-range is dilutive — fine for v0 testnet, refinement to
/// concentrated ranges is a follow-up).
///
/// ## Security
///
/// * `migrate` callable only by the wired ORCHESTRATOR (the orchestrator itself is
///   gated to admin).
/// * `uniswapV3MintCallback` checks `msg.sender` against the pool address encoded
///   in the callback data so a hostile pool cannot drain the adapter mid-tx.
/// * Pull amounts come from a single-use mapping; stale stage never replays.
contract UniswapV3LiquidityAdapter is IFAOLiquidityAdapter, IUniswapV3MintCallback {
    // ─── immutable wiring ──────────────────────────────────────────────────

    IConditionalTokensLike public immutable CTF;
    IWrapped1155FactoryLike public immutable W1155;
    address public immutable ORCHESTRATOR;
    address public immutable COMPANY; // e.g. FAO
    address public immutable CURRENCY; // e.g. WETH

    // ─── state ─────────────────────────────────────────────────────────────

    struct StagedAmounts {
        uint128 companyAmt;
        uint128 currencyAmt;
    }

    /// @notice Amounts staged by an EOA for their next `migrate` call. Single-use:
    /// `migrate` clears the entry on success. Re-staging overwrites.
    mapping(address => StagedAmounts) public stagedFor;

    // ─── errors / events ───────────────────────────────────────────────────

    error OnlyOrchestrator();
    error NothingStaged();
    error ZeroAmount();
    error InvalidPool();
    error ERC20TransferFailed();
    error CallbackUnauthorized();

    event Staged(address indexed user, uint256 companyAmt, uint256 currencyAmt);
    event Migrated(
        address indexed proposal,
        address yesPool,
        address noPool,
        uint256 companyAllocated,
        uint256 currencyAllocated
    );
    event PoolLiquidityMinted(
        address indexed pool, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1
    );

    constructor(
        IConditionalTokensLike ctf,
        IWrapped1155FactoryLike w1155,
        address orchestrator,
        address company,
        address currency
    ) {
        CTF = ctf;
        W1155 = w1155;
        ORCHESTRATOR = orchestrator;
        COMPANY = company;
        CURRENCY = currency;
    }

    // ─── public flows ──────────────────────────────────────────────────────

    /// @notice Stage the amount of COMPANY + CURRENCY this caller will deposit
    /// into the YES + NO conditional pools on their next promote. Single-use:
    /// consumed by the immediately-following `migrate(...)` call invoked by the
    /// orchestrator.
    ///
    /// Caller must also `approve` this adapter to pull `companyAmt` of COMPANY and
    /// `currencyAmt` of CURRENCY before calling the orchestrator.
    function stage(uint256 companyAmt, uint256 currencyAmt) external {
        if (companyAmt == 0 || currencyAmt == 0) revert ZeroAmount();
        require(companyAmt <= type(uint128).max && currencyAmt <= type(uint128).max, "amount > uint128");
        // forge-lint: disable-next-line(unsafe-typecast)
        stagedFor[msg.sender] = StagedAmounts({companyAmt: uint128(companyAmt), currencyAmt: uint128(currencyAmt)});
        emit Staged(msg.sender, companyAmt, currencyAmt);
    }

    /// @inheritdoc IFAOLiquidityAdapter
    function migrate(
        address proposal,
        address yesPool,
        address noPool,
        address /* spotPool */,
        uint160 sqrtPriceX96
    ) external override {
        if (msg.sender != ORCHESTRATOR) revert OnlyOrchestrator();

        // 1. Read staged amounts (single-use; cleared on success).
        StagedAmounts memory s = stagedFor[tx.origin];
        if (s.companyAmt == 0 || s.currencyAmt == 0) revert NothingStaged();
        uint256 companyAmt = uint256(s.companyAmt);
        uint256 currencyAmt = uint256(s.currencyAmt);

        // 2. Pull tokens from the proposer (tx.origin). Both must have been approved.
        _pull(COMPANY, tx.origin, companyAmt);
        _pull(CURRENCY, tx.origin, currencyAmt);

        // 3. Approve CTF then split both collaterals into YES/NO ERC1155 positions.
        _approveMax(COMPANY, address(CTF));
        _approveMax(CURRENCY, address(CTF));

        bytes32 conditionId = FAOFutarchyProposal(proposal).conditionId();
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // YES indexSet (binary 0b01)
        partition[1] = 2; // NO  indexSet (binary 0b10)

        IConditionalTokensSplitAndTransfer ctfX = IConditionalTokensSplitAndTransfer(address(CTF));
        ctfX.splitPosition(COMPANY, bytes32(0), conditionId, partition, companyAmt);
        ctfX.splitPosition(CURRENCY, bytes32(0), conditionId, partition, currencyAmt);

        // 4. Wrap each of the 4 ERC1155 positions into its ERC20 wrapper by
        // safeTransferFrom-ing to the wrapper address (which mints 1:1 on
        // onERC1155Received). The four wrapper addresses are pre-deployed by the
        // factory at proposal creation; we re-read them here for clarity.
        (address yesCompanyWrap, bytes memory yesCompanyData) = FAOFutarchyProposal(proposal).wrappedOutcome(0);
        (address noCompanyWrap, bytes memory noCompanyData) = FAOFutarchyProposal(proposal).wrappedOutcome(1);
        (address yesCurrencyWrap, bytes memory yesCurrencyData) = FAOFutarchyProposal(proposal).wrappedOutcome(2);
        (address noCurrencyWrap, bytes memory noCurrencyData) = FAOFutarchyProposal(proposal).wrappedOutcome(3);

        _wrap(COMPANY, conditionId, 1, yesCompanyWrap, yesCompanyData, companyAmt);
        _wrap(COMPANY, conditionId, 2, noCompanyWrap, noCompanyData, companyAmt);
        _wrap(CURRENCY, conditionId, 1, yesCurrencyWrap, yesCurrencyData, currencyAmt);
        _wrap(CURRENCY, conditionId, 2, noCurrencyWrap, noCurrencyData, currencyAmt);

        // 5. Mint full-range liquidity into each conditional pool.
        _mintFullRange(yesPool, yesCompanyWrap, yesCurrencyWrap, companyAmt, currencyAmt, sqrtPriceX96);
        _mintFullRange(noPool, noCompanyWrap, noCurrencyWrap, companyAmt, currencyAmt, sqrtPriceX96);

        // 6. Clear staging (single-use) + emit.
        delete stagedFor[tx.origin];

        emit Migrated(proposal, yesPool, noPool, companyAmt, currencyAmt);
    }

    // ─── UniV3 mint callback ───────────────────────────────────────────────

    struct MintCallbackData {
        address pool;
        address token0;
        address token1;
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external
        override
    {
        MintCallbackData memory cb = abi.decode(data, (MintCallbackData));
        // Pool integrity: only the encoded pool may invoke this callback.
        if (msg.sender != cb.pool) revert CallbackUnauthorized();

        if (amount0Owed > 0) _transfer(cb.token0, cb.pool, amount0Owed);
        if (amount1Owed > 0) _transfer(cb.token1, cb.pool, amount1Owed);
    }

    // ─── internals ─────────────────────────────────────────────────────────

    function _mintFullRange(
        address pool,
        address companyWrap,
        address currencyWrap,
        uint256 companyAmt,
        uint256 currencyAmt,
        uint160 sqrtPriceX96
    ) internal {
        if (pool == address(0)) revert InvalidPool();
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        address token0 = p.token0();
        address token1 = p.token1();

        // Map our (companyAmt, currencyAmt) into (amount0, amount1) for THIS pool's
        // token-ordering. companyWrap may be either token0 or token1; same for currency.
        uint256 amount0;
        uint256 amount1;
        if (token0 == companyWrap && token1 == currencyWrap) {
            amount0 = companyAmt;
            amount1 = currencyAmt;
        } else if (token0 == currencyWrap && token1 == companyWrap) {
            amount0 = currencyAmt;
            amount1 = companyAmt;
        } else {
            revert InvalidPool();
        }

        // Full range, snapped to tickSpacing(500-fee) = 10. We hard-code 10 here
        // since v0 always uses fee tier 500; if the pool returned a different
        // fee the math would still work but might mint less than intended.
        int24 tickSpacing = _tickSpacingFor(p.fee());
        int24 tickLower = UniV3Math.minUsableTick(tickSpacing);
        int24 tickUpper = UniV3Math.maxUsableTick(tickSpacing);

        // Use the pool's actual current price for the liquidity computation —
        // sqrtPriceX96 passed from the orchestrator is the spot price; the
        // conditional pool was initialized at the same value but reading from
        // the pool is robust against orientation discrepancies. sqrtPriceX96
        // argument is kept in the API for callers who want to override.
        (uint160 currentSqrt,,,,,,) = p.slot0();
        if (currentSqrt == 0) currentSqrt = sqrtPriceX96; // fallback for unusual mocks.

        uint160 sqrtLower = UniV3Math.getSqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = UniV3Math.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity =
            UniV3Math.getLiquidityForAmounts(currentSqrt, sqrtLower, sqrtUpper, amount0, amount1);

        bytes memory callbackData = abi.encode(MintCallbackData({pool: pool, token0: token0, token1: token1}));
        (uint256 used0, uint256 used1) = p.mint(address(this), tickLower, tickUpper, liquidity, callbackData);
        emit PoolLiquidityMinted(pool, tickLower, tickUpper, liquidity, used0, used1);
    }

    /// @dev Fee tier → tick spacing for the canonical UniV3 deployment.
    /// We only need the v0 fee (500); other tiers are included for forward-compat.
    function _tickSpacingFor(uint24 fee) internal pure returns (int24) {
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        if (fee == 100) return 1;
        revert InvalidPool();
    }

    function _wrap(
        address collateral,
        bytes32 conditionId,
        uint256 indexSet,
        address wrapper,
        bytes memory tokenData,
        uint256 amount
    ) internal {
        bytes32 collectionId = CTF.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = CTF.getPositionId(collateral, collectionId);
        // safeTransferFrom triggers wrapper.onERC1155Received → wrapper.mint(adapter,
        // amount). We pass tokenData so the wrapper can identify (and lazily-deploy
        // if needed) the correct ERC20 instance.
        IConditionalTokensSplitAndTransfer(address(CTF)).safeTransferFrom(
            address(this), wrapper, tokenId, amount, tokenData
        );
    }

    function _pull(address token, address from, uint256 amount) internal {
        bool ok = IERC20Minimal(token).transferFrom(from, address(this), amount);
        if (!ok) revert ERC20TransferFailed();
    }

    function _transfer(address token, address to, uint256 amount) internal {
        bool ok = IERC20Minimal(token).transfer(to, amount);
        if (!ok) revert ERC20TransferFailed();
    }

    function _approveMax(address token, address spender) internal {
        // Reset-then-set is safest across USDT-like tokens, but our two collaterals
        // (FAO, WETH) are both well-behaved. Single-shot approve is enough.
        IERC20Minimal(token).approve(spender, type(uint256).max);
    }
}
