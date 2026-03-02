'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { SUBGRAPH_URL } from '../config/contracts';

/**
 * Query to fetch all dashboard data from FAO Subgraph
 */
const DASHBOARD_QUERY = `
  query GetDashboardData {
    sale(id: "SALE") {
      id
      token
      saleStart
      initialPhaseEnd
      initialPhaseFinalized
      totalAmountRaised
      totalCurveFundsRaised
      totalCurveTokensSold
      totalSaleTokens
      initialTokensSold
      initialFundsRaised
      initialNetSale
      currentPriceWeiPerToken
      initialPriceWeiPerToken
      longTargetTokens
      longTargetReachedAt
      minInitialPhaseSold
    }
    purchaseEvents(first: 15, orderBy: timestamp, orderDirection: desc) {
      id
      buyer
      numTokens
      costWei
      timestamp
      txHash
      blockNumber
    }
    ragequitEvents(first: 15, orderBy: timestamp, orderDirection: desc) {
      id
      user
      faoBurned
      ethReturned
      timestamp
      txHash
      blockNumber
    }
  }
`;

/**
 * Format Wei to readable ETH/xDAI string
 */
function formatWei(weiString, decimals = 4) {
    if (!weiString) return '0';
    const wei = BigInt(weiString);
    const eth = Number(wei) / 1e18;
    return eth.toFixed(decimals);
}

/**
 * Calculate relative time string from Unix timestamp
 */
function getRelativeTime(timestamp) {
    const now = Date.now();
    const then = Number(timestamp) * 1000;
    const diff = now - then;

    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);

    if (days > 0) return `${days}D AGO`;
    if (hours > 0) return `${hours}H AGO`;
    if (minutes > 0) return `${minutes}M AGO`;
    return 'JUST NOW';
}

// ============================================
// SINGLETON CACHE - Shared across all hooks
// ============================================
const cache = {
    data: null,
    lastFetchedAt: null,
    isLoading: false,
    error: null,
    subscribers: new Set(),
    fetchPromise: null,
    pollInterval: null,
};

const CACHE_TTL = 10000; // 10 seconds cache validity
const POLL_INTERVAL = 10000; // Poll every 10 seconds

function notifySubscribers() {
    cache.subscribers.forEach(callback => callback());
}

async function fetchSubgraphData() {
    // If already fetching, return the existing promise
    if (cache.fetchPromise) {
        return cache.fetchPromise;
    }

    // If cache is still valid, skip fetch
    if (cache.data && cache.lastFetchedAt && (Date.now() - cache.lastFetchedAt < CACHE_TTL)) {
        return cache.data;
    }

    cache.isLoading = true;
    notifySubscribers();

    cache.fetchPromise = (async () => {
        try {
            const response = await fetch(SUBGRAPH_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ query: DASHBOARD_QUERY }),
            });

            if (!response.ok) {
                // Handle rate limiting gracefully
                if (response.status === 429) {
                    console.warn('[SubgraphCache] Rate limited (429), using cached data');
                    cache.isLoading = false;
                    cache.fetchPromise = null;
                    notifySubscribers();
                    return cache.data; // Return stale data if available
                }
                throw new Error(`HTTP error! status: ${response.status}`);
            }

            const result = await response.json();

            if (result.errors) {
                throw new Error(result.errors[0]?.message || 'GraphQL error');
            }

            const { sale, purchaseEvents, ragequitEvents } = result.data;

            // Merge and sort transactions
            const allTransactions = [
                ...purchaseEvents.map(e => ({
                    id: e.id,
                    type: 'BUY',
                    user: e.buyer,
                    amount: formatWei(e.costWei),
                    tokens: e.numTokens,
                    timestamp: e.timestamp,
                    txHash: e.txHash,
                    blockNumber: e.blockNumber,
                    relativeTime: getRelativeTime(e.timestamp),
                })),
                ...ragequitEvents.map(e => ({
                    id: e.id,
                    type: 'RAGEQUIT',
                    user: e.user,
                    amount: formatWei(e.ethReturned),
                    tokens: e.faoBurned,
                    timestamp: e.timestamp,
                    txHash: e.txHash,
                    blockNumber: e.blockNumber,
                    relativeTime: getRelativeTime(e.timestamp),
                })),
            ].sort((a, b) => Number(b.timestamp) - Number(a.timestamp));

            // Process sale data
            const processedSale = sale ? {
                // Raw values
                saleStart: sale.saleStart,
                saleStartTime: sale.saleStart,
                initialPhaseEnd: sale.initialPhaseEnd,
                initialPhaseFinalized: sale.initialPhaseFinalized,
                longTargetReachedAt: sale.longTargetReachedAt,

                // Formatted values
                totalAmountRaised: formatWei(sale.totalAmountRaised),
                totalAmountRaisedWei: sale.totalAmountRaised,
                totalCurveFundsRaised: formatWei(sale.totalCurveFundsRaised),
                initialFundsRaised: formatWei(sale.initialFundsRaised),

                // Token counts (these are already counts, not wei)
                totalSaleTokens: sale.totalSaleTokens,
                initialTokensSold: sale.initialTokensSold,
                totalCurveTokensSold: sale.totalCurveTokensSold,
                circulatingSupply: (
                    BigInt(sale.initialTokensSold || 0) +
                    BigInt(sale.totalCurveTokensSold || 0)
                ).toString(),

                // Price
                currentPriceWeiPerToken: sale.currentPriceWeiPerToken,
                currentPrice: formatWei(sale.currentPriceWeiPerToken),
                initialPrice: formatWei(sale.initialPriceWeiPerToken),

                // Targets
                longTargetTokens: sale.longTargetTokens,
                minInitialPhaseSold: sale.minInitialPhaseSold,
            } : null;

            cache.data = {
                sale: processedSale,
                transactions: allTransactions,
                purchaseEvents,
                ragequitEvents,
            };

            cache.lastFetchedAt = Date.now();
            cache.error = null;

        } catch (err) {
            console.error('[SubgraphCache] Error:', err);
            cache.error = err.message;
        } finally {
            cache.isLoading = false;
            cache.fetchPromise = null;
            notifySubscribers();
        }

        return cache.data;
    })();

    return cache.fetchPromise;
}

// Start global polling
function startPolling() {
    if (cache.pollInterval) return;

    cache.pollInterval = setInterval(() => {
        if (cache.subscribers.size > 0) {
            fetchSubgraphData();
        }
    }, POLL_INTERVAL);
}

function stopPolling() {
    if (cache.pollInterval) {
        clearInterval(cache.pollInterval);
        cache.pollInterval = null;
    }
}

/**
 * Hook to fetch and poll FAO Subgraph data (with shared cache)
 * @param {Object} options
 * @param {number} options.pollInterval - IGNORED (uses global polling)
 * @param {boolean} options.enabled - Whether to subscribe (default: true)
 */
export function useSubgraphData({ pollInterval = 30000, enabled = true } = {}) {
    const [, forceUpdate] = useState({});
    const mountedRef = useRef(true);

    const subscribe = useCallback(() => {
        const callback = () => {
            if (mountedRef.current) {
                forceUpdate({});
            }
        };
        cache.subscribers.add(callback);
        startPolling();

        return () => {
            cache.subscribers.delete(callback);
            if (cache.subscribers.size === 0) {
                stopPolling();
            }
        };
    }, []);

    useEffect(() => {
        mountedRef.current = true;

        if (enabled) {
            // Trigger initial fetch
            fetchSubgraphData();

            // Subscribe to updates
            const unsubscribe = subscribe();
            return () => {
                mountedRef.current = false;
                unsubscribe();
            };
        }
    }, [enabled, subscribe]);

    const refetch = useCallback(() => {
        // Force a fresh fetch by clearing the timestamp
        cache.lastFetchedAt = null;
        return fetchSubgraphData();
    }, []);

    return {
        sale: cache.data?.sale,
        transactions: cache.data?.transactions || [],
        purchaseEvents: cache.data?.purchaseEvents || [],
        ragequitEvents: cache.data?.ragequitEvents || [],
        isLoading: cache.isLoading,
        isSyncing: cache.isLoading,
        error: cache.error,
        lastSyncedAt: cache.lastFetchedAt ? new Date(cache.lastFetchedAt) : null,
        refetch,

        // Formatted helpers
        lastSyncedAtUTC: cache.lastFetchedAt
            ? new Date(cache.lastFetchedAt).toISOString().split('T')[1].split('.')[0] + ' UTC'
            : null,
    };
}

export default useSubgraphData;
