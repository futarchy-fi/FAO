// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFAOFutarchyFactoryLike} from "./interfaces/IFAOFutarchyFactoryLike.sol";
import {IFutarchyArbitrationLike} from "./interfaces/IFutarchyArbitrationLike.sol";

/// @title FAOCreateAndBond
/// @notice Permissionless atomic bridge between `FAOFutarchyFactory` and
/// `FutarchyArbitration`.
///
/// Without this contract, creating a futarchy market that is governed by the bond
/// escalation game requires THREE coordinated steps from at least two parties:
///   1. anyone: `FAOFutarchyFactory.createProposal(...)` — deploys the proposal + wrappers.
///   2. anyone: `FutarchyArbitration.createProposal(...)` (or `createProposalWithId`)
///      — opens the bond escalation slot.
///   3. admin: `FutarchyEvaluator.setFutarchyProposal(proposalId, futarchyProposal)`
///      — binds the arbitration id to the futarchy contract so CTF payouts can be
///      read at evaluation time.
///
/// This contract folds the first two into a single transaction and stores the
/// link from `proposalId -> futarchyProposal` on-chain, so any UI or daemon can
/// look it up without needing admin intervention. The admin step (3) is still
/// required, but the off-chain wiring is reduced to "scan
/// `BondedProposalCreated` events and call `setFutarchyProposal` for each".
///
/// Design notes:
///   - `proposalId = uint256(uint160(futarchyProposal))`. The futarchy proposal
///     address is unique and unforgeable (cloned via CREATE), so collisions are
///     statistically infeasible (160-bit address space, never reused). Using the
///     address as the id eliminates the need for an oracle that maps the two.
///   - We do NOT support placing the first YES bond atomically. Doing so would
///     require either pulling WETH from `msg.sender` here and re-approving
///     arbitration (which works) OR using some kind of meta-call so that the
///     bond is attributed to the user instead of this bridge. In v0 we keep the
///     contract minimal: users place bonds in a follow-up tx via
///     `FutarchyArbitration.placeYesBond`. Tracked for v1 in
///     `docs/onchain-futarchy-design.md`.
contract FAOCreateAndBond {
    // ═══════════════════════════════════════════════════════
    //  Immutables
    // ═══════════════════════════════════════════════════════

    /// @notice The factory that creates futarchy proposals (clones + wrappers + CTF condition).
    address public immutable factory;

    /// @notice The arbitration contract that runs the bond escalation game.
    address public immutable arbitration;

    /// @notice The WETH token used for bonds (exposed for off-chain discoverability).
    /// @dev The arbitration contract reads its own immutable WETH; we keep a copy here
    ///      so UIs only need to know the bridge address.
    address public immutable weth;

    /// @notice Default collateralToken1 passed to the factory (typically FAO).
    address public immutable collateralToken1;

    /// @notice Default collateralToken2 passed to the factory (typically WETH).
    address public immutable collateralToken2;

    // ═══════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════

    /// @notice arbitration proposalId -> futarchy proposal contract.
    /// @dev Set atomically during `createBondedProposal`. Read by the off-chain admin
    ///      to know which futarchy proposal to bind on `FutarchyEvaluator`.
    mapping(uint256 => address) public proposalToFutarchy;

    /// @notice All arbitration proposalIds created through this bridge, in creation order.
    /// @dev Exposed via `pendingProposalIds()` for UI / daemon iteration.
    uint256[] internal _proposalIds;

    // ═══════════════════════════════════════════════════════
    //  Events & Errors
    // ═══════════════════════════════════════════════════════

    event BondedProposalCreated(
        uint256 indexed proposalId,
        address indexed futarchyProposal,
        address indexed creator
    );

    error ZeroAddress();
    error FutarchyAddressZero();

    // ═══════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════

    constructor(
        address _factory,
        address _arbitration,
        address _weth,
        address _collateralToken1,
        address _collateralToken2
    ) {
        if (
            _factory == address(0) || _arbitration == address(0) || _weth == address(0)
                || _collateralToken1 == address(0) || _collateralToken2 == address(0)
        ) revert ZeroAddress();

        factory = _factory;
        arbitration = _arbitration;
        weth = _weth;
        collateralToken1 = _collateralToken1;
        collateralToken2 = _collateralToken2;
    }

    // ═══════════════════════════════════════════════════════
    //  Public API
    // ═══════════════════════════════════════════════════════

    /// @notice Create a futarchy proposal AND its matching arbitration slot atomically.
    /// @dev Steps:
    ///   1. Call `factory.createProposal(marketName, description, FAO, WETH)`. The
    ///      factory deploys a fresh proposal clone and 4 Wrapped1155 outcome tokens;
    ///      returns the proposal address.
    ///   2. Derive `proposalId = uint256(uint160(propAddr))` — a 160-bit
    ///      collision-free id tied to the proposal contract itself.
    ///   3. Call `arbitration.createProposalWithId(proposalId, baseX)`. We use
    ///      `baseX` as the `minActivationBond` so the very first YES bond can
    ///      directly graduate (avoiding a no-op escalation round in the common case).
    ///   4. Record the link in `proposalToFutarchy` and append to `_proposalIds`.
    ///   5. Emit `BondedProposalCreated`.
    ///
    /// First-YES-bond placement is intentionally NOT bundled — see contract NatSpec.
    ///
    /// @param marketName  Human-readable name (must be non-empty per the factory).
    /// @param description Long-form description of the proposal.
    /// @return proposalId The arbitration id (= uint256(uint160(futarchyProposal))).
    /// @return futarchyProposal The deployed FAOFutarchyProposal clone address.
    function createBondedProposal(string calldata marketName, string calldata description)
        external
        returns (uint256 proposalId, address futarchyProposal)
    {
        // Step 1: deploy futarchy proposal via the factory.
        IFAOFutarchyFactoryLike.CreateProposalParams memory params = IFAOFutarchyFactoryLike
            .CreateProposalParams({
            marketName: marketName,
            description: description,
            collateralToken1: collateralToken1,
            collateralToken2: collateralToken2
        });

        futarchyProposal = IFAOFutarchyFactoryLike(factory).createProposal(params);
        if (futarchyProposal == address(0)) revert FutarchyAddressZero();

        // Step 2: derive an arbitration-side id from the proposal contract address.
        proposalId = uint256(uint160(futarchyProposal));

        // Step 3: open the arbitration slot with `baseX` as the minActivationBond,
        // which equals the initial graduation threshold (queue empty => requiredYes = baseX).
        uint256 minActivationBond = IFutarchyArbitrationLike(arbitration).baseX();
        IFutarchyArbitrationLike(arbitration).createProposalWithId(proposalId, minActivationBond);

        // Step 4: register on-chain link (permissionless lookup).
        proposalToFutarchy[proposalId] = futarchyProposal;
        _proposalIds.push(proposalId);

        // Step 5: signal to off-chain watchers.
        emit BondedProposalCreated(proposalId, futarchyProposal, msg.sender);
    }

    // ═══════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════

    /// @notice All arbitration proposalIds created through this bridge, in creation order.
    /// @dev "Pending" is a misnomer — entries are never removed; the name reflects
    ///      that the off-chain admin still needs to bind each one via
    ///      `FutarchyEvaluator.setFutarchyProposal`. UIs typically filter by
    ///      whichever arbitration / evaluator state they care about.
    function pendingProposalIds() external view returns (uint256[] memory) {
        return _proposalIds;
    }

    /// @notice Number of bonded proposals created through this bridge.
    function proposalsCount() external view returns (uint256) {
        return _proposalIds.length;
    }
}
