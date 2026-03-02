import { useFAOContract } from '../hooks/useFAOContract';
import { useReadContract } from 'wagmi';
import FAOSaleABI from '../abi/FAOSale.json';
import { formatUnits } from 'viem';
import { FAO_SALE_ADDRESS } from '../hooks/useFAOContract';

function StatBox({ label, value, subtext }) {
    return (
        <div className="flex flex-col items-center justify-center p-6 border-2 border-black bg-white pixel-border-sm relative overflow-hidden group hover:-translate-y-1 transition-transform">
            <span className="text-[10px] font-pixel text-black/60 uppercase tracking-tighter mb-4 z-10">{label}</span>
            <span className="text-3xl font-pixel font-bold text-black max-w-full truncate z-10 tracking-tighter">
                {value}
            </span>
            {subtext && <span className="text-[10px] text-black font-pixel mt-4 z-10 bg-yellow-100 border border-black px-2 py-1">{subtext}</span>}
        </div>
    )
}

export function StatsDisplay() {
    const isConfigured = FAO_SALE_ADDRESS && FAO_SALE_ADDRESS !== "0x0000000000000000000000000000000000000000";

    const { data: price, isLoading: isLoadingPrice } = useReadContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'currentPriceWeiPerToken',
        watch: true,
        query: {
            enabled: isConfigured
        }
    });

    const { data: raised, isLoading: isLoadingRaised } = useReadContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'totalAmountRaised',
        watch: true,
        query: {
            enabled: isConfigured
        }
    });

    const { data: sold, isLoading: isLoadingSold } = useReadContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'totalSaleTokens',
        watch: true,
        query: {
            enabled: isConfigured
        }
    });

    if (!isConfigured) {
        return (
            <div className="w-full max-w-4xl mx-auto my-12 text-center p-8 glass-card border-yellow-500/30">
                <h3 className="text-xl font-display text-yellow-500 mb-2">Setup Required</h3>
                <p className="text-gray-400 mb-4">Please configure contract addresses in <code className="text-white bg-white/10 px-2 py-1 rounded">src/config/contracts.js</code></p>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4 opacity-50 blur-[2px]">
                    <StatBox label="Current Price" value="0.001 ETH" />
                    <StatBox label="Total Raised" value="125.5 ETH" />
                    <StatBox label="Tokens Sold" value="1,250,000" />
                </div>
            </div>
        )
    }

    return (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 w-full max-w-4xl mx-auto my-12">
            <StatBox
                label="Current Price"
                value={isLoadingPrice ? "..." : price ? `${formatUnits(price, 18)} ETH` : "0 ETH"}
            />
            <StatBox
                label="Total Raised"
                value={isLoadingRaised ? "..." : raised ? `${Number(formatUnits(raised, 18)).toFixed(2)} ETH` : "0 ETH"}
            />
            <StatBox
                label="Tokens Sold"
                value={isLoadingSold ? "..." : sold ? Number(formatUnits(sold, 18)).toLocaleString() : "0"}
            />
        </div>
    );
}
