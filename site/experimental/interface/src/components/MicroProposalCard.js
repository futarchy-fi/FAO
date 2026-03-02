'use client';

import { motion, AnimatePresence } from 'framer-motion';

export default function MicroProposalCard({ proposal, isActive = false, outcome = null }) {
    const {
        title,
        outcomeStr,
        companyLogo,
        networkTag
    } = proposal;

    const getStatusStyles = () => {
        if (!isActive) return 'bg-black border-white/10 text-white/40 hover:border-white/30';
        if (outcome === 'APPROVE') return 'bg-blue-600 border-blue-600 text-white shadow-[0_0_40px_rgba(59,130,246,0.3)]';
        if (outcome === 'REJECT') return 'bg-yellow-500 border-yellow-500 text-white shadow-[0_0_40px_rgba(250,204,21,0.3)]';
        return 'bg-white border-white text-black shadow-[0_0_30px_rgba(255,255,255,0.05)]';
    };

    return (
        <motion.div
            layout
            className={`flex items-center gap-4 px-6 py-4 rounded-full border transition-all duration-700 whitespace-nowrap overflow-hidden relative ${getStatusStyles()}`}
        >
            <div className={`w-10 h-10 rounded-full overflow-hidden border-2 border-white/40 bg-white/10 flex items-center justify-center flex-shrink-0 z-10 transition-all duration-500`}>
                {companyLogo ? (
                    <img
                        src={companyLogo}
                        alt="Logo"
                        className={`w-6 h-6 object-contain transition-all duration-500 ${isActive ? 'opacity-100' : 'opacity-40'} ${outcome ? 'brightness-200 contrast-125' : ''}`}
                        onError={(e) => { e.target.src = "https://www.google.com/s2/favicons?domain=gnosis.io&sz=128" }}
                    />
                ) : (
                    <span className={`font-pixel text-xs font-bold ${isActive ? 'opacity-100' : 'opacity-40'}`}>#</span>
                )}
            </div>

            <div className="flex flex-col z-10">
                <div className="flex items-center gap-2">
                    <span className="text-[10px] font-bold font-mono tracking-tight leading-none uppercase">
                        {title}
                    </span>
                    <span className={`text-[8px] font-pixel transition-colors duration-500 ${outcome ? 'text-white/60' : (isActive ? 'text-black/60' : 'text-white/20')
                        }`}>
                        {networkTag.toUpperCase()}
                    </span>
                </div>
                <div className={`text-[8px] font-pixel mt-0.5 transition-opacity duration-500 ${outcome ? 'opacity-80' : 'opacity-60'}`}>
                    {outcomeStr.split(' if ')[0]}...
                </div>
            </div>
        </motion.div>
    );
}
