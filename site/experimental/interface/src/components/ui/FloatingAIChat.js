'use client';

import { useState, useRef, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TypewriterText } from './TypewriterText';

export function FloatingAIChat() {
    const [isOpen, setIsOpen] = useState(false);
    const [messages, setMessages] = useState([
        { role: 'agent', text: 'NODE_INITIALIZED. I AM THE FAO AUTONOMOUS AGENT. HOW CAN I ASSIST YOUR PROTOCOL AUDIT?' }
    ]);
    const [input, setInput] = useState('');
    const scrollRef = useRef(null);

    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [messages, isOpen]);

    const handleSend = () => {
        if (!input.trim()) return;

        const userMsg = input.trim();
        setMessages(prev => [...prev, { role: 'user', text: userMsg }]);
        setInput('');

        // Simulated Agent Response
        setTimeout(() => {
            const response = getAgentResponse(userMsg);
            setMessages(prev => [...prev, { role: 'agent', text: response }]);
        }, 600);
    };

    const getAgentResponse = (msg) => {
        const query = msg.toLowerCase();
        if (query.includes('ragequit')) return 'RAGEQUIT_LOGIC ENABLED. YOU CAN LIQUIDATE YOUR POSITION FOR A PROPORTIONAL SHARE OF THE TREASURY AT ANY TIME. FAIRNESS IS HARDCODED.';
        if (query.includes('buy') || query.includes('fao')) return 'FAO_ACQUISITION DETECTED. BONDING CURVE PARAMETERS ARE OPERATIONAL. PHASE_I (14-DAY) EQUILIBRIUM ACTIVE.';
        if (query.includes('treasury')) return 'TREASURY_RESERVE SECURE. 100% LIQUIDITY BACKING DETECTED. CURRENT RATIO: 1:1.';
        return 'COMMAND_RECEIVED. PROCESSING PROBABILITIES... SYSTEM STABLE. PLEASE SPECIFY PROTOCOL QUERY.';
    };

    return (
        <div className="fixed bottom-8 right-8 z-[2000] font-mono">
            <AnimatePresence>
                {!isOpen ? (
                    <motion.button
                        layoutId="ai-widget"
                        onClick={() => setIsOpen(true)}
                        className="w-16 h-16 bg-white dark:bg-black border-2 border-black dark:border-white flex items-center justify-center shadow-[0_0_30px_rgba(0,0,0,0.1)] dark:shadow-[0_0_30px_rgba(255,255,255,0.1)] group"
                    >
                        <div className="w-6 h-6 border-2 border-black dark:border-white animate-spin [animation-duration:3s]" />
                        <div className="absolute inset-0 bg-black dark:bg-white scale-0 group-hover:scale-100 transition-transform duration-300 opacity-5" />
                        <span className="absolute -top-10 right-0 bg-black dark:bg-white text-white dark:text-black text-[8px] font-pixel px-2 py-1 opacity-0 group-hover:opacity-100 transition-opacity">AI_NODE_ACTIVE</span>
                    </motion.button>
                ) : (
                    <motion.div
                        layoutId="ai-widget"
                        className="w-[350px] md:w-[450px] h-[500px] bg-white dark:bg-black border-2 border-black dark:border-white flex flex-col shadow-[0_0_50px_rgba(0,0,0,0.2)] dark:shadow-[0_0_50px_rgba(255,255,255,0.2)] overflow-hidden"
                    >
                        {/* Header */}
                        <div className="p-4 border-b-2 border-black dark:border-white flex justify-between items-center bg-black dark:bg-white text-white dark:text-black">
                            <span className="font-pixel text-[10px] tracking-widest">FAO_AGENT_V4.2</span>
                            <button onClick={() => setIsOpen(false)} className="hover:opacity-50">[_CLOSE]</button>
                        </div>

                        {/* Messages */}
                        <div ref={scrollRef} className="flex-1 overflow-y-auto p-4 space-y-4 scrollbar-hide">
                            {messages.map((m, i) => (
                                <div key={i} className={`flex ${m.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                                    <div className={`max-w-[80%] p-3 text-[11px] leading-relaxed ${m.role === 'user'
                                            ? 'bg-black/5 dark:bg-white/5 border border-black/10 dark:border-white/10 italic'
                                            : 'text-black dark:text-white border-l-2 border-black dark:border-white pl-4'
                                        }`}>
                                        {m.role === 'agent' ? <TypewriterText text={m.text} speed={0.01} /> : m.text}
                                    </div>
                                </div>
                            ))}
                        </div>

                        {/* Input */}
                        <div className="p-4 border-t-2 border-black dark:border-white flex gap-2">
                            <input
                                type="text"
                                value={input}
                                onChange={(e) => setInput(e.target.value)}
                                onKeyDown={(e) => e.key === 'Enter' && handleSend()}
                                placeholder="ASK_THE_AGENT..."
                                className="flex-1 bg-transparent border-none outline-none text-[11px] placeholder:opacity-20 text-black dark:text-white"
                            />
                            <button onClick={handleSend} className="font-pixel text-[10px] bg-black dark:bg-white text-white dark:text-black px-4 py-2 hover:opacity-80">SEND</button>
                        </div>
                    </motion.div>
                )}
            </AnimatePresence>
        </div>
    );
}
