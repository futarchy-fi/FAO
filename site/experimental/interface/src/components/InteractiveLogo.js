'use client';

import { motion } from 'framer-motion';
import { useState, useEffect } from 'react';

import { AnimatedLogo } from './ui/AnimatedLogo';

export function InteractiveLogo() {
    const [mousePos, setMousePos] = useState({ x: 0.5, y: 0.5 });

    const handleMouseMove = (e) => {
        const rect = e.currentTarget.getBoundingClientRect();
        setMousePos({
            x: (e.clientX - rect.left) / rect.width,
            y: (e.clientY - rect.top) / rect.height
        });
    };

    return (
        <div
            className="relative w-full h-[500px] mb-12 cursor-none overflow-hidden group border-b-8 border-black bg-white"
            onMouseMove={handleMouseMove}
        >
            {/* The Giant Halftone Layer - Massive Dots */}
            <div
                className="absolute inset-0 z-0 opacity-80"
                style={{
                    WebkitMaskImage: `radial-gradient(circle at ${mousePos.x * 100}% ${mousePos.y * 100}%, transparent 0%, black 70%)`,
                    maskImage: `radial-gradient(circle at ${mousePos.x * 100}% ${mousePos.y * 100}%, transparent 0%, black 70%)`,
                    backgroundImage: 'radial-gradient(circle, #000 4px, transparent 4px)',
                    backgroundSize: '24px 24px'
                }}
            />

            {/* Dynamic Glitch / Noise Overlay */}
            <div className="absolute inset-0 pointer-events-none opacity-[0.03] z-10 select-none">
                <div className="absolute inset-0 bg-[url('https://media.giphy.com/media/oEI9uWU9zDSGk/giphy.gif')] bg-repeat" />
            </div>

            {/* Animated SVG FAO - The centerpiece */}
            <div className="absolute inset-0 flex items-center justify-center pointer-events-none z-20">
                <div className="w-full max-w-4xl px-12">
                    <AnimatedLogo />
                    <motion.div
                        initial={{ opacity: 0, y: 20 }}
                        animate={{ opacity: 1, y: 0 }}
                        transition={{ delay: 4, duration: 1 }}
                        className="mt-[-40px] text-center"
                    >
                        <div className="inline-block px-8 py-3 bg-black text-white font-pixel text-2xl pixel-border">
                            AUTHENTIC_PROTOCOL_REACHED
                        </div>
                    </motion.div>
                </div>
            </div>

            {/* Mouse Tracker Crosshair - More Intense */}
            <div
                className="absolute pointer-events-none transition-transform duration-75 z-50 flex items-center justify-center opacity-40 group-hover:opacity-100"
                style={{
                    left: `${mousePos.x * 100}%`,
                    top: `${mousePos.y * 100}%`,
                    transform: 'translate(-50%, -50%)'
                }}
            >
                <div className="w-32 h-0.5 bg-black" />
                <div className="absolute w-0.5 h-32 bg-black" />
                <div className="absolute w-8 h-8 border-4 border-black" />
                <div className="absolute -top-4 font-pixel text-[8px] text-black bg-white px-1">
                    X:{(mousePos.x * 1000).toFixed(0)} Y:{(mousePos.y * 1000).toFixed(0)}
                </div>
            </div>

            <div className="absolute bottom-6 left-10 font-pixel text-[10px] text-black font-bold uppercase tracking-widest bg-white p-2 border-2 border-black">
                SCENE: SYSTEM_CORE_EXPOSURE // INTERACTIVE_RENDER: MAX_FIDELITY
            </div>
        </div>
    );
}
