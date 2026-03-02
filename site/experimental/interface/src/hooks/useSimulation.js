'use client';

import { useState, useCallback, useEffect } from 'react';
import { parseUnits, formatUnits } from 'viem';

// Constants matching the smart contract logic
const INITIAL_PRICE_ETH = 0.0001;
const INITIAL_NET_SALE = 1000000; // 1M FAO sold in Phase I (Mock)
const INITIAL_FUNDS_RAISED = INITIAL_NET_SALE * INITIAL_PRICE_ETH;

export function useSimulation() {
    const [stats, setStats] = useState({
        totalSold: 1250000, // Starting point: 1.25M sold (Phase I + some Curve)
        totalRaised: 137.5, // 100 ETH (Phase I) + ~37.5 ETH (Curve)
        userBalance: 1000,
        history: [
            { id: 1, type: 'BUY', amount: 50000, price: 0.00012, time: '2m ago' },
            { id: 2, type: 'RAGEQUIT', amount: 10000, price: 0.00011, time: '5m ago' },
        ]
    });

    const calculateCurrentPrice = useCallback((sold) => {
        const bcSale = Math.max(0, sold - INITIAL_NET_SALE);
        // Price = P0 + (P0 * bcSale / InitialNetSale)
        return INITIAL_PRICE_ETH + (INITIAL_PRICE_ETH * bcSale) / INITIAL_NET_SALE;
    }, []);

    const [currentPrice, setCurrentPrice] = useState(0);

    useEffect(() => {
        setCurrentPrice(calculateCurrentPrice(stats.totalSold));
    }, [stats.totalSold, calculateCurrentPrice]);

    const simulateBuy = useCallback((amount) => {
        setStats(prev => {
            const newSold = prev.totalSold + Number(amount);
            const price = calculateCurrentPrice(newSold);
            const cost = Number(amount) * price;

            return {
                ...prev,
                totalSold: newSold,
                totalRaised: prev.totalRaised + cost,
                userBalance: prev.userBalance + Number(amount),
                history: [
                    {
                        id: Date.now(),
                        type: 'BUY',
                        amount: Number(amount),
                        price: price,
                        time: 'Just now'
                    },
                    ...prev.history.slice(0, 4)
                ]
            };
        });
    }, [calculateCurrentPrice]);

    const simulateRagequit = useCallback((amount) => {
        setStats(prev => {
            const burnAmount = Math.min(prev.userBalance, Number(amount));
            const newSold = prev.totalSold - burnAmount;
            const price = calculateCurrentPrice(prev.totalSold); // redemption at current price
            const refund = burnAmount * price;

            return {
                ...prev,
                totalSold: newSold,
                totalRaised: prev.totalRaised - refund,
                userBalance: prev.userBalance - burnAmount,
                history: [
                    {
                        id: Date.now(),
                        type: 'RAGEQUIT',
                        amount: burnAmount,
                        price: price,
                        time: 'Just now'
                    },
                    ...prev.history.slice(0, 4)
                ]
            };
        });
    }, [calculateCurrentPrice]);

    return {
        ...stats,
        currentPrice,
        simulateBuy,
        simulateRagequit,
        initialNetSale: INITIAL_NET_SALE,
        initialPrice: INITIAL_PRICE_ETH
    };
}
