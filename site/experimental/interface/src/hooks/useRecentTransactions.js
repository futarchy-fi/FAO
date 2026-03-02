import { useQuery } from '@tanstack/react-query';
import { formatEther } from 'viem';
import { SUBGRAPH_URL } from '../config/contracts';
import { useNativeCurrency } from './useNativeCurrency';

const QUERY = `
  query GetRecentActivity {
    purchaseEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
      id
      buyer
      numTokens
      costWei
      timestamp
      txHash
    }
    ragequitEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
      id
      user
      faoBurned
      ethReturned
      timestamp
      txHash
    }
  }
`;

export function useRecentTransactions() {
    // We can use the native symbol for labeling output currency
    const { symbol: nativeSymbol } = useNativeCurrency();

    return useQuery({
        queryKey: ['recentTransactions'],
        queryFn: async () => {
            // If url is missing, return empty
            if (!SUBGRAPH_URL) return [];

            const response = await fetch(SUBGRAPH_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ query: QUERY }),
            });

            if (!response.ok) {
                throw new Error('Network response was not ok');
            }

            const json = await response.json();
            const data = json.data;

            if (!data) return [];

            const purchases = (data.purchaseEvents || []).map(p => ({
                type: 'Buy',
                hash: p.txHash,
                val: `${parseFloat(formatEther(p.costWei)).toFixed(4)} ${nativeSymbol}`,
                // We will format timestamp relative in the component or here. 
                // The dashboard expects a string like "27 days ago". 
                timestamp: Number(p.timestamp),
                raw: p
            }));

            const ragequits = (data.ragequitEvents || []).map(r => ({
                type: 'Ragequit',
                hash: r.txHash,
                val: `${parseFloat(formatEther(r.ethReturned)).toFixed(4)} ${nativeSymbol}`, // Returning ETH/xDAI
                timestamp: Number(r.timestamp),
                raw: r
            }));

            // Merge and sort
            const all = [...purchases, ...ragequits].sort((a, b) => b.timestamp - a.timestamp);

            return all;
        },
        refetchInterval: 10000, // Poll every 10 seconds
    });
}

// Helper to format time ago (simple version)
export function timeAgo(timestamp) {
    const seconds = Math.floor((Date.now() / 1000) - timestamp);
    let interval = seconds / 31536000;
    if (interval > 1) return Math.floor(interval) + " years ago";
    interval = seconds / 2592000;
    if (interval > 1) return Math.floor(interval) + " months ago";
    interval = seconds / 86400;
    if (interval > 1) return Math.floor(interval) + " days ago";
    interval = seconds / 3600;
    if (interval > 1) return Math.floor(interval) + " hours ago";
    interval = seconds / 60;
    if (interval > 1) return Math.floor(interval) + " minutes ago";
    return Math.floor(seconds) + " seconds ago";
}
