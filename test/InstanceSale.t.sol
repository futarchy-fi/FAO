// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InstanceSale} from "../src/InstanceSale.sol";
import {GenericFutarchyToken} from "../src/GenericFutarchyToken.sol";
import {IFutarchyLiquidityManager} from "../src/interfaces/IFutarchyLiquidityManager.sol";

/// @dev Tiny ERC20 we use as a stand-in for the fLP token / generic ragequitToken.
contract MockShareToken {
    string public constant name = "Mock Share";
    string public constant symbol = "MSH";
    uint8  public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Mock manager that mints `liquidityMinted = sumOfInputs` of itself to msg.sender (the sale),
/// modeling the SaleSpotSeeder fLP flow without UniV3.
contract MockLiquidityManager is IFutarchyLiquidityManager, MockShareToken {
    function initializeFromSale(uint256 faoAmount, bytes calldata /*spotAddData*/)
        external payable returns (uint128 liquidityMinted)
    {
        liquidityMinted = uint128(faoAmount + msg.value);
        // mint to the caller (the sale)
        balanceOf[msg.sender] += liquidityMinted;
        totalSupply += liquidityMinted;
    }

    receive() external payable {}
}

contract ReentrantToken {
    /// Mimics IERC20Min + IMintableERC20 enough to attack ragequit.
    InstanceSale public victim;
    GenericFutarchyToken public real;
    bool public attacking;

    constructor(GenericFutarchyToken r) { real = r; }
    function setVictim(InstanceSale v) external { victim = v; }
    function setAttacking(bool a) external { attacking = a; }

    // Pass through to real token for all standard calls.
    function totalSupply() external view returns (uint256) { return real.totalSupply(); }
    function balanceOf(address a) external view returns (uint256) { return real.balanceOf(a); }
    function transferFrom(address, address, uint256) external returns (bool) {
        // Try to reenter into ragequit during the transferFrom in ragequit.
        if (attacking) victim.ragequit(1);
        return true;
    }
    function transfer(address, uint256) external returns (bool) { return true; }
}

contract InstanceSaleTest is Test {
    GenericFutarchyToken token;
    InstanceSale sale;
    MockLiquidityManager manager;
    MockShareToken extraToken;

    address admin    = address(0xA11CE);
    address buyer    = address(0xB0B);
    address attacker = address(0xBAD);

    uint256 constant INITIAL_PRICE = 1e14;          // 0.0001 ETH/token
    uint256 constant MIN_INITIAL_SOLD = 10;
    uint256 constant INITIAL_PHASE_DURATION = 1 hours;

    function setUp() public {
        // Deploy token with THIS contract as the initial admin so we can
        // grant MINTER_ROLE to the sale below.
        token = new GenericFutarchyToken("Test", "TST", address(this), 0);

        sale = new InstanceSale(
            address(token),
            admin,
            INITIAL_PRICE,
            MIN_INITIAL_SOLD,
            INITIAL_PHASE_DURATION
        );

        token.grantRole(token.MINTER_ROLE(), address(sale));

        // Give the buyer some ETH for buy() calls.
        vm.deal(buyer, 100 ether);
        vm.deal(admin, 10 ether);

        extraToken = new MockShareToken();
        manager = new MockLiquidityManager();
    }

    // ─── buy ─────────────────────────────────────────────────────────────

    function test_buy_initial_mints() public {
        vm.prank(buyer);
        sale.buy{value: 5 * INITIAL_PRICE}(5);

        assertEq(token.balanceOf(buyer), 5 ether, "buyer got 5 tokens");
        assertEq(token.totalSupply(), 5 ether, "supply = 5e18");
        assertEq(sale.initialTokensSold(), 5);
        assertEq(sale.totalAmountRaised(), 5 * INITIAL_PRICE);
        assertEq(address(sale).balance, 5 * INITIAL_PRICE, "sale ETH treasury matches paid");
    }

    function test_buy_revertsOnZero() public {
        vm.expectRevert(InstanceSale.ZeroNumTokens.selector);
        vm.prank(buyer);
        sale.buy(0);
    }

    function test_buy_revertsOnWrongETH() public {
        vm.expectRevert(InstanceSale.IncorrectEth.selector);
        vm.prank(buyer);
        sale.buy{value: INITIAL_PRICE - 1}(1);
    }

    function test_finalize_atEndAndThreshold() public {
        // Buy 10 to hit the threshold while in window.
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        // Advance past the window.
        skip(INITIAL_PHASE_DURATION + 1);
        // Next buy triggers _finalizeInitialPhaseIfNeeded. After finalize,
        // curveSold == 0 so the bonding-curve price is still INITIAL_PRICE.
        vm.prank(buyer);
        sale.buy{value: INITIAL_PRICE}(1);

        assertTrue(sale.initialPhaseFinalized(), "phase finalized after next buy");
        assertEq(sale.initialNetSale(), 10);
    }

    function test_buy_bondingCurvePrice() public {
        // Push to phase 2.
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);
        skip(INITIAL_PHASE_DURATION + 1);

        // After finalize, currentPrice == INITIAL_PRICE * (1 + curveSold/initialNetSale).
        // First post-finalize buy hits initial price exactly (curveSold == 0).
        uint256 priceBefore = INITIAL_PRICE; // curve still at 0
        vm.prank(buyer);
        sale.buy{value: priceBefore}(1);

        assertTrue(sale.initialPhaseFinalized());
        assertEq(sale.totalCurveTokensSold(), 1);

        // Price now = INITIAL_PRICE + INITIAL_PRICE * 1 / 10 = 1.1 * INITIAL_PRICE.
        assertEq(sale.currentPriceWeiPerToken(), INITIAL_PRICE + INITIAL_PRICE / 10);
    }

    // ─── effectiveSupply ─────────────────────────────────────────────────

    function test_effectiveSupply_excludesSaleBalance() public {
        // Buy 10 → totalSupply 10e18, sale holds 0 → effSupply = 10e18.
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);
        assertEq(sale.effectiveSupply(), 10 ether);

        // Mint 5e18 to the sale (treasury-side, as if the sale held some).
        // Sale has MINTER_ROLE so we use it via a workaround: this test acts
        // as the granted DEFAULT_ADMIN_ROLE holder, granting MINTER_ROLE to
        // this contract too, then minting directly.
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(address(sale), 5 ether);
        assertEq(token.totalSupply(), 15 ether);
        assertEq(sale.effectiveSupply(), 10 ether, "sale's own balance excluded");
    }

    function test_effectiveSupply_zeroWhenSaleOwnsAll() public {
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(address(sale), 5 ether);
        assertEq(sale.effectiveSupply(), 0);
    }

    // ─── quoteRagequit ───────────────────────────────────────────────────

    function test_quoteRagequit_matchesActual() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        uint256 quoted = sale.quoteRagequit(3);
        // 3 RAGE * 1e18 / 10e18 = 30% of treasury = 3 * INITIAL_PRICE = 3e14.
        assertEq(quoted, 3 * INITIAL_PRICE);

        // Now ragequit and verify the payout matches.
        vm.prank(buyer);
        token.approve(address(sale), 3 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        sale.ragequit(3);
        assertEq(buyer.balance - before, quoted);
    }

    function test_quoteRagequit_zeroOnEmptyTreasury() public {
        assertEq(sale.quoteRagequit(10), 0);
    }

    function test_quoteRagequit_zeroOnZeroAmount() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);
        assertEq(sale.quoteRagequit(0), 0);
    }

    // ─── ragequit ────────────────────────────────────────────────────────

    function test_ragequit_ETHOnly() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        vm.prank(buyer);
        token.approve(address(sale), 4 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        sale.ragequit(4);

        // 40% of treasury == 4 * INITIAL_PRICE
        assertEq(buyer.balance - before, 4 * INITIAL_PRICE);
        assertEq(token.balanceOf(buyer), 6 ether);
        assertEq(token.totalSupply(), 6 ether, "burn reduced supply");
        assertEq(address(sale).balance, 6 * INITIAL_PRICE);
    }

    function test_ragequit_revertsOnZero() public {
        vm.expectRevert(InstanceSale.ZeroNumTokens.selector);
        vm.prank(buyer);
        sale.ragequit(0);
    }

    function test_ragequit_revertsOnSelfCaller() public {
        // The sale calling itself — synthetic but we want explicit coverage.
        vm.deal(address(sale), 1 ether);
        vm.expectRevert(InstanceSale.CannotRagequitSelf.selector);
        vm.prank(address(sale));
        sale.ragequit(1);
    }

    function test_ragequit_revertsOnEmptyEffectiveSupply() public {
        vm.deal(address(sale), 1 ether);
        // No tokens minted at all → effSupply 0.
        vm.expectRevert(InstanceSale.NothingToReturn.selector);
        vm.prank(buyer);
        sale.ragequit(1);
    }

    function test_ragequit_revertsWhenBurnExceedsEffective() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);
        // try to ragequit 11 — more than total supply.
        vm.prank(buyer);
        token.approve(address(sale), 11 ether);
        vm.expectRevert(bytes("burn > effectiveSupply"));
        vm.prank(buyer);
        sale.ragequit(11);
    }

    function test_ragequit_distributesEachRagequitToken() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        // Add an extra ERC20 to the ragequit list, give the sale a balance.
        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
        extraToken.mint(address(sale), 1000);

        vm.prank(buyer);
        token.approve(address(sale), 5 ether);
        vm.prank(buyer);
        sale.ragequit(5);

        // 50% of 1000 = 500
        assertEq(extraToken.balanceOf(buyer), 500);
        assertEq(extraToken.balanceOf(address(sale)), 500);
    }

    function test_ragequit_skipsRemovedTokens() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
        extraToken.mint(address(sale), 1000);

        // Remove it. The array entry stays but the flag goes false.
        vm.prank(admin);
        sale.removeRagequitToken(address(extraToken));

        vm.prank(buyer);
        token.approve(address(sale), 5 ether);
        vm.prank(buyer);
        sale.ragequit(5);

        // No share transferred for the removed token.
        assertEq(extraToken.balanceOf(buyer), 0);
        assertEq(extraToken.balanceOf(address(sale)), 1000);
    }

    function test_ragequit_distributesProRataAcrossMultipleTokens() public {
        vm.prank(buyer);
        sale.buy{value: 20 * INITIAL_PRICE}(20);

        MockShareToken a = new MockShareToken();
        MockShareToken b = new MockShareToken();
        vm.prank(admin);
        sale.addRagequitToken(address(a));
        vm.prank(admin);
        sale.addRagequitToken(address(b));
        a.mint(address(sale), 1000);
        b.mint(address(sale), 7);

        vm.prank(buyer);
        token.approve(address(sale), 4 ether);
        vm.prank(buyer);
        sale.ragequit(4);

        // 20% pro-rata.
        assertEq(a.balanceOf(buyer), 200);
        assertEq(b.balanceOf(buyer), 1, "7 * 4 / 20 = 1 (floor)");
    }

    // ─── ragequit list admin ─────────────────────────────────────────────

    function test_addRagequitToken_admin() public {
        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
        assertTrue(sale.isRagequitToken(address(extraToken)));
        assertEq(sale.ragequitTokensLength(), 1);
    }

    function test_addRagequitToken_revertsOnZero() public {
        vm.expectRevert(InstanceSale.ZeroAddr.selector);
        vm.prank(admin);
        sale.addRagequitToken(address(0));
    }

    function test_addRagequitToken_revertsOnSaleToken() public {
        vm.expectRevert(InstanceSale.CannotAddSaleToken.selector);
        vm.prank(admin);
        sale.addRagequitToken(address(token));
    }

    function test_addRagequitToken_revertsIfAlreadyOnList() public {
        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
        vm.expectRevert(InstanceSale.AlreadyOnList.selector);
        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
    }

    function test_addRagequitToken_revertsForNonAdmin() public {
        vm.expectRevert(InstanceSale.NotAdmin.selector);
        vm.prank(buyer);
        sale.addRagequitToken(address(extraToken));
    }

    function test_removeRagequitToken_admin() public {
        vm.prank(admin);
        sale.addRagequitToken(address(extraToken));
        vm.prank(admin);
        sale.removeRagequitToken(address(extraToken));
        assertFalse(sale.isRagequitToken(address(extraToken)));
    }

    function test_removeRagequitToken_revertsIfNotOnList() public {
        vm.expectRevert(InstanceSale.NotOnList.selector);
        vm.prank(admin);
        sale.removeRagequitToken(address(extraToken));
    }

    // ─── seedLiquidityManager ────────────────────────────────────────────

    function test_seedLiquidityManager_autoAddsManager() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        vm.prank(admin);
        sale.seedLiquidityManager(address(manager), 1 ether, 0.0005 ether, "");

        assertTrue(sale.isRagequitToken(address(manager)), "auto-added to ragequit list");
        assertEq(sale.ragequitTokensLength(), 1);
        // Manager's MockLiquidityManager mints itself to msg.sender (sale).
        assertGt(manager.balanceOf(address(sale)), 0, "sale received fLP");
    }

    function test_seedLiquidityManager_idempotentAutoAdd() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);

        vm.prank(admin);
        sale.seedLiquidityManager(address(manager), 1 ether, 0.0005 ether, "");
        vm.prank(admin);
        sale.seedLiquidityManager(address(manager), 1 ether, 0.0005 ether, "");

        // Still only one entry.
        assertEq(sale.ragequitTokensLength(), 1);
    }

    function test_seedLiquidityManager_revertsForNonAdmin() public {
        vm.expectRevert(InstanceSale.NotAdmin.selector);
        vm.prank(buyer);
        sale.seedLiquidityManager(address(manager), 1, 1, "");
    }

    function test_seedLiquidityManager_revertsOnZeroManager() public {
        vm.expectRevert(InstanceSale.ZeroManager.selector);
        vm.prank(admin);
        sale.seedLiquidityManager(address(0), 1, 1, "");
    }

    function test_seedLiquidityManager_revertsOnZeroSeed() public {
        vm.expectRevert(InstanceSale.ZeroSeed.selector);
        vm.prank(admin);
        sale.seedLiquidityManager(address(manager), 0, 0, "");
    }

    function test_seedLiquidityManager_revertsOnInsufficientTreasury() public {
        // sale has no ETH yet.
        vm.expectRevert(InstanceSale.InsufficientTreasury.selector);
        vm.prank(admin);
        sale.seedLiquidityManager(address(manager), 1, 1 ether, "");
    }

    // ─── currentPriceWeiPerToken ─────────────────────────────────────────

    function test_currentPriceWeiPerToken_initial() public view {
        assertEq(sale.currentPriceWeiPerToken(), INITIAL_PRICE);
    }

    function test_currentPriceWeiPerToken_bondingCurve_isLinear() public {
        vm.prank(buyer);
        sale.buy{value: 10 * INITIAL_PRICE}(10);
        skip(INITIAL_PHASE_DURATION + 1);
        vm.prank(buyer);
        sale.buy{value: INITIAL_PRICE}(1); // triggers finalize

        // sold 1 curve token; initialNetSale = 10
        assertEq(sale.totalCurveTokensSold(), 1);
        assertEq(sale.currentPriceWeiPerToken(), INITIAL_PRICE + INITIAL_PRICE / 10);

        // sell another 4 → curveSold = 5; price = INITIAL * (1 + 5/10) = 1.5 * INITIAL
        uint256 price = sale.currentPriceWeiPerToken();
        vm.prank(buyer);
        sale.buy{value: 4 * price}(4);
        assertEq(sale.totalCurveTokensSold(), 5);
        assertEq(sale.currentPriceWeiPerToken(), INITIAL_PRICE + (INITIAL_PRICE * 5) / 10);
    }
}
