'use client';

import { useState, useEffect } from 'react';

/**
 * A simple hook to fetch the current ETH price in USD.
 * Falls back to a mock price if the API fails.
 */
export function useETHPrice() {
    const [price, setPrice] = useState(2450.00);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        async function fetchPrice() {
            try {
                // Using a public, no-auth API for the demo
                const response = await fetch('https://api.coinbase.com/v2/prices/ETH-USD/spot');
                const data = await response.json();
                if (data?.data?.amount) {
                    setPrice(parseFloat(data.data.amount));
                }
            } catch (err) {
                console.error("Failed to fetch ETH price, using fallback.", err);
            } finally {
                setIsLoading(false);
            }
        }

        fetchPrice();
        // Refresh every 60 seconds
        const interval = setInterval(fetchPrice, 60000);
        return () => clearInterval(interval);
    }, []);

    return { price, isLoading };
}
