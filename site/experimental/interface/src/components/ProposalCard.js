'use client';

import { motion } from 'framer-motion';

export default function ProposalCard({ proposal, isActive = false }) {
    const {
        title,
        outcomeStr,
        yesPrice,
        noPrice,
        assetLabel,
        companyLogo,
        networkTag,
        timeLeft
    } = proposal;

    const impact = ((yesPrice - noPrice) / noPrice * 100).toFixed(2);
    const isPositive = yesPrice > noPrice;

    return (
        <div className={`flex flex-col h-full bg-black border-2 transition-all duration-500 rounded-[2rem] overflow-hidden group relative cursor-pointer ${isActive ? 'border-white shadow-[0_0_40px_rgba(255,255,255,0.1)]' : 'border-white/10 hover:border-white/30'
            }`}>
            <div className="p-8 flex flex-col h-full gap-6">
                {/* Header: Logo, Progress, Tag */}
                <div className="flex justify-between items-center">
                    <div className="relative w-20 h-20">
                        {/* Circular Progress (Mock) */}
                        <svg className="absolute inset-0 w-full h-full -rotate-90">
                            <circle
                                cx="40" cy="40" r="38"
                                className="stroke-white/10"
                                fill="transparent"
                                strokeWidth="2"
                            />
                            <motion.circle
                                cx="40" cy="40" r="38"
                                className="stroke-white"
                                fill="transparent"
                                strokeWidth="2"
                                strokeDasharray="239"
                                initial={{ strokeDashoffset: 239 }}
                                animate={{ strokeDashoffset: isActive ? 40 : 180 }}
                                transition={{ duration: 2, ease: "easeOut" }}
                            />
                        </svg>
                        <div className="absolute inset-2 rounded-full overflow-hidden bg-white/5 border border-white/10 flex items-center justify-center">
                            <img
                                src={companyLogo}
                                alt="Logo"
                                className="w-10 h-10 object-contain opacity-80"
                                onError={(e) => { e.target.src = "https://www.google.com/s2/favicons?domain=gnosis.io&sz=128" }}
                            />
                        </div>
                    </div>

                    <div className={`px-3 py-1 rounded-full border text-[10px] font-pixel ${networkTag === 'Ethereum' ? 'bg-blue-500/10 border-blue-500/30 text-blue-400' : 'bg-emerald-500/10 border-emerald-500/30 text-emerald-400'
                        }`}>
                        {networkTag.toUpperCase()}
                    </div>
                </div>

                {/* Content */}
                <div className="flex flex-col gap-3">
                    <h3 className="text-xl font-bold font-mono leading-tight tracking-tight text-white/90">
                        <span>{title}</span> <span className="text-white/40">{outcomeStr}?</span>
                    </h3>
                    <div className="text-[10px] font-pixel text-white/30 uppercase tracking-[0.2em]">
                        {timeLeft}
                    </div>
                </div>

                <div className="flex-grow" />

                {/* Metrics Card */}
                <div className="mt-6 border border-white/10 bg-white/5 rounded-2xl overflow-hidden">
                    <div className="grid grid-cols-3 divide-x divide-white/10">
                        <div className="flex flex-col items-center p-4">
                            <span className="text-[8px] font-pixel opacity-40 mb-1">YES_PRICE</span>
                            <span className="text-sm font-mono font-bold text-blue-400">{yesPrice} {assetLabel}</span>
                        </div>
                        <div className="flex flex-col items-center p-4">
                            <span className="text-[8px] font-pixel opacity-40 mb-1">NO_PRICE</span>
                            <span className="text-sm font-mono font-bold text-yellow-500">{noPrice} {assetLabel}</span>
                        </div>
                        <div className="flex flex-col items-center p-4">
                            <span className="text-[8px] font-pixel opacity-40 mb-1">IMPACT</span>
                            <span className={`text-sm font-mono font-bold ${isPositive ? 'text-green-500' : 'text-red-500'}`}>
                                {isPositive ? '+' : ''}{impact}%
                            </span>
                        </div>
                    </div>
                </div>
            </div>

            {/* Hover Indicator */}
            <motion.div
                className="absolute inset-x-0 bottom-0 h-1 bg-white"
                initial={{ scaleX: 0 }}
                whileHover={{ scaleX: 1 }}
                transition={{ duration: 0.3 }}
            />
        </div>
    );
}
