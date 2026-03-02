const { createPublicClient, http, parseEther, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http("https://rpc.gnosischain.com")
    });

    const SALE = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
    const USER = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";

    // Test with RAW 1 (1n) - treating numTokens as whole tokens
    console.log("Testing ragequit(1n) - treating as whole token...");
    try {
        await publicClient.simulateContract({
            address: SALE,
            abi: [{ inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" }],
            functionName: 'ragequit',
            args: [1n],
            account: USER
        });
        console.log("SIMULATION_1N=SUCCESS");
    } catch (err) {
        console.log("SIMULATION_1N=FAILED:" + (err.shortMessage || err.message));
    }

    // Test with parseEther("1") - treating numTokens as Wei units
    console.log("\nTesting ragequit(1e18) - treating as Wei...");
    try {
        await publicClient.simulateContract({
            address: SALE,
            abi: [{ inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" }],
            functionName: 'ragequit',
            args: [parseEther("1")],
            account: USER
        });
        console.log("SIMULATION_1E18=SUCCESS");
    } catch (err) {
        console.log("SIMULATION_1E18=FAILED:" + (err.shortMessage || err.message));
    }
}

main();
