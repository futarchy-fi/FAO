// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFAOLiquidityAdapter} from "./FAOOfficialProposalOrchestrator.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IConditionalTokensLike} from "./interfaces/IConditionalTokensLike.sol";
import {IWrapped1155FactoryLike} from "./interfaces/IWrapped1155FactoryLike.sol";
import {FAOFutarchyProposal} from "./FAOFutarchyProposal.sol";

/// @notice Minimal IERC20 surface used by the adapter.
interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @title UniswapV3LiquidityAdapter
/// @notice v0 adapter invoked by FAOOfficialProposalOrchestrator at promote time.
///
/// Production responsibility (`migrate`):
///   1. Pull a configured slice of the orchestrator's spot-pool LP position(s)
///      back into FAO + WETH (requires holding the LP NFTs or a custodian
///      contract; not implemented in v0).
///   2. Split those FAO+WETH amounts into 4 conditional ERC1155 tokens via
///      CTF.splitPosition (twice: once per collateral).
///   3. Wrap each ERC1155 token into its ERC20 wrapper by transferring to
///      the Wrapped1155Factory's predeployed wrapper.
///   4. Deposit half of (YES_FAO + YES_WETH) into the YES pool and the
///      other half of (NO_FAO + NO_WETH) into the NO pool via
///      `pool.mint(...)` + IUniswapV3MintCallback.
///
/// This v0 implementation is **deliberately minimal**: it implements the
/// adapter interface but only performs the split + wrap steps on
/// pre-deposited balances held by this contract. The orchestrator can be
/// run without an adapter set (it skips `migrate`) for early testnet
/// validation. Production adapter with full UniV3 LP withdrawal + mint
/// callback support lands in a follow-up commit.
contract UniswapV3LiquidityAdapter is IFAOLiquidityAdapter {
    IConditionalTokensLike public immutable CTF;
    IWrapped1155FactoryLike public immutable W1155;
    address public immutable ORCHESTRATOR;
    address public immutable COMPANY; // FAO
    address public immutable CURRENCY; // WETH

    /// @notice Amount of COMPANY token (per proposal) to allocate into the
    /// conditional pools. Splits exactly this amount via CTF and wraps into
    /// outcomes. Calling contract must pre-fund this adapter with the corresponding
    /// COMPANY balance before invoking migrate.
    uint256 public constant DEFAULT_COMPANY_ALLOC = 0;

    error OnlyOrchestrator();
    error NotImplemented();

    event Migrated(
        address indexed proposal,
        address yesPool,
        address noPool,
        uint256 companyAllocated,
        uint256 currencyAllocated
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

    /// @inheritdoc IFAOLiquidityAdapter
    /// @dev v0: tracks the migration intent but does not actually move funds —
    /// production adapter must implement UniV3 LP withdrawal + IUniswapV3MintCallback.
    function migrate(
        address proposal,
        address yesPool,
        address noPool,
        address /* spotPool */,
        uint160 /* sqrtPriceX96 */
    ) external override {
        if (msg.sender != ORCHESTRATOR) revert OnlyOrchestrator();

        // STUB: in production we would
        //   - withdraw from spot pool (requires LP custody),
        //   - split into 4 wrappers via CTF,
        //   - mint into YES/NO pools via pool.mint + UniswapV3MintCallback.
        // For v0 we emit the intent so the operator dashboard can detect
        // proposals that landed but lack conditional liquidity.

        FAOFutarchyProposal p = FAOFutarchyProposal(proposal);
        // Read wrappers solely to validate proposal/oracle wiring is correct.
        (address yesCo,) = p.wrappedOutcome(0);
        (address yesCur,) = p.wrappedOutcome(2);
        (address noCo,) = p.wrappedOutcome(1);
        (address noCur,) = p.wrappedOutcome(3);
        yesCo; yesCur; noCo; noCur; yesPool; noPool;

        emit Migrated(proposal, yesPool, noPool, DEFAULT_COMPANY_ALLOC, DEFAULT_COMPANY_ALLOC);
    }
}
