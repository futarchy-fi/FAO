// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyLiquidityAdapter} from "./interfaces/IFutarchyLiquidityAdapter.sol";
import {IFutarchyOfficialProposalSource} from "./interfaces/IFutarchyOfficialProposalSource.sol";
import {IFutarchyConditionalRouter} from "./interfaces/IFutarchyConditionalRouter.sol";
import {IAlgebraPoolLike} from "./interfaces/IAlgebraPoolLike.sol";

interface IWrappedNative is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

interface IFutarchyProposalConditionLike {
    function conditionId() external view returns (bytes32);
}

/// @title FutarchyLiquidityManager
/// @notice Immutable, permissionless state machine that keeps most liquidity in spot and
///         migrates 80% of LP units to conditional markets while the official proposal is live.
contract FutarchyLiquidityManager is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIGRATION_BPS = 8000;
    uint256 public constant EMERGENCY_EXIT_DELAY = 2 days;
    uint24 public constant MAX_EXIT_TICK_DELTA = 200; // ~2% price band (1.0001^200 ~= 1.0202)

    IERC20 public immutable FAO_TOKEN;
    IWrappedNative public immutable WRAPPED_NATIVE;
    address public immutable SALE;
    address public immutable OFFICIAL_PROPOSER;
    IFutarchyOfficialProposalSource public immutable PROPOSAL_SOURCE;
    IFutarchyLiquidityAdapter public immutable SPOT_ADAPTER;
    IFutarchyLiquidityAdapter public immutable CONDITIONAL_ADAPTER;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;

    address public immutable TOKEN0;
    address public immutable TOKEN1;
    bool public immutable FAO_IS_TOKEN0;

    bool public initializedFromSale;
    bool public inConditionalMode;
    bool public emergencyExitExecuted;
    uint256 public activeProposalId;
    uint256 public emergencyExitArmedAt;
    uint128 public spotLiquidity;
    uint128 public conditionalLiquidity;
    uint128 public conditionalYesLiquidity;
    uint128 public conditionalNoLiquidity;
    address public activeProposal;
    address public activeYesCompanyToken;
    address public activeNoCompanyToken;
    address public activeYesCurrencyToken;
    address public activeNoCurrencyToken;

    enum SyncAction {
        None,
        MigratedToConditional,
        MigratedBackToSpot
    }

    struct ProposalData {
        uint256 proposalId;
        address proposal;
        address creator;
        bool exists;
        bool settled;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
    }

    struct SyncParams {
        bytes spotCompoundData;
        bytes conditionalCompoundData;
        bytes spotToConditionalRemoveData;
        bytes spotToConditionalAddData;
        bytes conditionalToSpotRemoveData;
        bytes conditionalToSpotAddData;
    }

    struct RedeemPlan {
        uint128 spotToRemove;
        uint128 conditionalToRemove;
        uint128 yesToRemove;
        uint128 noToRemove;
    }

    error OnlySale();
    error AlreadyInitialized();
    error ZeroAddress();
    error InvalidProposalConfig();
    error ActiveProposalRequired();
    error EmergencyModeActive();
    error EmergencyExitAlreadyArmed();
    error EmergencyExitNotArmed();
    error EmergencyExitDelayActive();
    error EmergencyExitAlreadyExecuted();
    error AdapterOverusedInput();
    error ZeroLiquidityMinted();
    error ZeroSharesMinted();
    error ZeroRecipient();
    error ZeroRedeemLiquidity();

    event InitializedFromSale(uint256 faoAmount, uint256 nativeAmount, uint128 spotLiquidityMinted);
    event SpotDeposited(
        address indexed sender,
        uint256 faoAmount,
        uint256 nativeAmount,
        uint128 liquidityMinted,
        uint256 sharesMinted
    );
    event SharesRedeemed(
        address indexed owner,
        address indexed recipient,
        uint256 sharesBurned,
        uint128 spotLiquidityRemoved,
        uint128 conditionalLiquidityRemoved,
        uint256 faoOut,
        uint256 collateralOut
    );
    event LiquidityMigratedToConditional(
        uint256 indexed proposalId, uint128 spotRemoved, uint128 conditionalAdded
    );
    event LiquidityMigratedBackToSpot(
        uint256 indexed proposalId, uint128 conditionalRemoved, uint128 spotAdded
    );
    event Compounded(bool conditionalMode, uint128 liquidityAdded);
    event EmergencyExitArmed(uint256 armedAt, uint256 executableAt);
    event EmergencyExitDisarmed();
    event EmergencyExitExecuted(
        uint128 spotRemoved,
        uint128 conditionalRemoved,
        uint256 faoSentToSale,
        uint256 collateralSentToSale,
        uint256 nativeSentToSale
    );
    event IdleSweptToSale(
        uint256 faoSentToSale, uint256 collateralSentToSale, uint256 nativeSentToSale
    );

    constructor(
        address sale,
        IERC20 faoToken,
        IWrappedNative wrappedNative,
        address officialProposer,
        IFutarchyOfficialProposalSource proposalSource,
        IFutarchyLiquidityAdapter spotAdapter,
        IFutarchyLiquidityAdapter conditionalAdapter,
        IFutarchyConditionalRouter conditionalRouter,
        address initialOwner
    ) ERC20("Futarchy LP", "fLP") {
        if (
            sale == address(0) || address(faoToken) == address(0)
                || address(wrappedNative) == address(0) || officialProposer == address(0)
                || address(proposalSource) == address(0) || address(spotAdapter) == address(0)
                || address(conditionalAdapter) == address(0)
                || address(conditionalRouter) == address(0) || initialOwner == address(0)
        ) {
            revert ZeroAddress();
        }

        SALE = sale;
        FAO_TOKEN = faoToken;
        WRAPPED_NATIVE = wrappedNative;
        OFFICIAL_PROPOSER = officialProposer;
        PROPOSAL_SOURCE = proposalSource;
        SPOT_ADAPTER = spotAdapter;
        CONDITIONAL_ADAPTER = conditionalAdapter;
        CONDITIONAL_ROUTER = conditionalRouter;

        bool faoFirst = address(faoToken) < address(wrappedNative);
        TOKEN0 = faoFirst ? address(faoToken) : address(wrappedNative);
        TOKEN1 = faoFirst ? address(wrappedNative) : address(faoToken);
        FAO_IS_TOKEN0 = faoFirst;

        _transferOwnership(initialOwner);
    }

    receive() external payable {}

    /// @dev OpenZeppelin v4 SafeERC20 does not include `forceApprove`.
    ///      This helper provides the same semantics: set allowance to 0 first when needed.
    function _forceApprove(IERC20 token, address spender, uint256 value) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current != 0) {
            token.safeApprove(spender, 0);
        }
        token.safeApprove(spender, value);
    }

    function initializeFromSale(uint256 faoAmount, bytes calldata spotAddData)
        external
        payable
        nonReentrant
        returns (uint128 liquidityMinted)
    {
        _assertOnlySale();
        _assertNotEmergencyMode();
        if (initializedFromSale) revert AlreadyInitialized();
        initializedFromSale = true;

        if (msg.value > 0) {
            WRAPPED_NATIVE.deposit{value: msg.value}();
        }

        uint256 faoUnused;
        uint256 collateralUnused;
        (liquidityMinted, faoUnused, collateralUnused) =
            _addToSpot(faoAmount, msg.value, spotAddData);
        _payout(SALE, faoUnused, collateralUnused, true);
        uint256 sharesMinted = _mintShares(SALE, liquidityMinted);
        if (sharesMinted == 0) revert ZeroSharesMinted();
        emit InitializedFromSale(faoAmount, msg.value, liquidityMinted);
    }

    /// @notice Lets anyone add FAO + native assets into the manager and route to spot liquidity.
    function depositToSpot(uint256 faoAmount, bytes calldata spotAddData)
        external
        payable
        nonReentrant
        returns (uint128 liquidityMinted, uint256 sharesMinted)
    {
        _assertNotEmergencyMode();
        if (faoAmount > 0) {
            FAO_TOKEN.safeTransferFrom(msg.sender, address(this), faoAmount);
        }
        if (msg.value > 0) {
            WRAPPED_NATIVE.deposit{value: msg.value}();
        }

        uint256 faoUnused;
        uint256 collateralUnused;
        (liquidityMinted, faoUnused, collateralUnused) =
            _addToSpot(faoAmount, msg.value, spotAddData);
        _payout(msg.sender, faoUnused, collateralUnused, true);
        sharesMinted = _mintShares(msg.sender, liquidityMinted);
        if (sharesMinted == 0) revert ZeroSharesMinted();
        emit SpotDeposited(msg.sender, faoAmount, msg.value, liquidityMinted, sharesMinted);
    }

    /// @notice Burns share tokens and redeems underlying assets from all active pools pro-rata.
    function redeem(
        uint256 shares,
        address recipient,
        bool unwrapNative,
        bytes calldata spotRemoveData,
        bytes calldata conditionalRemoveData
    ) external nonReentrant returns (uint256 faoOut, uint256 collateralOut) {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 supply = totalSupply();
        uint256 totalLiquidity = totalManagedLiquidity();
        require(shares > 0 && shares <= balanceOf(msg.sender), "invalid shares");
        RedeemPlan memory plan = _buildRedeemPlan(shares, supply, totalLiquidity);

        _burn(msg.sender, shares);

        if (plan.spotToRemove > 0) {
            (uint256 faoFromSpot, uint256 collateralFromSpot) =
                _removeFromSpot(plan.spotToRemove, spotRemoveData);
            faoOut += faoFromSpot;
            collateralOut += collateralFromSpot;
        }
        if (plan.conditionalToRemove > 0 && (plan.yesToRemove > 0 || plan.noToRemove > 0)) {
            (uint256 faoFromConditional, uint256 collateralFromConditional) =
                _redeemConditional(plan, recipient, conditionalRemoveData);
            faoOut += faoFromConditional;
            collateralOut += collateralFromConditional;
        }

        _payout(recipient, faoOut, collateralOut, unwrapNative);
        emit SharesRedeemed(
            msg.sender,
            recipient,
            shares,
            plan.spotToRemove,
            plan.conditionalToRemove,
            faoOut,
            collateralOut
        );
    }

    /// @notice Permissionless, idempotent transition function.
    /// @dev While in a given mode, sync also compounds liquidity on that active venue.
    function sync(SyncParams calldata params) external nonReentrant returns (SyncAction action) {
        _assertNotEmergencyMode();
        _compoundActive(params);

        ProposalData memory proposal = _readProposal();

        bool proposalByOfficialCreator = proposal.exists && proposal.creator == OFFICIAL_PROPOSER;
        if (proposalByOfficialCreator) {
            _validateProposal(
                proposal.proposal,
                proposal.proposalToken,
                proposal.collateralToken,
                proposal.yesCompanyToken,
                proposal.noCompanyToken,
                proposal.yesCurrencyToken,
                proposal.noCurrencyToken,
                proposal.yesPool,
                proposal.noPool
            );
        }

        if (!inConditionalMode) {
            return _syncFromSpot(params, proposal, proposalByOfficialCreator);
        }

        return _syncFromConditional(params, proposal, proposalByOfficialCreator);
    }

    function previewLiquidityMigration() external view returns (uint128 liquidityToMove) {
        liquidityToMove = uint128((uint256(spotLiquidity) * MIGRATION_BPS) / BPS_DENOMINATOR);
    }

    function totalManagedLiquidity() public view returns (uint256) {
        return uint256(spotLiquidity) + uint256(conditionalLiquidity);
    }

    function emergencyExitReady() public view returns (bool) {
        return
            emergencyExitArmedAt != 0
                && block.timestamp >= emergencyExitArmedAt + EMERGENCY_EXIT_DELAY;
    }

    function armEmergencyExit() external {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt != 0) revert EmergencyExitAlreadyArmed();
        emergencyExitArmedAt = block.timestamp;
        emit EmergencyExitArmed(block.timestamp, block.timestamp + EMERGENCY_EXIT_DELAY);
    }

    function disarmEmergencyExit() external {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt == 0) revert EmergencyExitNotArmed();
        emergencyExitArmedAt = 0;
        emit EmergencyExitDisarmed();
    }

    function sweepIdleToSale(bool unwrapNative)
        external
        nonReentrant
        returns (uint256 faoSentToSale, uint256 collateralSentToSale, uint256 nativeSentToSale)
    {
        _checkOwner();
        (faoSentToSale, collateralSentToSale, nativeSentToSale) = _sweepIdleToSale(unwrapNative);
        emit IdleSweptToSale(faoSentToSale, collateralSentToSale, nativeSentToSale);
    }

    function emergencyExitAllToSale(
        bool unwrapNative,
        bytes calldata spotRemoveData,
        bytes calldata conditionalRemoveData
    )
        external
        nonReentrant
        returns (uint256 faoSentToSale, uint256 collateralSentToSale, uint256 nativeSentToSale)
    {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt == 0) revert EmergencyExitNotArmed();
        if (!emergencyExitReady()) revert EmergencyExitDelayActive();

        uint128 spotRemoved = spotLiquidity;
        uint128 conditionalRemoved = conditionalLiquidity;

        if (spotRemoved > 0) {
            _removeFromSpot(spotRemoved, spotRemoveData);
        }
        if (conditionalRemoved > 0) {
            (bytes memory yesRemoveData, bytes memory noRemoveData) =
                _decodeDualData(conditionalRemoveData);
            if (conditionalYesLiquidity > 0) {
                _removeFromConditionalPair(
                    activeYesCompanyToken,
                    activeYesCurrencyToken,
                    conditionalYesLiquidity,
                    yesRemoveData
                );
                conditionalYesLiquidity = 0;
            }
            if (conditionalNoLiquidity > 0) {
                _removeFromConditionalPair(
                    activeNoCompanyToken,
                    activeNoCurrencyToken,
                    conditionalNoLiquidity,
                    noRemoveData
                );
                conditionalNoLiquidity = 0;
            }
            _recomputeConditionalLiquidity();
            _recoverCollateralFromOutcomeTokens(false);
            _sweepActiveOutcomeTokensTo(SALE);
        }

        (faoSentToSale, collateralSentToSale, nativeSentToSale) = _sweepIdleToSale(unwrapNative);

        _clearConditionalModeState();
        emergencyExitExecuted = true;

        emit EmergencyExitExecuted(
            spotRemoved, conditionalRemoved, faoSentToSale, collateralSentToSale, nativeSentToSale
        );
    }

    function _validateProposal(
        address proposal,
        address proposalToken,
        address collateralToken,
        address yesCompanyToken,
        address noCompanyToken,
        address yesCurrencyToken,
        address noCurrencyToken,
        address yesPool,
        address noPool
    ) internal view {
        if (
            proposal == address(0) || proposalToken != address(FAO_TOKEN)
                || collateralToken != address(WRAPPED_NATIVE) || yesCompanyToken == address(0)
                || noCompanyToken == address(0) || yesCurrencyToken == address(0)
                || noCurrencyToken == address(0) || yesPool == address(0) || noPool == address(0)
        ) {
            revert InvalidProposalConfig();
        }
    }

    function _readProposal() internal view returns (ProposalData memory proposal) {
        IFutarchyOfficialProposalSource.OfficialProposalData memory data =
            PROPOSAL_SOURCE.officialProposalExtended();

        proposal.proposalId = data.proposalId;
        proposal.proposal = data.proposal;
        proposal.creator = data.creator;
        proposal.exists = data.exists;
        proposal.settled = data.settled;
        proposal.proposalToken = data.proposalToken;
        proposal.collateralToken = data.collateralToken;
        proposal.yesCompanyToken = data.yesCompanyToken;
        proposal.noCompanyToken = data.noCompanyToken;
        proposal.yesCurrencyToken = data.yesCurrencyToken;
        proposal.noCurrencyToken = data.noCurrencyToken;
        proposal.yesPool = data.yesPool;
        proposal.noPool = data.noPool;
    }

    function _syncFromSpot(
        SyncParams calldata params,
        ProposalData memory proposal,
        bool proposalByOfficialCreator
    ) internal returns (SyncAction) {
        if (!proposalByOfficialCreator || proposal.settled) {
            return SyncAction.None;
        }

        uint128 liquidityToMove =
            uint128((uint256(spotLiquidity) * MIGRATION_BPS) / BPS_DENOMINATOR);
        if (liquidityToMove > 0) {
            uint128 conditionalBefore = conditionalLiquidity;
            (uint256 faoOut, uint256 collateralOut) =
                _removeFromSpot(liquidityToMove, params.spotToConditionalRemoveData);

            _splitCollateral(proposal.proposal, address(FAO_TOKEN), faoOut);
            _splitCollateral(proposal.proposal, address(WRAPPED_NATIVE), collateralOut);

            (bytes memory yesAddData, bytes memory noAddData) =
                _decodeDualData(params.spotToConditionalAddData);
            uint128 yesAdded = _addToConditionalPair(
                proposal.yesCompanyToken,
                proposal.yesCurrencyToken,
                IERC20(proposal.yesCompanyToken).balanceOf(address(this)),
                IERC20(proposal.yesCurrencyToken).balanceOf(address(this)),
                yesAddData
            );
            uint128 noAdded = _addToConditionalPair(
                proposal.noCompanyToken,
                proposal.noCurrencyToken,
                IERC20(proposal.noCompanyToken).balanceOf(address(this)),
                IERC20(proposal.noCurrencyToken).balanceOf(address(this)),
                noAddData
            );
            conditionalYesLiquidity += yesAdded;
            conditionalNoLiquidity += noAdded;
            _recomputeConditionalLiquidity();
            uint128 condAdded = conditionalLiquidity - conditionalBefore;
            emit LiquidityMigratedToConditional(proposal.proposalId, liquidityToMove, condAdded);
        } else {
            emit LiquidityMigratedToConditional(proposal.proposalId, 0, 0);
        }

        inConditionalMode = true;
        activeProposal = proposal.proposal;
        activeProposalId = proposal.proposalId;
        activeYesCompanyToken = proposal.yesCompanyToken;
        activeNoCompanyToken = proposal.noCompanyToken;
        activeYesCurrencyToken = proposal.yesCurrencyToken;
        activeNoCurrencyToken = proposal.noCurrencyToken;
        return SyncAction.MigratedToConditional;
    }

    function _syncFromConditional(
        SyncParams calldata params,
        ProposalData memory proposal,
        bool proposalByOfficialCreator
    ) internal returns (SyncAction) {
        // If conditional mode is active, we only transition back after settlement of the active
        // proposal.
        if (!proposalByOfficialCreator || proposal.proposalId != activeProposalId) {
            revert ActiveProposalRequired();
        }
        if (!proposal.settled) return SyncAction.None;

        // After settlement, wait until spot price has converged to the winning conditional price
        // before migrating back. This avoids adding back to spot at an obviously stale price.
        if (!_isExitPriceAligned(proposal)) return SyncAction.None;

        uint128 condLiq = conditionalLiquidity;
        uint128 spotAddedBack;
        if (condLiq > 0) {
            (bytes memory yesRemoveData, bytes memory noRemoveData) =
                _decodeDualData(params.conditionalToSpotRemoveData);

            if (conditionalYesLiquidity > 0) {
                _removeFromConditionalPair(
                    activeYesCompanyToken,
                    activeYesCurrencyToken,
                    conditionalYesLiquidity,
                    yesRemoveData
                );
                conditionalYesLiquidity = 0;
            }
            if (conditionalNoLiquidity > 0) {
                _removeFromConditionalPair(
                    activeNoCompanyToken,
                    activeNoCurrencyToken,
                    conditionalNoLiquidity,
                    noRemoveData
                );
                conditionalNoLiquidity = 0;
            }
            _recomputeConditionalLiquidity();

            (uint256 faoOut, uint256 collateralOut) = _recoverCollateralFromOutcomeTokens(true);
            if (faoOut > 0 || collateralOut > 0) {
                (spotAddedBack,,) =
                    _addToSpot(faoOut, collateralOut, params.conditionalToSpotAddData);
            }
        }

        emit LiquidityMigratedBackToSpot(activeProposalId, condLiq, spotAddedBack);
        _clearConditionalModeState();
        return SyncAction.MigratedBackToSpot;
    }

    function _isExitPriceAligned(ProposalData memory proposal) internal view returns (bool) {
        // Resolve winning outcome from CTF.
        bytes32 conditionId = IFutarchyProposalConditionLike(proposal.proposal).conditionId();
        bool[] memory winning = CONDITIONAL_ROUTER.getWinningOutcomes(conditionId);
        if (winning.length < 2) return false;
        bool yesWins = winning[0];
        bool noWins = winning[1];
        if (yesWins == noWins) return false; // either unresolved (both false) or ambiguous (both
        // true)

        address spotPool = PROPOSAL_SOURCE.ALGEBRA_FACTORY().poolByPair(TOKEN0, TOKEN1);
        if (spotPool == address(0)) return false;
        int24 spotTick = _economicTick(spotPool, address(FAO_TOKEN), address(WRAPPED_NATIVE));

        address winPool = yesWins ? proposal.yesPool : proposal.noPool;
        if (winPool == address(0)) return false;
        address winBase = yesWins ? proposal.yesCompanyToken : proposal.noCompanyToken;
        address winQuote = yesWins ? proposal.yesCurrencyToken : proposal.noCurrencyToken;
        int24 winTick = _economicTick(winPool, winBase, winQuote);

        uint256 delta = _absDiff(int256(spotTick), int256(winTick));
        return delta <= MAX_EXIT_TICK_DELTA;
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
        revert InvalidProposalConfig();
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        int256 d = a - b;
        return uint256(d < 0 ? -d : d);
    }

    function _compoundActive(SyncParams calldata params) internal {
        uint128 added;
        if (inConditionalMode) {
            uint128 conditionalBefore = conditionalLiquidity;
            (bytes memory yesCompoundData, bytes memory noCompoundData) =
                _decodeDualData(params.conditionalCompoundData);

            if (conditionalYesLiquidity > 0) {
                added = _compoundConditionalPair(
                    activeYesCompanyToken, activeYesCurrencyToken, yesCompoundData
                );
                if (added > 0) {
                    conditionalYesLiquidity += added;
                }
            }

            if (conditionalNoLiquidity > 0) {
                added = _compoundConditionalPair(
                    activeNoCompanyToken, activeNoCurrencyToken, noCompoundData
                );
                if (added > 0) {
                    conditionalNoLiquidity += added;
                }
            }

            _recomputeConditionalLiquidity();
            uint128 addedTotal = conditionalLiquidity - conditionalBefore;
            if (addedTotal > 0) {
                emit Compounded(true, addedTotal);
            }
        } else {
            added = SPOT_ADAPTER.compoundPosition(TOKEN0, TOKEN1, params.spotCompoundData);
            if (added > 0) {
                spotLiquidity += added;
                emit Compounded(false, added);
            }
        }
    }

    function _addToSpot(uint256 faoAmount, uint256 collateralAmount, bytes memory data)
        internal
        returns (uint128 liquidityMinted, uint256 faoUnused, uint256 collateralUnused)
    {
        (uint256 amount0Desired, uint256 amount1Desired) =
            _toTokenOrder(faoAmount, collateralAmount);
        _approveForAdapter(SPOT_ADAPTER, amount0Desired, amount1Desired);

        uint256 amount0Used;
        uint256 amount1Used;
        (liquidityMinted, amount0Used, amount1Used) = SPOT_ADAPTER.addFullRangeLiquidity(
            TOKEN0, TOKEN1, amount0Desired, amount1Desired, data
        );
        if (liquidityMinted == 0) revert ZeroLiquidityMinted();
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert AdapterOverusedInput();
        }

        (uint256 faoUsed, uint256 collateralUsed) = _fromTokenOrder(amount0Used, amount1Used);
        faoUnused = faoAmount - faoUsed;
        collateralUnused = collateralAmount - collateralUsed;
        if (liquidityMinted > 0) {
            spotLiquidity += liquidityMinted;
        }
    }

    function _addToConditionalPair(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        bytes memory data
    ) internal returns (uint128 liquidityMinted) {
        if (amountADesired == 0 || amountBDesired == 0) {
            revert ZeroLiquidityMinted();
        }
        (address token0, address token1, uint256 amount0Desired, uint256 amount1Desired) =
            _sortPairWithAmounts(tokenA, tokenB, amountADesired, amountBDesired);
        _approvePairForAdapter(CONDITIONAL_ADAPTER, token0, token1, amount0Desired, amount1Desired);

        uint256 amount0Used;
        uint256 amount1Used;
        (liquidityMinted, amount0Used, amount1Used) = CONDITIONAL_ADAPTER.addFullRangeLiquidity(
            token0, token1, amount0Desired, amount1Desired, data
        );
        if (liquidityMinted == 0) revert ZeroLiquidityMinted();
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert AdapterOverusedInput();
        }
    }

    function _removeFromSpot(uint128 liquidity, bytes memory data)
        internal
        returns (uint256 faoOut, uint256 collateralOut)
    {
        (uint256 amount0Out, uint256 amount1Out) =
            SPOT_ADAPTER.removeLiquidity(TOKEN0, TOKEN1, liquidity, data);
        spotLiquidity -= liquidity;
        (faoOut, collateralOut) = _fromTokenOrder(amount0Out, amount1Out);
    }

    function _removeFromConditionalPair(
        address tokenA,
        address tokenB,
        uint128 liquidity,
        bytes memory data
    ) internal {
        if (liquidity == 0) return;
        (address token0, address token1) = _sortPair(tokenA, tokenB);
        CONDITIONAL_ADAPTER.removeLiquidity(token0, token1, liquidity, data);
    }

    function _buildRedeemPlan(uint256 shares, uint256 supply, uint256 totalLiquidity)
        internal
        view
        returns (RedeemPlan memory plan)
    {
        if (shares == supply) {
            plan.spotToRemove = spotLiquidity;
            plan.yesToRemove = conditionalYesLiquidity;
            plan.noToRemove = conditionalNoLiquidity;
            plan.conditionalToRemove = plan.yesToRemove + plan.noToRemove;
            return plan;
        }

        uint256 liquidityToRemove = (totalLiquidity * shares) / supply;
        if (liquidityToRemove == 0) revert ZeroRedeemLiquidity();

        plan.spotToRemove = uint128((uint256(spotLiquidity) * liquidityToRemove) / totalLiquidity);
        plan.conditionalToRemove = uint128(liquidityToRemove - plan.spotToRemove);

        if (plan.conditionalToRemove == 0 || conditionalLiquidity == 0) return plan;

        plan.yesToRemove = uint128(
            (uint256(conditionalYesLiquidity) * plan.conditionalToRemove) / conditionalLiquidity
        );
        plan.noToRemove = uint128(
            (uint256(conditionalNoLiquidity) * plan.conditionalToRemove) / conditionalLiquidity
        );
    }

    function _redeemConditional(
        RedeemPlan memory plan,
        address recipient,
        bytes memory conditionalRemoveData
    ) internal returns (uint256 faoOut, uint256 collateralOut) {
        (bytes memory yesRemoveData, bytes memory noRemoveData) =
            _decodeDualData(conditionalRemoveData);

        uint256 yesCompanyBefore = IERC20(activeYesCompanyToken).balanceOf(address(this));
        uint256 noCompanyBefore = IERC20(activeNoCompanyToken).balanceOf(address(this));
        uint256 yesCurrencyBefore = IERC20(activeYesCurrencyToken).balanceOf(address(this));
        uint256 noCurrencyBefore = IERC20(activeNoCurrencyToken).balanceOf(address(this));

        if (plan.yesToRemove > 0) {
            _removeFromConditionalPair(
                activeYesCompanyToken, activeYesCurrencyToken, plan.yesToRemove, yesRemoveData
            );
            conditionalYesLiquidity -= plan.yesToRemove;
        }
        if (plan.noToRemove > 0) {
            _removeFromConditionalPair(
                activeNoCompanyToken, activeNoCurrencyToken, plan.noToRemove, noRemoveData
            );
            conditionalNoLiquidity -= plan.noToRemove;
        }
        _recomputeConditionalLiquidity();

        (faoOut, collateralOut) = _recoverCollateralFromOutcomeTokens(false);
        _transferOutcomeDelta(
            recipient, yesCompanyBefore, noCompanyBefore, yesCurrencyBefore, noCurrencyBefore
        );
    }

    function _compoundConditionalPair(address tokenA, address tokenB, bytes memory data)
        internal
        returns (uint128 liquidityAdded)
    {
        (address token0, address token1) = _sortPair(tokenA, tokenB);
        liquidityAdded = CONDITIONAL_ADAPTER.compoundPosition(token0, token1, data);
    }

    function _splitCollateral(address proposal, address collateralToken, uint256 amount) internal {
        if (amount == 0) return;
        _forceApprove(IERC20(collateralToken), address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.splitPosition(proposal, collateralToken, amount);
    }

    function _recoverCollateralFromOutcomeTokens(bool allowRedeem)
        internal
        returns (uint256 faoOut, uint256 collateralOut)
    {
        if (activeProposal == address(0)) return (0, 0);

        uint256 faoBefore = FAO_TOKEN.balanceOf(address(this));
        uint256 collateralBefore = WRAPPED_NATIVE.balanceOf(address(this));

        _mergeOutcomePair(
            activeProposal, address(FAO_TOKEN), activeYesCompanyToken, activeNoCompanyToken
        );
        _mergeOutcomePair(
            activeProposal, address(WRAPPED_NATIVE), activeYesCurrencyToken, activeNoCurrencyToken
        );

        if (allowRedeem) {
            _tryRedeemOutcomeRemainder(
                activeProposal, address(FAO_TOKEN), activeYesCompanyToken, activeNoCompanyToken
            );
            _tryRedeemOutcomeRemainder(
                activeProposal,
                address(WRAPPED_NATIVE),
                activeYesCurrencyToken,
                activeNoCurrencyToken
            );
        }

        faoOut = FAO_TOKEN.balanceOf(address(this)) - faoBefore;
        collateralOut = WRAPPED_NATIVE.balanceOf(address(this)) - collateralBefore;
    }

    function _mergeOutcomePair(
        address proposal,
        address collateralToken,
        address yesToken,
        address noToken
    ) internal {
        if (yesToken == address(0) || noToken == address(0)) return;
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        uint256 noBal = IERC20(noToken).balanceOf(address(this));
        uint256 mergeAmount = _min(yesBal, noBal);
        if (mergeAmount == 0) return;

        _forceApprove(IERC20(yesToken), address(CONDITIONAL_ROUTER), mergeAmount);
        _forceApprove(IERC20(noToken), address(CONDITIONAL_ROUTER), mergeAmount);
        CONDITIONAL_ROUTER.mergePositions(proposal, collateralToken, mergeAmount);
    }

    function _tryRedeemOutcomeRemainder(
        address proposal,
        address collateralToken,
        address yesToken,
        address noToken
    ) internal {
        if (yesToken == address(0) || noToken == address(0)) return;
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        uint256 noBal = IERC20(noToken).balanceOf(address(this));
        uint256 redeemAmount = _max(yesBal, noBal);
        if (redeemAmount == 0) return;

        _forceApprove(IERC20(yesToken), address(CONDITIONAL_ROUTER), redeemAmount);
        _forceApprove(IERC20(noToken), address(CONDITIONAL_ROUTER), redeemAmount);

        try CONDITIONAL_ROUTER.redeemPositions(proposal, collateralToken, redeemAmount) {} catch {}
    }

    function _transferOutcomeDelta(
        address recipient,
        uint256 yesCompanyBefore,
        uint256 noCompanyBefore,
        uint256 yesCurrencyBefore,
        uint256 noCurrencyBefore
    ) internal {
        if (activeYesCompanyToken != address(0)) {
            uint256 yesCompanyAfter = IERC20(activeYesCompanyToken).balanceOf(address(this));
            if (yesCompanyAfter > yesCompanyBefore) {
                IERC20(activeYesCompanyToken)
                    .safeTransfer(recipient, yesCompanyAfter - yesCompanyBefore);
            }
        }
        if (activeNoCompanyToken != address(0)) {
            uint256 noCompanyAfter = IERC20(activeNoCompanyToken).balanceOf(address(this));
            if (noCompanyAfter > noCompanyBefore) {
                IERC20(activeNoCompanyToken)
                    .safeTransfer(recipient, noCompanyAfter - noCompanyBefore);
            }
        }
        if (activeYesCurrencyToken != address(0)) {
            uint256 yesCurrencyAfter = IERC20(activeYesCurrencyToken).balanceOf(address(this));
            if (yesCurrencyAfter > yesCurrencyBefore) {
                IERC20(activeYesCurrencyToken)
                    .safeTransfer(recipient, yesCurrencyAfter - yesCurrencyBefore);
            }
        }
        if (activeNoCurrencyToken != address(0)) {
            uint256 noCurrencyAfter = IERC20(activeNoCurrencyToken).balanceOf(address(this));
            if (noCurrencyAfter > noCurrencyBefore) {
                IERC20(activeNoCurrencyToken)
                    .safeTransfer(recipient, noCurrencyAfter - noCurrencyBefore);
            }
        }
    }

    function _sweepActiveOutcomeTokensTo(address recipient) internal {
        if (recipient == address(0)) return;
        if (activeYesCompanyToken != address(0)) {
            uint256 bal = IERC20(activeYesCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeYesCompanyToken).safeTransfer(recipient, bal);
        }
        if (activeNoCompanyToken != address(0)) {
            uint256 bal = IERC20(activeNoCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeNoCompanyToken).safeTransfer(recipient, bal);
        }
        if (activeYesCurrencyToken != address(0)) {
            uint256 bal = IERC20(activeYesCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeYesCurrencyToken).safeTransfer(recipient, bal);
        }
        if (activeNoCurrencyToken != address(0)) {
            uint256 bal = IERC20(activeNoCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeNoCurrencyToken).safeTransfer(recipient, bal);
        }
    }

    function _recomputeConditionalLiquidity() internal {
        conditionalLiquidity =
            uint128((uint256(conditionalYesLiquidity) + uint256(conditionalNoLiquidity)) / 2);
    }

    function _clearConditionalModeState() internal {
        conditionalLiquidity = 0;
        conditionalYesLiquidity = 0;
        conditionalNoLiquidity = 0;
        inConditionalMode = false;
        activeProposalId = 0;
        activeProposal = address(0);
        activeYesCompanyToken = address(0);
        activeNoCompanyToken = address(0);
        activeYesCurrencyToken = address(0);
        activeNoCurrencyToken = address(0);
    }

    function _decodeDualData(bytes memory data)
        internal
        pure
        returns (bytes memory first, bytes memory second)
    {
        if (data.length == 0) return ("", "");
        (first, second) = abi.decode(data, (bytes, bytes));
    }

    function _sortPair(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _sortPairWithAmounts(address tokenA, address tokenB, uint256 amountA, uint256 amountB)
        internal
        pure
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
            amount0 = amountA;
            amount1 = amountB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
            amount0 = amountB;
            amount1 = amountA;
        }
    }

    function _approvePairForAdapter(
        IFutarchyLiquidityAdapter adapter,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (amount0 > 0) {
            _forceApprove(IERC20(token0), address(adapter), amount0);
        }
        if (amount1 > 0) {
            _forceApprove(IERC20(token1), address(adapter), amount1);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _toTokenOrder(uint256 faoAmount, uint256 collateralAmount)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (FAO_IS_TOKEN0) {
            amount0 = faoAmount;
            amount1 = collateralAmount;
        } else {
            amount0 = collateralAmount;
            amount1 = faoAmount;
        }
    }

    function _fromTokenOrder(uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256 faoAmount, uint256 collateralAmount)
    {
        if (FAO_IS_TOKEN0) {
            faoAmount = amount0;
            collateralAmount = amount1;
        } else {
            faoAmount = amount1;
            collateralAmount = amount0;
        }
    }

    function _approveForAdapter(IFutarchyLiquidityAdapter adapter, uint256 amount0, uint256 amount1)
        internal
    {
        if (amount0 > 0) {
            _forceApprove(IERC20(TOKEN0), address(adapter), amount0);
        }
        if (amount1 > 0) {
            _forceApprove(IERC20(TOKEN1), address(adapter), amount1);
        }
    }

    function _mintShares(address to, uint128 liquidityAdded)
        internal
        returns (uint256 sharesMinted)
    {
        uint256 supply = totalSupply();
        uint256 totalLiquidityBefore = totalManagedLiquidity() - liquidityAdded;
        if (supply == 0 || totalLiquidityBefore == 0) {
            sharesMinted = liquidityAdded;
        } else {
            sharesMinted = (uint256(liquidityAdded) * supply) / totalLiquidityBefore;
        }

        if (sharesMinted > 0) {
            _mint(to, sharesMinted);
        }
    }

    function _payout(address recipient, uint256 faoOut, uint256 collateralOut, bool unwrapNative)
        internal
    {
        if (faoOut > 0) {
            FAO_TOKEN.safeTransfer(recipient, faoOut);
        }
        if (collateralOut > 0) {
            if (unwrapNative) {
                WRAPPED_NATIVE.withdraw(collateralOut);
                payable(recipient).sendValue(collateralOut);
            } else {
                IERC20(address(WRAPPED_NATIVE)).safeTransfer(recipient, collateralOut);
            }
        }
    }

    function _sweepIdleToSale(bool unwrapNative)
        internal
        returns (uint256 faoSentToSale, uint256 collateralSentToSale, uint256 nativeSentToSale)
    {
        _sweepActiveOutcomeTokensTo(SALE);

        faoSentToSale = FAO_TOKEN.balanceOf(address(this));
        if (faoSentToSale > 0) {
            FAO_TOKEN.safeTransfer(SALE, faoSentToSale);
        }

        uint256 collateralBalance = WRAPPED_NATIVE.balanceOf(address(this));
        if (collateralBalance > 0) {
            if (unwrapNative) {
                WRAPPED_NATIVE.withdraw(collateralBalance);
            } else {
                IERC20(address(WRAPPED_NATIVE)).safeTransfer(SALE, collateralBalance);
                collateralSentToSale = collateralBalance;
            }
        }

        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            payable(SALE).sendValue(nativeBalance);
            nativeSentToSale = nativeBalance;
        }
    }

    function _assertOnlySale() internal view {
        if (msg.sender != SALE) revert OnlySale();
    }

    function _assertNotEmergencyMode() internal view {
        if (emergencyExitArmedAt != 0) revert EmergencyModeActive();
    }
}
