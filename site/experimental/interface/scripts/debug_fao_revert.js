const { createPublicClient, http, formatEther, parseAbiItem } = require('viem');
const { gnosis } = require('viem/chains');

const USER_ADDRESS = '0x645A3D9208523bbFEE980f7269ac72C61Dd3b552';
const FAO_SALE_ADDRESS = '0x3f3ab07ad792bb89dff7528d1cef78372b0d8b93';
const FAO_TOKEN_ADDRESS = '0x19c85acb4ca0ff6fed5f8d7b376bfbb37a2d67e9';

// Minimal ABI for debugging
const SALE_ABI = [
    "function currentPriceWeiPerToken() view returns (uint256)",
    "function ragequit(uint256 amount) external",
    "function buy(uint256 minAmountOut) external payable"
];

const TOKEN_ABI = [
    "function balanceOf(address) view returns (uint256)"
];

async function main() {
    const client = createPublicClient({
        chain: gnosis,
        transport: http()
    });

    console.log(`Checking state for User: ${USER_ADDRESS}`);
    console.log(`Checking state for Sale Contract: ${FAO_SALE_ADDRESS}`);

    // 1. Check Native Balance (xDAI)
    try {
        const balance = await client.getBalance({ address: USER_ADDRESS });
        console.log(`\n[User Native Balance]`);
        console.log(`Balance: ${formatEther(balance)} xDAI`);
    } catch (e) {
        console.error("Failed to fetch native balance:", e.message);
    }

    // 2. Check FAO Token Balance
    try {
        const tokenBalance = await client.readContract({
            address: FAO_TOKEN_ADDRESS,
            abi: TOKEN_ABI,
            functionName: 'balanceOf',
            args: [USER_ADDRESS]
        });
        console.log(`\n[User FAO Balance]`);
        console.log(`Balance: ${formatEther(tokenBalance)} FAO`);
    } catch (e) {
        console.error("Failed to fetch FAO balance:", e.message);
    }

    // 3. Check Sale Contract State
    try {
        const currentPrice = await client.readContract({
            address: FAO_SALE_ADDRESS,
            abi: SALE_ABI,
            functionName: 'currentPriceWeiPerToken'
        });
        console.log(`\n[Sale Contract State]`);
        console.log(`Current Price: ${formatEther(currentPrice)} xDAI per Token`);
    } catch (e) {
        console.error("Failed to fetch current price (might be 'No initial net sale'?):", e.message);
        // Try to decode revert reason if possible, essentially confirmed if this fails
    }
}

main();
