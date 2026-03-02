'use client';

import { motion } from 'framer-motion';

export function BigHeader({ text, subtext }) {
    return (
        <div className="flex flex-col items-center justify-center py-20 relative overflow-hidden bg-white">
            <motion.h1
                initial={{ opacity: 0, scale: 0.9 }}
                animate={{ opacity: 1, scale: 1 }}
                transition={{ duration: 0.5, ease: "easeOut" }}
                className="font-pixel text-6xl md:text-[8rem] font-black text-black tracking-tighter text-center z-10 leading-[0.85]"
            >
                {text}
            </motion.h1>

            {subtext && (
                <motion.p
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 1 }}
                    transition={{ delay: 0.3, duration: 0.5 }}
                    className="mt-12 text-lg md:text-xl text-black font-pixel tracking-widest uppercase z-10 border-y-2 border-black inline-block px-4 py-2"
                >
                    {subtext}
                </motion.p>
            )}
        </div>
    );
}
