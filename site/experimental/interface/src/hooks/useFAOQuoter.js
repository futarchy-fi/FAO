'use client';

import { useMemo, useCallback } from 'react';
import { usePublicClient, useAccount, useReadContracts } from 'wagmi';
import { FAO_SALE_ADDRESS } from './useFAOContract';
import FAOSaleABI from '../abi/FAOSale.json';

/**
 * FAO Price Quoter Hook - USES DIRECT RPC CALLS
 * 
 * Provides real-time price quotes and transaction validation for FAO purchases.
 * Uses DIRECT CONTRACT READS (not subgraph) for accurate, up-to-date pricing.
 * 
 * Phase 0: Fixed price = INITIAL_PRICE_WEI_PER_TOKEN (0.0001 xDAI)
 * Phase 1: Price = P₀ × (1 + x/S) where:
 *   - P₀ = Initial price (0.0001 xDAI)
 *   - S = initialNetSale (tokens sold in Phase 0)
 *   - x = bondingCurveSaleTokens (tokens sold after Phase 0)
 */
export function useFAOQuoter() {
    const publicClient = usePublicClient();
    const { address: userAddress } = useAccount();

    // Read all required contract state via RPC (not subgraph!)
    const { data: contractData, isLoading, refetch, dataUpdatedAt } = useReadContracts({
        contracts: [
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'initialPhaseFinalized',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'currentPriceWeiPerToken',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'bondingCurveSaleTokens',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'initialNetSale',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'saleStart',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'initialPhaseEnd',
                chainId: 100,
            },
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'INITIAL_PRICE_WEI_PER_TOKEN',
                chainId: 100,
            },
        ],
        query: {
            refetchInterval: 10000, // Refetch every 10 seconds
            staleTime: 5000, // Consider data stale after 5 seconds
        },
    });

    // Parse contract results
    const parsedData = useMemo(() => {
        if (!contractData) {
            return {
                initialPhaseFinalized: false,
                currentPriceWei: BigInt('100000000000000'), // 0.0001 default
                bondingCurveSaleTokens: 0n,
                initialNetSale: 0n,
                saleStart: 0n,
                initialPhaseEnd: 0n,
                initialPriceWei: BigInt('100000000000000'),
            };
        }

        return {
            initialPhaseFinalized: contractData[0]?.result ?? false,
            currentPriceWei: contractData[1]?.result ?? BigInt('100000000000000'),
            bondingCurveSaleTokens: contractData[2]?.result ?? 0n,
            initialNetSale: contractData[3]?.result ?? 0n,
            saleStart: contractData[4]?.result ?? 0n,
            initialPhaseEnd: contractData[5]?.result ?? 0n,
            initialPriceWei: contractData[6]?.result ?? BigInt('100000000000000'),
        };
    }, [contractData]);

    // Phase detection from contract (not subgraph!)
    const phase = useMemo(() => {
        if (parsedData.saleStart === 0n) return 'NOT_STARTED';
        if (parsedData.initialPhaseFinalized) {
            return 'BONDING_CURVE'; // Phase 1
        }
        return 'INITIAL'; // Phase 0
    }, [parsedData.saleStart, parsedData.initialPhaseFinalized]);

    // Curve parameters for display
    const curveParams = useMemo(() => {
        const initialPrice = parsedData.initialPriceWei;
        const currentPrice = parsedData.currentPriceWei;
        const initialNetSale = parsedData.initialNetSale;
        const curveSold = parsedData.bondingCurveSaleTokens;

        return {
            initialPrice,
            initialNetSale,
            curveSold,
            currentPrice,
            // Formatted for display
            initialPriceFormatted: (Number(initialPrice) / 1e18).toFixed(6),
            initialNetSaleFormatted: Number(initialNetSale).toLocaleString(),
            curveSoldFormatted: Number(curveSold).toLocaleString(),
            currentPriceFormatted: (Number(currentPrice) / 1e18).toFixed(6),
        };
    }, [parsedData]);

    /**
     * Calculate cost/value in wei for a given amount of WHOLE tokens
     * Uses LIVE contract price from RPC
     * 
     * @param {bigint} wholeTokens - Number of WHOLE tokens (not Wei)
     * @returns {bigint} Cost/Value in wei
     */
    const getQuoteForTokens = useCallback((wholeTokens) => {
        const amount = BigInt(wholeTokens);
        if (amount <= 0n) return 0n;

        // Price is Wei per WHOLE token
        // Cost = wholeTokens * pricePerToken
        return amount * parsedData.currentPriceWei;
    }, [parsedData.currentPriceWei]);

    /**
     * Calculate maximum WHOLE tokens purchasable with a given amount of ETH/xDAI
     * 
     * @param {bigint} weiAmount - Amount of wei to spend
     * @returns {{ numTokens: bigint, exactCost: bigint, change: bigint }}
     */
    const getQuoteForEth = useCallback((weiAmount) => {
        if (!weiAmount || weiAmount <= 0n) {
            return { numTokens: 0n, exactCost: 0n, change: 0n };
        }

        const price = parsedData.currentPriceWei;
        if (price === 0n) {
            return { numTokens: 0n, exactCost: 0n, change: weiAmount };
        }

        // numTokens = WHOLE tokens = weiAmount / pricePerWholeToken
        const numTokens = weiAmount / price;

        // Recalculate exact cost = wholeTokens * pricePerToken
        const exactCost = numTokens * price;
        const change = weiAmount - exactCost;

        return { numTokens, exactCost, change };
    }, [parsedData.currentPriceWei]);

    /**
     * Simulate a buy transaction using staticCall
     * Validates the transaction will succeed before asking the user to sign.
     * 
     * @param {bigint} numTokens - Number of tokens to buy
     * @param {bigint} value - Wei amount to send
     * @returns {Promise<{ success: boolean, error?: string }>}
     */
    const simulateBuy = useCallback(async (numTokens, value) => {
        if (!publicClient || !userAddress) {
            return { success: false, error: 'Wallet not connected' };
        }

        try {
            await publicClient.simulateContract({
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'buy',
                args: [numTokens],
                value,
                account: userAddress
            });
            return { success: true };
        } catch (err) {
            const reason = err.shortMessage || err.message || 'Unknown error';
            return { success: false, error: reason };
        }
    }, [publicClient, userAddress]);

    /**
     * Simulate a ragequit transaction using staticCall
     * 
     * @param {bigint} numTokens - Number of tokens to return
     * @returns {Promise<{ success: boolean, error?: string }>}
     */
    const simulateRagequit = useCallback(async (numTokens) => {
        if (!publicClient || !userAddress) {
            return { success: false, error: 'Wallet not connected' };
        }

        try {
            await publicClient.simulateContract({
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'ragequit',
                args: [numTokens],
                account: userAddress
            });
            return { success: true };
        } catch (err) {
            const reason = err.shortMessage || err.message || 'Unknown error';
            return { success: false, error: reason };
        }
    }, [publicClient, userAddress]);

    /**
     * Get accurate ragequit return estimate using contract's pro-rata formula:
     * ethShare = (treasuryBalance * burnAmount) / effectiveSupply
     * 
     * @param {bigint} wholeTokens - Number of WHOLE tokens to ragequit
     * @returns {Promise<{ estReturnWei: bigint, effectiveSupply: bigint, treasuryBalance: bigint }>}
     */
    const getQuoteForRagequit = useCallback(async (wholeTokens) => {
        if (!publicClient || wholeTokens <= 0n) {
            return { estReturnWei: 0n, effectiveSupply: 0n, treasuryBalance: 0n };
        }

        try {
            // Fetch all required data in parallel
            const [treasuryBalance, totalSupply, incentiveAddr, insiderAddr] = await Promise.all([
                publicClient.getBalance({ address: FAO_SALE_ADDRESS }),
                publicClient.readContract({
                    address: FAO_SALE_ADDRESS,
                    abi: FAOSaleABI,
                    functionName: 'TOKEN'
                }).then(tokenAddr => publicClient.readContract({
                    address: tokenAddr,
                    abi: [{ inputs: [], name: "totalSupply", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" }],
                    functionName: 'totalSupply'
                })),
                publicClient.readContract({ address: FAO_SALE_ADDRESS, abi: FAOSaleABI, functionName: 'incentiveContract' }),
                publicClient.readContract({ address: FAO_SALE_ADDRESS, abi: FAOSaleABI, functionName: 'insiderVestingContract' }),
            ]);

            // Get balances of excluded addresses
            const tokenAddr = await publicClient.readContract({
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'TOKEN'
            });

            const balanceABI = [{ inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" }];

            const [incentiveBal, insiderBal, treasuryTokenBal] = await Promise.all([
                incentiveAddr && incentiveAddr !== '0x0000000000000000000000000000000000000000'
                    ? publicClient.readContract({ address: tokenAddr, abi: balanceABI, functionName: 'balanceOf', args: [incentiveAddr] })
                    : 0n,
                insiderAddr && insiderAddr !== '0x0000000000000000000000000000000000000000'
                    ? publicClient.readContract({ address: tokenAddr, abi: balanceABI, functionName: 'balanceOf', args: [insiderAddr] })
                    : 0n,
                publicClient.readContract({ address: tokenAddr, abi: balanceABI, functionName: 'balanceOf', args: [FAO_SALE_ADDRESS] }),
            ]);

            // Calculate effective supply (total - incentive - insider - treasury)
            const effectiveSupply = totalSupply - incentiveBal - insiderBal - treasuryTokenBal;

            if (effectiveSupply <= 0n) {
                return { estReturnWei: 0n, effectiveSupply: 0n, treasuryBalance };
            }

            // Calculate pro-rata share: (treasuryBalance * burnAmount) / effectiveSupply
            const burnAmount = wholeTokens * 1000000000000000000n; // Convert to Wei
            const estReturnWei = (treasuryBalance * burnAmount) / effectiveSupply;

            return { estReturnWei, effectiveSupply, treasuryBalance };
        } catch (err) {
            console.error('getQuoteForRagequit error:', err);
            return { estReturnWei: 0n, effectiveSupply: 0n, treasuryBalance: 0n };
        }
    }, [publicClient]);

    /**
     * Project what the price would be after buying N tokens (Phase 1 only)
     * 
     * @param {bigint|number} additionalTokens - Tokens being purchased
     * @returns {bigint} Projected price per token in wei
     */
    const projectPriceAfter = useCallback((additionalTokens) => {
        if (phase !== 'BONDING_CURVE' || parsedData.initialNetSale === 0n) {
            return parsedData.initialPriceWei;
        }

        const newCurveSold = parsedData.bondingCurveSaleTokens + BigInt(additionalTokens);
        // P = P₀ × (1 + x/S) = P₀ + (P₀ × x / S)
        const priceIncrease = (parsedData.initialPriceWei * newCurveSold) / parsedData.initialNetSale;
        return parsedData.initialPriceWei + priceIncrease;
    }, [phase, parsedData]);

    // Formatted timestamp for "quote updated X ago"
    const quoteAge = useMemo(() => {
        if (!dataUpdatedAt) return null;
        const seconds = Math.floor((Date.now() - dataUpdatedAt) / 1000);
        if (seconds < 60) return `${seconds}s`;
        const minutes = Math.floor(seconds / 60);
        return `${minutes}m`;
    }, [dataUpdatedAt]);

    return {
        // Phase info
        phase,
        isPhase0: phase === 'INITIAL',
        isPhase1: phase === 'BONDING_CURVE',
        isNotStarted: phase === 'NOT_STARTED',

        // Curve parameters (for display in Phase 1)
        curveParams,

        // Raw contract data
        contractData: parsedData,

        // Quote functions (all work with WHOLE tokens, not Wei)
        getQuoteForTokens,   // (wholeTokens) => costWei (for BUY)
        getQuoteForEth,      // (weiAmount) => { numTokens: wholeTokens, exactCost, change }
        getQuoteForRagequit, // (wholeTokens) => Promise<{ estReturnWei, effectiveSupply, treasuryBalance }>
        projectPriceAfter,

        // Transaction validation
        simulateBuy,
        simulateRagequit,

        // Metadata
        isLoading,
        lastSyncedAt: dataUpdatedAt ? new Date(dataUpdatedAt) : null,
        quoteAge,
        refetch,
    };
}

/**
 * Token Distribution Hook - Fetches on-chain token allocation data
 * Returns breakdown of FAO token distribution for pie chart visualization
 */
export function useTokenDistribution() {
    const publicClient = usePublicClient();

    const { data, isLoading, refetch, dataUpdatedAt } = useReadContracts({
        contracts: [
            // Get the token address
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'TOKEN',
                chainId: 100,
            },
            // Get incentive contract address
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'incentiveContract',
                chainId: 100,
            },
            // Get insider vesting contract address
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'insiderVestingContract',
                chainId: 100,
            },
            // Get phase status
            {
                address: FAO_SALE_ADDRESS,
                abi: FAOSaleABI,
                functionName: 'initialPhaseFinalized',
                chainId: 100,
            },
        ],
        query: {
            refetchInterval: 15000,
            staleTime: 10000,
        },
    });

    // Once we have addresses, fetch token balances
    const tokenAddress = data?.[0]?.result;
    const incentiveAddress = data?.[1]?.result;
    const insiderAddress = data?.[2]?.result;
    const isPhaseFinalized = data?.[3]?.result ?? false;

    const balanceABI = [{
        inputs: [{ name: "account", type: "address" }],
        name: "balanceOf",
        outputs: [{ type: "uint256" }],
        stateMutability: "view",
        type: "function"
    }, {
        inputs: [],
        name: "totalSupply",
        outputs: [{ type: "uint256" }],
        stateMutability: "view",
        type: "function"
    }];

    const zeroAddress = '0x0000000000000000000000000000000000000000';

    const { data: balances, isLoading: balancesLoading } = useReadContracts({
        contracts: tokenAddress ? [
            // Total supply
            {
                address: tokenAddress,
                abi: balanceABI,
                functionName: 'totalSupply',
                chainId: 100,
            },
            // Treasury balance (FAOSale contract holds FAO tokens)
            {
                address: tokenAddress,
                abi: balanceABI,
                functionName: 'balanceOf',
                args: [FAO_SALE_ADDRESS],
                chainId: 100,
            },
            // Incentive balance
            {
                address: tokenAddress,
                abi: balanceABI,
                functionName: 'balanceOf',
                args: [incentiveAddress && incentiveAddress !== zeroAddress ? incentiveAddress : FAO_SALE_ADDRESS],
                chainId: 100,
            },
            // Insider balance
            {
                address: tokenAddress,
                abi: balanceABI,
                functionName: 'balanceOf',
                args: [insiderAddress && insiderAddress !== zeroAddress ? insiderAddress : FAO_SALE_ADDRESS],
                chainId: 100,
            },
        ] : [],
        query: {
            enabled: !!tokenAddress,
            refetchInterval: 15000,
            staleTime: 10000,
        },
    });

    // Parse and calculate distribution
    const distribution = useMemo(() => {
        if (!balances || balances.length < 4) {
            return {
                totalSupply: 0n,
                treasuryBalance: 0n,
                incentiveBalance: 0n,
                insiderBalance: 0n,
                circulatingSupply: 0n,
            };
        }

        const totalSupply = balances[0]?.result ?? 0n;
        const treasuryBalance = balances[1]?.result ?? 0n;

        // Only count incentive/insider if they have separate addresses
        const incentiveBalance = incentiveAddress && incentiveAddress !== zeroAddress
            ? (balances[2]?.result ?? 0n)
            : 0n;
        const insiderBalance = insiderAddress && insiderAddress !== zeroAddress
            ? (balances[3]?.result ?? 0n)
            : 0n;

        // Circulating = total - treasury - incentive - insider
        const circulatingSupply = totalSupply - treasuryBalance - incentiveBalance - insiderBalance;

        return {
            totalSupply,
            treasuryBalance,
            incentiveBalance,
            insiderBalance,
            circulatingSupply,
        };
    }, [balances, incentiveAddress, insiderAddress]);

    return {
        ...distribution,
        isPhaseFinalized,
        incentiveAddress,
        insiderAddress,
        isLoading: isLoading || balancesLoading,
        refetch,
        lastUpdated: dataUpdatedAt ? new Date(dataUpdatedAt) : null,
    };
}

export default useFAOQuoter;
