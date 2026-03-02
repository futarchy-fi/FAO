'use client';

import { motion, AnimatePresence } from 'framer-motion';
import { useState, useEffect } from 'react';
import { useSubgraphData } from '../hooks/useSubgraphData';
import { useNativeCurrency } from '../hooks/useNativeCurrency';

export default function ActivityCarousel() {
    const [index, setIndex] = useState(0);
    const { transactions } = useSubgraphData({ pollInterval: 30000 });
    const { symbol: nativeSymbol } = useNativeCurrency();

    // Map transactions to carousel format
    const events = transactions.slice(0, 8).map(tx => ({
        id: tx.id,
        type: tx.type === 'BUY' ? 'buy()' : 'ragequit()',
        user: `${tx.user.slice(0, 6)}...${tx.user.slice(-4)}`,
        amount: `${tx.amount} ${nativeSymbol}`,
        val: `${tx.txHash.slice(0, 6)}..${tx.txHash.slice(-4)}`,
        time: tx.relativeTime,
        isRagequit: tx.type === 'RAGEQUIT',
        txHash: tx.txHash,
    }));

    // Fallback if no events
    const displayEvents = events.length > 0 ? events : [
        { id: 'placeholder', type: 'awaiting...', user: 'SYSTEM', amount: `0 ${nativeSymbol}`, val: '...', time: 'SYNCING', isRagequit: false }
    ];

    useEffect(() => {
        if (displayEvents.length <= 1) return;

        const timer = setInterval(() => {
            setIndex((prev) => (prev + 1) % displayEvents.length);
        }, 4000);
        return () => clearInterval(timer);
    }, [displayEvents.length]);

    const event = displayEvents[index] || displayEvents[0];

    return (
        <div className="h-24 border border-white/10 bg-white/2 flex items-center px-8 relative overflow-hidden">
            <div className="absolute left-0 top-0 bottom-0 w-1 bg-white" />

            <AnimatePresence mode="wait">
                <motion.div
                    key={index}
                    initial={{ opacity: 0, y: 10 }}
                    animate={{ opacity: 1, y: 0 }}
                    exit={{ opacity: 0, y: -10 }}
                    className="flex flex-1 items-center justify-between"
                >
                    <div className="flex items-center gap-6">
                        <div className={`text-[10px] font-pixel px-2 py-1 ${event.isRagequit ? 'bg-red-500 text-white' : 'bg-white text-black'
                            }`}>
                            {event.type}
                        </div>
                        <div className="flex flex-col">
                            <span className="text-[8px] font-pixel opacity-30 uppercase tracking-widest">
                                {event.isRagequit ? 'EXIT_NODE' : 'USER_NODE'}
                            </span>
                            <a
                                href={event.txHash ? `https://gnosisscan.io/tx/${event.txHash}` : '#'}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="font-mono text-sm hover:underline"
                            >
                                {event.user}
                            </a>
                        </div>
                    </div>

                    <div className="text-right flex flex-col items-end">
                        <span className={`text-lg font-mono font-bold leading-none ${event.isRagequit ? 'text-red-400' : 'text-white'
                            }`}>
                            {event.amount}
                        </span>
                        <span className="text-[8px] font-pixel opacity-20 uppercase mt-1">
                            {event.time} // LIVE_FEED
                        </span>
                    </div>
                </motion.div>
            </AnimatePresence>

            {/* Pagination Dotted Line */}
            <div className="absolute bottom-2 left-8 right-8 flex gap-1">
                {displayEvents.map((_, i) => (
                    <div
                        key={i}
                        className={`h-[1px] flex-1 transition-all ${i === index ? 'bg-white' : 'bg-white/10'}`}
                    />
                ))}
            </div>
        </div>
    );
}
