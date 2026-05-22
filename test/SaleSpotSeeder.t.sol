// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SaleSpotSeeder, ISpotSeederNPM} from "../src/SaleSpotSeeder.sol";

/// @dev Tiny ERC20 + mint helper for the FAO side.
contract MockToken {
    string public constant name = "Mock";
    string public constant symbol = "MOK";
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

/// @dev WETH9-shaped mock: deposit() converts msg.value into WETH owned by the caller.
contract MockWETH is MockToken {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "eth");
    }
}

/// @dev Mock UniV3 NonfungiblePositionManager. Tracks a single position per
/// tokenId; mint/increase/decrease/collect update internal accounting and
/// move tokens accordingly. Liquidity == amount0Desired + amount1Desired
/// (i.e. summed) — good enough for share math, doesn't try to model UniV3
/// curve precisely.
contract MockNPM is ISpotSeederNPM {
    struct Position {
        address owner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }
    uint256 public nextTokenId = 1;
    mapping(uint256 => Position) public pos;

    function mint(MintParams calldata p)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        liquidity = uint128(amount0 + amount1);
        tokenId = nextTokenId++;
        pos[tokenId] = Position({
            owner: msg.sender,
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: liquidity,
            owed0: 0, owed1: 0
        });
        // Pull tokens from msg.sender (matches real NPM).
        _pull(p.token0, msg.sender, amount0);
        _pull(p.token1, msg.sender, amount1);
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata p)
        external payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage q = pos[p.tokenId];
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        liquidity = uint128(amount0 + amount1);
        q.liquidity += liquidity;
        _pull(q.token0, msg.sender, amount0);
        _pull(q.token1, msg.sender, amount1);
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata p)
        external payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage q = pos[p.tokenId];
        require(q.liquidity >= p.liquidity, "bad liq");
        // Split the burned liquidity into half token0 + half token1 (we
        // stored liquidity = a0+a1; can't recover the original split, so
        // we just split 50/50 — fine for share-math tests).
        amount0 = uint256(p.liquidity) / 2;
        amount1 = uint256(p.liquidity) - amount0;
        q.liquidity -= p.liquidity;
        q.owed0 += uint128(amount0);
        q.owed1 += uint128(amount1);
    }

    function collect(CollectParams calldata p)
        external payable
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage q = pos[p.tokenId];
        amount0 = q.owed0;
        amount1 = q.owed1;
        q.owed0 = 0;
        q.owed1 = 0;
        if (amount0 > 0) _push(q.token0, p.recipient, amount0);
        if (amount1 > 0) _push(q.token1, p.recipient, amount1);
    }

    function positions(uint256 tokenId)
        external view
        returns (
            uint96, address, address, address, uint24, int24, int24,
            uint128 liquidity, uint256, uint256, uint128, uint128
        )
    {
        Position memory q = pos[tokenId];
        return (0, q.owner, q.token0, q.token1, q.fee, q.tickLower, q.tickUpper, q.liquidity, 0, 0, q.owed0, q.owed1);
    }

    function safeTransferFrom(address /*from*/, address to, uint256 tokenId) external {
        pos[tokenId].owner = to;
    }

    function _pull(address token, address from, uint256 amount) internal {
        MockToken(token).transferFrom(from, address(this), amount);
    }
    function _push(address token, address to, uint256 amount) internal {
        MockToken(token).transfer(to, amount);
    }
}

contract SaleSpotSeederTest is Test {
    MockToken fao;
    MockWETH  weth;
    MockNPM   npm;
    SaleSpotSeeder seeder;

    address sale  = address(0xCAFE);
    address admin = address(0xA11CE);
    address user  = address(0xB0B);

    function setUp() public {
        fao  = new MockToken();
        weth = new MockWETH();
        npm  = new MockNPM();
        seeder = new SaleSpotSeeder(
            sale,
            admin,
            address(fao),
            address(weth),
            address(npm),
            address(0xDEADBEEF), // spotPool — not actually used by the mock
            uint24(500)
        );

        vm.deal(sale, 100 ether);
        vm.deal(user, 100 ether);

        // Pre-fund the sale with FAO so seedLiquidityManager-style flow works
        // (the InstanceSale mints fao to the manager; here we simulate by
        // pre-funding the seeder when the sale calls initializeFromSale).
    }

    // ─── initializeFromSale ─────────────────────────────────────────────

    function test_firstSeed_createsPosition_andMintsFLP() public {
        // The sale's seedLiquidityManager mints `tokenAmount` to manager
        // (= seeder), then calls initializeFromSale with that same amount.
        fao.mint(address(seeder), 5 ether);

        vm.prank(sale);
        uint128 liq = seeder.initializeFromSale{value: 0.005 ether}(5 ether, "");

        assertEq(seeder.lpTokenId(), 1, "tokenId set");
        assertEq(liq, uint128(5 ether + 0.005 ether), "liquidity = a0+a1");
        assertEq(seeder.balanceOf(sale), liq, "fLP minted to sale");
        // Tokens consumed by mock NPM.
        assertEq(fao.balanceOf(address(seeder)), 0);
        assertEq(weth.balanceOf(address(seeder)), 0);
    }

    function test_subsequentSeed_increasesLiquidity() public {
        fao.mint(address(seeder), 5 ether);
        vm.prank(sale);
        uint128 liq1 = seeder.initializeFromSale{value: 0.005 ether}(5 ether, "");
        uint256 idAfterFirst = seeder.lpTokenId();

        // Second call: same tokenId, liquidity grows.
        fao.mint(address(seeder), 3 ether);
        vm.prank(sale);
        uint128 liq2 = seeder.initializeFromSale{value: 0.003 ether}(3 ether, "");

        assertEq(seeder.lpTokenId(), idAfterFirst, "no new NFT");
        assertEq(seeder.balanceOf(sale), uint256(liq1) + uint256(liq2), "fLP additive");
    }

    function test_initializeFromSale_revertsForNonSale() public {
        fao.mint(address(seeder), 1 ether);
        vm.expectRevert(SaleSpotSeeder.OnlySale.selector);
        vm.prank(user);
        seeder.initializeFromSale{value: 0.001 ether}(1 ether, "");
    }

    function test_initializeFromSale_acceptsZeroETH() public {
        fao.mint(address(seeder), 1 ether);
        vm.prank(sale);
        uint128 liq = seeder.initializeFromSale(1 ether, "");
        assertEq(liq, 1 ether, "liquidity == fao only");
    }

    // ─── redeem ─────────────────────────────────────────────────────────

    function test_redeem_burnsAndWithdraws() public {
        // Use balanced deposits so the mock's 50/50 decreaseLiquidity split
        // (a stand-in for real UniV3 math) doesn't overdraw one side.
        fao.mint(address(seeder), 1 ether);
        vm.prank(sale);
        uint128 liq = seeder.initializeFromSale{value: 1 ether}(1 ether, "");

        vm.prank(sale);
        seeder.transfer(user, liq / 2);

        uint256 faoBefore  = fao.balanceOf(user);
        uint256 wethBefore = weth.balanceOf(user);

        vm.prank(user);
        (uint256 a0, uint256 a1) = seeder.redeem(liq / 2);

        // Pro-rata: liquidity removed = currentLiq * (liq/2) / liq = liq/2.
        // Mock splits ~50/50 → a0 == liq/4, a1 == liq/4 (within floor).
        assertEq(seeder.balanceOf(user), 0, "fLP burned");
        assertEq(a0 + a1, uint256(liq) / 2, "tokens out = removed liquidity (no fee model)");
        bool faoIsT0 = address(fao) < address(weth);
        if (faoIsT0) {
            assertEq(fao.balanceOf(user) - faoBefore, a0);
            assertEq(weth.balanceOf(user) - wethBefore, a1);
        } else {
            assertEq(fao.balanceOf(user) - faoBefore, a1);
            assertEq(weth.balanceOf(user) - wethBefore, a0);
        }
    }

    function test_redeem_revertsOnZero() public {
        fao.mint(address(seeder), 1 ether);
        vm.prank(sale);
        seeder.initializeFromSale{value: 0.001 ether}(1 ether, "");
        vm.expectRevert(bytes("fLPAmount=0"));
        vm.prank(sale);
        seeder.redeem(0);
    }

    function test_redeem_revertsBeforeAnyPosition() public {
        vm.expectRevert(bytes("no LP position yet"));
        vm.prank(user);
        seeder.redeem(1);
    }

    // Note: "slice rounds to zero" is only reachable when currentLiq < supply
    // — fee-tier accruals can shrink position liquidity over time. Our mock
    // NPM doesn't model that path; rely on the on-chain integration for
    // coverage. The pure `fLPAmount == 0` revert is already covered by
    // test_redeem_revertsOnZero above.

    function test_quoteRedeem() public {
        fao.mint(address(seeder), 10 ether);
        vm.prank(sale);
        uint128 liq = seeder.initializeFromSale{value: 0.01 ether}(10 ether, "");

        // Quote half: should equal half the current liquidity.
        uint128 q = seeder.quoteRedeem(uint256(liq) / 2);
        assertEq(q, liq / 2);
    }

    function test_quoteRedeem_zeroBeforePosition() public view {
        assertEq(seeder.quoteRedeem(1), 0);
    }

    // ─── sweep ──────────────────────────────────────────────────────────

    function test_sweepLP_adminOnly() public {
        fao.mint(address(seeder), 1 ether);
        vm.prank(sale);
        seeder.initializeFromSale{value: 0.001 ether}(1 ether, "");

        vm.expectRevert(SaleSpotSeeder.OnlyAdmin.selector);
        vm.prank(user);
        seeder.sweepLP(user);

        vm.prank(admin);
        seeder.sweepLP(user);
        (, address owner,,,,,,,,,,) = npm.positions(seeder.lpTokenId());
        assertEq(owner, user, "NFT moved");
    }

    function test_sweepLP_revertsBeforePosition() public {
        vm.expectRevert(SaleSpotSeeder.NoPositionYet.selector);
        vm.prank(admin);
        seeder.sweepLP(user);
    }

    // ─── ERC721 receiver ────────────────────────────────────────────────

    function test_onERC721Received_returnsMagic() public view {
        bytes4 sel = seeder.onERC721Received(address(0), address(0), 0, "");
        assertEq(sel, this.dummyHook.selector ^ this.dummyHook.selector ^ 0x150b7a02);
        // 0x150b7a02 == onERC721Received(address,address,uint256,bytes).selector
        assertEq(sel, bytes4(0x150b7a02));
    }
    function dummyHook(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}
