// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FAOCreateAndBond} from "../src/FAOCreateAndBond.sol";
import {IFAOFutarchyFactoryLike} from "../src/interfaces/IFAOFutarchyFactoryLike.sol";

// ════════════════════════════════════════════════════════════════════════════════
//  Mocks
// ════════════════════════════════════════════════════════════════════════════════

/// @notice Minimal stand-in for a deployed FAOFutarchyProposal. Address-only — the
/// bridge never calls into it.
contract MockProposal {
    bytes32 public conditionId;
    string public marketName;
    string public description;

    constructor(string memory _name, string memory _desc) {
        marketName = _name;
        description = _desc;
        conditionId = keccak256(abi.encodePacked(_name, _desc));
    }
}

/// @notice Mock FAOFutarchyFactory that mirrors the real `createProposal` signature
/// (`CreateProposalParams` struct → returns address). Each call deploys a fresh
/// MockProposal so the bridge's `proposalId = uint256(uint160(addr))` derivation
/// yields a unique id.
contract MockFactory {
    address[] public proposals;

    bool public shouldRevert;
    bool public returnZeroAddress;
    string public revertMessage;

    error EmptyMarketName();

    function setShouldRevert(bool v, string calldata reason) external {
        shouldRevert = v;
        revertMessage = reason;
    }

    function setReturnZeroAddress(bool v) external {
        returnZeroAddress = v;
    }

    function createProposal(IFAOFutarchyFactoryLike.CreateProposalParams memory params)
        external
        returns (address)
    {
        if (shouldRevert) {
            // Match the kind of revert the real factory uses for empty name (selector-based),
            // but allow alternative string reverts for the "zero collateral" style tests.
            if (bytes(revertMessage).length == 0) {
                revert EmptyMarketName();
            }
            revert(revertMessage);
        }
        if (returnZeroAddress) {
            return address(0);
        }

        address p = address(new MockProposal(params.marketName, params.description));
        proposals.push(p);
        return p;
    }

    function marketsCount() external view returns (uint256) {
        return proposals.length;
    }
}

/// @notice Mock FutarchyArbitration exposing the subset the bridge uses
/// (`baseX()` + `createProposalWithId`). Records every call so tests can assert
/// the bridge wired arguments correctly.
contract MockArbitration {
    uint256 public baseX;

    struct CreatedProposal {
        uint256 proposalId;
        uint256 minActivationBond;
        bool exists;
    }

    mapping(uint256 => CreatedProposal) public created;
    uint256 public createCalls;

    error ProposalAlreadyExists();
    error InvalidMinActivationBond();

    constructor(uint256 _baseX) {
        baseX = _baseX;
    }

    function setBaseX(uint256 _baseX) external {
        baseX = _baseX;
    }

    function createProposalWithId(uint256 proposalId, uint256 minActivationBond)
        external
        returns (uint256)
    {
        if (minActivationBond == 0) revert InvalidMinActivationBond();
        if (created[proposalId].exists) revert ProposalAlreadyExists();
        created[proposalId] = CreatedProposal({
            proposalId: proposalId,
            minActivationBond: minActivationBond,
            exists: true
        });
        createCalls += 1;
        return proposalId;
    }
}

/// @notice Inert placeholders for WETH / collaterals — the bridge only stores their
/// addresses, never calls into them.
contract MockToken {
    string public name;

    constructor(string memory _name) {
        name = _name;
    }
}

// ════════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════════

contract FAOCreateAndBondTest is Test {
    FAOCreateAndBond bridge;
    MockFactory factory;
    MockArbitration arbitration;
    MockToken weth;
    MockToken fao;

    address constant CREATOR = address(0xC0FFEE);

    uint256 constant TEST_BASE_X = 0.001 ether;

    event BondedProposalCreated(
        uint256 indexed proposalId,
        address indexed futarchyProposal,
        address indexed creator
    );

    function setUp() public {
        factory = new MockFactory();
        arbitration = new MockArbitration(TEST_BASE_X);
        weth = new MockToken("WETH");
        fao = new MockToken("FAO");

        bridge = new FAOCreateAndBond(
            address(factory),
            address(arbitration),
            address(weth),
            address(fao),   // collateralToken1
            address(weth)   // collateralToken2
        );
    }

    // ─── Construction ───────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(bridge.factory(), address(factory));
        assertEq(bridge.arbitration(), address(arbitration));
        assertEq(bridge.weth(), address(weth));
        assertEq(bridge.collateralToken1(), address(fao));
        assertEq(bridge.collateralToken2(), address(weth));
    }

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(FAOCreateAndBond.ZeroAddress.selector);
        new FAOCreateAndBond(
            address(0), address(arbitration), address(weth), address(fao), address(weth)
        );
    }

    function test_constructor_revertsOnZeroArbitration() public {
        vm.expectRevert(FAOCreateAndBond.ZeroAddress.selector);
        new FAOCreateAndBond(
            address(factory), address(0), address(weth), address(fao), address(weth)
        );
    }

    function test_constructor_revertsOnZeroWeth() public {
        vm.expectRevert(FAOCreateAndBond.ZeroAddress.selector);
        new FAOCreateAndBond(
            address(factory), address(arbitration), address(0), address(fao), address(weth)
        );
    }

    function test_constructor_revertsOnZeroCollateral1() public {
        vm.expectRevert(FAOCreateAndBond.ZeroAddress.selector);
        new FAOCreateAndBond(
            address(factory), address(arbitration), address(weth), address(0), address(weth)
        );
    }

    function test_constructor_revertsOnZeroCollateral2() public {
        vm.expectRevert(FAOCreateAndBond.ZeroAddress.selector);
        new FAOCreateAndBond(
            address(factory), address(arbitration), address(weth), address(fao), address(0)
        );
    }

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_createBondedProposal_returnsMatchingIdAndAddress() public {
        vm.prank(CREATOR);
        (uint256 proposalId, address futarchyProposal) =
            bridge.createBondedProposal("Should we ship X?", "Long-form desc");

        // proposalId is exactly the lower-160-bits cast of the proposal address.
        assertEq(proposalId, uint256(uint160(futarchyProposal)), "proposalId must equal uint160(addr)");
        assertTrue(futarchyProposal != address(0), "futarchy address must be non-zero");
    }

    function test_createBondedProposal_emitsEvent() public {
        // Pre-compute the address the factory will deploy at so we can verify event args.
        // MockFactory deploys a MockProposal via `new`, so the address is determined by
        // (factory, factory.nonce) — for the first call, nonce starts at 1 (or higher
        // if the factory has already deployed children during construction; here it has
        // not). We compute it manually:
        address expected = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint256 expectedId = uint256(uint160(expected));

        vm.expectEmit(true, true, true, false, address(bridge));
        emit BondedProposalCreated(expectedId, expected, CREATOR);

        vm.prank(CREATOR);
        bridge.createBondedProposal("Should we ship X?", "desc");
    }

    function test_createBondedProposal_registersInMapping() public {
        vm.prank(CREATOR);
        (uint256 proposalId, address futarchyProposal) =
            bridge.createBondedProposal("Prop A", "desc A");

        assertEq(
            bridge.proposalToFutarchy(proposalId),
            futarchyProposal,
            "mapping must record proposalId -> futarchy address"
        );
    }

    function test_createBondedProposal_callsArbitrationWithBaseX() public {
        vm.prank(CREATOR);
        (uint256 proposalId,) = bridge.createBondedProposal("Prop A", "desc");

        (uint256 storedId, uint256 storedBond, bool exists) = arbitration.created(proposalId);
        assertTrue(exists, "arbitration must record the proposal");
        assertEq(storedId, proposalId);
        assertEq(storedBond, TEST_BASE_X, "minActivationBond must equal baseX");
        assertEq(arbitration.createCalls(), 1);
    }

    function test_createBondedProposal_appendsToPendingList() public {
        assertEq(bridge.pendingProposalIds().length, 0);
        assertEq(bridge.proposalsCount(), 0);

        vm.prank(CREATOR);
        (uint256 id1,) = bridge.createBondedProposal("A", "a");
        vm.prank(CREATOR);
        (uint256 id2,) = bridge.createBondedProposal("B", "b");

        uint256[] memory ids = bridge.pendingProposalIds();
        assertEq(ids.length, 2, "two pending entries");
        assertEq(ids[0], id1, "first id");
        assertEq(ids[1], id2, "second id");
        assertEq(bridge.proposalsCount(), 2);
    }

    function test_createBondedProposal_multipleCallsAreIndependent() public {
        vm.prank(CREATOR);
        (uint256 id1, address p1) = bridge.createBondedProposal("A", "a");
        vm.prank(CREATOR);
        (uint256 id2, address p2) = bridge.createBondedProposal("B", "b");

        assertTrue(id1 != id2, "different proposals must yield different ids");
        assertTrue(p1 != p2, "different proposals must yield different addresses");
        assertEq(bridge.proposalToFutarchy(id1), p1);
        assertEq(bridge.proposalToFutarchy(id2), p2);
    }

    // ─── Failure propagation ────────────────────────────────────────────────

    function test_createBondedProposal_revertsWhenFactoryReverts_emptyName() public {
        factory.setShouldRevert(true, ""); // emits EmptyMarketName selector
        vm.expectRevert(MockFactory.EmptyMarketName.selector);
        bridge.createBondedProposal("", "desc");

        // Bridge state must remain clean.
        assertEq(bridge.proposalsCount(), 0);
        assertEq(arbitration.createCalls(), 0, "arbitration must not be called on factory failure");
    }

    function test_createBondedProposal_revertsWhenFactoryReverts_zeroCollateral() public {
        // Simulate the InvalidCollateral path with a string revert (matches the spirit
        // of a factory revert without us having to wire the exact selector).
        factory.setShouldRevert(true, "InvalidCollateral");
        vm.expectRevert(bytes("InvalidCollateral"));
        bridge.createBondedProposal("Prop", "desc");

        assertEq(bridge.proposalsCount(), 0);
        assertEq(arbitration.createCalls(), 0);
    }

    function test_createBondedProposal_revertsWhenFactoryReturnsZero() public {
        factory.setReturnZeroAddress(true);
        vm.expectRevert(FAOCreateAndBond.FutarchyAddressZero.selector);
        bridge.createBondedProposal("Prop", "desc");

        assertEq(bridge.proposalsCount(), 0);
        assertEq(arbitration.createCalls(), 0);
    }

    function test_createBondedProposal_revertsWhenArbitrationReverts_duplicate() public {
        // First call succeeds.
        vm.prank(CREATOR);
        (uint256 firstId,) = bridge.createBondedProposal("Prop A", "a");

        // Force the second call's arbitration leg to collide. The MockFactory deploys
        // a new MockProposal each call, so addresses naturally differ. We instead
        // pre-seed the arbitration with the *next* derived id by computing it.
        address nextProposalAddr =
            vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        uint256 nextId = uint256(uint160(nextProposalAddr));
        arbitration.createProposalWithId(nextId, 1 ether);

        // Sanity: the first id and the colliding next id are distinct.
        assertTrue(firstId != nextId);

        // Now the bridge call should revert with ProposalAlreadyExists from arbitration.
        vm.expectRevert(MockArbitration.ProposalAlreadyExists.selector);
        vm.prank(CREATOR);
        bridge.createBondedProposal("Prop B", "b");

        // Bridge mapping for the colliding id must NOT have been written (revert unwinds it).
        assertEq(bridge.proposalToFutarchy(nextId), address(0), "mapping must unwind on revert");
        assertEq(bridge.proposalsCount(), 1, "only the successful first call must remain");
    }

    function test_createBondedProposal_revertsWhenArbitrationReverts_zeroBaseX() public {
        // If baseX is 0, the arbitration will reject the create as invalid minActivationBond.
        arbitration.setBaseX(0);

        vm.expectRevert(MockArbitration.InvalidMinActivationBond.selector);
        vm.prank(CREATOR);
        bridge.createBondedProposal("Prop", "desc");

        assertEq(bridge.proposalsCount(), 0);
    }

    // ─── Mapping coverage ────────────────────────────────────────────────────

    function test_proposalToFutarchy_returnsZeroForUnknownId() public view {
        assertEq(bridge.proposalToFutarchy(uint256(123_456)), address(0));
    }
}
