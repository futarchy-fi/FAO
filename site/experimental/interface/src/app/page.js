'use client';

import { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { motion, AnimatePresence, useInView } from 'framer-motion';
import { formatEther } from 'viem';
import { useAccount, useReadContract } from 'wagmi';
import { useNativeCurrency } from '../hooks/useNativeCurrency';
import FAOTokenABI from '../abi/FAOToken.json';
import FAOSaleABI from '../abi/FAOSale.json';
import { FAO_TOKEN_ADDRESS, FAO_SALE_ADDRESS } from '../hooks/useFAOContract';

import { ConnectWallet } from '../components/ConnectWallet';
import SwapPanel from '../components/SwapPanel';
import { TypewriterText } from '../components/ui/TypewriterText';
import PhaseCountdown from '../components/PhaseCountdown';
import ActivityCarousel from '../components/ActivityCarousel';
import FutarchyVisualizer from '../components/FutarchyVisualizer';
import { ConstructionLogo } from '../components/ui/ConstructionLogo';
import LiveTicker from '../components/LiveTicker';
import ProtocolStats from '../components/ProtocolStats';
import ContractCodeViewer from '../components/ContractCodeViewer';
import TokenDistribution from '../components/TokenDistribution';
import { useSubgraphData } from '../hooks/useSubgraphData';
import { useFAOQuoter } from '../hooks/useFAOQuoter';
import { toast } from 'sonner';

const ScrollTypingHeader = ({ text, className = "" }) => {
    const ref = useRef(null);
    const isInView = useInView(ref, { once: true, amount: 0.5 });

    return (
        <div ref={ref} className={className}>
            {isInView ? <TypewriterText text={text} speed={0.03} /> : <span className="opacity-0">{text}</span>}
        </div>
    );
};

export default function Dashboard() {
    // const [tradeMode, setTradeMode] = useState('buy'); // Removed: SwapPanel handles mode internally
    const [showCurveInfo, setShowCurveInfo] = useState(false);
    const [activeSection, setActiveSection] = useState('manifesto');
    const [isMobile, setIsMobile] = useState(false);
    const [navIndex, setNavIndex] = useState(0);
    const [navOffset, setNavOffset] = useState(0);
    const [navAnimating, setNavAnimating] = useState(false);
    const [navDragX, setNavDragX] = useState(0);
    const navViewportRef = useRef(null);
    const navDragXRef = useRef(0);
    const navWidthRef = useRef(0);
    const navPendingRef = useRef(0);
    const [tradePanelOpen, setTradePanelOpen] = useState(false);
    const [portalReady, setPortalReady] = useState(false);
    const [portfolioUpdatePending, setPortfolioUpdatePending] = useState(false);
    const previousBalanceRef = useRef(null);
    const optimisticStartTimeRef = useRef(null);

    const sections = [
        { id: 'manifesto', label: '01 // GOVERNANCE_ARCHITECTURE' },
        { id: 'intel', label: '02 // PROTOCOL_INTEL' },
        { id: 'audit', label: '03 // TRANSACTION_LOG' },
        { id: 'treasury', label: '04 // TREASURY' },
        { id: 'governance', label: '05 // PARTICIPATION' }
    ];

    // Fetch live transaction and sale data from subgraph (30s auto-refresh)
    const {
        transactions: liveTransactions,
        sale,
        lastSyncedAtUTC,
        refetch: refetchSubgraph,
        isLoading: isSyncing
    } = useSubgraphData({ pollInterval: 30000 });

    useEffect(() => {
        const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    setActiveSection(entry.target.id);
                }
            });
        }, { threshold: 0.5 });

        sections.forEach(s => {
            const el = document.getElementById(s.id);
            if (el) observer.observe(el);
        });

        return () => observer.disconnect();
    }, []);

    const scrollTo = (id) => {
        const el = document.getElementById(id);
        if (el) el.scrollIntoView({ behavior: 'smooth' });
    };

    useEffect(() => {
        const handleResize = () => setIsMobile(window.innerWidth <= 768);
        handleResize();
        window.addEventListener('resize', handleResize);
        return () => window.removeEventListener('resize', handleResize);
    }, []);

    useEffect(() => {
        setPortalReady(true);
    }, []);

    // Mobile Navigation Effects
    useEffect(() => {
        const updateWidth = () => {
            const width = navViewportRef.current?.getBoundingClientRect().width || 0;
            navWidthRef.current = width;
            setNavOffset(-width);
            setNavDragX(0);
        };
        updateWidth();
        window.addEventListener('resize', updateWidth);
        return () => window.removeEventListener('resize', updateWidth);
    }, []);

    const navPrevIndex = (navIndex - 1 + sections.length) % sections.length;
    const navNextIndex = (navIndex + 1) % sections.length;

    const navGoNext = () => {
        if (navAnimating || !navWidthRef.current) return;
        navPendingRef.current = 1;
        setNavAnimating(true);
        setNavOffset(-2 * navWidthRef.current);
    };

    const navGoPrev = () => {
        if (navAnimating || !navWidthRef.current) return;
        navPendingRef.current = -1;
        setNavAnimating(true);
        setNavOffset(0);
    };

    const navSnapBack = () => {
        if (navAnimating || !navWidthRef.current) return;
        navPendingRef.current = 0;
        setNavAnimating(true);
        setNavOffset(-navWidthRef.current);
    };

    const navHandleTransitionEnd = () => {
        if (!navAnimating) return;
        if (navPendingRef.current === 1) {
            setNavIndex((current) => (current + 1) % sections.length);
        } else if (navPendingRef.current === -1) {
            setNavIndex((current) => (current - 1 + sections.length) % sections.length);
        }
        navPendingRef.current = 0;
        setNavAnimating(false);
        setNavDragX(0);
        setNavOffset(-navWidthRef.current);
    };

    const navTouchStart = (event) => {
        navWidthRef.current = navViewportRef.current?.getBoundingClientRect().width || navWidthRef.current;
        navDragXRef.current = event.touches[0].clientX;
    };

    const navTouchMove = (event) => {
        if (navAnimating || !navWidthRef.current) return;
        const delta = event.touches[0].clientX - navDragXRef.current;
        setNavDragX(delta);
        setNavOffset(-navWidthRef.current + delta);
    };

    const navTouchEnd = () => {
        if (navAnimating || !navWidthRef.current) return;
        const threshold = Math.max(40, navWidthRef.current * 0.18);
        if (navDragX > threshold) {
            navGoPrev();
        } else if (navDragX < -threshold) {
            navGoNext();
        } else {
            navSnapBack();
        }
    };

    // -- REAL DATA INTEGRATION --
    const { address } = useAccount();
    const { symbol: nativeSymbol } = useNativeCurrency();
    const quoterData = useFAOQuoter();
    const [isPhase0TimeExpired, setIsPhase0TimeExpired] = useState(false);

    useEffect(() => {
        if (quoterData.contractData?.initialPhaseEnd) {
            const check = () => {
                const now = Date.now() / 1000;
                setIsPhase0TimeExpired(now > Number(quoterData.contractData.initialPhaseEnd));
            };
            check();
            const timer = setInterval(check, 1000);
            return () => clearInterval(timer);
        }
    }, [quoterData.contractData?.initialPhaseEnd]);

    const [optimisticDelta, setOptimisticDelta] = useState(0); // Tokens added/removed optimistically

    // Fetch FAO Balance
    const { data: faoBalance, refetch: refetchBalance } = useReadContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'balanceOf',
        args: [address],
        query: { enabled: !!address, pollInterval: portfolioUpdatePending ? 1000 : 5000 }
    });

    // Callback for child panels to trigger optimistic update
    // delta: positive for buy (tokens gained), negative for ragequit (tokens burned)
    const onTransactionSuccess = useCallback((deltaTokens) => {
        const delta = deltaTokens || 0;

        if (portfolioUpdatePending) {
            // ALREADY SYNCING: Stack the new delta on top of existing optimistic delta
            // Example: Was showing 15k, sold 10k (delta=-10k, showing 5k), now buy 20k
            // New delta should be: -10k + 20k = +10k (so 15k + 10k = 25k displayed)
            console.log("=== STACKING TRANSACTION ===", {
                existingDelta: optimisticDelta,
                newDelta: delta,
                combined: optimisticDelta + delta
            });

            const newCombinedDelta = optimisticDelta + delta;
            const rawBalance = faoBalance ? Number(formatEther(faoBalance)) : 0;
            const newExpectedBalance = Math.floor(rawBalance + newCombinedDelta);

            previousBalanceRef.current = newExpectedBalance;
            setOptimisticDelta(newCombinedDelta);
            // Reset the timer for the new stacked transaction
            optimisticStartTimeRef.current = Date.now();
        } else {
            // FRESH TRANSACTION: Start optimistic update from current RPC balance
            const currentBalance = faoBalance ? Number(formatEther(faoBalance)) : 0;
            const expectedBalance = Math.floor(currentBalance + delta);

            console.log("=== NEW OPTIMISTIC UPDATE ===", {
                currentBalance,
                delta,
                expectedBalance
            });

            previousBalanceRef.current = expectedBalance;
            setOptimisticDelta(delta);
            setPortfolioUpdatePending(true);
        }
    }, [faoBalance, portfolioUpdatePending, optimisticDelta]);

    // Clear optimistic delta ONLY when RPC returns the expected value
    useEffect(() => {
        if (!portfolioUpdatePending || previousBalanceRef.current === null) return;

        // Set start time on first run
        if (!optimisticStartTimeRef.current) {
            optimisticStartTimeRef.current = Date.now();
        }

        // Wait at least 2 seconds before checking (prevent race conditions)
        const elapsed = Date.now() - optimisticStartTimeRef.current;
        if (elapsed < 2000) {
            const waitTimeout = setTimeout(() => { }, 100); // Force re-check
            return () => clearTimeout(waitTimeout);
        }

        // Check if RPC balance now matches our expected value
        const currentBalance = faoBalance ? Math.floor(Number(formatEther(faoBalance))) : 0;
        const expectedBalance = previousBalanceRef.current;

        console.log("=== OPTIMISTIC CHECK ===", { currentBalance, expectedBalance, elapsed });

        if (currentBalance === expectedBalance) {
            // RPC caught up to expected value - clear optimistic delta
            console.log("RPC SYNCED - clearing optimistic state");
            setOptimisticDelta(0);
            setPortfolioUpdatePending(false);
            previousBalanceRef.current = null;
            optimisticStartTimeRef.current = null;
            return;
        }

        // Fallback timeout: clear after 60 seconds (but keep showing real RPC value)
        const timeout = setTimeout(() => {
            console.log("FALLBACK TIMEOUT - clearing optimistic state");
            setOptimisticDelta(0);
            setPortfolioUpdatePending(false);
            previousBalanceRef.current = null;
            optimisticStartTimeRef.current = null;
        }, 60000);

        return () => clearTimeout(timeout);
    }, [faoBalance, portfolioUpdatePending]);

    // Fetch Current Price
    const { data: currentPriceWei } = useReadContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'currentPriceWeiPerToken',
        watch: true,
    });

    // Add FAO token to MetaMask
    const addToMetaMask = async () => {
        if (typeof window.ethereum === 'undefined') {
            toast.error('MetaMask not detected');
            return;
        }
        try {
            await window.ethereum.request({
                method: 'wallet_watchAsset',
                params: {
                    type: 'ERC20',
                    options: {
                        address: FAO_TOKEN_ADDRESS,
                        symbol: 'FAO',
                        decimals: 18,
                        image: 'https://fao.futarchy.fi/fao-icon.png',
                    },
                },
            });
            toast.success('FAO token added to wallet!');
        } catch (error) {
            toast.error('Failed to add token');
        }
    };

    // Calculations - use optimistic delta for immediate feedback
    // Calculations - separated for clear UI feedback (Real vs Projected)
    const rawHoldings = faoBalance ? Number(formatEther(faoBalance)) : 0;
    const projectedHoldings = rawHoldings + optimisticDelta;

    // Exit Value based on CONFIRMED holdings (Real RPC)
    const exitValueEth = (rawHoldings * (currentPriceWei ? Number(formatEther(currentPriceWei)) : 0));

    // Use en-US locale for consistent formatting
    const formattedRpcHoldings = Math.floor(rawHoldings).toLocaleString('en-US');
    const formattedProjected = Math.floor(projectedHoldings).toLocaleString('en-US');
    const formattedDelta = (optimisticDelta > 0 ? '+' : '') + Math.floor(optimisticDelta).toLocaleString('en-US');
    const formattedExitValue = exitValueEth > 0 ? exitValueEth.toFixed(4) : "0.0000";


    return (
        <div className="min-h-[100dvh] bg-black text-white selection:bg-white selection:text-black scroll-smooth flex flex-col">
            {/* REAL-TIME TOP TICKER */}
            <LiveTicker />

            {/* PROTOCOL STATUS HUD (PINNED) */}

            {/* Subtle Global Scanline Overlay */}
            <div className="fixed inset-0 pointer-events-none z-50 opacity-[0.03] bg-[linear-gradient(rgba(18,16,16,0)_50%,rgba(255,255,255,0.25)_50%),linear-gradient(90deg,rgba(255,255,255,0.06),rgba(255,255,255,0.02),rgba(255,255,255,0.06))] bg-[length:100%_2px,2px_100%]" />

            <div className="max-w-[1800px] mx-auto px-4 sm:px-6 lg:px-12 py-8 md:py-12 relative z-10 w-full">
                {/* Website Header */}
                <header className="flex flex-col gap-4 border-b border-white/10 pb-6 md:pb-12 mb-10 md:mb-16">
                    <div className="flex flex-col sm:flex-row sm:items-center gap-4">
                        <div className="flex items-center gap-3 sm:gap-4">
                            <div className="w-10 h-10 sm:w-12 sm:h-12 grayscale brightness-200 cursor-pointer flex-shrink-0" onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })}>
                                <ConstructionLogo />
                            </div>
                            <h1 className="font-pixel text-xl sm:text-2xl tracking-tighter leading-none whitespace-nowrap">FAO</h1>
                        </div>
                        <span className="font-pixel text-[7px] sm:text-[8px] opacity-30 tracking-[0.35em] uppercase sm:ml-2 whitespace-nowrap">
                            FUTARCHY_AUTONOMOUS_OPTIMIZER
                        </span>
                        <div className="w-full sm:w-auto sm:ml-auto flex items-center gap-3 sm:gap-4">
                            <div className="w-full sm:w-auto">
                                <ConnectWallet />
                            </div>
                        </div>
                    </div>

                    {/* GLOBAL NAVIGATION TABS - now on its own row */}
                    <div className="relative w-full">
                        <button
                            type="button"
                            onClick={navGoPrev}
                            className="sm:hidden absolute left-2 top-1/2 -translate-y-1/2 z-20 w-8 h-8 rounded-full border border-white/20 bg-black/80 text-white/80 flex items-center justify-center"
                            aria-label="Scroll navigation left"
                        >
                            {'<'}
                        </button>
                        <button
                            type="button"
                            onClick={navGoNext}
                            className="sm:hidden absolute right-2 top-1/2 -translate-y-1/2 z-20 w-8 h-8 rounded-full border border-white/20 bg-black/80 text-white/80 flex items-center justify-center"
                            aria-label="Scroll navigation right"
                        >
                            {'>'}
                        </button>

                        {/* Mobile carousel */}
                        <div
                            ref={navViewportRef}
                            className="sm:hidden overflow-hidden bg-white/5 p-1 rounded-sm border border-white/5"
                            onTouchStart={navTouchStart}
                            onTouchMove={navTouchMove}
                            onTouchEnd={navTouchEnd}
                            onTouchCancel={navTouchEnd}
                        >
                            <div
                                className="flex w-[300%]"
                                onTransitionEnd={navHandleTransitionEnd}
                                style={{
                                    transform: `translateX(${navOffset}px)`,
                                    transition: navAnimating ? 'transform 240ms ease' : 'none',
                                }}
                            >
                                {[navPrevIndex, navIndex, navNextIndex].map((idx) => {
                                    const section = sections[idx];
                                    const label = section.label.split(' // ')[1];
                                    const active = activeSection === section.id;
                                    return (
                                        <button
                                            key={section.id}
                                            onClick={() => scrollTo(section.id)}
                                            className={`w-full flex-shrink-0 py-2 font-pixel text-[9px] transition-all whitespace-nowrap flex items-center justify-center text-center ${active
                                                ? 'bg-white text-black'
                                                : 'text-white/40 hover:text-white hover:bg-white/5'
                                                }`}
                                        >
                                            {label}
                                        </button>
                                    );
                                })}
                            </div>
                        </div>

                        {/* Desktop tabs */}
                        <nav className="hidden sm:flex flex-wrap items-center gap-2 bg-white/5 p-1 rounded-sm border border-white/5 w-full">
                            {sections.map((s) => (
                                <button
                                    key={s.id}
                                    onClick={() => scrollTo(s.id)}
                                    className={`px-3 sm:px-4 py-2 font-pixel text-[8px] sm:text-[9px] transition-all whitespace-nowrap ${activeSection === s.id
                                        ? 'bg-white text-black'
                                        : 'text-white/40 hover:text-white hover:bg-white/5'
                                        }`}
                                >
                                    {s.label.split(' // ')[1]}
                                </button>
                            ))}
                        </nav>
                    </div>
                </header>

                {/* FULL-WIDTH HERO SECTION (BREAKING OUT OF SIDEBARS) */}
                <section id="manifesto" className="scroll-mt-20 mb-16 md:mb-20">
                    <div className="relative w-full border border-white/20 bg-black group mb-8 md:mb-12">
                        <FutarchyVisualizer />
                    </div>

                    <div className="space-y-6">
                        <ScrollTypingHeader text="PROTOCOL_GOVERNANCE_ARCHITECTURE" className="ico-header" />
                        <div className="text-2xl sm:text-3xl xl:text-4xl font-mono leading-tight max-w-5xl text-white/90">
                            <TypewriterText text="FAO IS AN AUTONOMOUS GOVERNANCE PROTOCOL POWERED BY CONDITIONAL TOKEN MARKETS. WE SEPARATE STRATEGIC VALUES FROM ANALYTICAL BELIEFS TO OPTIMIZE CAPITAL ALLOCATION VIA THE GNOSIS CONDITIONAL TOKEN FRAMEWORK (CTF)." speed={0.01} />
                        </div>
                    </div>

                    {/* LIVE PROTOCOL STATS */}
                    <div className="mt-8">
                        <ProtocolStats />
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6 md:gap-10 pt-10 md:pt-12 border-t border-white/10 mt-10 md:mt-12">
                        <div className="phase-card space-y-6 p-5 md:p-8">
                            <div className="flex justify-between items-start">
                                <div className="space-y-4">
                                    <h3 className={`font-pixel text-sm flex items-center gap-3 ${quoterData.isPhase1 ? 'text-white/40' : 'text-white'}`}>
                                        PHASE_0: COLLATERAL_ACCUMULATION
                                        {quoterData.isPhase0 && !isPhase0TimeExpired && (
                                            <span className="bg-green-500 text-black px-2 py-0.5 text-[8px] animate-pulse">ACTIVE</span>
                                        )}
                                        {quoterData.isPhase0 && isPhase0TimeExpired && (
                                            <span className="bg-yellow-500 text-black px-2 py-0.5 text-[8px] animate-pulse">AWAITING_FINALIZATION</span>
                                        )}
                                        {quoterData.isPhase1 && (
                                            <span className="bg-white/20 text-white px-2 py-0.5 text-[8px]">COMPLETE</span>
                                        )}
                                    </h3>
                                    <p className="text-white/50 font-mono text-sm leading-relaxed">
                                        {quoterData.isPhase1 || isPhase0TimeExpired
                                            ? 'Phase 0 has ended. See Phase 1 for current bonding curve status.'
                                            : 'Initial allocation phase. FAO is priced at a constant floor to ensure fair-start liquidity depth before curve activation.'
                                        }
                                    </p>
                                </div>
                            </div>
                            <PhaseCountdown />
                        </div>
                        <div className="phase-card space-y-6 p-5 md:p-8">
                            <div className="space-y-4">
                                <h3 className={`font-pixel text-sm ${quoterData.isPhase1 ? 'text-yellow-400' : 'text-white/40'}`}>
                                    PHASE_1: ALGORITHMIC_EXPANSION
                                    {quoterData.isPhase1 && <span className="bg-yellow-500 text-black px-2 py-0.5 text-[8px] animate-pulse ml-3">ACTIVE</span>}
                                </h3>
                                <p className="text-white/30 font-mono text-sm leading-relaxed">
                                    {quoterData.isPhase1
                                        ? 'The bonding curve is now active. Price increases with each token minted.'
                                        : 'The mathematical expansion phase. Price increases proportionally with supply, following a predefined P = P₀ × (1 + x/S) curve.'
                                    }
                                </p>

                                {quoterData.isPhase1 ? (
                                    <div className="space-y-4">
                                        <div className="p-4 bg-yellow-500/10 border border-yellow-500/30">
                                            <div className="font-pixel text-[9px] text-yellow-400 tracking-wider mb-3">
                                                BONDING_CURVE: P = P₀ × (1 + x/S)
                                            </div>
                                            <div className="space-y-4">
                                                <div className="grid grid-cols-2 gap-4 text-[10px] font-mono">
                                                    {/* P0 */}
                                                    <div className="space-y-1 bg-white/5 p-2 border border-white/5">
                                                        <div className="flex items-baseline justify-between text-white/40 border-b border-white/10 pb-1 mb-1">
                                                            <span className="text-white/60 font-bold text-xs">P₀</span>
                                                            <span className="text-[7px] uppercase tracking-wide opacity-50">INITIAL_PRICE</span>
                                                        </div>
                                                        <div className="text-white text-xs font-bold">
                                                            {quoterData.curveParams.initialPriceFormatted} <span className="text-[9px] opacity-40 font-normal">xDAI</span>
                                                        </div>
                                                        <div className="text-[8px] text-white/30 leading-tight pt-1">
                                                            Base floor price established during Phase 0.
                                                        </div>
                                                    </div>

                                                    {/* S */}
                                                    <div className="space-y-1 bg-white/5 p-2 border border-white/5">
                                                        <div className="flex items-baseline justify-between text-white/40 border-b border-white/10 pb-1 mb-1">
                                                            <span className="text-white/60 font-bold text-xs">S</span>
                                                            <span className="text-[7px] uppercase tracking-wide opacity-50">ANCHOR_SUPPLY</span>
                                                        </div>
                                                        <div className="text-white text-xs font-bold">
                                                            {quoterData.curveParams.initialNetSaleFormatted} <span className="text-[9px] opacity-40 font-normal">FAO</span>
                                                        </div>
                                                        <div className="text-[8px] text-white/30 leading-tight pt-1">
                                                            Total FAO sold in Phase 0. Acts as the liquidity scalar.
                                                        </div>
                                                    </div>
                                                </div>

                                                {/* x */}
                                                <div className="grid grid-cols-2 gap-4 text-[10px] font-mono">
                                                    <div className="space-y-1 bg-white/5 p-2 border border-white/5">
                                                        <div className="flex items-baseline justify-between text-white/40 border-b border-white/10 pb-1 mb-1">
                                                            <span className="text-white/60 font-bold text-xs">x</span>
                                                            <span className="text-[7px] uppercase tracking-wide opacity-50">CURVE_MINTED</span>
                                                        </div>
                                                        <div className="text-white text-xs font-bold">
                                                            {quoterData.curveParams.curveSoldFormatted} <span className="text-[9px] opacity-40 font-normal">FAO</span>
                                                        </div>
                                                        <div className="text-[8px] text-white/30 leading-tight pt-1">
                                                            New supply minted via bonding curve since Phase 1 start.
                                                        </div>
                                                    </div>

                                                    {/* Result P */}
                                                    <div className="flex flex-col justify-center text-right p-2">
                                                        <div className="text-[8px] text-white/40 mb-1 uppercase tracking-widest">Current Price (P)</div>
                                                        <div className="text-yellow-400 font-bold text-xl">
                                                            {quoterData.curveParams.currentPriceFormatted} <span className="text-xs text-yellow-500/50">xDAI</span>
                                                        </div>
                                                        <div className="text-[9px] font-mono text-white/20 mt-1">
                                                            P = P₀ × (1 + x/S)
                                                        </div>
                                                    </div>
                                                </div>
                                            </div>
                                            {quoterData.quoteAge && (
                                                <div className="text-[8px] font-mono text-white/30 mt-3 text-right">
                                                    RPC_SYNCED: {quoterData.quoteAge} AGO
                                                </div>
                                            )}
                                        </div>
                                    </div>
                                ) : (
                                    <div className="space-y-4">
                                        <div className="p-3 bg-white/5 border border-white/10 font-mono text-[10px] space-y-2">
                                            <div className="flex justify-between">
                                                <span className="text-white/40">INITIAL_PHASE_FINALIZED:</span>
                                                <span className={quoterData.contractData?.initialPhaseFinalized ? "text-green-500" : "text-red-500"}>
                                                    {quoterData.contractData?.initialPhaseFinalized ? 'TRUE' : 'FALSE'}
                                                </span>
                                            </div>
                                            <div className="flex justify-between">
                                                <span className="text-white/40">MARKET_STATUS:</span>
                                                <span className="text-white">AWAITING_FINALIZATION</span>
                                            </div>
                                            {quoterData.quoteAge && (
                                                <div className="pt-2 mt-2 border-t border-white/5 text-[9px] text-white/30 text-right">
                                                    RPC_SYNCED_VIA_WAGMI: {quoterData.quoteAge} AGO
                                                </div>
                                            )}
                                        </div>
                                    </div>
                                )}
                            </div>
                        </div>
                    </div>
                </section>

                <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_440px] xl:grid-cols-[minmax(0,1fr)_480px] gap-8 xl:gap-16 items-start">
                    {/* MAIN SCROLLABLE CONTENT */}
                    <main className="flex-1 min-w-0 space-y-16 md:space-y-32 xl:space-y-40 pb-24 md:pb-32">
                        {/* SECTION 02: KNOWLEDGE_BASE */}
                        <section id="intel" className="space-y-16 md:space-y-24 scroll-mt-20">
                            <div className="space-y-4">
                                <ScrollTypingHeader text="PROTOCOL_GOVERNANCE_INTEL" className="ico-header text-3xl sm:text-4xl lg:text-5xl" />
                                <p className="opacity-40 font-pixel text-[8px] tracking-[0.4em] uppercase italic">// SOURCE: GOVERNANCE_OPERATING_MANUAL_V1.2</p>
                            </div>

                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8 md:gap-12">
                                {/* Core Concept */}
                                <div className="space-y-6 md:space-y-8 p-6 md:p-10 border border-white/20 bg-white/[0.02]">
                                    <div className="flex items-center gap-4">
                                        <div className="w-10 h-10 rounded-full border border-blue-500/40 flex items-center justify-center font-pixel text-blue-500 text-xs">01</div>
                                        <h3 className="font-pixel text-lg tracking-tighter">VALUES_VS_BELIEFS</h3>
                                    </div>
                                    <p className="font-mono text-white/60 leading-relaxed text-sm md:text-base">
                                        FUTARCHY TARGETS THE CORE INEFFICIENCY OF GOVERNANCE: THE BLURRING OF INTENT (VALUES) AND EXECUTION (BELIEFS).
                                        IN OUR SYSTEM, <span className="text-white font-bold uppercase">HUMANS DECIDE THE TARGET OUTCOME</span> (E.G., TOKEN PRICE GROWTH),
                                        WHILE <span className="text-white font-bold uppercase">MARKETS AGGREGATE INFORMATION</span> TO DETERMINE THE BEST PATH TO THAT OUTCOME.
                                    </p>
                                    <div className="grid grid-cols-2 gap-4 pt-4 border-t border-white/5">
                                        <div className="space-y-2">
                                            <div className="font-pixel text-[8px] opacity-30 uppercase tracking-widest">HUMAN_ROLE</div>
                                            <div className="text-[10px] font-mono opacity-80 uppercase">DEFINE_SUCCESS_METRIC</div>
                                        </div>
                                        <div className="space-y-2">
                                            <div className="font-pixel text-[8px] opacity-30 uppercase tracking-widest">MARKET_ROLE</div>
                                            <div className="text-[10px] font-mono opacity-80 uppercase">EXECUTE_OPTIMAL_PATH</div>
                                        </div>
                                    </div>
                                </div>

                                {/* Counterfactual Worlds */}
                                <div className="space-y-6 md:space-y-8 p-6 md:p-10 border border-white/10 bg-black">
                                    <div className="flex items-center gap-4">
                                        <div className="w-10 h-10 rounded-full border border-yellow-500/40 flex items-center justify-center font-pixel text-yellow-500 text-xs">02</div>
                                        <h3 className="font-pixel text-lg tracking-tighter">COUNTERFACTUAL_EXP</h3>
                                    </div>
                                    <p className="font-mono text-white/50 leading-relaxed italic">
                                        "WHAT IF THE PROPOSAL IS APPROVED? WHAT IF IT IS NOT?"
                                    </p>
                                    <p className="font-mono text-white/60 leading-relaxed">
                                        FOR EVERY GOVERNANCE PROPOSAL, WE INITIALIZE TWO PARALLEL WORLDS: <span className="text-blue-400">YES (APPROVAL)</span> AND <span className="text-yellow-400">NO (REJECTION)</span>.
                                        TRADERS DO NOT BET ON THE FUTURE; THEY TRADE ON <span className="text-white font-bold opacity-100">CONDITIONAL EXPOSURE</span>.
                                        POSITIONS ONLY LEGALIZE IF THE CORRESPONDING WORLD OCCURS ON-CHAIN.
                                    </p>
                                    <div className="flex items-center gap-6 pt-4 border-t border-white/5">
                                        <div className="flex items-center gap-2">
                                            <div className="w-2 h-2 rounded-full bg-blue-500" />
                                            <span className="font-pixel text-[8px] opacity-40 uppercase">WORLD_ALPHA</span>
                                        </div>
                                        <div className="flex items-center gap-2">
                                            <div className="w-2 h-2 rounded-full bg-yellow-500" />
                                            <span className="font-pixel text-[8px] opacity-40 uppercase">WORLD_BETA</span>
                                        </div>
                                    </div>
                                </div>
                            </div>

                            {/* Deep Trading Logic */}
                            <div className="p-8 md:p-12 border border-white/5 bg-white/[0.01] space-y-10 md:space-y-12">
                                <div className="max-w-3xl space-y-6">
                                    <h3 className="font-pixel text-lg tracking-tighter uppercase leading-none">SECURED_BY_GNOSIS_CFT</h3>
                                    <p className="font-mono text-base md:text-lg text-white/50 leading-relaxed uppercase">
                                        SECURED BY THE INDUSTRY-STANDARD GNOSIS CONDITIONAL TOKEN FRAMEWORK (CTF) - THE SAME CRYPTOGRAPHIC ARCHITECTURE PROTECTING BILLIONS IN TVL.
                                    </p>
                                </div>

                                <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 md:gap-12">
                                    <div className="space-y-4">
                                        <div className="font-pixel text-[8px] text-white/30 uppercase tracking-[0.3em]">/ COLLATERAL_SPLITTING</div>
                                        <p className="font-mono text-xs text-white/40 leading-relaxed lowercase">
                                            your currency is first split into YES_CURRENCY and NO_CURRENCY. this represents your collateral in each of the two possible worlds.
                                        </p>
                                    </div>
                                    <div className="space-y-4">
                                        <div className="font-pixel text-[8px] text-white/30 uppercase tracking-[0.3em]">/ DETERMINISTIC_SETTLEMENT</div>
                                        <p className="font-mono text-xs text-white/40 leading-relaxed lowercase">
                                            if a proposal fails, NO_CURRENCY is redeemable back to original currency. if it passes, YES_TOKEN becomes the underlying project asset.
                                        </p>
                                    </div>
                                    <div className="space-y-4">
                                        <div className="font-pixel text-[8px] text-white/30 uppercase tracking-[0.3em]">/ INFORMATION_HARVESTING</div>
                                        <p className="font-mono text-xs text-white/40 leading-relaxed lowercase">
                                            as participants trade in both markets, prices adjust to balance all views. the price delta represents the expected impact of the decision.
                                        </p>
                                    </div>
                                </div>

                                <div className="pt-10 md:pt-12 border-t border-white/5 flex flex-col md:flex-row gap-8 md:gap-12">
                                    <div className="flex flex-col gap-2">
                                        <span className="font-pixel text-[8px] opacity-20 uppercase tracking-widest">SYSTEM_VERSION</span>
                                        <span className="font-mono text-xs opacity-60 italic">FAO_PROTOCOL_V4.2</span>
                                    </div>
                                    <div className="flex flex-col gap-2">
                                        <span className="font-pixel text-[8px] opacity-20 uppercase tracking-widest">NETWORK_DEPLOYMENT</span>
                                        <span className="font-mono text-xs opacity-60 italic">GNOSIS_CHAIN_MAINTNET</span>
                                    </div>
                                </div>
                            </div>

                            {/* Practical Example Scenario */}
                            <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 items-center">
                                <div className="space-y-6">
                                    <h4 className="font-pixel text-xl tracking-tighter uppercase">PRACTICAL_SCENARIO: PROPOSAL_#84</h4>
                                    <div className="p-6 border-l-2 border-blue-500 bg-white/[0.02] space-y-4 font-mono text-sm uppercase">
                                        <p className="text-white">PROPOSAL: ALLOCATE 1M USDC TO PROTOCOL_MARKETING</p>
                                        <div className="grid grid-cols-2 gap-4">
                                            <div className="space-y-1">
                                                <span className="text-[8px] opacity-40">YES_MARKET_PRICE</span>
                                                <div className="text-blue-400 font-black">$1.45</div>
                                            </div>
                                            <div className="space-y-1">
                                                <span className="text-[8px] opacity-40">NO_MARKET_PRICE</span>
                                                <div className="text-yellow-400 font-black">$1.32</div>
                                            </div>
                                        </div>
                                    </div>
                                    <p className="font-mono text-sm text-white/50 leading-relaxed uppercase">
                                        IN THIS SCENARIO, THE MARKET PREDICTS A <span className="text-white font-bold">$0.13 VALUE UPLIFT</span> IF THE MARKETING BUDGET IS APPROVED. THE PROTOCOL AUTOMATICALLY EXECUTES THE APPROVAL BASED ON THIS DELTA.
                                    </p>
                                </div>
                                <div className="border border-white/10 p-8 space-y-6">
                                    <div className="space-y-2">
                                        <div className="font-pixel text-[8px] opacity-30 tracking-[0.3em]">DECISION_MATRIX</div>
                                        <div className="h-2 w-full bg-white/5 overflow-hidden">
                                            <div className="h-full bg-blue-500 w-[65%]" />
                                        </div>
                                    </div>
                                    <div className="space-y-4 font-mono text-[10px] text-white/40 uppercase">
                                        <div className="flex justify-between">
                                            <span>MARKET_CONFIDENCE</span>
                                            <span className="text-white opacity-100">89.2%</span>
                                        </div>
                                        <div className="flex justify-between">
                                            <span>SETTLEMENT_ETD</span>
                                            <span className="text-white opacity-100">48H_00M</span>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </section>

                        {/* SECTION 03: TRANSACTION_LOG */}
                        <section id="audit" className="space-y-12 scroll-mt-20">
                            <div className="space-y-4">
                                <ScrollTypingHeader text="TRANSACTION_LOG" className="ico-header px-4 py-2 border border-white/10 inline-block" />
                                <div className="flex gap-4 items-center">
                                    <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
                                    <span className="text-[8px] font-pixel opacity-40 uppercase tracking-[0.4em]">VERIFIED_ON_CHAIN_TRANSMISSION</span>
                                </div>
                            </div>

                            <ActivityCarousel />

                            <div className="border border-white/10 overflow-hidden bg-white/2">
                                <div className="overflow-x-auto">
                                    <table className="min-w-[640px] w-full text-left font-mono text-[10px] md:text-xs">
                                        <thead>
                                            <tr className="border-b border-white/10 bg-white/5">
                                                <th className="p-4 md:p-6 font-pixel text-[8px] opacity-40 uppercase">COMMAND</th>
                                                <th className="p-4 md:p-6 font-pixel text-[8px] opacity-40 uppercase whitespace-nowrap">TRANSACTION HASH</th>
                                                <th className="p-4 md:p-6 font-pixel text-[8px] opacity-40 uppercase">MAGNITUDE</th>
                                                <th className="p-4 md:p-6 font-pixel text-[8px] opacity-40 uppercase whitespace-nowrap">TIME RELATIVE</th>
                                            </tr>
                                        </thead>
                                        <tbody className="divide-y divide-white/5">
                                            {liveTransactions.slice(0, 10).map((tx, i) => (
                                                <tr key={tx.id || i} className="hover:bg-white/5 transition-colors group">
                                                    <td className="p-4 md:p-6 uppercase">
                                                        <span className={`px-2 py-1 font-pixel text-[9px] ${tx.type === 'BUY' ? 'bg-blue-600 text-white' :
                                                            tx.type === 'RAGEQUIT' ? 'bg-red-600 text-white' :
                                                                'bg-white text-black'
                                                            }`}>
                                                            {tx.type}
                                                        </span>
                                                    </td>
                                                    <td className="p-4 md:p-6 font-mono opacity-60 group-hover:opacity-100 transition-opacity">
                                                        <a
                                                            href={`https://gnosisscan.io/tx/${tx.txHash}`}
                                                            target="_blank"
                                                            rel="noopener noreferrer"
                                                            className="hover:underline"
                                                        >
                                                            {tx.txHash.slice(0, 12)}...{tx.txHash.slice(-8)}
                                                        </a>
                                                    </td>
                                                    <td className="p-4 md:p-6 font-black">{tx.amount} xDAI</td>
                                                    <td className="p-4 md:p-6 opacity-40 whitespace-nowrap">{tx.relativeTime}</td>
                                                </tr>
                                            ))}
                                        </tbody>
                                    </table>
                                </div>
                            </div>
                        </section>

                        {/* SECTION: TREASURY / TOKEN DISTRIBUTION */}
                        <section id="treasury" className="space-y-12 scroll-mt-20">
                            <div className="space-y-4">
                                <ScrollTypingHeader text="TOKEN_TREASURY_DISTRIBUTION" className="ico-header px-4 py-2 border border-white/10 inline-block" />
                                <div className="flex gap-4 items-center">
                                    <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
                                    <span className="text-[8px] font-pixel opacity-40 uppercase tracking-[0.4em]">LIVE_ONCHAIN_DATA // RPC_VERIFIED</span>
                                </div>
                            </div>
                            <TokenDistribution />
                        </section>

                        {/* SECTION: SMART CONTRACT SOURCE */}
                        <section id="contracts" className="space-y-12 scroll-mt-20">
                            <div className="space-y-4">
                                <ScrollTypingHeader text="PROTOCOL_SOURCE_CODE" className="ico-header px-4 py-2 border border-white/10 inline-block" />
                                <div className="flex gap-4 items-center">
                                    <div className="w-2 h-2 rounded-full bg-blue-500" />
                                    <span className="text-[8px] font-pixel opacity-40 uppercase tracking-[0.4em]">VERIFIED_MIT_LICENSE // OPEN_TRANSPARENCY</span>
                                </div>
                            </div>
                            <ContractCodeViewer />
                        </section>

                        {/* SECTION 04: PARTICIPATION */}
                        <section id="governance" className="scroll-mt-20 py-24 md:py-40 border-t border-white/10">
                            <div className="max-w-5xl space-y-12 md:space-y-16">
                                <div className="space-y-6">
                                    <h2 className="font-pixel text-3xl sm:text-4xl md:text-5xl tracking-tighter leading-tight break-words">
                                        JOIN_FUTARCHY
                                    </h2>
                                    <p className="text-lg md:text-xl font-mono text-white/50 leading-relaxed uppercase max-w-3xl">
                                        JOIN THE COMMUNITY. CONTRIBUTE TO GOVERNANCE. SHAPE THE FUTURE OF DECENTRALIZED DECISION-MAKING.
                                    </p>
                                </div>

                                {/* Big Social Links Grid */}
                                <div className="grid grid-cols-2 md:grid-cols-4 gap-4 md:gap-6">
                                    {/* Discord - Featured */}
                                    <a
                                        href="https://discord.gg/ATzpEDKq6Z"
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="col-span-2 md:col-span-2 group p-8 md:p-12 border-2 border-[#5865F2]/30 bg-[#5865F2]/5 hover:bg-[#5865F2]/10 hover:border-[#5865F2]/60 transition-all flex flex-col items-center justify-center gap-4"
                                    >
                                        <svg className="w-16 h-16 md:w-24 md:h-24 text-[#5865F2] group-hover:scale-110 transition-transform" fill="currentColor" viewBox="0 0 24 24">
                                            <path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028 14.09 14.09 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
                                        </svg>
                                        <div className="text-center">
                                            <div className="font-pixel text-lg md:text-xl text-[#5865F2] tracking-wider">DISCORD</div>
                                            <div className="font-mono text-[10px] text-white/40 uppercase mt-1">JOIN_THE_COMMUNITY</div>
                                        </div>
                                    </a>

                                    {/* X (Twitter) */}
                                    <a
                                        href="https://x.com/_futarchy"
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="group p-6 md:p-8 border border-white/20 hover:border-white/40 hover:bg-white/5 transition-all flex flex-col items-center justify-center gap-3"
                                    >
                                        <svg className="w-10 h-10 md:w-12 md:h-12 text-white/60 group-hover:text-white group-hover:scale-110 transition-all" fill="currentColor" viewBox="0 0 24 24">
                                            <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
                                        </svg>
                                        <div className="text-center">
                                            <div className="font-pixel text-sm text-white/80 tracking-wider">X / TWITTER</div>
                                            <div className="font-mono text-[9px] text-white/30 uppercase mt-1">@_futarchy</div>
                                        </div>
                                    </a>

                                    {/* GitHub */}
                                    <a
                                        href="https://github.com/futarchy-fi"
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="group p-6 md:p-8 border border-white/20 hover:border-white/40 hover:bg-white/5 transition-all flex flex-col items-center justify-center gap-3"
                                    >
                                        <svg className="w-10 h-10 md:w-12 md:h-12 text-white/60 group-hover:text-white group-hover:scale-110 transition-all" fill="currentColor" viewBox="0 0 24 24">
                                            <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
                                        </svg>
                                        <div className="text-center">
                                            <div className="font-pixel text-sm text-white/80 tracking-wider">GITHUB</div>
                                            <div className="font-mono text-[9px] text-white/30 uppercase mt-1">SOURCE_CODE</div>
                                        </div>
                                    </a>
                                </div>

                                {/* Additional Links */}
                                <div className="flex flex-wrap gap-4 pt-4 border-t border-white/10">
                                    <a
                                        href="https://app.futarchy.fi"
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="terminal-button !py-4 !px-8 flex items-center gap-3"
                                    >
                                        <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth="2">
                                            <path strokeLinecap="round" strokeLinejoin="round" d="M12 21a9.004 9.004 0 008.716-6.747M12 21a9.004 9.004 0 01-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3" />
                                        </svg>
                                        [ FUTARCHY_APP ]
                                    </a>
                                </div>
                            </div>
                        </section>
                    </main >

                    {/* RIGHT SIDEBAR (TRADING) */}
                    < aside className="w-full lg:max-w-[440px] xl:max-w-[480px] lg:sticky lg:top-12 lg:self-start" >
                        <div className="hidden lg:flex flex-col gap-6">
                            <div className="border border-white/10 bg-black/80">
                                <div className="p-2">
                                    <div className="flex flex-col border border-white shadow-[0_0_60px_rgba(255,255,255,0.05)] bg-black">
                                        <div className="p-2">
                                            <SwapPanel
                                                onTransactionSuccess={onTransactionSuccess}
                                                holdingsValue={formattedRpcHoldings}
                                                exitValue={formattedExitValue}
                                                exitSymbol={nativeSymbol}
                                            />
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <div className="p-6 border border-white/5 font-mono text-[9px] opacity-20 italic leading-relaxed uppercase tracking-widest">
                                DAO_CLEARANCE_LEVEL: ALPHA // SECURE_SOCKET: ENABLED // BY_OPERATING_THIS_TERMINAL_YOU_ACCEPT_ON_CHAIN_DYNAMICS.
                            </div>
                        </div>
                    </aside >
                </div >

                {/* Mobile floating button + drawer */}
                {portalReady && createPortal((
                    <div className="lg:hidden">
                        <button
                            type="button"
                            onClick={() => setTradePanelOpen(true)}
                            className="fixed w-full z-[2200] border border-white/20 bg-black/80 text-white/80 px-4 py-3 font-pixel text-[9px] tracking-widest shine-button"
                            style={{ bottom: 'calc(var(--hud-height) + 44px)' }}
                        >
                            OPEN_SWAP
                        </button>

                        {tradePanelOpen && (
                            <div className="fixed inset-0 z-[2300] bg-black/70 backdrop-blur-sm">
                                <div
                                    className="absolute left-0 right-0 bottom-0 border-t border-white/10 bg-black"
                                    style={{ maxHeight: '80dvh' }}
                                >
                                    <div className="flex items-center justify-between px-4 py-3 border-b border-white/10">
                                        <span className="font-pixel text-[9px] tracking-widest">TRADE_PANEL</span>
                                        <button
                                            type="button"
                                            onClick={() => setTradePanelOpen(false)}
                                            className="font-pixel text-[10px] opacity-60 hover:opacity-100"
                                        >
                                            [ CLOSE ]
                                        </button>
                                    </div>
                                    <div className="p-3 overflow-y-auto" style={{ maxHeight: 'calc(80dvh - 52px)' }}>
                                        <div className="flex flex-col border border-white shadow-[0_0_60px_rgba(255,255,255,0.05)] bg-black">
                                            <div className="p-2">
                                                <SwapPanel
                                                    onTransactionSuccess={onTransactionSuccess}
                                                    holdingsValue={formattedRpcHoldings}
                                                    exitValue={formattedExitValue}
                                                    exitSymbol={nativeSymbol}
                                                />
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        )}
                    </div>
                ), document.body)}

                {/* Website Footer */}
                < footer className="mt-24 md:mt-32 pt-12 md:pt-16 border-t border-white/10 flex flex-col md:flex-row items-center justify-between gap-6 md:gap-8 pb-12" >
                    {/* Social Links */}
                    < div className="flex items-center gap-6" >
                        {/* Discord */}
                        < a href="https://discord.gg/ATzpEDKq6Z" target="_blank" rel="noopener noreferrer"
                            className="opacity-40 hover:opacity-100 transition-opacity" title="Discord" >
                            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                                <path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028 14.09 14.09 0 0 0 1.226-1.994.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.955-2.419 2.157-2.419 1.21 0 2.176 1.096 2.157 2.42 0 1.333-.946 2.418-2.157 2.418z" />
                            </svg>
                        </a >
                        {/* X (Twitter) */}
                        < a href="https://x.com/_futarchy" target="_blank" rel="noopener noreferrer"
                            className="opacity-40 hover:opacity-100 transition-opacity" title="X (Twitter)" >
                            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                                <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
                            </svg>
                        </a >
                        {/* Website */}
                        < a href="https://app.futarchy.fi" target="_blank" rel="noopener noreferrer"
                            className="opacity-40 hover:opacity-100 transition-opacity" title="Futarchy App" >
                            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" strokeWidth="2">
                                <path strokeLinecap="round" strokeLinejoin="round" d="M12 21a9.004 9.004 0 008.716-6.747M12 21a9.004 9.004 0 01-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 017.843 4.582M12 3a8.997 8.997 0 00-7.843 4.582m15.686 0A11.953 11.953 0 0112 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0121 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0112 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 013 12c0-1.605.42-3.113 1.157-4.418" />
                            </svg>
                        </a >
                        {/* GitHub */}
                        < a href="https://github.com/futarchy-fi" target="_blank" rel="noopener noreferrer"
                            className="opacity-40 hover:opacity-100 transition-opacity" title="GitHub" >
                            <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                                <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
                            </svg>
                        </a >
                    </div >
                    <div className="font-pixel text-[8px] opacity-20 tracking-[0.5em] uppercase">
                        FAO_AUTONOMOUS_OPTIMIZER // EST_2026
                    </div>
                </footer >
            </div >
        </div >
    );
}

