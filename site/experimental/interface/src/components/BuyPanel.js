'use client';

import { useState, useMemo } from 'react';
import { parseEther, formatEther } from 'viem';
import { useAccount, useWalletClient, usePublicClient } from 'wagmi';
import { useFAOContract, FAO_SALE_ADDRESS } from '../hooks/useFAOContract';

import { useSubgraphData } from '../hooks/useSubgraphData';
import { useFAOQuoter } from '../hooks/useFAOQuoter';
import { toast } from 'sonner';
import TransactionConfirmModal from './TransactionConfirmModal';
import FAOSaleABI from '../abi/FAOSale.json';

export default function BuyPanel({ onTransactionSuccess }) {
    const [amount, setAmount] = useState('');
    const [isModalOpen, setIsModalOpen] = useState(false);
    const [isSimulating, setIsSimulating] = useState(false);

    // Hardcode to xDAI since FAO is on Gnosis Chain
    const nativeSymbol = 'xDAI';
    const nativePrice = 1.00; // xDAI is stable
    // const { price: nativePrice, symbol: nativeSymbol } = useNativeCurrency(); // Removed to avoid ETH/Mainnet confusion
    const { saleContract } = useFAOContract();
    const { address } = useAccount();
    const { data: walletClient } = useWalletClient();
    const publicClient = usePublicClient();
    const { refetch: refetchSubgraph } = useSubgraphData();

    // Use the new quoter hook
    const {
        getQuoteForEth,
        getQuoteForTokens,
        simulateBuy,
        curveParams,
        quoteAge,
        isPhase1
    } = useFAOQuoter();

    const usdValue = (parseFloat(amount) || 0) * nativePrice;

    // Calculate tokens and exact cost using quoter
    const quoteResult = useMemo(() => {
        if (!amount || parseFloat(amount) <= 0) {
            return { numTokens: 0n, exactCost: 0n, change: 0n };
        }
        try {
            const ethWei = parseEther(amount);
            return getQuoteForEth(ethWei);
        } catch (e) {
            return { numTokens: 0n, exactCost: 0n, change: 0n };
        }
    }, [amount, getQuoteForEth]);

    const estimatedTokens = Number(quoteResult.numTokens);

    const handleBuyClick = async () => {
        if (!amount || isNaN(amount) || parseFloat(amount) <= 0) {
            toast.error("INVALID_INPUT_DETECTED");
            return;
        }
        if (!address) {
            toast.error("WALLET_NOT_CONNECTED");
            return;
        }
        if (quoteResult.numTokens === 0n) {
            toast.error("AMOUNT_TOO_LOW: Minimum 1 Token");
            return;
        }

        // Simulate first to catch reverts before opening modal
        setIsSimulating(true);
        const simulation = await simulateBuy(quoteResult.numTokens, quoteResult.exactCost);
        setIsSimulating(false);

        if (!simulation.success) {
            toast.error(`SIMULATION_FAILED: ${simulation.error}`);
            return;
        }

        setIsModalOpen(true);
    };

    const executeBuy = async () => {
        setIsModalOpen(false);
        if (!walletClient || !publicClient) return;

        const toastId = toast.loading("INITIATING_SEQUENCE...");

        try {
            const numTokensBigInt = quoteResult.numTokens;
            const exactCostWei = quoteResult.exactCost;

            if (numTokensBigInt === 0n) {
                toast.error("AMOUNT_TOO_LOW: Minimum 1 Token", { id: toastId });
                return;
            }

            // Final simulation check (state may have changed)
            toast.loading("VALIDATING_STATE...", { id: toastId });
            const finalCheck = await simulateBuy(numTokensBigInt, exactCostWei);

            if (!finalCheck.success) {
                toast.error(`STATE_CHANGED: ${finalCheck.error}. Refresh quote.`, { id: toastId });
                return;
            }

            toast.loading(`SIGN_TRANSACTION: Buying ${numTokensBigInt.toString()} FAO...`, { id: toastId });

            const hash = await walletClient.writeContract({
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'buy',
                args: [numTokensBigInt],
                value: exactCostWei
            });

            toast.loading(`PROCESSING: ${hash.slice(0, 10)}...`, { id: toastId });

            await publicClient.waitForTransactionReceipt({ hash });

            toast.success("ASSET_SECURED", { id: toastId });
            setAmount('');

            // Trigger optimistic portfolio update with tokens bought
            if (onTransactionSuccess) onTransactionSuccess(Number(numTokensBigInt));

            // Refetch subgraph data after successful transaction
            setTimeout(() => refetchSubgraph(), 3000);
        } catch (err) {
            console.error(err);
            toast.error("TRANSACTION_FAILED: " + (err.shortMessage || err.message), { id: toastId });
        }
    };

    // Data for the confirmation modal
    const receiveAmount = estimatedTokens.toLocaleString(undefined, { maximumFractionDigits: 0 });

    // Calculate reserves based on the purchase
    const distribution = [
        { label: 'TREASURY_RESERVE (50%)', value: (estimatedTokens * 0.50).toLocaleString(undefined, { maximumFractionDigits: 2 }) },
        { label: 'INCENTIVE_RESERVE (20%)', value: (estimatedTokens * 0.20).toLocaleString(undefined, { maximumFractionDigits: 2 }) },
        { label: 'INSIDER_VESTING (30%)', value: (estimatedTokens * 0.30).toLocaleString(undefined, { maximumFractionDigits: 2 }) },
    ];

    return (
        <div className="flex flex-col gap-6 sm:gap-8 w-full relative overflow-hidden p-4 sm:p-6 border transition-colors duration-700 bg-black border-white/10">
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-3 sm:gap-0 border-b pb-4 border-white">
                <h2 className="ico-header">BUY()</h2>
                <div className="flex items-center gap-2">
                    <div className="w-1.5 h-1.5 rounded-full bg-blue-500 animate-pulse" />
                    <span className="font-pixel text-[8px] opacity-40 uppercase">CONTRACT_EXECUTION</span>
                </div>
            </div>

            <p className="font-mono text-[11px] sm:text-xs leading-relaxed border-l pl-4 italic transition-colors duration-700 text-white/60 border-white/20">
                DEPOSIT_COLLATERAL: Mints FAO tokens against the bonding reserve by calling the buy() function on the protocol sale contract.
            </p>

            {(!saleContract || FAO_SALE_ADDRESS === "0x00000000000000000000000000000000") && (
                <div className="absolute inset-0 z-40 flex items-center justify-center border flex-col text-center p-6 backdrop-blur-sm bg-black/95 border-white">
                    <span className="font-pixel font-bold text-sm mb-4 tracking-widest px-2 py-1 bg-white text-black">!! ERR_SETUP !!</span>
                    <p className="text-[10px] font-pixel text-white/50">CONFIGURE CONTRACT_MANIFEST in config/contracts.js</p>
                </div>
            )}

            {!address && (
                <div className="absolute inset-0 z-30 flex items-center justify-center border flex-col text-center p-6 backdrop-blur-sm bg-black/90 border-white/20">
                    <span className="font-pixel font-bold text-xs mb-2 tracking-widest">WALLET_NOT_CONNECTED</span>
                    <p className="text-[9px] font-pixel text-white/40 mb-4">Connect wallet to execute transactions</p>
                </div>
            )}

            <div className="flex flex-col gap-4">
                <div className="flex flex-col sm:flex-row justify-between items-start sm:items-end gap-2 sm:gap-0">
                    <label className="text-[10px] font-pixel uppercase tracking-[0.2em] text-white/40">PAY ({nativeSymbol})</label>
                    <div className="text-[10px] font-mono">
                        <span className="text-green-500/80">ƒ%^ ${usdValue.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USD</span>
                        <span className="ml-2 text-blue-400">→ {estimatedTokens > 0 ? estimatedTokens.toLocaleString(undefined, { maximumFractionDigits: 0 }) : '0'} FAO</span>
                    </div>
                </div>
                <div className="relative group">
                    <input
                        type="number"
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        placeholder="0.00"
                        disabled={!saleContract || FAO_SALE_ADDRESS === "0x00000000000000000000000000000000"}
                        className="w-full border p-4 sm:p-6 text-3xl sm:text-4xl font-mono focus:outline-none transition-all duration-300 placeholder:text-white/10 bg-white/5 border-white/20 text-white focus:bg-white focus:text-black"
                    />
                    <div className="absolute right-4 top-1/2 -translate-y-1/2 font-pixel text-[10px] text-white/30 group-focus-within:text-black">{nativeSymbol}</div>
                </div>
                {/* Display Current Price and Quote Info */}
                <div className="flex justify-between text-[9px] font-mono text-white/30">
                    <span>
                        PRICE: {curveParams.currentPriceFormatted} {nativeSymbol}
                        {isPhase1 && <span className="text-yellow-500 ml-1">(CURVE)</span>}
                    </span>
                    {quoteAge && (
                        <span>QUOTE: {quoteAge} AGO</span>
                    )}
                </div>
                {/* Show exact cost */}
                {quoteResult.exactCost > 0n && (
                    <div className="text-[9px] font-mono text-cyan-400/70">
                        EXACT_COST: {formatEther(quoteResult.exactCost)} {nativeSymbol}
                        {quoteResult.change > 0n && (
                            <span className="text-white/30 ml-2">
                                (CHANGE: {formatEther(quoteResult.change)} {nativeSymbol})
                            </span>
                        )}
                    </div>
                )}
            </div>

            <button
                onClick={handleBuyClick}
                disabled={isSimulating}
                className="w-full terminal-button py-6 sm:py-8 text-base sm:text-lg font-bold hover:!bg-white hover:!text-black transition-all duration-500 disabled:opacity-50"
            >
                {isSimulating ? 'SIMULATING...' : 'EXECUTE_BUY'}
            </button>

            <TransactionConfirmModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onConfirm={executeBuy}
                data={{
                    amount: formatEther(quoteResult.exactCost),
                    receiveAmount: receiveAmount,
                    distribution: distribution,
                    inputSymbol: nativeSymbol,
                    outputSymbol: "FAO"
                }}
            />
        </div>
    );
}
