'use client';

import { useState } from 'react';
import { useAccount, useReadContract, useWalletClient, usePublicClient } from 'wagmi';
import { parseEther, formatEther, encodeFunctionData } from 'viem';
import { useFAOContract, FAO_SALE_ADDRESS, FAO_TOKEN_ADDRESS } from '../hooks/useFAOContract';
import { useApproveAndCall } from '../hooks/useApproveAndCall';
import { useNativeCurrency } from '../hooks/useNativeCurrency';
import { useSubgraphData } from '../hooks/useSubgraphData';
import { toast } from 'sonner';
import TransactionConfirmModal from './TransactionConfirmModal';
import FAOSaleABI from '../abi/FAOSale.json';

export default function RagequitPanel({ onTransactionSuccess }) {
    const [amount, setAmount] = useState('');
    const [isModalOpen, setIsModalOpen] = useState(false);

    // Hooks
    const { price: nativePrice, symbol: nativeSymbol } = useNativeCurrency();
    const { approveAndCall, isLoading: isHandling } = useApproveAndCall();
    const { address } = useAccount();
    const { data: walletClient } = useWalletClient();
    const publicClient = usePublicClient();
    const { refetch: refetchSubgraph } = useSubgraphData();

    // Fetch current price for estimation
    const { data: currentPriceWei } = useReadContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'currentPriceWeiPerToken',
        watch: true,
    });

    // Estimate Native Token value based on current price (Approximation)
    const estimatedWei = amount && currentPriceWei
        ? (parseEther(amount) * currentPriceWei) / 1000000000000000000n
        : 0n;

    const estimatedNative = Number(formatEther(estimatedWei));
    const usdValue = estimatedNative * nativePrice;

    const handleRagequitClick = () => {
        if (!amount || isNaN(amount) || parseFloat(amount) <= 0) {
            toast.error("INVALID_DAO_EXIT_COMMAND");
            return;
        }
        if (!address) {
            toast.error("WALLET_NOT_CONNECTED");
            return;
        }
        setIsModalOpen(true);
    };

    const executeRagequit = async () => {
        setIsModalOpen(false);

        if (!walletClient || !publicClient) {
            console.error("Wallet or public client not ready");
            return;
        }

        console.log("=== RAGEQUIT DEBUG ===");
        console.log("Amount input:", amount);
        console.log("FAO_SALE_ADDRESS:", FAO_SALE_ADDRESS);
        console.log("FAO_TOKEN_ADDRESS:", FAO_TOKEN_ADDRESS);
        console.log("User address:", address);

        // 1. Parse input to Wei (e.g. "1.5" -> 1.5e18)
        const rawAmountWei = parseEther(amount);

        // 2. Calculate Whole Tokens (floor) because contract expects uint256 numTokens
        // Example: 1.5e18 / 1e18 = 1n
        const numTokensBigInt = rawAmountWei / BigInt(1e18);

        console.log("rawAmountWei:", rawAmountWei.toString());
        console.log("numTokensBigInt:", numTokensBigInt.toString());

        if (numTokensBigInt === 0n) {
            toast.error("AMOUNT_TOO_LOW: Minimum 1 Token");
            return;
        }

        // 3. Recalculate exact Wei to approve/burn based on whole tokens
        // Example: 1n * 1e18 = 1e18 Wei
        const exactWeiToBurn = numTokensBigInt * BigInt(1e18);
        console.log("exactWeiToBurn:", exactWeiToBurn.toString());

        // useApproveAndCall handles the Approval then executes onAction
        // We approve the EXACT Wei amount needed for the whole tokens
        approveAndCall({
            tokenAddress: FAO_TOKEN_ADDRESS,
            spenderAddress: FAO_SALE_ADDRESS,
            amountWei: exactWeiToBurn,
            actionName: "RAGEQUIT",
            onAction: async () => {
                console.log("=== EXECUTING RAGEQUIT CONTRACT CALL ===");
                console.log("Calling ragequit with numTokens:", numTokensBigInt.toString());

                // Use writeContract for proper contract interaction display
                const hash = await walletClient.writeContract({
                    address: FAO_SALE_ADDRESS,
                    abi: FAOSaleABI,
                    functionName: 'ragequit',
                    args: [numTokensBigInt],
                });
                console.log("Transaction hash:", hash);
                return hash;
            },
            onSuccess: () => {
                setAmount('');
                // Trigger optimistic portfolio update with tokens burned (negative delta)
                if (onTransactionSuccess) onTransactionSuccess(-Number(numTokensBigInt));
                // Refetch subgraph data after successful transaction
                setTimeout(() => refetchSubgraph(), 3000);
            }
        });
    };

    // Modal Data
    const distribution = [
        { label: 'BURNING', value: `${amount} FAO` },
        { label: 'RECEIVING (EST)', value: `${estimatedNative.toFixed(4)} ${nativeSymbol}` },
        { label: 'TREASURY_IMPACT', value: 'DEFLATIONARY' },
    ];

    return (
        <div className="flex flex-col gap-6 sm:gap-8 w-full relative overflow-hidden p-4 sm:p-6 border transition-colors duration-700 bg-black border-white/10">
            <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-3 sm:gap-0 border-b pb-4 border-white">
                <h2 className="ico-header">RAGEQUIT()</h2>
                <div className="flex items-center gap-2">
                    <div className="w-1.5 h-1.5 rounded-full bg-yellow-500 animate-pulse" />
                    <span className="font-pixel text-[8px] opacity-40 uppercase">CONTRACT_EXECUTION</span>
                </div>
            </div>

            <p className="font-mono text-[11px] sm:text-xs leading-relaxed border-l pl-4 italic transition-colors duration-700 text-white/60 border-white/20">
                REDEEM_SHARE: Pro-rata redemption of treasury assets by calling the ragequit() function. This process burns your FAO holdings.
            </p>

            {(FAO_SALE_ADDRESS === "0x00000000000000000000000000000000") && (
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
                    <label className="text-[10px] font-pixel uppercase tracking-[0.2em] text-white/40">BURN (FAO)</label>
                    <div className="text-[10px] font-mono text-white/30">
                        SETTLEMENT: <span className="text-white">{estimatedNative.toFixed(4)} {nativeSymbol}</span>
                        <span className="ml-2 text-yellow-500">ƒ%^ ${usdValue.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USD</span>
                    </div>
                </div>
                <div className="relative group">
                    <input
                        type="number"
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        placeholder="0.00"
                        disabled={FAO_SALE_ADDRESS === "0x00000000000000000000000000000000"}
                        className="w-full border p-4 sm:p-6 text-3xl sm:text-4xl font-mono focus:outline-none transition-all duration-300 placeholder:text-white/10 bg-white/5 border-white/20 text-white focus:bg-white focus:text-black"
                    />
                    <div className="absolute right-4 top-1/2 -translate-y-1/2 font-pixel text-[10px] text-white/30 group-focus-within:text-black">FAO</div>
                </div>
            </div>

            <button
                onClick={handleRagequitClick}
                className="w-full terminal-button py-6 sm:py-8 text-base sm:text-lg font-bold border-white/40 text-white/40 hover:bg-white hover:text-black hover:border-white transition-all duration-500"
            >
                {isHandling ? 'WAITING_FOR_CONFIRMATION...' : 'EXECUTE_RAGEQUIT'}
            </button>

            <TransactionConfirmModal
                isOpen={isModalOpen}
                onClose={() => setIsModalOpen(false)}
                onConfirm={executeRagequit}
                data={{
                    type: 'ragequit',
                    amount: amount,
                    receiveAmount: estimatedNative.toFixed(4),
                    distribution: distribution,
                    inputSymbol: "FAO",
                    outputSymbol: nativeSymbol
                }}
            />
        </div>
    );
}
