// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FaoToken} from "../../src/FaoToken.sol";

interface IMockShortPool {
    function onRagequit(address recipient, uint256 amount, uint256 supply)
        external
        returns (uint256);
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Pool that accumulates its tick over time like Uniswap v3. "Now" is exact; older points
/// assume the current tick was in force, which is enough for the 30-minute average in tests.
contract MockPool {
    int24 public tick;
    int56 public cumulative;
    uint256 public lastUpdate;

    constructor() {
        lastUpdate = block.timestamp;
    }

    function setTick(int24 tick_) external {
        cumulative += int56(tick) * int56(uint56(block.timestamp - lastUpdate));
        lastUpdate = block.timestamp;
        tick = tick_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory liquidity)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        liquidity = new uint160[](secondsAgos.length);
        int56 nowCumulative = cumulative + int56(tick) * int56(uint56(block.timestamp - lastUpdate));
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = nowCumulative - int56(tick) * int56(uint56(secondsAgos[i]));
        }
    }
}

contract MockFactory {
    address public pool;

    function setPool(address pool_) external {
        pool = pool_;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

/// @dev Stand-in for GenesisVault: deploys the token, holds the treasury itself, and pays a
/// WETH-only pro-rata ragequit over (totalSupply - shortOutstanding), which is the one-line
/// change the real vault's effectiveSupply() gets.
contract MockVault {
    uint8 public phase;
    uint256 public totalSold;
    uint256 public terminalPrice;
    /// @dev The fixed sale price; this mock also stands in for the sale curve.
    uint256 public INITIAL_PRICE;
    FaoToken public token;
    IERC20 public weth;

    address private _burnAccount;
    uint256 private _burnAmount;

    constructor(IERC20 weth_, address optionIssuer, address shortIssuer) {
        weth = weth_;
        token =
            new FaoToken("FAO", "FAO", address(this), type(uint128).max, optionIssuer, shortIssuer);
    }

    function COMPANY_TOKEN() external view returns (address) {
        return address(token);
    }

    function TREASURY_EXECUTOR() external view returns (address) {
        return address(this);
    }

    function WETH() external view returns (address) {
        return address(weth);
    }

    function CURVE() external view returns (address) {
        return address(this);
    }

    function goLive(uint256 sold, uint256 price) external {
        totalSold = sold;
        terminalPrice = price;
        INITIAL_PRICE = price;
        phase = 2;
    }

    function setTerminalPrice(uint256 price) external {
        terminalPrice = price;
    }

    function mintTo(address to, uint256 amount) external {
        token.mint(to, amount);
    }

    function effectiveSupply() public view returns (uint256) {
        return token.totalSupply();
    }

    /// @dev WETH-only ragequit: the caller's fraction of this treasury, then the same fraction
    /// of the short facility's locked pool, as the real vault does.
    function ragequit(uint256 amount) external returns (uint256 payout) {
        uint256 supply = effectiveSupply();
        require(supply != 0 && amount <= supply, "effective supply");
        payout = weth.balanceOf(address(this)) * amount / supply;
        _burnAccount = msg.sender;
        _burnAmount = amount;
        token.burnFromVault(msg.sender, amount);
        weth.transfer(msg.sender, payout);
        address shortIssuer = token.shortIssuer();
        if (shortIssuer != address(0)) {
            payout += IMockShortPool(shortIssuer).onRagequit(msg.sender, amount, supply);
        }
    }

    function consumeTokenBurnAuthorization(address account, uint256 amount) external {
        require(
            msg.sender == address(token) && account == _burnAccount && amount == _burnAmount,
            "burn auth"
        );
        _burnAccount = address(0);
        _burnAmount = 0;
    }
}
