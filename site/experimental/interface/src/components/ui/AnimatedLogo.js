'use client';

import { motion } from 'framer-motion';

export function AnimatedLogo() {
    const draw = {
        hidden: { pathLength: 0, opacity: 0 },
        visible: (i) => {
            const delay = 1 + i * 0.5;
            return {
                pathLength: 1,
                opacity: 1,
                transition: {
                    pathLength: { delay, type: "spring", duration: 1.5, bounce: 0 },
                    opacity: { delay, duration: 0.01 }
                }
            };
        }
    };

    return (
        <div className="relative w-full max-w-2xl mx-auto py-12">
            <motion.svg
                viewBox="0 0 400 120"
                initial="hidden"
                animate="visible"
                className="w-full h-auto"
            >
                {/* Stylized 'F' - Blocky & Industrial */}
                <motion.path
                    d="M40 20 h60 v15 h-45 v25 h40 v15 h-40 v40 h-15 z"
                    fill="none"
                    stroke="black"
                    strokeWidth="4"
                    variants={draw}
                    custom={0}
                />

                {/* Stylized 'A' - Triangle based but sharp */}
                <motion.path
                    d="M130 115 l35 -95 l35 95 h-15 l-7 -20 h-41 l-7 20 z M160 80 h26 l-13 -35 z"
                    fill="none"
                    stroke="black"
                    strokeWidth="4"
                    variants={draw}
                    custom={1}
                />

                {/* Stylized 'O' - Hexagonal/Square variant */}
                <motion.path
                    d="M230 40 l20 -20 h60 l20 20 v40 l-20 20 h-60 l-20 -20 z M245 45 v30 l15 15 h30 l15 -15 v-30 l-15 -15 h-30 z"
                    fill="none"
                    stroke="black"
                    strokeWidth="4"
                    variants={draw}
                    custom={2}
                />

                {/* Fill Animation - Subtle reveal after drawing */}
                <motion.path
                    d="M40 20 h60 v15 h-45 v25 h40 v15 h-40 v40 h-15 z"
                    fill="black"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 0.05 }}
                    transition={{ delay: 2.5, duration: 1 }}
                />
                <motion.path
                    d="M130 115 l35 -95 l35 95 h-15 l-7 -20 h-41 l-7 20 z M160 80 h26 l-13 -35 z"
                    fill="black"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 0.05 }}
                    transition={{ delay: 3, duration: 1 }}
                />
                <motion.path
                    d="M230 40 l20 -20 h60 l20 20 v40 l-20 20 h-60 l-20 -20 z M245 45 v30 l15 15 h30 l15 -15 v-30 l-15 -15 h-30 z"
                    fill="black"
                    initial={{ opacity: 0 }}
                    animate={{ opacity: 0.05 }}
                    transition={{ delay: 3.5, duration: 1 }}
                />
            </motion.svg>
        </div>
    );
}
