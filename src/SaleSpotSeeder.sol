// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityManager} from "./interfaces/IFutarchyLiquidityManager.sol";

interface ISpotSeederERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ISpotSeederWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
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
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Minimal `IFutarchyLiquidityManager` that takes FAO + native ETH from
/// the FAOSale's `seedLiquidityManager(...)` and routes them as full-range LP
/// into the FAO/WETH UniV3 spot pool. Testnet v0 only — the heavyweight
/// `FutarchyLiquidityManager` in the codebase tracks fLP shares, conditional
/// migration, emergency mode, etc., which we don't need to demo the
/// "FAOSale → liquidez_spot" flow.
contract SaleSpotSeeder is IFutarchyLiquidityManager {
    address public immutable SALE;
    address public immutable ADMIN;
    address public immutable FAO;
    address public immutable WETH;
    address public immutable NPM;
    address public immutable SPOT_POOL;
    uint24  public immutable FEE_TIER;

    int24 public constant TICK_LOWER = -887270;
    int24 public constant TICK_UPPER =  887270;

    uint256 public totalFaoSeeded;
    uint256 public totalNativeSeeded;
    uint128 public totalLiquidityMinted;
    uint256[] public lpTokenIds;

    event Seeded(uint256 faoAmount, uint256 nativeAmount, uint128 liquidity, uint256 tokenId);
    event LPSwept(uint256 tokenId, address recipient);

    error OnlySale();
    error OnlyAdmin();

    constructor(
        address sale,
        address admin,
        address fao,
        address weth,
        address npm,
        address spotPool,
        uint24 feeTier
    ) {
        SALE = sale;
        ADMIN = admin;
        FAO = fao;
        WETH = weth;
        NPM = npm;
        SPOT_POOL = spotPool;
        FEE_TIER = feeTier;
    }

    receive() external payable {}

    function initializeFromSale(uint256 faoAmount, bytes calldata /* spotAddData */)
        external
        payable
        returns (uint128 liquidityMinted)
    {
        if (msg.sender != SALE) revert OnlySale();

        if (msg.value > 0) {
            ISpotSeederWETH9(WETH).deposit{value: msg.value}();
        }

        ISpotSeederERC20(FAO).approve(NPM, faoAmount);
        ISpotSeederWETH9(WETH).approve(NPM, msg.value);

        bool faoFirst = FAO < WETH;
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

        totalFaoSeeded += faoAmount;
        totalNativeSeeded += msg.value;
        totalLiquidityMinted += liquidityMinted;
        lpTokenIds.push(tokenId);

        emit Seeded(faoAmount, msg.value, liquidityMinted, tokenId);
    }

    /// @notice Admin sweep: move an LP NFT out of the seeder (e.g. to a multisig
    /// or to manually re-stake). Does not modify any tracking counters.
    function sweepLP(uint256 tokenId, address recipient) external {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        ISpotSeederNPM(NPM).safeTransferFrom(address(this), recipient, tokenId);
        emit LPSwept(tokenId, recipient);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function lpTokenIdsCount() external view returns (uint256) {
        return lpTokenIds.length;
    }
}
