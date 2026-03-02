'use client';

import { motion } from 'framer-motion';

export default function BondingCurveChart() {
    // Current simulated progress: 35% through the linear curve
    const currentX = 35;
    const currentPrice = 0.52;
    // Calculation: If X=25 is threshold, and X=100 is max.
    // Curve is flat until 25, then linear to 100.
    const currentY = 80 - (Math.max(0, currentX - 25) * 0.8);

    return (
        <div className="w-full max-w-4xl mx-auto my-6 bg-black p-4 border border-white/10">
            <h3 className="font-pixel text-[10px] mb-8 uppercase tracking-[0.3em] text-white/40">/VIRTUAL_BONDING_CURVE_BLUEPRINT</h3>

            <div className="relative h-64 w-full">
                <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="w-full h-full overflow-visible">
                    {/* Grid lines - Very subtle white */}
                    <line x1="0" y1="80" x2="100" y2="80" stroke="rgba(255, 255, 255, 0.05)" strokeWidth="0.5" strokeDasharray="1,2" />
                    <line x1="25" y1="0" x2="25" y2="100" stroke="rgba(255, 255, 255, 0.05)" strokeWidth="0.5" strokeDasharray="1,2" />

                    {/* The Curve - Crisp White */}
                    <path
                        d="M 0 80 L 25 80 L 100 20"
                        fill="none"
                        stroke="#FFFFFF"
                        strokeWidth="1"
                        strokeLinejoin="round"
                    />

                    {/* Progress Fill */}
                    <path
                        d={`M 0 80 L 25 80 L ${currentX} ${currentY} L ${currentX} 100 L 0 100 Z`}
                        fill="rgba(255, 255, 255, 0.03)"
                        className="transition-all duration-500"
                    />

                    {/* Current Position Marker - Blinking White */}
                    <motion.circle
                        cx={currentX}
                        cy={currentY}
                        r="1.5"
                        fill="#FFFFFF"
                        animate={{ opacity: [1, 0.2, 1] }}
                        transition={{ duration: 1.5, repeat: Infinity }}
                    />
                </svg>

                {/* Labels */}
                <div className="absolute left-0 bottom-0 translate-y-8 font-pixel text-[7px] text-white/20 tracking-widest">_ORIGIN</div>
                <div className="absolute left-[25%] bottom-0 translate-y-8 -translate-x-1/2 font-pixel text-[7px] text-white tracking-widest border-t border-white pt-1">_THRESHOLD</div>
                <div className="absolute right-0 bottom-0 translate-y-8 font-pixel text-[7px] text-white/20 tracking-widest">_EXPANSION</div>

                {/* Price Tooltip */}
                <motion.div
                    style={{ left: `${currentX}%`, top: `${currentY}%` }}
                    className="absolute -translate-x-1/2 -translate-y-16 border border-white bg-black text-white px-4 py-2 font-pixel text-[9px] whitespace-nowrap shadow-[0_0_20px_rgba(255,255,255,0.2)]"
                >
                    <span className="opacity-40 mr-2">VAL:</span> {currentPrice.toFixed(6)} ETH
                </motion.div>
            </div>

            <div className="mt-20 grid grid-cols-2 lg:grid-cols-4 gap-6">
                <div className="border border-white/10 p-4 bg-white/2 hover:bg-white/5 transition-colors">
                    <div className="text-[7px] font-pixel text-white/30 uppercase mb-2">SYSTEM_MODEL</div>
                    <div className="text-[10px] font-pixel text-white italic">LINEAR_COEFFICIENT_V4</div>
                </div>
                <div className="border border-white/10 p-4 bg-white/2 hover:bg-white/5 transition-colors">
                    <div className="text-[7px] font-pixel text-white/30 uppercase mb-2">REDEMPTION_STATUS</div>
                    <div className="text-[10px] font-pixel text-white italic">IMMUTABLE_FLOOR_ACTIVE</div>
                </div>
            </div>
        </div>
    );
}
