import { useState, useCallback } from 'react';
import { usePublicClient, useWalletClient, useAccount } from 'wagmi';
import { parseUnits, formatUnits } from 'viem';
import { toast } from 'sonner';
import FAOTokenABI from '../abi/FAOToken.json';

/**
 * useApproveAndCall
 * 
 * A secure hook that handles the "Approve -> Contract Action" flow.
 * 
 * Features:
 * - Checks current allowance first.
 * - Only asks for approval if necessary.
 * - Defaults to EXACT amount approval (more secure than infinite).
 * - Manages UI states via Sonner toasts (Mining, Success, Error).
 */
export function useApproveAndCall() {
    const [isLoading, setIsLoading] = useState(false);
    const { address } = useAccount();
    const publicClient = usePublicClient();
    const { data: walletClient } = useWalletClient();

    const execute = useCallback(async ({
        tokenAddress,
        spenderAddress,
        amountWei,
        actionName = "Transaction",
        onAction, // The actual contract write function (async)
        onSuccess,
    }) => {
        if (!address || !walletClient || !publicClient) {
            toast.error("Wallet not connected");
            return;
        }

        setIsLoading(true);
        const toastId = toast.loading(`Preparing ${actionName}...`);

        try {
            // 1. Check Allowance
            const allowance = await publicClient.readContract({
                address: tokenAddress,
                abi: FAOTokenABI,
                functionName: 'allowance',
                args: [address, spenderAddress]
            });

            const needsApproval = allowance < amountWei;

            if (needsApproval) {
                // 2. Need Approval
                toast.message(`Step 1/2: Approve Tokens`, {
                    description: `Please approve the request in your wallet. Amount: ${formatUnits(amountWei, 18)} tokens.`,
                    id: toastId,
                });

                const hash = await walletClient.writeContract({
                    address: tokenAddress,
                    abi: FAOTokenABI,
                    functionName: 'approve',
                    args: [spenderAddress, amountWei] // Secure: Exact amount
                });

                toast.loading(`Approving... Waiting for block confirmation.`, { id: toastId });
                await publicClient.waitForTransactionReceipt({ hash });

                toast.success("Approval Confirmed!", { id: toastId, duration: 2000 });
                // Small delay to ensure node sync
                await new Promise(r => setTimeout(r, 1000));
            } else {
                // Already approved - skip approval step
                toast.success(`Already approved. Proceeding to ${actionName}...`, { id: toastId, duration: 1500 });
                await new Promise(r => setTimeout(r, 500));
            }

            // 3. Execute Action
            toast.loading(`${needsApproval ? 'Step 2/2' : 'Executing'}: Confirm ${actionName}`, {
                id: toastId,
                description: "Please sign the final transaction."
            });

            const txHash = await onAction();

            toast.loading(`${actionName} submitted... Waiting for receipt.`, { id: toastId });

            const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

            console.log("=== TRANSACTION RECEIPT ===", receipt.status, typeof receipt.status);

            // Handle both viem formats: 'success' string or 1n BigInt
            const isSuccess = receipt.status === 'success' || receipt.status === 1n || receipt.status === 1;

            if (isSuccess) {
                toast.success(`${actionName} Successful!`, { id: toastId });
                if (onSuccess) onSuccess(receipt);
            } else {
                toast.error(`${actionName} Failed on-chain. Status: ${receipt.status}`, { id: toastId });
            }

        } catch (error) {
            console.error(error);
            if (error.message.includes("User rejected")) {
                toast.error("Transaction rejected by user", { id: toastId });
            } else {
                toast.error(`Error: ${error.message.slice(0, 50)}...`, { id: toastId });
            }
        } finally {
            setIsLoading(false);
        }
    }, [address, walletClient, publicClient]);

    return { approveAndCall: execute, isLoading };
}
