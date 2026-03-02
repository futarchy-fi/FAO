const { createPublicClient, http, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({ chain: gnosis, transport: http("https://rpc.gnosischain.com") });

    const SALE = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
    const USER = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";

    // Test with 1 WHOLE token (the FIX)
    console.log("Testing ragequit(1n) - 1 WHOLE token...");
    try {
        await publicClient.simulateContract({
            address: SALE,
            abi: [{ inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" }],
            functionName: 'ragequit',
            args: [1n], // WHOLE token
            account: USER
        });
        console.log("SUCCESS! Ragequit(1) works!");
    } catch (err) {
        console.log("FAILED: " + (err.shortMessage || err.message));
    }
}

main();
