/**
 * Debug ragequit for specific address: 0x36CC73A1a83a9f7D99fD152B822d8d660E417208
 */
const { createPublicClient, http, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({ chain: gnosis, transport: http("https://rpc.gnosischain.com") });

    const SALE = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
    const TOKEN = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17";
    const USER = "0x36CC73A1a83a9f7D99fD152B822d8d660E417208";

    const TokenABI = [
        { inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
        { inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], name: "allowance", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
    ];

    console.log("=== DEBUG RAGEQUIT FOR " + USER + " ===\n");

    // 1. Check FAO Balance
    const balance = await publicClient.readContract({ address: TOKEN, abi: TokenABI, functionName: 'balanceOf', args: [USER] });
    console.log("1. FAO Balance (Wei): " + balance.toString());
    console.log("   FAO Balance (Tokens): " + formatEther(balance));
    console.log("   Whole Tokens: " + (balance / 1000000000000000000n).toString());

    // 2. Check Allowance
    const allowance = await publicClient.readContract({ address: TOKEN, abi: TokenABI, functionName: 'allowance', args: [USER, SALE] });
    console.log("\n2. Allowance (Wei): " + allowance.toString());
    console.log("   Allowance (Tokens): " + formatEther(allowance));
    console.log("   Allowance Whole: " + (allowance / 1000000000000000000n).toString());

    // 3. Simulate ragequit with 5 WHOLE tokens
    console.log("\n3. Simulating ragequit(5) - 5 WHOLE tokens...");
    try {
        await publicClient.simulateContract({
            address: SALE,
            abi: [{ inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" }],
            functionName: 'ragequit',
            args: [5n], // 5 WHOLE tokens
            account: USER
        });
        console.log("   RESULT: SUCCESS!");
    } catch (err) {
        console.log("   RESULT: FAILED");
        console.log("   Error: " + (err.shortMessage || err.message));
        if (err.cause) {
            console.log("   Cause: " + JSON.stringify(err.cause.reason || err.cause.data || err.cause));
        }
    }

    // 4. Check if allowance is sufficient
    const burnAmount = 5n * 1000000000000000000n; // 5 * 1e18
    console.log("\n4. Required burn amount for 5 tokens: " + burnAmount.toString() + " Wei");
    console.log("   Balance >= Burn: " + (balance >= burnAmount));
    console.log("   Allowance >= Burn: " + (allowance >= burnAmount));

    if (allowance < burnAmount) {
        console.log("\n   >>> ISSUE FOUND: Allowance too low! <<<");
        console.log("   Need: " + burnAmount.toString());
        console.log("   Have: " + allowance.toString());
    }
}

main().catch(e => console.log("ERROR: " + e.message));
