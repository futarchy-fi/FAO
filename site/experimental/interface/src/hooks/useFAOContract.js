import { useMemo } from 'react';
import { getContract } from 'viem';
import { usePublicClient, useWalletClient } from 'wagmi';
import FAOTokenABI from '../abi/FAOToken.json';
import FAOSaleABI from '../abi/FAOSale.json';

import { CONTRACTS } from '../config/contracts';

export const FAO_TOKEN_ADDRESS = CONTRACTS.FAO_TOKEN;
export const FAO_SALE_ADDRESS = CONTRACTS.FAO_SALE;

export function useFAOContract() {
    const publicClient = usePublicClient();
    const { data: walletClient } = useWalletClient();

    const tokenContract = useMemo(() => {
        if (!publicClient) return null;
        return getContract({
            address: FAO_TOKEN_ADDRESS,
            abi: FAOTokenABI,
            client: { public: publicClient, wallet: walletClient }
        });
    }, [publicClient, walletClient]);

    const saleContract = useMemo(() => {
        if (!publicClient) return null;
        return getContract({
            address: FAO_SALE_ADDRESS,
            abi: FAOSaleABI,
            client: { public: publicClient, wallet: walletClient }
        });
    }, [publicClient, walletClient]);

    return { tokenContract, saleContract };
}
