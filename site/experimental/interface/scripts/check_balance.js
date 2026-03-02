const { createPublicClient, http, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

// Configuration
const FAO_TOKEN_ADDRESS = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17"; // Confirmed Address
const USER_ADDRESS = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";
const RPC_URL = "https://rpc.gnosischain.com";

const FAOTokenABI = [
    { "inputs": [{ "name": "account", "type": "address" }], "name": "balanceOf", "outputs": [{ "name": "", "type": "uint256" }], "stateMutability": "view", "type": "function" },
    { "inputs": [], "name": "decimals", "outputs": [{ "name": "", "type": "uint8" }], "stateMutability": "view", "type": "function" }
];

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http(RPC_URL)
    });

    try {
        console.log(`Checking balance for ${USER_ADDRESS}...`);

        // Check Balance
        const balance = await publicClient.readContract({
            address: FAO_TOKEN_ADDRESS,
            abi: FAOTokenABI,
            functionName: 'balanceOf',
            args: [USER_ADDRESS]
        });

        console.log(`\nFAO Balance (Wei): ${balance.toString()}`);
        console.log(`FAO Balance (Tokens): ${formatEther(balance)}`);

        if (balance < BigInt(5000) * BigInt(1e18)) {
            console.log("\n[DIAGNOSIS] User has LESS than 5000 tokens.");
            console.log("This explains the revert: contract tries to burn 5000 * 1e18, but user lacks funds.");
        } else {
            console.log("\n[DIAGNOSIS] User HAS enough tokens.");
        }

    } catch (error) {
        console.error("Error:", error);
    }
}

main();
