'use client';

import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';

const MOCK_THOUGHTS = [
    "ANALYZING_LIQUIDITY_DEPTH...",
    "DETECTED_WHALE_ACCUMULATION_IN_RESERVE_04",
    "OPTIMIZING_BONDING_CURVE_PARAMETERS...",
    "FUTARCHY_PROJECTION: +14.2%_EST_GAIN",
    "NODE_HEALTH: 100%_SECURE",
    "SYNCHRONIZING_CROSS_CHAIN_SIGNALS...",
    "THREAT_MODEL_V4: NO_ANOMALIES_DETECTED",
    "GOVERN_NODE_V5.2_IDLE...",
];

export default function AINodeTerminal() {
    const [messages, setMessages] = useState([{ id: 0, text: "FAO_OS_INITIATED...", type: 'system' }]);
    const [input, setInput] = useState('');
    const scrollRef = useRef(null);

    useEffect(() => {
        const interval = setInterval(() => {
            const thought = MOCK_THOUGHTS[Math.floor(Math.random() * MOCK_THOUGHTS.length)];
            setMessages(prev => [...prev, { id: Date.now(), text: thought, type: 'live' }].slice(-6));
        }, 5000);
        return () => clearInterval(interval);
    }, []);

    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [messages]);

    const handleSend = (e) => {
        e.preventDefault();
        if (!input.trim()) return;

        const userMsg = { id: Date.now(), text: `> ${input.toUpperCase()}`, type: 'user' };
        setMessages(prev => [...prev, userMsg].slice(-6));
        setInput('');

        // Mock AI response
        setTimeout(() => {
            const response = { id: Date.now() + 1, text: "REQUEST_LOGGED: PROCESSING_DYNAMICS...", type: 'system' };
            setMessages(prev => [...prev, response].slice(-6));
        }, 1000);
    };

    return (
        <div className="border border-white/10 bg-black/40 backdrop-blur-md p-4 flex flex-col gap-4 font-mono select-none overflow-hidden">
            <div className="flex items-center justify-between text-[8px] font-pixel opacity-30 uppercase tracking-widest border-b border-white/10 pb-2">
                <div className="flex items-center gap-2">
                    <div className="w-1.5 h-1.5 bg-green-500 rounded-full animate-pulse" />
                    AI_GOVERN_NODE_ACTIVE
                </div>
                <span>NODE_ID: 1402</span>
            </div>

            <div
                ref={scrollRef}
                className="h-32 overflow-y-auto space-y-2 scrollbar-hide text-[10px]"
            >
                <AnimatePresence initial={false}>
                    {messages.map((m) => (
                        <motion.div
                            key={m.id}
                            initial={{ opacity: 0, x: -5 }}
                            animate={{ opacity: 1, x: 0 }}
                            className={`${m.type === 'user' ? 'text-white font-bold' :
                                    m.type === 'system' ? 'text-blue-400' : 'text-white/40'
                                }`}
                        >
                            {m.text}
                        </motion.div>
                    ))}
                </AnimatePresence>
            </div>

            <form onSubmit={handleSend} className="relative mt-2">
                <input
                    type="text"
                    value={input}
                    onChange={(e) => setInput(e.target.value)}
                    placeholder="ENTER_COMMAND..."
                    className="w-full bg-white/5 border border-white/10 px-3 py-2 text-[10px] outline-none focus:border-white/30 transition-colors uppercase"
                />
                <button type="submit" className="hidden" />
            </form>

            <div className="text-[6px] font-pixel opacity-10 uppercase tracking-widest">
                // SECURE_COMMUNICATION_ESTABLISHED
            </div>
        </div>
    );
}
