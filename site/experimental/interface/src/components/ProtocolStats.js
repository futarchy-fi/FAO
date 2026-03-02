'use client';

import { useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useBalance, useReadContract } from 'wagmi';
import { formatEther } from 'viem';
import { useSubgraphData } from '../hooks/useSubgraphData';

import { useFAOQuoter } from '../hooks/useFAOQuoter';
import { FAO_SALE_ADDRESS, FAO_TOKEN_ADDRESS } from '../hooks/useFAOContract';
import FAOTokenABI from '../abi/FAOToken.json';

/**
 * Format large numbers with K/M suffix (with space for clarity)
 */
function formatNumber(num) {
    if (!num) return '0';
    const n = Number(num);
    if (n >= 1e9) return (n / 1e9).toFixed(2) + ' B';
    if (n >= 1e6) return (n / 1e6).toFixed(2) + ' M';
    if (n >= 1e3) return (n / 1e3).toFixed(2) + ' K';
    return n.toLocaleString();
}

/**
 * ProtocolStats - Displays live metrics.
 * Stats (TVL, Supply, Price) -> RPC (Real-time)
 * Transactions -> Subgraph (History)
 */
export default function ProtocolStats() {
    const [isExpanded, setIsExpanded] = useState(false);


    // -- RPC DATA (Real-time Stats) --
    const { contractData, curveParams } = useFAOQuoter();

    // TVL (Treasury Balance)
    const { data: treasuryBalance } = useBalance({
        address: FAO_SALE_ADDRESS,
        chainId: 100, // Force Gnosis Chain
        query: { refetchInterval: 10000 }
    });

    // Circulating Supply (Total Minted)
    const { data: totalSupply } = useReadContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'totalSupply',
        chainId: 100, // Force Gnosis Chain
        query: { refetchInterval: 10000 }
    });

    // -- SUBGRAPH DATA (Transactions Log Only) --
    const {
        transactions,
        isLoading: isGraphLoading,
        error: graphError,
        lastSyncedAtUTC,
        refetch
    } = useSubgraphData({ pollInterval: 30000 });

    // Calculate countdown using RPC data
    const getCountdown = () => {
        const endTimeBigInt = contractData?.initialPhaseEnd;
        if (!endTimeBigInt) return null;

        const endTime = Number(endTimeBigInt) * 1000;
        const now = Date.now();
        const remaining = endTime - now;

        if (remaining <= 0) return { ended: true };

        return {
            days: Math.floor(remaining / 86400000),
            hours: Math.floor((remaining % 86400000) / 3600000),
            minutes: Math.floor((remaining % 3600000) / 60000),
            ended: false,
        };
    };

    const countdown = getCountdown();

    // Derived values
    const tvlFormatted = treasuryBalance ? Number(formatEther(treasuryBalance.value)).toFixed(2) : '0.00';
    const supplyFormatted = totalSupply ? formatEther(totalSupply) : '0';
    const priceFormatted = curveParams?.currentPriceFormatted || '0.0001';

    return (
        <div className="border border-white/20 bg-white/[0.02] relative overflow-hidden">
            {/* Header with sync status */}
            <div className="flex items-center justify-between px-4 py-3 border-b border-white/10 bg-white/5">
                <div className="flex items-center gap-3">
                    <div className={`w-2 h-2 rounded-full ${isGraphLoading ? 'bg-yellow-500 animate-pulse' : graphError ? 'bg-red-500' : 'bg-green-500'}`} />
                    <span className="font-pixel text-[8px] tracking-[0.3em] opacity-50 uppercase">INDEXER_STATUS</span>
                </div>

                <div className="flex items-center gap-4">
                    {lastSyncedAtUTC && (
                        <span className="font-mono text-[9px] opacity-30">
                            SYNCED: {lastSyncedAtUTC}
                        </span>
                    )}
                    <button
                        onClick={() => refetch()}
                        disabled={isGraphLoading}
                        className="font-pixel text-[8px] px-2 py-1 border border-white/20 hover:bg-white hover:text-black transition-all disabled:opacity-30 uppercase tracking-widest"
                    >
                        {isGraphLoading ? '↻ SYNCING...' : '↻ SYNC_NOW'}
                    </button>
                </div>
            </div>

            {/* Main stats grid - POWERED BY RPC */}
            <div className="grid grid-cols-2 lg:grid-cols-4 gap-px bg-white/10">
                {/* TVL */}
                <div className="bg-black p-4 space-y-2">
                    <span className="font-pixel text-[7px] opacity-30 uppercase tracking-widest block">PROTOCOL_TREASURY</span>
                    <div className="flex items-baseline gap-2">
                        <span className="text-2xl font-mono font-black">
                            {tvlFormatted}
                        </span>
                        <span className="font-pixel text-[8px] opacity-50">{treasuryBalance?.symbol || 'xDAI'}</span>
                    </div>
                </div>

                {/* Circulating Supply */}
                <div className="bg-black p-4 space-y-2">
                    <span className="font-pixel text-[7px] opacity-30 uppercase tracking-widest block">CIRCULATING_SUPPLY</span>
                    <div className="flex items-baseline gap-2">
                        <span className="text-2xl font-mono font-black">
                            {formatNumber(supplyFormatted)}
                        </span>
                        <span className="font-pixel text-[8px] opacity-50">FAO</span>
                    </div>
                </div>

                {/* Current Price */}
                <div className="bg-black p-4 space-y-2">
                    <span className="font-pixel text-[7px] opacity-30 uppercase tracking-widest block">CURRENT_FAO_PRICE</span>
                    <div className="flex items-baseline gap-2">
                        <span className="text-2xl font-mono font-black">
                            {priceFormatted}
                        </span>
                        <span className="font-pixel text-[8px] opacity-50">xDAI</span>
                        <span className="font-mono text-[8px] opacity-30">≈$ {(Number(priceFormatted) * 1.00).toFixed(4)} USD</span>
                    </div>
                </div>

                {/* Countdown */}
                <div className="bg-black p-4 space-y-2">
                    <span className="font-pixel text-[7px] opacity-30 uppercase tracking-widest block">
                        {contractData?.initialPhaseFinalized || countdown?.ended ? 'PHASE_1_ACTIVE' : 'PHASE_0_ACTIVE'}
                    </span>
                    {countdown?.ended && !contractData?.initialPhaseFinalized ? (
                        <span className="text-sm font-mono text-yellow-500 animate-pulse">AWAITING_FINALIZATION</span>
                    ) : countdown?.ended ? (
                        <span className="text-2xl font-mono font-black text-green-500">ACTIVE</span>
                    ) : countdown ? (
                        <div className="flex items-baseline gap-1">
                            <span className="text-2xl font-mono font-black">{countdown.days}</span>
                            <span className="font-pixel text-[8px] opacity-50">D</span>
                            <span className="text-2xl font-mono font-black ml-1">{countdown.hours}</span>
                            <span className="font-pixel text-[8px] opacity-50">H</span>
                            <span className="text-2xl font-mono font-black ml-1">{countdown.minutes}</span>
                            <span className="font-pixel text-[8px] opacity-50">M</span>
                        </div>
                    ) : (
                        <span className="text-2xl font-mono font-black opacity-20">--</span>
                    )}
                </div>
            </div>

            {/* Expandable transaction feed */}
            <button
                onClick={() => setIsExpanded(!isExpanded)}
                className="w-full px-4 py-2 flex items-center justify-between border-t border-white/10 hover:bg-white/5 transition-colors"
            >
                <span className="font-pixel text-[8px] opacity-40 uppercase tracking-widest">
                    RECENT_TRANSACTIONS ({transactions.length})
                </span>
                <span className="font-mono text-[10px] opacity-40">
                    {isExpanded ? '[ COLLAPSE ]' : '[ EXPAND ]'}
                </span>
            </button>

            <AnimatePresence>
                {isExpanded && (
                    <motion.div
                        initial={{ height: 0, opacity: 0 }}
                        animate={{ height: 'auto', opacity: 1 }}
                        exit={{ height: 0, opacity: 0 }}
                        className="border-t border-white/10 overflow-hidden"
                    >
                        <div className="max-h-48 overflow-y-auto">
                            {transactions.slice(0, 8).map((tx, i) => (
                                <div
                                    key={tx.id}
                                    className="px-4 py-2 flex items-center justify-between border-b border-white/5 hover:bg-white/5"
                                >
                                    <div className="flex items-center gap-3">
                                        <span className={`px-1.5 py-0.5 font-pixel text-[7px] ${tx.type === 'BUY' ? 'bg-blue-600 text-white' : 'bg-red-600 text-white'
                                            }`}>
                                            {tx.type}
                                        </span>
                                        <span className="font-mono text-[10px] opacity-60">
                                            {tx.txHash.slice(0, 8)}...{tx.txHash.slice(-6)}
                                        </span>
                                    </div>
                                    <div className="flex items-center gap-4">
                                        <span className="font-mono text-[10px] font-bold">
                                            {tx.amount} xDAI
                                        </span>
                                        <span className="font-pixel text-[7px] opacity-30">
                                            {tx.relativeTime}
                                        </span>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </motion.div>
                )}
            </AnimatePresence>

            {/* Error display */}
            {
                graphError && (
                    <div className="px-4 py-2 bg-red-500/10 border-t border-red-500/20">
                        <span className="font-pixel text-[8px] text-red-500">ERROR: {graphError}</span>
                    </div>
                )
            }
        </div >
    );
}
