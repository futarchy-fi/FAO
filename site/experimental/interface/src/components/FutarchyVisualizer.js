'use client';

import { motion, AnimatePresence } from 'framer-motion';
import { useState, useEffect } from 'react';

// Intercalated proposals: alternating PASS and FAIL outcomes for variety
const REAL_PROPOSALS = [
    {
        id: 1,
        title: "PROPOSAL_EXAMPLE #1",
        outcomeStr: "Impact on token price if governance proposal passes",
        yesPrice: 161.01,  // PASS: yesPrice > noPrice
        noPrice: 143.96,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Ethereum",
        timeLeft: "37d 1h 42m"
    },
    {
        id: 2,
        title: "PROPOSAL_EXAMPLE #2",
        outcomeStr: "Treasury allocation decision outcome simulation",
        yesPrice: 82.35,   // FAIL: noPrice > yesPrice
        noPrice: 127.14,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Gnosis",
        timeLeft: "2d 13h 41m"
    },
    {
        id: 3,
        title: "PROPOSAL_EXAMPLE #3",
        outcomeStr: "Protocol upgrade impact assessment",
        yesPrice: 113.23,  // PASS: yesPrice > noPrice
        noPrice: 102.90,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Gnosis",
        timeLeft: "4d 13h 42m"
    },
    {
        id: 4,
        title: "PROPOSAL_EXAMPLE #4",
        outcomeStr: "Strategic partnership evaluation",
        yesPrice: 79.06,   // FAIL: noPrice > yesPrice
        noPrice: 136.47,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Ethereum",
        timeLeft: "5d 13h 42m"
    },
    {
        id: 5,
        title: "PROPOSAL_EXAMPLE #5",
        outcomeStr: "Liquidity pool rebalancing proposal",
        yesPrice: 124.80,  // PASS: yesPrice > noPrice
        noPrice: 98.45,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Gnosis",
        timeLeft: "12d 8h 15m"
    },
    {
        id: 6,
        title: "PROPOSAL_EXAMPLE #6",
        outcomeStr: "Token burn mechanism activation",
        yesPrice: 91.20,   // FAIL: noPrice > yesPrice
        noPrice: 118.35,
        assetLabel: "USD",
        companyLogo: null,
        networkTag: "Ethereum",
        timeLeft: "8d 22h 03m"
    }
];

import MicroProposalCard from './MicroProposalCard';

export default function FutarchyVisualizer() {
    const [points, setPoints] = useState({ yes: [{ x: 0, y: 50 }], no: [{ x: 0, y: 50 }] });
    const [outcome, setOutcome] = useState(null);
    const [step, setStep] = useState(0);
    const [currentIdx, setCurrentIdx] = useState(0);
    const [proposalQueue, setProposalQueue] = useState(REAL_PROPOSALS);

    const current = proposalQueue[0];

    const cycleQueue = () => {
        setOutcome(null);
        setStep(0);
        setPoints({ yes: [{ x: 0, y: 50 }], no: [{ x: 0, y: 50 }] });
        // Move the first item to the end of the queue
        setProposalQueue(prev => {
            const [first, ...rest] = prev;
            return [...rest, first];
        });
    };

    useEffect(() => {
        const timer = setTimeout(() => {
            if (step >= 100) {
                const impact = ((current.yesPrice - current.noPrice) / current.noPrice);
                setOutcome(impact > 0 ? 'APPROVE' : 'REJECT');
                const nextTimer = setTimeout(cycleQueue, 4000);
                return () => clearTimeout(nextTimer);
            }

            setStep(s => s + 2.0); // Slightly faster simulation for ticker feel
            setPoints(prev => {
                const lastYes = prev.yes[prev.yes.length - 1];
                const lastNo = prev.no[prev.no.length - 1];

                const targetYesY = 100 - (current.yesPrice / (current.yesPrice + current.noPrice) * 120);
                const targetNoY = 100 - (current.noPrice / (current.yesPrice + current.noPrice) * 120);

                const nextYesY = lastYes.y + (targetYesY - lastYes.y) * 0.15 + (Math.random() - 0.5) * 6;
                const nextNoY = lastNo.y + (targetNoY - lastNo.y) * 0.15 + (Math.random() - 0.5) * 6;

                return {
                    yes: [...prev.yes, { x: step + 2.0, y: Math.max(5, Math.min(95, nextYesY)) }],
                    no: [...prev.no, { x: step + 2.0, y: Math.max(5, Math.min(95, nextNoY)) }]
                };
            });
        }, 30); // Faster updates

        return () => clearTimeout(timer);
    }, [step, proposalQueue]);

    const toPath = (pts) => pts.map(p => `${p.x},${p.y} `).join(' ');

    return (
        <div className="relative w-full overflow-hidden bg-black">
            {/* HERO SIMULATOR SECTION */}
            <div className="relative h-[340px] sm:h-[420px] md:h-[500px] border-b border-white/5 flex flex-col items-center justify-center">
                {/* Background Branding */}
                <div className="absolute inset-0 flex items-center justify-center pointer-events-none select-none">
                    <span className="font-pixel text-[20vw] opacity-[0.02] leading-none text-white uppercase italic">SIMULATION</span>
                </div>

                {/* Dashboard Metrics */}
                <div className="absolute top-8 left-8 z-10 space-y-1">
                    <h3 className="font-pixel text-[8px] tracking-[0.4em] text-white/20">CONDITIONAL_DECISION_STREAM</h3>
                    <div className="flex items-center gap-3">
                        <div className="w-1 h-1 rounded-full bg-blue-500 animate-pulse" />
                        <span className="font-mono text-[10px] text-white/40 uppercase tracking-tighter">NODE_SYNC_ACTIVE // 240TPS</span>
                    </div>
                </div>

                {/* Simulation Canvas */}
                <div className="w-full h-full max-w-7xl relative px-6 sm:px-10 md:px-20">
                    <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="w-full h-full opacity-60">
                        <defs>
                            <linearGradient id="simYes" x1="0%" y1="0%" x2="100%" y2="0%">
                                <stop offset="0%" stopColor="#3B82F6" stopOpacity="0" />
                                <stop offset="100%" stopColor="#3B82F6" stopOpacity="0.8" />
                            </linearGradient>
                            <linearGradient id="simNo" x1="0%" y1="0%" x2="100%" y2="0%">
                                <stop offset="0%" stopColor="#FACC15" stopOpacity="0" />
                                <stop offset="100%" stopColor="#FACC15" stopOpacity="0.8" />
                            </linearGradient>
                        </defs>
                        <motion.polyline points={toPath(points.yes)} fill="none" stroke="url(#simYes)" strokeWidth="0.5" />
                        <motion.polyline points={toPath(points.no)} fill="none" stroke="url(#simNo)" strokeWidth="0.5" />
                    </svg>

                    {/* Minimalist Terminal Toast */}
                    <AnimatePresence>
                        {outcome && (
                            <motion.div
                                initial={{ opacity: 0, x: 20 }}
                                animate={{ opacity: 1, x: 0 }}
                                exit={{ opacity: 0, x: 20 }}
                                className="absolute top-4 sm:top-6 md:top-8 right-4 sm:right-6 md:right-8 z-30 pointer-events-none"
                            >
                                <div className={`flex items-center gap-6 px-8 py-4 bg-black/80 backdrop-blur-xl border-l-2 ${outcome === 'APPROVE' ? 'border-blue-500 shadow-[0_0_40px_rgba(59,130,246,0.1)]' : 'border-yellow-500 shadow-[0_0_40px_rgba(250,204,21,0.1)]'}`}>
                                    <div className="flex flex-col">
                                        <div className="font-pixel text-[8px] opacity-40 mb-1 tracking-widest uppercase">DECISION_LOGGED</div>
                                        <div className={`text-2xl font-pixel ${outcome === 'APPROVE' ? 'text-blue-500' : 'text-yellow-500'}`}>
                                            {outcome === 'APPROVE' ? 'PASS' : 'FAIL'}
                                        </div>
                                    </div>
                                    <div className="h-10 w-px bg-white/10" />
                                    <div className="flex flex-col">
                                        <div className="font-pixel text-[8px] opacity-40 mb-1 tracking-widest uppercase">IMPACT</div>
                                        <div className={`text-lg font-mono font-bold ${outcome === 'APPROVE' ? 'text-blue-500' : 'text-yellow-500'}`}>
                                            {((current.yesPrice - current.noPrice) / current.noPrice * 100).toFixed(2)}%
                                        </div>
                                    </div>
                                </div>
                            </motion.div>
                        )}
                    </AnimatePresence>
                </div>
            </div>

            {/* MINIMALIST TICKER CAROUSEL */}
            <div className="relative -mt-10 sm:-mt-12 md:-mt-16 z-20 overflow-hidden py-8 md:py-10">
                <div className="max-w-[1400px] mx-auto px-4 sm:px-8 md:px-12">
                    <div className="flex items-center gap-6 sm:gap-12 mb-4 sm:mb-6">
                        <div className="font-pixel text-[10px] text-white/30 tracking-[0.4em] uppercase whitespace-nowrap">/ PROPOSAL_QUEUE</div>
                        <div className="h-px bg-white/10 flex-1" />
                    </div>

                    <div className="relative min-h-[64px] flex items-center">
                        <AnimatePresence mode="popLayout" initial={false}>
                            <div className="flex gap-4">
                                {proposalQueue.map((p, idx) => (
                                    <motion.div
                                        key={p.id}
                                        layout
                                        initial={{ opacity: 0, x: 50, scale: 0.9 }}
                                        animate={{
                                            opacity: 1,
                                            x: 0,
                                            scale: 1,
                                            zIndex: proposalQueue.length - idx
                                        }}
                                        exit={{ opacity: 0, x: -100, scale: 0.8 }}
                                        transition={{
                                            type: 'spring',
                                            damping: 25,
                                            stiffness: 200,
                                            layout: { duration: 0.6, ease: "easeInOut" }
                                        }}
                                    >
                                        <MicroProposalCard
                                            proposal={p}
                                            isActive={idx === 0}
                                            outcome={idx === 0 ? outcome : null}
                                        />
                                    </motion.div>
                                ))}
                            </div>
                        </AnimatePresence>
                    </div>
                </div>
            </div>
        </div>
    );
}
