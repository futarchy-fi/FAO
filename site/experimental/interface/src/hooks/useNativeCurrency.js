'use client';

import { useState, useEffect } from 'react';
import { useChainId, useAccount } from 'wagmi';

/**
 * Hook to get the native currency symbol and price based on the connected chain.
 * Returns:
 * - symbol: "xDAI" for Gnosis (100), "ETH" for others
 * - price: Fixed $1.00 for xDAI, fetched price for ETH.
 * - isLoading: Loading state for price fetch.
 * 
 * Defaults to Gnosis Chain (100) / xDAI when no wallet is connected.
 */
export function useNativeCurrency() {
    const connectedChainId = useChainId();
    const { isConnected } = useAccount();

    // Default to Gnosis Chain (100) when not connected
    // useChainId returns default chain from config, so we check isConnected explicitly
    const chainId = isConnected ? connectedChainId : 100;
    const [price, setPrice] = useState(0);
    const [isLoading, setIsLoading] = useState(true);

    const isGnosis = chainId === 100;
    const symbol = isGnosis ? 'xDAI' : 'ETH';

    useEffect(() => {
        let isMounted = true;

        async function fetchPrice() {
            if (isGnosis) {
                // xDAI is pegged to DAI (~$1)
                if (isMounted) {
                    setPrice(1.00);
                    setIsLoading(false);
                }
                return;
            }

            try {
                // Fetch ETH price for Mainnet/Sepolia
                const response = await fetch('https://api.coinbase.com/v2/prices/ETH-USD/spot');
                const data = await response.json();
                if (data?.data?.amount && isMounted) {
                    setPrice(parseFloat(data.data.amount));
                }
            } catch (err) {
                console.error("Failed to fetch ETH price, using fallback.", err);
            } finally {
                if (isMounted) setIsLoading(false);
            }
        }

        fetchPrice();
        // Refresh every 60 seconds if not Gnosis
        const interval = isGnosis ? null : setInterval(fetchPrice, 60000);

        return () => {
            isMounted = false;
            if (interval) clearInterval(interval);
        };
    }, [isGnosis]);

    return { symbol, price, isLoading, isGnosis };
}
