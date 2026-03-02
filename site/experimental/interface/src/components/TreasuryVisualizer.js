'use client';

import { useState, useMemo, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

const WALLET_COUNT = 320;
const TIERS = [
    { name: 'WHALE', probability: 0.05, min: 50, max: 200 },
    { name: 'SHARK', probability: 0.15, min: 10, max: 49 },
    { name: 'RETAIL', probability: 0.80, min: 0.1, max: 9.9 },
];

const generateWallets = () => {
    return Array.from({ length: WALLET_COUNT }, (_, i) => {
        const rand = Math.random();
        let cumulativeProbability = 0;
        let tier = TIERS[2];

        for (const t of TIERS) {
            cumulativeProbability += t.probability;
            if (rand < cumulativeProbability) {
                tier = t;
                break;
            }
        }

        return {
            id: i,
            tier: tier.name,
            balance: (Math.random() * (tier.max - tier.min) + tier.min).toFixed(2),
            address: `0x${Math.random().toString(16).slice(2, 6)}...${Math.random().toString(16).slice(2, 6)}`,
            activity: Math.random() > 0.7 ? 'ACTIVE' : 'IDLE',
        };
    });
};

export default function TreasuryVisualizer() { // Dark now handled by global context or default
    const wallets = useMemo(() => generateWallets(), []);
    const [hovered, setHovered] = useState(null);
    const [price, setPrice] = useState(1.42);

    return (
        <div className="relative flex flex-col h-full border transition-colors duration-700 overflow-hidden group/mempool bg-black/40 border-white/5">
            {/* PRICE HEADER */}
            <div className="p-8 border-b transition-colors duration-700 border-white/5">
                <div className="flex flex-col md:flex-row md:items-end justify-between gap-4">
                    <div className="space-y-1">
                        <div className="text-[8px] font-pixel transition-colors duration-700 text-white/20">MARKET_STATE // LIVE_PRICE_ORACLE</div>
                        <motion.div
                            animate={{ scale: [1, 1.02, 1] }}
                            transition={{ duration: 2, repeat: Infinity }}
                            className="text-6xl font-mono font-black tracking-tighter transition-colors duration-700 text-white"
                        >
                            <span className="opacity-20">$</span>{price.toFixed(2)}
                        </motion.div>
                    </div>

                    <div className="text-right">
                        <div className="text-[8px] font-pixel mb-1 tracking-widest uppercase transition-colors duration-700 text-blue-400">CURRENT_MARKET_EQUILIBRIUM</div>
                        <div className="flex items-center gap-2 justify-end">
                            <motion.div
                                animate={{ scale: [1, 1.2, 1], opacity: [0.5, 1, 0.5] }}
                                transition={{ repeat: Infinity, duration: 2 }}
                                className="w-1.5 h-1.5 bg-green-500 rounded-full"
                            />
                            <span className="text-[12px] font-mono tracking-widest uppercase italic transition-colors duration-700 text-white/40">LIVE_NETWORK_SCAN_ACTIVE</span>
                        </div>
                    </div>
                </div>
            </div>

            {/* MEMPOOL GRID */}
            <div className="flex-1 relative p-1 overflow-hidden select-none">
                <div className="w-full h-full flex flex-wrap gap-[2px] items-start justify-start content-start">
                    {wallets.map((w) => (
                        <motion.div
                            key={w.id}
                            onMouseEnter={() => setHovered(w)}
                            onMouseLeave={() => setHovered(null)}
                            initial={{ opacity: 0, scale: 0.8 }}
                            animate={{ opacity: 1, scale: 1 }}
                            className={`
                                flex-shrink-0 cursor-crosshair transition-colors duration-300
                                ${w.tier === 'WHALE' ? 'w-6 h-6 bg-white' : ''}
                                ${w.tier === 'SHARK' ? 'w-4 h-4 bg-blue-500/60' : ''}
                                ${w.tier === 'RETAIL' ? 'w-2 h-2 bg-white/10' : ''}
                                hover:bg-green-400 hover:z-30
                            `}
                        />
                    ))}
                </div>

                {/* GOGGLES TOOLTIP */}
                <AnimatePresence>
                    {hovered && (
                        <motion.div
                            initial={{ opacity: 0, y: 10, scale: 0.95 }}
                            animate={{ opacity: 1, y: 0, scale: 1 }}
                            exit={{ opacity: 0, scale: 0.95 }}
                            className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 z-40 pointer-events-none"
                        >
                            <div className="p-6 border backdrop-blur-xl shadow-2xl min-w-[240px] bg-black/90 border-white/20 text-white">
                                <div className="flex items-center justify-between mb-4 pb-2 border-b border-white/10">
                                    <span className="font-pixel text-[8px] opacity-40 uppercase">WALLET_GOGGLES_v2.1</span>
                                    <span className={`px-2 py-0.5 rounded-sm text-[8px] font-pixel ${hovered.tier === 'WHALE' ? 'bg-white text-black' : 'bg-blue-500 text-white'
                                        }`}>{hovered.tier}</span>
                                </div>
                                <div className="space-y-4">
                                    <div>
                                        <div className="text-[7px] font-pixel opacity-20 uppercase mb-1">IDENTIFIED_ADDR</div>
                                        <div className="font-mono text-sm">{hovered.address}</div>
                                    </div>
                                    <div className="flex justify-between">
                                        <div>
                                            <div className="text-[7px] font-pixel opacity-20 uppercase mb-1">BALANCE</div>
                                            <div className="font-mono text-lg font-black text-green-500">{hovered.balance} ETH</div>
                                        </div>
                                        <div className="text-right">
                                            <div className="text-[7px] font-pixel opacity-20 uppercase mb-1">ACTIVITY</div>
                                            <div className={`font-mono text-xs ${hovered.activity === 'ACTIVE' ? 'text-blue-400 animate-pulse' : 'opacity-40'}`}>
                                                {hovered.activity}
                                            </div>
                                        </div>
                                    </div>
                                </div>
                                <div className="mt-4 pt-2 border-t border-white/5 flex gap-2 overflow-hidden items-center justify-center">
                                    {[...Array(20)].map((_, i) => (
                                        <div key={i} className="w-[1px] bg-white transition-all duration-1000 opacity-10" style={{ height: Math.random() * 10 + 'px' }} />
                                    ))}
                                </div>
                            </div>
                        </motion.div>
                    )}
                </AnimatePresence>
            </div>

            {/* FOOTER STATS */}
            <div className="px-8 py-4 border-t flex items-center justify-between text-[8px] font-pixel transition-colors duration-700 border-white/5 text-white/20">
                <span>NODES_SCANNED: {WALLET_COUNT}</span>
                <span className="tracking-[0.5em]">SYSTEM_HEALTH: NOMINAL</span>
                <span className="opacity-10">V4.2.0_CORE</span>
            </div>
        </div>
    );
}
