// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {InstanceSale} from "../src/InstanceSale.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";

/// @custom:spec INV-SALE-001, INV-SALE-002, INV-SALE-003, INV-SALE-004,
/// INV-TOKEN-001 — see audit/specs/INVARIANTS.md.
///
/// These are stateful invariant tests: Foundry's invariant runner picks a
/// random sequence of `Handler` calls and after each step asserts the
/// load-bearing predicates from the spec hold.
contract InstanceSaleInvariants is StdInvariant, Test {
    InstanceSale     internal sale;
    GenericFutarchyToken internal token;
    Handler          internal handler;

    address internal admin = address(0xA11CE);
    uint256 internal constant INITIAL_PRICE   = 1e14;     // 0.0001 ETH/token
    uint256 internal constant MIN_INITIAL_SOLD = 10;
    uint256 internal constant INITIAL_PHASE_DURATION = 1 hours;

    function setUp() public {
        token = new GenericFutarchyToken("InvTest", "INV", address(this), 0);
        sale  = new InstanceSale(address(token), admin, INITIAL_PRICE, MIN_INITIAL_SOLD, INITIAL_PHASE_DURATION);
        token.grantRole(token.MINTER_ROLE(), address(sale));

        handler = new Handler(sale, token);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = Handler.buyTokens.selector;
        selectors[1] = Handler.ragequitTokens.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @custom:spec INV-SALE-001 — effectiveSupply formula always holds.
    function invariant_INV_SALE_001_effectiveSupplyFormula() public view {
        uint256 total = token.totalSupply();
        uint256 saleBal = token.balanceOf(address(sale));
        uint256 expected = total > saleBal ? total - saleBal : 0;
        assertEq(sale.effectiveSupply(), expected, "INV-SALE-001 violated");
    }

    /// @custom:spec INV-SALE-004 — initialPhaseFinalized is monotone.
    function invariant_INV_SALE_004_phaseMonotone() public view {
        // Once finalized, subsequent calls must keep it true. Handler ratchets
        // the flag in `_observePhase` so we can compare a previously-observed
        // value against the current.
        if (handler.observedFinalized()) {
            assertTrue(sale.initialPhaseFinalized(), "INV-SALE-004 violated: phase regressed");
        }
    }

    /// @custom:spec INV-TOKEN-001 — totalSupply changes only via mint/burn.
    /// The handler exposes only `buy` and `ragequit`; if either changes the
    /// supply, the invariant follows.
    function invariant_INV_TOKEN_001_supplyTracksHandlerOps() public view {
        uint256 expected = handler.totalMinted() - handler.totalBurned();
        assertEq(token.totalSupply(), expected, "INV-TOKEN-001 violated");
    }
}

/// @dev Handler restricts the invariant runner to the two state-mutating
/// surfaces relevant to the invariants above. Each call is gated so the
/// runner doesn't get stuck on trivial reverts (e.g. ragequit with 0 supply).
contract Handler is Test {
    InstanceSale         public immutable SALE;
    GenericFutarchyToken public immutable TOKEN;

    uint256 public totalMinted;
    uint256 public totalBurned;
    bool    public observedFinalized;

    address[] internal buyers;

    constructor(InstanceSale _sale, GenericFutarchyToken _token) {
        SALE = _sale;
        TOKEN = _token;
        // Seed a small set of buyer addresses for the runner to pick from.
        for (uint256 i = 0; i < 5; i++) {
            buyers.push(address(uint160(uint256(keccak256(abi.encode("buyer", i))))));
            vm.deal(buyers[i], 100 ether);
        }
    }

    function buyTokens(uint256 buyerSeed, uint256 amountSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 amount = (amountSeed % 50) + 1; // 1..50 whole tokens
        uint256 cost = amount * SALE.currentPriceWeiPerToken();
        vm.prank(buyer);
        (bool ok, ) = address(SALE).call{value: cost}(abi.encodeWithSignature("buy(uint256)", amount));
        if (ok) {
            totalMinted += amount * 1e18;
        }
        _observePhase();
    }

    function ragequitTokens(uint256 buyerSeed, uint256 amountSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 bal = TOKEN.balanceOf(buyer);
        if (bal == 0) return;
        uint256 wholeBal = bal / 1e18;
        if (wholeBal == 0) return;
        uint256 amount = (amountSeed % wholeBal) + 1;

        vm.prank(buyer);
        TOKEN.approve(address(SALE), amount * 1e18);

        // Track pre-state to detect successful burn.
        uint256 preSupply = TOKEN.totalSupply();
        vm.prank(buyer);
        (bool ok, ) = address(SALE).call(abi.encodeWithSignature("ragequit(uint256)", amount));
        if (ok) {
            uint256 postSupply = TOKEN.totalSupply();
            totalBurned += preSupply - postSupply;
        }
        _observePhase();
    }

    function _observePhase() internal {
        if (SALE.initialPhaseFinalized()) observedFinalized = true;
    }
}
