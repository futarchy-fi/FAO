'use client';

import { motion, useInView } from 'framer-motion';
import { useRef, useState, useEffect } from 'react';

export function TypewriterText({ text, className = "", delay = 0, speed = 0.03 }) {
    const ref = useRef(null);
    const isInView = useInView(ref, { once: true, amount: 0.5 });
    const [displayedText, setDisplayedText] = useState("");
    const [isComplete, setIsComplete] = useState(false);

    useEffect(() => {
        if (!isInView) return;

        let currentIndex = 0;
        const timer = setTimeout(() => {
            const interval = setInterval(() => {
                if (currentIndex <= text.length) {
                    setDisplayedText(text.slice(0, currentIndex));
                    currentIndex++;
                } else {
                    clearInterval(interval);
                    setIsComplete(true);
                }
            }, speed * 1000);

            return () => clearInterval(interval);
        }, delay * 1000);

        return () => clearTimeout(timer);
    }, [isInView, text, speed, delay]);

    return (
        <span ref={ref} className={`${className} relative`}>
            {displayedText}
            {isInView && !isComplete && (
                <motion.span
                    animate={{ opacity: [1, 1, 0, 0] }}
                    transition={{
                        duration: 0.8,
                        repeat: Infinity,
                        ease: "linear",
                        times: [0, 0.5, 0.5, 1]
                    }}
                    className="inline-block w-[0.5em] h-[1em] bg-white ml-1 align-middle shadow-[0_0_5px_rgba(255,255,255,0.8)]"
                />
            )}
        </span>
    );
}
