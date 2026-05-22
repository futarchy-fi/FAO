// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FAOOfficialProposalOrchestrator} from "../src/FAOOfficialProposalOrchestrator.sol";
import {FAOFutarchyFactory} from "../src/FAOFutarchyFactory.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../src/interfaces/IUniswapV3PoolLike.sol";
import {IFAOFutarchyTwapResolver} from "../src/interfaces/IFAOFutarchyOracle.sol";

contract SymbolicUniV3Pool is IUniswapV3PoolLike {
    address internal immutable TOKEN0;
    address internal immutable TOKEN1;
    uint24 internal immutable POOL_FEE;
    uint160 internal sqrtPriceX96_;

    constructor(address token0_, address token1_, uint24 fee_, uint160 sqrtPriceX96) {
        TOKEN0 = token0_;
        TOKEN1 = token1_;
        POOL_FEE = fee_;
        sqrtPriceX96_ = sqrtPriceX96;
    }

    function token0() external view returns (address) {
        return TOKEN0;
    }

    function token1() external view returns (address) {
        return TOKEN1;
    }

    function fee() external view returns (uint24) {
        return POOL_FEE;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (sqrtPriceX96_, 0, 0, 1, 1, 0, true);
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(sqrtPriceX96_ == 0, "already initialized");
        sqrtPriceX96_ = sqrtPriceX96;
    }

    function increaseObservationCardinalityNext(uint16) external pure {}

    function observe(uint32[] calldata secondsAgos)
        external
        pure
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        return (new int56[](secondsAgos.length), new uint160[](secondsAgos.length));
    }

    function mint(address, int24, int24, uint128, bytes calldata)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return (0, 0);
    }
}

contract SymbolicUniV3Factory is IUniswapV3FactoryLike {
    mapping(address => mapping(address => mapping(uint24 => address))) internal pools;

    constructor(address tokenA, address tokenB, uint24 fee, address pool) {
        (address token0, address token1) = _sort(tokenA, tokenB);
        pools[token0][token1][fee] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        return pools[token0][token1][fee];
    }

    function createPool(address tokenA, address tokenB, uint24 fee)
        external
        returns (address pool)
    {
        (address token0, address token1) = _sort(tokenA, tokenB);
        require(pools[token0][token1][fee] == address(0), "pool exists");
        pool = address(new SymbolicUniV3Pool(token0, token1, fee, 0));
        pools[token0][token1][fee] = pool;
    }

    function _sort(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}

contract ExposedFAOOfficialProposalOrchestrator is FAOOfficialProposalOrchestrator {
    constructor(
        address admin,
        IUniswapV3FactoryLike univ3Factory,
        address spotPool,
        address companyToken,
        address currencyToken,
        uint24 feeTier
    )
        FAOOfficialProposalOrchestrator(
            admin,
            FAOFutarchyFactory(address(0xFACADE)),
            univ3Factory,
            spotPool,
            companyToken,
            currencyToken,
            feeTier,
            5,
            IFAOFutarchyTwapResolver(address(0x1234)),
            true
        )
    {}

    function exposedMaybeCreatePoolAndInit(
        address companyWrap,
        address currencyWrap,
        uint160 sqrtCurrencyPerCompanyX96
    ) external returns (address) {
        return _maybeCreatePoolAndInit(companyWrap, currencyWrap, sqrtCurrencyPerCompanyX96, 0);
    }
}

/// @custom:spec INV-ORCH-002 - pre-initialized pools are refused.
/// Halmos-checkable symbolic tests for the invariants listed in
/// `audit/specs/INVARIANTS.md`.
contract FAOOfficialProposalOrchestratorSymbolic is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant SPOT_POOL = address(0x5000);
    address internal constant COMPANY_TOKEN = address(0x1000);
    address internal constant CURRENCY_TOKEN = address(0x2000);
    address internal constant COMPANY_WRAP = address(0x3000);
    address internal constant CURRENCY_WRAP = address(0x4000);
    uint24 internal constant FEE_TIER = 500;
    uint160 internal constant SQRT_PRICE_X96 = uint160(1 << 96);

    /// @custom:spec INV-ORCH-002 - See audit/specs/INVARIANTS.md.
    /// If the deterministic conditional pool already exists and is initialized, promotion refuses
    /// it.
    function check_INV_ORCH_002_refusesPreInit() public {
        SymbolicUniV3Pool hostilePool =
            new SymbolicUniV3Pool(COMPANY_WRAP, CURRENCY_WRAP, FEE_TIER, SQRT_PRICE_X96);
        SymbolicUniV3Factory univ3Factory =
            new SymbolicUniV3Factory(COMPANY_WRAP, CURRENCY_WRAP, FEE_TIER, address(hostilePool));
        ExposedFAOOfficialProposalOrchestrator orch = new ExposedFAOOfficialProposalOrchestrator(
            ADMIN,
            IUniswapV3FactoryLike(address(univ3Factory)),
            SPOT_POOL,
            COMPANY_TOKEN,
            CURRENCY_TOKEN,
            FEE_TIER
        );

        (uint160 preSqrtPriceX96,,,,,,) = hostilePool.slot0();
        assertGt(preSqrtPriceX96, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                FAOOfficialProposalOrchestrator.PreCreated.selector, address(hostilePool)
            )
        );
        vm.prank(ADMIN);
        orch.exposedMaybeCreatePoolAndInit(COMPANY_WRAP, CURRENCY_WRAP, SQRT_PRICE_X96);

        (uint160 postSqrtPriceX96,,,,,,) = hostilePool.slot0();
        assertEq(postSqrtPriceX96, preSqrtPriceX96);
    }
}
