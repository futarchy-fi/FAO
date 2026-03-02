'use client';

import { useState, useEffect } from 'react';
import { parseEther, formatEther } from 'viem';
import { useAccount, useWalletClient, usePublicClient, useReadContract } from 'wagmi';
import { useFAOContract, FAO_SALE_ADDRESS, FAO_TOKEN_ADDRESS } from '../hooks/useFAOContract';
import { useSubgraphData } from '../hooks/useSubgraphData';
import { useFAOQuoter } from '../hooks/useFAOQuoter';
import { toast } from 'sonner';
import TransactionConfirmModal from './TransactionConfirmModal';
import FAOSaleABI from '../abi/FAOSale.json';
import FAOTokenABI from '../abi/FAOToken.json';

const NATIVE_SYMBOL = 'xDAI';
const TOKEN_SYMBOL = 'FAO';

export default function SwapPanel({
    onTransactionSuccess,
    holdingsValue,
    exitValue,
    exitSymbol
}) {
    // Mode: 'BUY' (xDAI -> FAO) or 'SELL' (FAO -> xDAI)
    const [mode, setMode] = useState('BUY');

    // Inputs: 'pay' is top, 'receive' is bottom
    const [payAmount, setPayAmount] = useState('');
    const [receiveAmount, setReceiveAmount] = useState('');

    // Which field controls the calculation?
    const [activeField, setActiveField] = useState('PAY'); // 'PAY' or 'RECEIVE'

    const { address } = useAccount();
    const { data: walletClient } = useWalletClient();
    const publicClient = usePublicClient();
    const { refetch: refetchSubgraph } = useSubgraphData();
    const {
        getQuoteForEth,
        getQuoteForTokens,
        getQuoteForRagequit,
        simulateBuy,
        simulateRagequit,
        curveParams
    } = useFAOQuoter();

    const [isSimulating, setIsSimulating] = useState(false);
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [quoteData, setQuoteData] = useState(null); // Stores exact transaction values

    // Fetch FAO Balance for Sell Mode
    const { data: faoBalance, refetch: refetchBalance } = useReadContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'balanceOf',
        args: [address],
        query: { enabled: !!address }
    });

    const balanceFormatted = faoBalance ? Number(formatEther(faoBalance)).toFixed(2) : '0.00';
    // For SELL, we need WHOLE tokens (not Wei) since contract does: burnAmount = numTokens * 1e18
    const balanceWholeTokens = faoBalance ? faoBalance / 1000000000000000000n : 0n;

    // Fetch Allowance for Sell Mode
    const { data: allowance, refetch: refetchAllowance } = useReadContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'allowance',
        args: [address, FAO_SALE_ADDRESS],
        query: { enabled: !!address && mode === 'SELL' }
    });

    // --- QUOTING LOGIC ---
    useEffect(() => {
        const calculateQuote = () => {
            // Reset if empty
            if (!payAmount && !receiveAmount) {
                setQuoteData(null);
                return;
            }

            // BUY MODE: xDAI -> FAO
            // Contract expects WHOLE tokens for buy(numTokens)
            if (mode === 'BUY') {
                if (activeField === 'PAY') {
                    // Exact Input (xDAI) -> Calculate FAO (whole tokens)
                    if (!payAmount || parseFloat(payAmount) <= 0) return;
                    try {
                        const wei = parseEther(payAmount);
                        const res = getQuoteForEth(wei);
                        // res.numTokens is now WHOLE tokens
                        setReceiveAmount(res.numTokens.toString());
                        setQuoteData({
                            tokens: res.numTokens, // WHOLE tokens for contract
                            costWei: res.exactCost,
                            type: 'BUY'
                        });
                    } catch (e) { console.error(e); }
                } else {
                    // Exact Output (FAO whole tokens) -> Calculate xDAI Cost
                    if (!receiveAmount || parseFloat(receiveAmount) <= 0) return;
                    try {
                        // User enters whole tokens
                        const wholeTokens = BigInt(Math.floor(parseFloat(receiveAmount)));
                        if (wholeTokens <= 0n) return;

                        const costWei = getQuoteForTokens(wholeTokens);
                        setPayAmount(formatEther(costWei));
                        setQuoteData({
                            tokens: wholeTokens, // WHOLE tokens for contract
                            costWei: costWei,
                            type: 'BUY'
                        });
                    } catch (e) { console.error(e); }
                }
            }
            // SELL MODE: FAO -> xDAI
            // IMPORTANT: Contract expects WHOLE tokens, not Wei!
            // Uses pro-rata formula: (treasuryBalance * burnAmount) / effectiveSupply
            else {
                if (activeField === 'PAY') {
                    // Exact Input (FAO whole tokens) -> Est xDAI
                    if (!payAmount || parseFloat(payAmount) <= 0) return;
                    try {
                        // numTokens = WHOLE tokens (integer)
                        const wholeTokens = BigInt(Math.floor(parseFloat(payAmount)));
                        if (wholeTokens <= 0n) return;

                        // Get accurate pro-rata return from on-chain data
                        getQuoteForRagequit(wholeTokens).then(result => {
                            setReceiveAmount(formatEther(result.estReturnWei));
                            setQuoteData({
                                tokens: wholeTokens, // WHOLE tokens for contract
                                estReturnWei: result.estReturnWei,
                                type: 'SELL'
                            });
                        });
                    } catch (e) { console.error(e); }
                } else {
                    // Exact Output (xDAI) -> Est FAO (whole tokens)
                    if (!receiveAmount || parseFloat(receiveAmount) <= 0) return;
                    try {
                        const targetWei = parseEther(receiveAmount);
                        // Reverse: wholeTokens = targetWei / pricePerToken
                        if (curveParams.currentPrice > 0n) {
                            const estWholeTokens = targetWei / curveParams.currentPrice;
                            setPayAmount(estWholeTokens.toString());
                            setQuoteData({
                                tokens: estWholeTokens, // WHOLE tokens
                                estReturnWei: targetWei,
                                type: 'SELL'
                            });
                        }
                    } catch (e) { console.error(e); }
                }
            }
        };

        // Debounce slightly to avoid rapid updates/loops
        const timer = setTimeout(calculateQuote, 100);
        return () => clearTimeout(timer);
    }, [activeField, payAmount, receiveAmount, mode, getQuoteForEth, getQuoteForTokens, getQuoteForRagequit, curveParams]);


    // --- HANDLERS ---
    const handleToggleMode = () => {
        setMode(prev => prev === 'BUY' ? 'SELL' : 'BUY');
        setPayAmount('');
        setReceiveAmount('');
        setQuoteData(null);
        setActiveField('PAY');
    };

    const handlePercentage = (percent) => {
        if (!faoBalance) return;
        if (mode === 'BUY') return;

        // Use WHOLE tokens for SELL mode
        const wholeBalance = Number(faoBalance / 1000000000000000000n);

        let amount;
        if (percent === 100) {
            amount = wholeBalance.toString();
        } else {
            amount = Math.floor(wholeBalance * (percent / 100)).toString();
        }

        setPayAmount(amount);
        setActiveField('PAY');
    };

    const handlePayChange = (val) => {
        setPayAmount(val);
        setActiveField('PAY');
    };

    const handleReceiveChange = (val) => {
        setReceiveAmount(val);
        setActiveField('RECEIVE');
    };

    const handleActionClick = async () => {
        if (!address) {
            toast.error("WALLET_NOT_CONNECTED");
            return;
        }
        if (!quoteData || quoteData.tokens === 0n) {
            toast.error("INVALID_AMOUNT");
            return;
        }

        // --- APPROVAL FLOW (SELL MODE) ---
        // Note: quoteData.tokens is WHOLE tokens, but ERC20 approve expects Wei
        if (mode === 'SELL') {
            const tokensInWei = quoteData.tokens * 1000000000000000000n; // Convert to Wei for ERC20
            if (!allowance || allowance < tokensInWei) {
                const toastId = toast.loading("APPROVING_FAO...");
                try {
                    const hash = await walletClient.writeContract({
                        address: FAO_TOKEN_ADDRESS,
                        abi: FAOTokenABI,
                        functionName: 'approve',
                        args: [FAO_SALE_ADDRESS, tokensInWei] // Approve Wei amount
                    });
                    toast.loading(`APPROVING: ${hash.slice(0, 10)}...`, { id: toastId });
                    await publicClient.waitForTransactionReceipt({ hash });
                    toast.success("APPROVAL_CONFIRMED", { id: toastId });
                    refetchAllowance();
                    return;
                } catch (err) {
                    console.error(err);
                    toast.error("APPROVAL_FAILED", { id: toastId });
                    return;
                }
            }
        }

        setIsSimulating(true);
        let simResult;

        // Ensure simulation works with Wei inputs
        if (mode === 'BUY') {
            simResult = await simulateBuy(quoteData.tokens, quoteData.costWei);
        } else {
            simResult = await simulateRagequit(quoteData.tokens);
        }

        setIsSimulating(false);

        if (!simResult.success) {
            toast.error(`SIMULATION_FAILED: ${simResult.error}`);
            // If simulation failed, it might be due to race condition on allowance?
            // But we checked allowance above.
            return;
        }

        setIsModalOpen(true);
    };

    const executeTransaction = async () => {
        setIsModalOpen(false);
        if (!walletClient || !publicClient || !quoteData) return;

        const toastId = toast.loading("INITIATING_SEQUENCE...");
        try {
            let hash;
            if (mode === 'BUY') {
                hash = await walletClient.writeContract({
                    address: FAO_SALE_ADDRESS,
                    abi: FAOSaleABI,
                    functionName: 'buy',
                    args: [quoteData.tokens],
                    value: quoteData.costWei
                });
            } else {
                hash = await walletClient.writeContract({
                    address: FAO_SALE_ADDRESS,
                    abi: FAOSaleABI,
                    functionName: 'ragequit',
                    args: [quoteData.tokens]
                });
            }

            toast.loading(`PROCESSING: ${hash.slice(0, 10)}...`, { id: toastId });
            await publicClient.waitForTransactionReceipt({ hash });

            toast.success(mode === 'BUY' ? "ASSET_SECURED" : "EXIT_COMPLETED", { id: toastId });

            setPayAmount('');
            setReceiveAmount('');
            setQuoteData(null);
            refetchBalance(); // Update balance

            // Optimistic Update can use float delta
            const delta = mode === 'BUY' ? Number(formatEther(quoteData.tokens)) : -Number(formatEther(quoteData.tokens));
            if (onTransactionSuccess) onTransactionSuccess(delta);

            setTimeout(() => refetchSubgraph(), 3000);

        } catch (err) {
            console.error(err);
            toast.error("TRANSACTION_FAILED: " + (err.shortMessage || err.message), { id: toastId });
        }
    };

    // Visual Helpers
    const paySymbol = mode === 'BUY' ? NATIVE_SYMBOL : TOKEN_SYMBOL;
    const receiveSymbol = mode === 'BUY' ? TOKEN_SYMBOL : NATIVE_SYMBOL;

    // Button Label Calculation
    let actionLabel = isSimulating ? 'SIMULATING...' : (mode === 'BUY' ? 'BUY_FAO' : 'BURN_AND_EXIT');

    // Override label for Approval (compare in Wei since allowance is Wei)
    if (mode === 'SELL' && quoteData && quoteData.tokens > 0n) {
        const tokensInWei = quoteData.tokens * 1000000000000000000n;
        if (!allowance || allowance < tokensInWei) {
            actionLabel = 'APPROVE_FAO';
        }
    }

    return (
        <div className="flex flex-col gap-4 w-full relative overflow-hidden p-4 sm:p-6 border transition-colors duration-700 bg-black border-white/10">
            {/* Simplified portfolio summary */}
            <div className="grid grid-cols-2 gap-3">
                <div className="border border-white/10 bg-white/5 p-3">
                    <div className="text-[9px] font-pixel opacity-30 uppercase mb-2 whitespace-nowrap">HOLDINGS</div>
                    <div className="font-mono text-sm font-bold">
                        {holdingsValue ?? '0'}
                    </div>
                </div>
                <div className="border border-white/10 bg-white/5 p-3">
                    <div className="text-[9px] font-pixel opacity-30 uppercase mb-2 whitespace-nowrap">AVG_EXIT</div>
                    <div className="font-mono text-sm font-bold">
                        {exitValue ?? '0'} {exitSymbol ?? NATIVE_SYMBOL}
                    </div>
                </div>
            </div>

            {/* ERROR / WALLET STATES */}
            {!address && (
                <div className="absolute inset-0 z-30 flex items-center justify-center flex-col text-center p-6 backdrop-blur-sm bg-black/90">
                    <span className="font-pixel font-bold text-xs mb-2 tracking-widest">WALLET_NOT_CONNECTED</span>
                </div>
            )}

            {/* Inputs Container */}
            <div className="relative flex flex-col gap-2">
                {/* PAY INPUT */}
                <div className="bg-white/5 p-4 border border-white/10 hover:border-white/20 transition-colors rounded-sm">
                    <div className="flex justify-between mb-2">
                        <label className="text-[9px] font-pixel opacity-40 uppercase whitespace-nowrap">PAY ({paySymbol})</label>
                        {mode === 'SELL' && (
                            <div className="flex items-center gap-2">
                                <span className="text-[9px] font-mono opacity-40">
                                    BALANCE: {balanceFormatted}
                                </span>
                                {/* Percentage Buttons */}
                                <div className="flex gap-1">
                                    {[25, 50, 75, 100].map(pct => (
                                        <button
                                            key={pct}
                                            onClick={() => handlePercentage(pct)}
                                            className="px-1.5 py-0.5 bg-white/10 hover:bg-white/20 text-[8px] font-pixel rounded transition-colors"
                                        >
                                            {pct === 100 ? 'MAX' : `${pct}%`}
                                        </button>
                                    ))}
                                </div>
                            </div>
                        )}
                    </div>
                    <div className="flex items-center gap-4">
                        <input
                            type="text"
                            inputMode="decimal"
                            pattern="^[0-9]*[.,]?[0-9]*$"
                            placeholder="0.00"
                            value={payAmount}
                            onChange={(e) => {
                                if (e.target.value === '' || /^[0-9]*[.,]?[0-9]*$/.test(e.target.value)) {
                                    handlePayChange(e.target.value);
                                }
                            }}
                            className="bg-transparent text-2xl font-mono w-full focus:outline-none placeholder:text-white/10"
                        />
                        <span className="font-pixel text-xs bg-white/10 px-2 py-1 rounded whitespace-nowrap">{paySymbol}</span>
                    </div>
                </div>

                {/* TOGGLE BUTTON */}
                <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 z-10">
                    <button
                        onClick={handleToggleMode}
                        className="w-8 h-8 flex items-center justify-center bg-black border border-white/20 rounded-sm hover:border-white hover:bg-white/10 transition-all text-white/60"
                        title="Switch Direction"
                    >
                        <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4" /></svg>
                    </button>
                </div>

                {/* RECEIVE INPUT */}
                <div className="bg-white/5 p-4 border border-white/10 hover:border-white/20 transition-colors rounded-sm">
                    <div className="flex justify-between mb-2">
                        <label className="text-[9px] font-pixel opacity-40 uppercase whitespace-nowrap">RECEIVE ({receiveSymbol})</label>
                        {mode === 'BUY' && (
                            <span className="text-[9px] font-mono opacity-40 whitespace-nowrap">EST. OUTPUT</span>
                        )}
                    </div>
                    <div className="flex items-center gap-4">
                        <input
                            type="text"
                            inputMode="decimal"
                            pattern="^[0-9]*[.,]?[0-9]*$"
                            placeholder="0.00"
                            value={receiveAmount}
                            onChange={(e) => {
                                if (e.target.value === '' || /^[0-9]*[.,]?[0-9]*$/.test(e.target.value)) {
                                    handleReceiveChange(e.target.value);
                                }
                            }}
                            className="bg-transparent text-2xl font-mono w-full focus:outline-none placeholder:text-white/10"
                        />
                        <span className="font-pixel text-xs bg-white/10 px-2 py-1 rounded whitespace-nowrap">{receiveSymbol}</span>
                    </div>
                </div>
            </div>

            {/* Quote Info */}
            <div className="flex justify-between items-center text-[9px] font-mono text-white/30 px-1">
                <span>
                    PRICE: {curveParams.currentPriceFormatted} {NATIVE_SYMBOL}
                </span>
                {quoteData && quoteData.type === 'BUY' && (
                    <span className="hidden sm:inline whitespace-nowrap">
                        EXACT_COST: {formatEther(quoteData.costWei)} {NATIVE_SYMBOL}
                    </span>
                )}
            </div>

            {/* Action Button */}
            <button
                onClick={handleActionClick}
                disabled={isSimulating || !quoteData}
                className={`w-full py-6 text-lg font-bold transition-all duration-300 ${mode === 'BUY'
                    ? 'bg-white text-black hover:bg-white/90'
                    : 'bg-red-900/20 text-red-500 border border-red-500/50 hover:bg-red-900/40'
                    } disabled:opacity-50 disabled:cursor-not-allowed uppercase font-pixel tracking-widest`}
            >
                {actionLabel}
            </button>

            {/* Modals */}
            <TransactionConfirmModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onConfirm={executeTransaction}
                data={{
                    amount: mode === 'BUY' ? formatEther(quoteData?.costWei || 0n) : payAmount,
                    receiveAmount: mode === 'BUY' ? receiveAmount : formatEther(quoteData?.estReturnWei || 0n),
                    inputSymbol: paySymbol,
                    outputSymbol: receiveSymbol
                }}
            />
        </div>
    );
}
