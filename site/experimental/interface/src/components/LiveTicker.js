'use client';

import { motion } from 'framer-motion';
import { useSubgraphData } from '../hooks/useSubgraphData';
import { useNativeCurrency } from '../hooks/useNativeCurrency';

export default function LiveTicker() {
    const { transactions, lastSyncedAtUTC } = useSubgraphData({ pollInterval: 30000 });
    const { symbol: nativeSymbol, price: nativePrice, isGnosis } = useNativeCurrency();

    // Map transaction types to display labels
    const getEventLabel = (type) => {
        switch (type) {
            case 'BUY': return 'LIQUIDITY_SECURED';
            case 'RAGEQUIT': return 'DAO_EXIT';
            default: return 'PROTOCOL_EVENT';
        }
    };

    // Create ticker events from live transactions
    const tickerEvents = transactions.slice(0, 10).map(tx => ({
        label: getEventLabel(tx.type),
        val: `${tx.txHash.slice(0, 6)}..${tx.txHash.slice(-4)}`,
        type: tx.type,
        amount: `${tx.amount} ${nativeSymbol}`,
    }));

    // If no transactions yet, show placeholder
    if (tickerEvents.length === 0) {
        tickerEvents.push(
            { label: 'AWAITING_DATA', val: '...', type: 'LOADING', amount: `0 ${nativeSymbol}` }
        );
    }

    // Duplicate for seamless scrolling
    const allEvents = [...tickerEvents, ...tickerEvents];

    return (
        <div className="w-full bg-white text-black h-8 overflow-hidden flex items-center whitespace-nowrap border-b border-black select-none z-[100] relative">
            <motion.div
                className="flex items-center gap-16 px-4"
                animate={{ x: [0, -1000] }}
                transition={{
                    duration: 30,
                    repeat: Infinity,
                    ease: "linear"
                }}
            >
                {/* NATIVE CURRENCY PRICE */}
                <div className="flex items-center gap-3">
                    <span className="font-pixel text-[8px] uppercase tracking-widest opacity-50">ORACLE_FEED:</span>
                    <span className="font-mono text-xs font-black">
                        {nativeSymbol}/USD: ${nativePrice ? nativePrice.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : '...'}
                    </span>
                    <div className="w-1.5 h-1.5 rounded-full bg-green-600 animate-pulse" />
                </div>

                {/* SYNC STATUS */}
                <div className="flex items-center gap-2">
                    <span className="font-pixel text-[8px] uppercase tracking-widest opacity-50">LAST_SYNC:</span>
                    <span className="font-mono text-[10px]">{lastSyncedAtUTC || '...'}</span>
                </div>

                {/* EVENTS LOOP */}
                {allEvents.map((e, i) => (
                    <div key={i} className="flex items-center gap-4">
                        <span className="font-pixel text-[8px] uppercase tracking-widest opacity-50">{e.label}:</span>
                        <div className="flex items-center gap-2">
                            <span className={`px-1.5 py-0.5 text-[8px] font-pixel ${e.type === 'BUY' ? 'bg-blue-600 text-white' :
                                e.type === 'RAGEQUIT' ? 'bg-black text-white' :
                                    'bg-gray-200 text-black'
                                }`}>{e.type}</span>
                            <span className="font-mono text-[10px] font-bold">{e.val}</span>
                            <span className="font-mono text-[10px] opacity-40">[{e.amount}]</span>
                        </div>
                    </div>
                ))}
            </motion.div>
        </div>
    );
}
