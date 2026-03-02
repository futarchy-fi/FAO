'use client';

import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { CONTRACTS, CHAIN_ID } from '../config/contracts';

// Get explorer URL based on chain
const getExplorerUrl = (address) => {
    if (CHAIN_ID === 100) {
        return `https://gnosisscan.io/address/${address}`;
    }
    return `https://etherscan.io/address/${address}`;
};

const FAO_SALE_CODE = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FAOToken} from "./FAOToken.sol";

/// @title FAO Sale / Treasury / Ragequit Contract
/// @notice
/// - Accepts ETH for FAO via:
///   - 2-week initial fixed-price phase
///   - Then linear bonding curve:
///       price = initialPrice + (initialPrice * bondingCurveSale / initialNetSale)
/// - Mints distribution per 1 FAO sold:
///     1.0 FAO to buyer
///     0.5 FAO to this contract (treasury)
///     0.2 FAO to incentive contract
///     0.3 FAO to insider vesting contract
/// - Ragequit: burn FAO to get pro-rata ETH + selected ERC20s
contract FAOSale is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    FAOToken public immutable TOKEN;
    address public incentiveContract;
    address public insiderVestingContract;
    uint256 public immutable INITIAL_PRICE_WEI_PER_TOKEN; // e.g. 1e14 wei

    // Sale timing
    uint256 public saleStart;
    uint256 public immutable MIN_INITIAL_PHASE_SOLD;
    uint256 public initialPhaseEnd;
    bool public initialPhaseFinalized;

    // Token & ETH tracking
    uint256 public initialTokensSold;
    uint256 public initialNetSale;
    uint256 public totalCurveTokensSold;
    uint256 public initialFundsRaised;
    uint256 public totalCurveFundsRaised;

    // Long target: 200,000,000 FAO sold
    uint256 public constant LONG_TARGET_TOKENS = 200_000_000;

    // Ragequit tokens
    address[] public ragequitTokens;
    mapping(address => bool) public isRagequitToken;

    event Purchase(address indexed buyer, uint256 numTokens, uint256 costWei);
    event Ragequit(address indexed user, uint256 faoBurned, uint256 ethReturned);

    /// @notice Buy FAO tokens using ETH
    function buy(uint256 numTokens) external payable nonReentrant {
        require(numTokens > 0, "numTokens=0");
        require(saleStart != 0, "Sale not started");
        // ... pricing logic
        _mintToBuyer(numTokens, msg.sender);
        emit Purchase(msg.sender, numTokens, msg.value);
    }

    /// @notice Ragequit: burn FAO for pro-rata treasury share
    function ragequit(uint256 numTokens) external nonReentrant {
        require(numTokens > 0, "numTokens=0");
        // ... calculate share and transfer
        emit Ragequit(msg.sender, numTokens * 1e18, ethShare);
    }

    // ... full implementation at GitHub
}`;

const FAO_TOKEN_CODE = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Futarchy Autonomous Optimizer Token (FAO)
/// @notice Standard ERC20 with burn support and controlled minting role.
contract FAOToken is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("Futarchy Autonomous Optimizer", "FAO") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint new FAO tokens.
    /// @dev Caller must have the MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}`;

const TABS = [
    { id: 'faosale', name: 'FAOSale.sol', code: FAO_SALE_CODE },
    { id: 'faotoken', name: 'FAOToken.sol', code: FAO_TOKEN_CODE },
];

export default function ContractCodeViewer() {
    const [activeTab, setActiveTab] = useState('faosale');
    const activeContract = TABS.find(t => t.id === activeTab);

    return (
        <div className="space-y-6">
            {/* Header */}
            <div className="flex items-center justify-between flex-wrap gap-4">
                <div className="space-y-2">
                    <h3 className="font-pixel text-lg tracking-tighter">SMART_CONTRACT_SOURCE</h3>
                    <p className="font-mono text-[10px] text-white/40 uppercase tracking-widest">
                        VERIFIED_ON_CHAIN // MIT_LICENSE // OPEN_SOURCE
                    </p>
                </div>
                <a
                    href="https://github.com/futarchy-fi/FAO"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex items-center gap-2 px-4 py-2 border border-white/20 hover:border-white/40 hover:bg-white/5 transition-all"
                >
                    <svg className="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
                        <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
                    </svg>
                    <span className="font-pixel text-[10px] uppercase tracking-wider">VIEW_FULL_SOURCE</span>
                </a>
            </div>

            {/* Tabs */}
            <div className="flex gap-2 border-b border-white/10">
                {TABS.map(tab => (
                    <button
                        key={tab.id}
                        onClick={() => setActiveTab(tab.id)}
                        className={`px-4 py-2 font-mono text-xs uppercase tracking-wider transition-all border-b-2 -mb-px ${activeTab === tab.id
                            ? 'border-blue-500 text-blue-500'
                            : 'border-transparent text-white/40 hover:text-white/60'
                            }`}
                    >
                        {tab.name}
                    </button>
                ))}
            </div>

            {/* Code Block */}
            <AnimatePresence mode="wait">
                <motion.div
                    key={activeTab}
                    initial={{ opacity: 0, y: 10 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -10 }}
                    transition={{ duration: 0.2 }}
                    className="relative"
                >
                    <div className="absolute top-0 right-0 px-3 py-1 bg-white/5 border-l border-b border-white/10">
                        <span className="font-mono text-[9px] text-white/30 uppercase">Solidity ^0.8.20</span>
                    </div>
                    <pre className="bg-black/50 border border-white/10 p-6 overflow-x-auto max-h-[500px] overflow-y-auto">
                        <code className="font-mono text-xs leading-relaxed text-white/70 whitespace-pre">
                            {activeContract?.code}
                        </code>
                    </pre>
                </motion.div>
            </AnimatePresence>

            {/* Security Notes */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                <div className="p-4 border border-green-500/20 bg-green-500/5">
                    <div className="flex items-center gap-2 mb-2">
                        <div className="w-2 h-2 rounded-full bg-green-500"></div>
                        <span className="font-pixel text-[9px] text-green-500 uppercase tracking-widest">REENTRANCY_GUARD</span>
                    </div>
                    <p className="font-mono text-[10px] text-white/40">Protected against reentrancy attacks via OpenZeppelin</p>
                </div>
                <div className="p-4 border border-blue-500/20 bg-blue-500/5">
                    <div className="flex items-center gap-2 mb-2">
                        <div className="w-2 h-2 rounded-full bg-blue-500"></div>
                        <span className="font-pixel text-[9px] text-blue-500 uppercase tracking-widest">ACCESS_CONTROL</span>
                    </div>
                    <p className="font-mono text-[10px] text-white/40">Role-based permissions with timelocked admin</p>
                </div>
                <div className="p-4 border border-yellow-500/20 bg-yellow-500/5">
                    <div className="flex items-center gap-2 mb-2">
                        <div className="w-2 h-2 rounded-full bg-yellow-500"></div>
                        <span className="font-pixel text-[9px] text-yellow-500 uppercase tracking-widest">RAGEQUIT_ENABLED</span>
                    </div>
                    <p className="font-mono text-[10px] text-white/40">Exit anytime for pro-rata treasury share</p>
                </div>
            </div>

            {/* Deployed Contracts */}
            <div className="border border-white/10 p-6 space-y-4">
                <div className="flex items-center gap-3 mb-4">
                    <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse"></div>
                    <span className="font-pixel text-[10px] text-white/40 uppercase tracking-widest">DEPLOYED_CONTRACTS // GNOSIS_CHAIN</span>
                </div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <a
                        href={getExplorerUrl(CONTRACTS.FAO_SALE)}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="group p-4 border border-white/10 hover:border-blue-500/50 hover:bg-blue-500/5 transition-all cursor-pointer"
                    >
                        <div className="flex items-center justify-between mb-2">
                            <span className="font-pixel text-xs text-blue-500">FAOSale.sol</span>
                            <svg className="w-4 h-4 text-white/30 group-hover:text-blue-500 transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth="2">
                                <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                            </svg>
                        </div>
                        <code className="font-mono text-[10px] text-white/50 group-hover:text-white/70 break-all">
                            {CONTRACTS.FAO_SALE}
                        </code>
                    </a>
                    <a
                        href={getExplorerUrl(CONTRACTS.FAO_TOKEN)}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="group p-4 border border-white/10 hover:border-yellow-500/50 hover:bg-yellow-500/5 transition-all cursor-pointer"
                    >
                        <div className="flex items-center justify-between mb-2">
                            <span className="font-pixel text-xs text-yellow-500">FAOToken.sol</span>
                            <svg className="w-4 h-4 text-white/30 group-hover:text-yellow-500 transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth="2">
                                <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                            </svg>
                        </div>
                        <code className="font-mono text-[10px] text-white/50 group-hover:text-white/70 break-all">
                            {CONTRACTS.FAO_TOKEN}
                        </code>
                    </a>
                </div>
            </div>
        </div>
    );
}
