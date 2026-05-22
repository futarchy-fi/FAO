// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {InstanceSale} from "../src/InstanceSale.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";

/// @custom:spec INV-SALE-002 — see audit/specs/INVARIANTS.md.
///
/// Standalone stateful invariant test focused on the *pro-rata payout*
/// guarantee of `ragequit`. The base `InstanceSale.invariants.t.sol`
/// covers `effectiveSupply` formula and phase monotonicity; this file
/// adds the harder invariant: that the ETH a ragequitter receives is
/// exactly the floor-rounded share of the sale's ETH treasury, and that
/// the sale's per-second ETH-per-effective-token ratio is monotonically
/// non-increasing as users ragequit (no extraction of more than fair
/// share).
contract InstanceSaleProRataInvariants is StdInvariant, Test {
    InstanceSale         internal sale;
    GenericFutarchyToken internal token;
    ProRataHandler       internal handler;

    address internal admin = address(0xA11CE);
    uint256 internal constant INITIAL_PRICE        = 1e14;       // 0.0001 ETH/token
    uint256 internal constant MIN_INITIAL_SOLD     = 10;
    uint256 internal constant INITIAL_PHASE_DURATION = 1 hours;

    function setUp() public {
        token = new GenericFutarchyToken("ProRata", "PR", address(this), 0);
        sale = new InstanceSale(address(token), admin, INITIAL_PRICE, MIN_INITIAL_SOLD, INITIAL_PHASE_DURATION);
        token.grantRole(token.MINTER_ROLE(), address(sale));

        handler = new ProRataHandler(sale, token);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ProRataHandler.buyTokens.selector;
        selectors[1] = ProRataHandler.ragequitWithReceipt.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @custom:spec INV-SALE-002 — every observed ragequit paid exactly
    ///                            `floor(ethBalance_pre * burn / effSupply_pre)`.
    function invariant_INV_SALE_002_ragequitPaysExactlyProRata() public view {
        uint256 obs = handler.observationCount();
        for (uint256 i = 0; i < obs; i++) {
            (uint256 ethPre, uint256 burnAmount, uint256 effPre, uint256 ethReceived) = handler.observation(i);
            if (effPre == 0) continue;
            uint256 expected = (ethPre * burnAmount) / effPre;
            assertEq(ethReceived, expected, "INV-SALE-002 violated: ragequit ETH != floor pro-rata");
        }
    }

    /// @custom:spec INV-SALE-002 — non-increasing ETH-per-effective-token ratio.
    /// After ANY ragequit, the post-state ratio is ≤ pre-state ratio (caller
    /// cannot extract a larger share than they paid for).
    function invariant_INV_SALE_002_ratioNonIncreasing() public view {
        uint256 obs = handler.observationCount();
        for (uint256 i = 0; i < obs; i++) {
            (uint256 ethPre, uint256 burnAmount, uint256 effPre, uint256 ethReceived) = handler.observation(i);
            if (effPre == 0 || effPre == burnAmount) continue;
            uint256 ratioPre  = (ethPre * 1e18) / effPre;
            uint256 ratioPost = ((ethPre - ethReceived) * 1e18) / (effPre - burnAmount);
            // floor-rounding can make ratioPost === ratioPre + ε in the very
            // last wei; allow that boundary, forbid strict increase.
            assertLe(ratioPost, ratioPre + 1, "INV-SALE-002 violated: per-token ratio increased after ragequit");
        }
    }
}

contract ProRataHandler is Test {
    InstanceSale         public immutable SALE;
    GenericFutarchyToken public immutable TOKEN;
    address[] internal buyers;

    struct RagequitObservation {
        uint256 ethPre;
        uint256 burnAmount;
        uint256 effSupplyPre;
        uint256 ethReceived;
    }
    RagequitObservation[] private obs;

    constructor(InstanceSale _sale, GenericFutarchyToken _token) {
        SALE = _sale;
        TOKEN = _token;
        for (uint256 i = 0; i < 5; i++) {
            buyers.push(address(uint160(uint256(keccak256(abi.encode("rqbuyer", i))))));
            vm.deal(buyers[i], 100 ether);
        }
    }

    function buyTokens(uint256 buyerSeed, uint256 amountSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 amount = (amountSeed % 50) + 1;
        uint256 cost = amount * SALE.currentPriceWeiPerToken();
        vm.prank(buyer);
        (bool ok, ) = address(SALE).call{value: cost}(abi.encodeWithSignature("buy(uint256)", amount));
        ok;
    }

    function ragequitWithReceipt(uint256 buyerSeed, uint256 amountSeed) external {
        address buyer = buyers[buyerSeed % buyers.length];
        uint256 bal = TOKEN.balanceOf(buyer);
        if (bal == 0) return;
        uint256 wholeBal = bal / 1e18;
        if (wholeBal == 0) return;
        uint256 amount = (amountSeed % wholeBal) + 1;

        vm.prank(buyer);
        TOKEN.approve(address(SALE), amount * 1e18);

        // Snapshot the predicate inputs BEFORE the call.
        uint256 ethPre = address(SALE).balance;
        uint256 effPre = SALE.effectiveSupply();
        uint256 buyerEthPre = buyer.balance;

        vm.prank(buyer);
        (bool ok, ) = address(SALE).call(abi.encodeWithSignature("ragequit(uint256)", amount));
        if (!ok) return;

        uint256 ethReceived = buyer.balance - buyerEthPre;
        obs.push(RagequitObservation({
            ethPre: ethPre,
            burnAmount: amount * 1e18,
            effSupplyPre: effPre,
            ethReceived: ethReceived
        }));
    }

    function observationCount() external view returns (uint256) { return obs.length; }
    function observation(uint256 i) external view returns (uint256, uint256, uint256, uint256) {
        RagequitObservation memory o = obs[i];
        return (o.ethPre, o.burnAmount, o.effSupplyPre, o.ethReceived);
    }
}
