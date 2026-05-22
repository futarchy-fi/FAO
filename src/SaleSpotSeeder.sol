// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFutarchyLiquidityManager} from "./interfaces/IFutarchyLiquidityManager.sol";

interface ISpotSeederERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISpotSeederWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ISpotSeederNPM {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable
        returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params)
        external payable
        returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title SaleSpotSeeder (v2 — ERC20 fLP)
/// @notice `IFutarchyLiquidityManager` plugin. The sale calls
///         `initializeFromSale{value:eth}(faoAmount, "")` which:
///           1. Wraps ETH → WETH.
///           2. On the first call: mints a new full-range UniV3 LP position
///              on the FAO/WETH pool (recipient: this seeder).
///              Subsequent calls: increases liquidity on the same tokenId.
///           3. Mints `liquidityMinted` units of fLP (this contract = ERC20)
///              to msg.sender (the sale).
///         The sale auto-adds the seeder to its `ragequitTokens[]`, so fLP
///         flows out through ragequit pro-rata. fLP holders can then
///         `redeem(fLPAmount)` to burn their fLP and receive a pro-rata
///         share of the underlying FAO + WETH from the pooled UniV3 position.
contract SaleSpotSeeder is ERC20, IFutarchyLiquidityManager {
    address public immutable SALE;
    address public immutable ADMIN;
    address public immutable FAO;
    address public immutable WETH;
    address public immutable NPM;
    address public immutable SPOT_POOL;
    uint24  public immutable FEE_TIER;

    int24 public constant TICK_LOWER = -887270;
    int24 public constant TICK_UPPER =  887270;

    uint256 public lpTokenId;

    event Seeded(uint256 faoAmount, uint256 nativeAmount, uint128 liquidity, uint256 tokenId);
    event Redeemed(address indexed user, uint256 fLPBurned, uint256 amount0, uint256 amount1);

    error OnlySale();
    error OnlyAdmin();
    error NoPositionYet();

    constructor(
        address sale,
        address admin,
        address fao,
        address weth,
        address npm,
        address spotPool,
        uint24 feeTier
    ) ERC20("Futarchy LP", "fLP") {
        SALE = sale;
        ADMIN = admin;
        FAO = fao;
        WETH = weth;
        NPM = npm;
        SPOT_POOL = spotPool;
        FEE_TIER = feeTier;
    }

    receive() external payable {}

    // ─── manager hook (called by InstanceSale.seedLiquidityManager) ──────

    function initializeFromSale(uint256 faoAmount, bytes calldata /* spotAddData */)
        external
        payable
        override
        returns (uint128 liquidityMinted)
    {
        if (msg.sender != SALE) revert OnlySale();

        if (msg.value > 0) {
            ISpotSeederWETH9(WETH).deposit{value: msg.value}();
        }

        ISpotSeederERC20(FAO).approve(NPM, faoAmount);
        ISpotSeederWETH9(WETH).approve(NPM, msg.value);

        bool faoFirst = FAO < WETH;

        if (lpTokenId == 0) {
            ISpotSeederNPM.MintParams memory params = ISpotSeederNPM.MintParams({
                token0: faoFirst ? FAO : WETH,
                token1: faoFirst ? WETH : FAO,
                fee: FEE_TIER,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: faoFirst ? faoAmount : msg.value,
                amount1Desired: faoFirst ? msg.value : faoAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 600
            });
            uint256 tokenId;
            (tokenId, liquidityMinted,,) = ISpotSeederNPM(NPM).mint(params);
            lpTokenId = tokenId;
        } else {
            ISpotSeederNPM.IncreaseLiquidityParams memory params = ISpotSeederNPM.IncreaseLiquidityParams({
                tokenId: lpTokenId,
                amount0Desired: faoFirst ? faoAmount : msg.value,
                amount1Desired: faoFirst ? msg.value : faoAmount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600
            });
            (liquidityMinted,,) = ISpotSeederNPM(NPM).increaseLiquidity(params);
        }

        // Mint pro-rata-claim ERC20 shares to the sale. The sale's
        // ragequit() distributes these to ragequitting users.
        _mint(SALE, liquidityMinted);

        emit Seeded(faoAmount, msg.value, liquidityMinted, lpTokenId);
    }

    // ─── redeem: fLP → underlying FAO + WETH ────────────────────────────

    /// @notice Burn `fLPAmount` of fLP and withdraw a pro-rata slice of the
    ///         pooled UniV3 liquidity back to the caller as FAO + WETH.
    /// @dev Pro-rata = current position liquidity × (fLPAmount / fLP total
    ///      supply). Reads the live liquidity from NPM so external
    ///      `decreaseLiquidity` (none possible here — only this contract is
    ///      owner) doesn't desync the math.
    function redeem(uint256 fLPAmount) external returns (uint256 amount0, uint256 amount1) {
        require(fLPAmount > 0, "fLPAmount=0");
        require(lpTokenId > 0, "no LP position yet");

        // Snapshot total fLP supply BEFORE we burn, so the slice is taken
        // against the pre-burn supply (matches Compound-style mint/redeem
        // accounting).
        uint256 supplyBefore = totalSupply();
        (,,,,,,, uint128 currentLiq,,,,) = ISpotSeederNPM(NPM).positions(lpTokenId);

        uint128 toRemove = uint128((uint256(currentLiq) * fLPAmount) / supplyBefore);
        require(toRemove > 0, "slice rounds to zero");

        _burn(msg.sender, fLPAmount);

        // Decrease liquidity moves the underlying into `tokensOwed*`; collect
        // sweeps it out to the recipient.
        ISpotSeederNPM(NPM).decreaseLiquidity(
            ISpotSeederNPM.DecreaseLiquidityParams({
                tokenId: lpTokenId,
                liquidity: toRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 600
            })
        );

        (amount0, amount1) = ISpotSeederNPM(NPM).collect(
            ISpotSeederNPM.CollectParams({
                tokenId: lpTokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit Redeemed(msg.sender, fLPAmount, amount0, amount1);
    }

    /// @notice Quote the FAO + WETH the caller would receive from a redeem
    ///         of `fLPAmount`. UI price-comparison helper. Reads the pool's
    ///         current sqrtPriceX96 isn't needed here — we just split the
    ///         current uncollected position pro-rata.
    function quoteRedeem(uint256 fLPAmount) external view returns (uint128 liquidityToRemove) {
        if (fLPAmount == 0 || lpTokenId == 0) return 0;
        uint256 supplyNow = totalSupply();
        if (supplyNow == 0) return 0;
        (,,,,,,, uint128 currentLiq,,,,) = ISpotSeederNPM(NPM).positions(lpTokenId);
        liquidityToRemove = uint128((uint256(currentLiq) * fLPAmount) / supplyNow);
    }

    /// @notice Admin escape hatch: move the LP NFT out (e.g. into a Safe).
    ///         Skips the ragequit/redeem accounting; only useful for testnet
    ///         winddown. Production should leave the NFT here.
    function sweepLP(address recipient) external {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        if (lpTokenId == 0) revert NoPositionYet();
        ISpotSeederNPM(NPM).safeTransferFrom(address(this), recipient, lpTokenId);
    }

    // ─── ERC-721 receiver (NPM mints LP NFT to us via safeTransfer) ─────

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
