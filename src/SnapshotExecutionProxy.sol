// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProposalStatus} from "src/types.sol";

interface IConditionalTokensReport {
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

interface ISpaceGetProposalStatus {
    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus);
}

interface IProposalQuestionId {
    function questionId() external view returns (bytes32);
}

/// @title SnapshotExecutionProxy
/// @notice CTF oracle that resolves market settlement (Step 2) based on SnapshotX proposal
/// execution state.
///
/// When a futarchy market is ready to settle, this proxy reads the SX Space's proposal status
/// and reports payouts to CTF:
///   - SX Executed    -> payouts [1, 0]  (YES wins — tokens redeemable for underlying)
///   - SX Rejected    -> payouts [0, 1]  (NO wins)
///   - SX Cancelled   -> payouts [0, 1]  (NO wins)
///   - Anything else  -> revert          (not final yet)
///
/// This is the market settlement oracle (Step 2 in the two-step resolution).
/// The futarchy signal (TWAP oracle decision, Step 1) is a separate CTF condition
/// read by the EvaluationPipeline.
///
/// Access control:
///   - Only the `binder` (factory or pipeline) can create bindings between futarchy proposals
///     and SX proposals. This prevents malicious mis-binding.
///   - Resolution (reportPayouts) is permissionless once the SX proposal is final.
///   - CTF enforces that only this contract can report payouts for conditions prepared with
///     its address as oracle.
contract SnapshotExecutionProxy {
    // ═══════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════

    error NotFinal();
    error NotBound(address proposal);
    error NotBinder();
    error AlreadyBound(address proposal);
    error InsufficientGas();

    // ═══════════════════════════════════════════════════════
    //  Types
    // ═══════════════════════════════════════════════════════

    struct SXBinding {
        address space;
        uint256 sxProposalId;
    }

    // ═══════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════

    /// @dev Minimum gas that must remain after the Space call's catch block.
    /// If gasleft() is below this after the catch fires, the revert was likely caused by
    /// the caller deliberately supplying insufficient gas (gas griefing attack), NOT by a
    /// genuinely broken execution strategy. In that case we revert instead of settling.
    ///
    /// EIP-150: the caller retains 1/64th of gas when the subcall OOGs. A genuine revert
    /// (e.g. `revert("broken")`) returns almost all remaining gas. So after a genuine
    /// revert, gasleft() >> POST_CALL_GAS_FLOOR; after an OOG it's ≈ 1/64th of the
    /// original gas, which for any reasonable tx will be much less.
    ///
    /// 100k is enough headroom to complete the settlement (reportPayouts + events ≈ 60k)
    /// and well above the ~1.5k-15k you'd have after an OOG griefing attempt.
    uint256 internal constant POST_CALL_GAS_FLOOR = 100_000;

    IConditionalTokensReport public immutable conditionalTokens;
    address public immutable binder;

    // ═══════════════════════════════════════════════════════
    //  State
    // ═══════════════════════════════════════════════════════

    mapping(address futarchyProposal => SXBinding) public bindings;

    // ═══════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════

    event ProposalBound(
        address indexed futarchyProposal, address indexed space, uint256 sxProposalId
    );
    event MarketSettled(address indexed futarchyProposal, bytes32 indexed questionId, bool yesWins);
    event SpaceCallFailed(
        address indexed futarchyProposal, address indexed space, uint256 sxProposalId
    );

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    /// @param _conditionalTokens The Gnosis CTF contract address.
    /// @param _binder The address authorized to bind futarchy proposals to SX proposals
    ///        (typically the EvaluationPipeline or factory).
    constructor(address _conditionalTokens, address _binder) {
        conditionalTokens = IConditionalTokensReport(_conditionalTokens);
        binder = _binder;
    }

    // ═══════════════════════════════════════════════════════
    //  Binding
    // ═══════════════════════════════════════════════════════

    /// @notice Bind a futarchy proposal to an SX Space + proposalId.
    /// @dev Only callable by the binder (factory or pipeline).
    ///      Once bound, a proposal cannot be re-bound (prevents manipulation).
    function bind(address futarchyProposal, address space, uint256 sxProposalId) external {
        if (msg.sender != binder) revert NotBinder();
        if (bindings[futarchyProposal].space != address(0)) {
            revert AlreadyBound(futarchyProposal);
        }

        bindings[futarchyProposal] = SXBinding(space, sxProposalId);
        emit ProposalBound(futarchyProposal, space, sxProposalId);
    }

    // ═══════════════════════════════════════════════════════
    //  Resolution
    // ═══════════════════════════════════════════════════════

    /// @notice Resolve the market settlement CTF condition for a futarchy proposal.
    /// @dev Permissionless — anyone can call once the SX proposal has reached a final state.
    ///      Reads the SX Space's proposal status and reports payouts to CTF.
    ///      CTF enforces that this contract is the authorized oracle for the condition.
    ///
    ///      If the Space call reverts (broken/malicious execution strategy), the market
    ///      settles as NO automatically. Rationale: a proposal whose execution strategy is
    ///      broken can never be executed, so it is effectively rejected. This keeps
    ///      resolution fully permissionless with no admin intervention needed.
    ///
    ///      Gas griefing protection: an attacker could call resolve() with barely enough
    ///      gas so the Space call OOGs and the catch block settles as NO on a valid
    ///      Executed proposal. We detect this by checking gasleft() after the catch.
    ///      EIP-150 retains only 1/64th of gas after an OOG subcall, whereas a genuine
    ///      revert returns almost all gas. If gasleft() < POST_CALL_GAS_FLOOR after the
    ///      catch, we revert instead of settling — the caller must retry with more gas.
    function resolve(address futarchyProposal) external {
        SXBinding memory binding = bindings[futarchyProposal];
        if (binding.space == address(0)) revert NotBound(futarchyProposal);

        bool yesWins;

        try ISpaceGetProposalStatus(binding.space).getProposalStatus(binding.sxProposalId) returns (
            ProposalStatus status
        ) {
            if (status == ProposalStatus.Executed) {
                yesWins = true;
            } else if (status == ProposalStatus.Rejected || status == ProposalStatus.Cancelled) {
                yesWins = false;
            } else {
                revert NotFinal();
            }
        } catch {
            // Guard: if gasleft is low, the revert was likely OOG from insufficient
            // gas, not a genuinely broken strategy. Revert to prevent gas griefing.
            if (gasleft() < POST_CALL_GAS_FLOOR) revert InsufficientGas();

            // Genuine revert → broken strategy → proposal can never execute → NO.
            yesWins = false;
            emit SpaceCallFailed(futarchyProposal, binding.space, binding.sxProposalId);
        }

        bytes32 qId = IProposalQuestionId(futarchyProposal).questionId();
        uint256[] memory payouts = new uint256[](2);
        if (yesWins) {
            payouts[0] = 1;
        } else {
            payouts[1] = 1;
        }

        conditionalTokens.reportPayouts(qId, payouts);
        emit MarketSettled(futarchyProposal, qId, yesWins);
    }
}
