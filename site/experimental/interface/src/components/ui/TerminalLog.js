'use client';

import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TypewriterText } from './TypewriterText';

export function TerminalLog({ commands, onCommandSelect }) {
    const [history, setHistory] = useState([]);
    const [availableOptions, setAvailableOptions] = useState([]);
    const scrollRef = useRef(null);

    useEffect(() => {
        if (commands && commands.length > 0) {
            const initial = commands.find(c => c.id === 'boot') || commands[0];
            executeCommand(initial);
        }
    }, [commands]);

    useEffect(() => {
        if (scrollRef.current) {
            scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
        }
    }, [history]);

    const executeCommand = (cmd) => {
        const timestamp = new Date().toLocaleTimeString('en-GB', { hour12: false });

        setHistory(prev => [...prev, {
            type: 'input',
            text: `> EXECUTE: ${cmd.label}`,
            time: timestamp
        }]);

        setTimeout(() => {
            setHistory(prev => [...prev, {
                type: 'output',
                content: cmd.output,
                time: timestamp
            }]);
            setAvailableOptions(cmd.nextOptions || []);
            if (onCommandSelect) onCommandSelect(cmd.id);
        }, 300);
    };

    return (
        <div className="flex flex-col h-full font-mono text-white">
            {/* The Output Log */}
            <div
                ref={scrollRef}
                className="flex-1 overflow-y-auto space-y-5 sm:space-y-6 mb-6 sm:mb-8 pr-2 sm:pr-4 scrollbar-hide"
            >
                <AnimatePresence mode="popLayout">
                    {history.map((item, idx) => (
                        <motion.div
                            key={idx}
                            initial={{ opacity: 0, y: 5 }}
                            animate={{ opacity: 1, y: 0 }}
                            className={`${item.type === 'input' ? 'text-white/40' : 'text-white'}`}
                        >
                            <div className="flex flex-col sm:flex-row gap-2 sm:gap-6 items-start">
                                <span className="opacity-20 text-[8px] sm:text-[9px] whitespace-nowrap sm:pt-1">[{item.time}]</span>
                                <div className="flex-1 w-full">
                                    {item.type === 'input' ? (
                                        <span className="font-bold underline decoration-white/20 underline-offset-4">{item.text}</span>
                                    ) : (
                                        <div className="terminal-text leading-relaxed">
                                            {typeof item.content === 'string' ? (
                                                <TypewriterText text={item.content} speed={0.01} />
                                            ) : (
                                                item.content
                                            )}
                                        </div>
                                    )}
                                </div>
                            </div>
                        </motion.div>
                    ))}
                </AnimatePresence>
            </div>

            {/* The Input Options (Monochrome Grid) */}
            <div className="border-t border-white/10 pt-6 sm:pt-8 pb-4">
                <div className="text-[9px] sm:text-[10px] font-pixel mb-4 sm:mb-6 opacity-30 tracking-widest uppercase">
                    SYSTEM_COMMAND_SELECTION:
                </div>
                <div className="flex flex-wrap gap-3 sm:gap-4">
                    {availableOptions.map((optId) => {
                        const opt = commands.find(c => c.id === optId);
                        if (!opt) return null;
                        return (
                            <button
                                key={opt.id}
                                onClick={() => executeCommand(opt)}
                                className="terminal-button w-full sm:w-auto text-center"
                            >
                                [ {opt.label} ]
                            </button>
                        );
                    })}
                </div>
            </div>
        </div>
    );
}
