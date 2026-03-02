'use client';

import { useState } from 'react';
import { formatEther } from 'viem';
import { PieChart, Pie, Cell, Tooltip, ResponsiveContainer } from 'recharts';
import { useTokenDistribution } from '../hooks/useFAOQuoter';

/**
 * Format large numbers with K/M/B suffix
 */
function formatNumber(num) {
    if (!num) return '0';
    const n = Number(num);
    if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
    if (n >= 1e3) return (n / 1e3).toFixed(2) + 'K';
    return n.toLocaleString();
}

/**
 * Custom tooltip for pie chart
 */
function CustomTooltip({ active, payload }) {
    if (!active || !payload?.length) return null;

    const data = payload[0].payload;
    return (
        <div className="bg-black border border-white/40 px-3 py-2 shadow-lg">
            <div className="font-pixel text-[8px] opacity-60 uppercase tracking-widest mb-1">
                {data.label}
            </div>
            <div className="font-mono text-sm font-bold">
                {formatNumber(data.value)} <span className="text-[10px] opacity-50">FAO</span>
            </div>
            <div className="font-mono text-[10px] opacity-40">
                {data.percentage.toFixed(1)}% of total
            </div>
        </div>
    );
}

/**
 * TokenDistribution - Live on-chain token allocation visualization
 * Shows pie chart of FAO distribution: Treasury, Incentive, Insider, Circulating
 */
export default function TokenDistribution() {
    const [activeIndex, setActiveIndex] = useState(null);
    const {
        totalSupply,
        treasuryBalance,
        incentiveBalance,
        insiderBalance,
        circulatingSupply,
        isPhaseFinalized,
        incentiveAddress,
        insiderAddress,
        isLoading,
        lastUpdated
    } = useTokenDistribution();

    // Convert from wei (1e18) to whole tokens for display
    const toWholeTokens = (wei) => {
        if (!wei || wei === 0n) return 0;
        return Number(formatEther(wei));
    };

    const total = toWholeTokens(totalSupply);
    const treasury = toWholeTokens(treasuryBalance);
    const incentive = toWholeTokens(incentiveBalance);
    const insider = toWholeTokens(insiderBalance);
    const circulating = toWholeTokens(circulatingSupply);

    // Build pie chart data (only include non-zero allocations)
    const items = [
        { id: 'circulating', label: 'Public Liquidity', value: circulating, color: '#ffffff', icon: '👤' },
        { id: 'treasury', label: 'FAO Treasury', value: treasury, color: '#888888', icon: '🏦' },
        { id: 'incentive', label: 'Incentive Buffer', value: incentive, color: '#555555', icon: '🎁' },
        { id: 'insider', label: 'Guardian Vesting', value: insider, color: '#333333', icon: '🔐' },
    ].filter(item => item.value > 0).map(item => ({
        ...item,
        percentage: total > 0 ? (item.value / total) * 100 : 0
    }));

    const COLORS = items.map(i => i.color);

    const handlePieEnter = (_, index) => setActiveIndex(index);
    const handlePieLeave = () => setActiveIndex(null);

    return (
        <div className="w-full bg-black p-4 border border-white/10">
            <div className="flex items-center justify-between mb-6">
                <h3 className="font-pixel text-[10px] uppercase tracking-[0.3em] text-white/40">
                    /TOKEN_EMISSION_DISTRIBUTION_MAP
                </h3>
                {lastUpdated && (
                    <span className="font-mono text-[8px] opacity-30">
                        LIVE_DATA: {lastUpdated.toLocaleTimeString()}
                    </span>
                )}
            </div>

            {isLoading ? (
                <div className="h-64 flex items-center justify-center">
                    <span className="font-pixel text-[10px] opacity-40 animate-pulse">SYNCING_ONCHAIN_DATA...</span>
                </div>
            ) : total === 0 ? (
                <div className="h-64 flex items-center justify-center">
                    <span className="font-pixel text-[10px] opacity-40">NO_TOKENS_MINTED_YET</span>
                </div>
            ) : (
                <div className="flex flex-col lg:flex-row gap-8 items-center">
                    {/* Pie Chart */}
                    <div className="w-full lg:w-1/2 h-64">
                        <ResponsiveContainer width="100%" height="100%">
                            <PieChart>
                                <Pie
                                    data={items}
                                    dataKey="value"
                                    nameKey="label"
                                    cx="50%"
                                    cy="50%"
                                    innerRadius={50}
                                    outerRadius={80}
                                    stroke="#000"
                                    strokeWidth={2}
                                    onMouseEnter={handlePieEnter}
                                    onMouseLeave={handlePieLeave}
                                    animationBegin={0}
                                    animationDuration={800}
                                >
                                    {items.map((entry, index) => (
                                        <Cell
                                            key={entry.id}
                                            fill={COLORS[index]}
                                            style={{
                                                filter: activeIndex === index ? 'brightness(1.3)' : 'none',
                                                transform: activeIndex === index ? 'scale(1.05)' : 'scale(1)',
                                                transformOrigin: 'center',
                                                transition: 'all 0.2s ease'
                                            }}
                                        />
                                    ))}
                                </Pie>
                                <Tooltip content={<CustomTooltip />} />
                            </PieChart>
                        </ResponsiveContainer>
                    </div>

                    {/* Legend / Stats */}
                    <div className="w-full lg:w-1/2 grid grid-cols-1 gap-3">
                        {items.map((item, i) => (
                            <div
                                key={item.id}
                                className={`flex items-center justify-between p-3 border border-white/10 bg-white/2 group hover:bg-white hover:text-black transition-all duration-300 ${activeIndex === i ? 'bg-white/10' : ''}`}
                                onMouseEnter={() => setActiveIndex(i)}
                                onMouseLeave={() => setActiveIndex(null)}
                            >
                                <div className="flex items-center gap-3">
                                    <div
                                        className="w-3 h-3 border border-black/20"
                                        style={{ backgroundColor: item.color }}
                                    />
                                    <span className="text-lg filter grayscale group-hover:invert transition-all">{item.icon}</span>
                                    <div className="flex flex-col">
                                        <span className="font-pixel text-[7px] opacity-40 uppercase tracking-widest">{item.label}</span>
                                        <span className="font-mono text-sm font-black tracking-tighter">
                                            {formatNumber(item.value)} <span className="text-[9px] opacity-40">FAO</span>
                                        </span>
                                    </div>
                                </div>
                                <div className="text-right font-pixel text-xs font-bold bg-white/5 px-2 py-1 group-hover:bg-black/10">
                                    {item.percentage.toFixed(1)}%
                                </div>
                            </div>
                        ))}
                    </div>
                </div>
            )}

            {/* Tokenomics Explainer */}
            <div className="mt-8 p-4 border border-white/10 bg-white/2">
                <h4 className="font-pixel text-[8px] uppercase tracking-[0.2em] opacity-50 mb-3">
                    /EMISSION_MECHANICS
                </h4>

                {/* Minting Ratio */}
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-[11px] font-mono opacity-70 mb-4">
                    <div>
                        <div className="font-bold mb-1 text-white/90">Minting Ratio:</div>
                        <div className="leading-relaxed">
                            For every <span className="text-white font-bold">1 FAO sold</span> →{' '}
                            <span className="text-white font-bold">2 FAO minted</span>
                        </div>
                    </div>
                    <div>
                        <div className="font-bold mb-1 text-white/90">Per-Sale Allocation:</div>
                        <div className="leading-relaxed space-y-0.5">
                            <div>• 1.0 FAO → Buyer</div>
                            <div>• 0.5 FAO → Treasury</div>
                            <div>• 0.2 FAO → Incentive</div>
                            <div>• 0.3 FAO → Guardians</div>
                        </div>
                    </div>
                </div>

                {/* Phase Minting Mechanics */}
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4 p-3 bg-white/5 border border-white/10 text-[10px] font-mono">
                    <div className={`p-2 ${!isPhaseFinalized ? 'border-l-2 border-blue-500 bg-blue-500/5' : 'opacity-60'}`}>
                        <div className="font-bold text-blue-400 mb-1">PHASE_0: FIXED_PRICE</div>
                        <div className="text-white/60 leading-relaxed">
                            <span className="text-white">Only buyer tokens minted</span> during purchases.
                            Pool allocations (Treasury, Incentive, Guardians) are <span className="text-yellow-400">deferred</span> and
                            minted in bulk when phase finalizes.
                        </div>
                    </div>
                    <div className={`p-2 ${isPhaseFinalized ? 'border-l-2 border-green-500 bg-green-500/5' : 'opacity-60'}`}>
                        <div className="font-bold text-green-400 mb-1">PHASE_1: BONDING_CURVE</div>
                        <div className="text-white/60 leading-relaxed">
                            <span className="text-white">All tokens minted immediately</span> per sale.
                            Buyer + Treasury + Incentive + Guardians receive allocations in real-time.
                        </div>
                    </div>
                </div>

                {/* Current Phase Status */}
                <div className="mt-3 text-[10px] font-mono">
                    <span className={`px-2 py-1 ${isPhaseFinalized ? 'bg-green-900/30 text-green-400' : 'bg-blue-900/30 text-blue-400'}`}>
                        {isPhaseFinalized ? 'PHASE_1: BONDING_CURVE_ACTIVE' : 'PHASE_0: FIXED_PRICE_ACTIVE'}
                    </span>
                </div>
            </div>

            {/* Contract Addresses */}
            <div className="mt-4 p-3 border border-white/10 bg-white/2">
                <h4 className="font-pixel text-[8px] uppercase tracking-[0.2em] opacity-50 mb-3">
                    /POOL_CONTRACTS
                </h4>
                <div className="space-y-2 text-[10px] font-mono">
                    {/* Incentive Contract */}
                    <div className="flex items-center justify-between p-2 bg-white/5 border border-white/5">
                        <div className="flex items-center gap-2">
                            <span className="text-lg">🎁</span>
                            <span className="text-white/60">INCENTIVE_CONTRACT:</span>
                        </div>
                        {incentiveAddress && incentiveAddress !== '0x0000000000000000000000000000000000000000' ? (
                            <a
                                href={`https://gnosisscan.io/address/${incentiveAddress}`}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="text-blue-400 hover:text-blue-300 hover:underline transition-colors"
                            >
                                {incentiveAddress.slice(0, 8)}...{incentiveAddress.slice(-6)} ↗
                            </a>
                        ) : (
                            <span className="text-white/30 italic">NOT_SET</span>
                        )}
                    </div>

                    {/* Insider/Guardian Contract */}
                    <div className="flex items-center justify-between p-2 bg-white/5 border border-white/5">
                        <div className="flex items-center gap-2">
                            <span className="text-lg">🔐</span>
                            <span className="text-white/60">GUARDIAN_VESTING:</span>
                        </div>
                        {insiderAddress && insiderAddress !== '0x0000000000000000000000000000000000000000' ? (
                            <a
                                href={`https://gnosisscan.io/address/${insiderAddress}`}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="text-blue-400 hover:text-blue-300 hover:underline transition-colors"
                            >
                                {insiderAddress.slice(0, 8)}...{insiderAddress.slice(-6)} ↗
                            </a>
                        ) : (
                            <span className="text-white/30 italic">NOT_SET</span>
                        )}
                    </div>
                </div>
            </div>

            {/* RAGEQUIT FORMULA - Important User Info */}
            <div className="mt-4 p-4 border-2 border-green-500/30 bg-green-500/5">
                <h4 className="font-pixel text-[10px] uppercase tracking-[0.2em] text-green-400 mb-3 flex items-center gap-2">
                    <span className="text-xl">🛡️</span>
                    /RAGEQUIT_GUARANTEE
                </h4>

                {/* Formula Display */}
                <div className="p-4 bg-black border border-green-500/20 mb-4">
                    <div className="font-mono text-center">
                        <div className="text-[9px] text-white/40 mb-2 uppercase tracking-wider">Your Exit Value Formula</div>
                        <div className="text-lg md:text-xl text-green-400 font-bold tracking-wide">
                            xDAI_Return = Treasury × (Your_FAO / <span className="text-white underline decoration-green-500">Effective_Supply</span>)
                        </div>
                    </div>
                </div>

                {/* Key Explanation */}
                <div className="space-y-3 text-[11px] font-mono">
                    <div className="p-3 bg-green-500/10 border-l-4 border-green-500">
                        <div className="font-bold text-green-400 mb-1">✓ EFFECTIVE SUPPLY = PUBLIC LIQUIDITY ONLY</div>
                        <div className="text-white/80 leading-relaxed">
                            Your share is calculated against <span className="text-white font-bold">only public holder tokens</span> -
                            NOT total supply. Treasury, Incentive, and Guardian tokens are <span className="text-green-400 font-bold">excluded</span> from the denominator.
                        </div>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                        <div className="p-2 bg-white/5 border border-white/10">
                            <div className="text-[9px] text-white/40 uppercase mb-1">What's Included (Denominator)</div>
                            <div className="text-white">
                                <span className="text-green-400">✓</span> Your tokens +{' '}
                                <span className="text-green-400">✓</span> Other public holders
                            </div>
                        </div>
                        <div className="p-2 bg-white/5 border border-white/10">
                            <div className="text-[9px] text-white/40 uppercase mb-1">What's Excluded (Denominator)</div>
                            <div className="text-white/60">
                                <span className="text-red-400">✗</span> Treasury /{' '}
                                <span className="text-red-400">✗</span> Incentive /{' '}
                                <span className="text-red-400">✗</span> Guardians
                            </div>
                        </div>
                    </div>

                    <div className="text-[10px] text-white/50 pt-2 border-t border-white/10">
                        <strong className="text-green-400">Why this matters:</strong> You're not competing against locked protocol tokens.
                        Your pro-rata share of the treasury is calculated fairly among active public participants only.
                    </div>
                </div>
            </div>

            {/* Footer */}
            <div className="mt-4 pt-3 border-t border-white/10 text-white/30 font-mono text-[9px] italic uppercase tracking-widest">
                TOTAL_SUPPLY: {formatNumber(total)} FAO
            </div>
        </div>
    );
}
