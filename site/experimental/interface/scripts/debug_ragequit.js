/**
 * Deep Debug Script: Ragequit Failure Investigation
 * 
 * This script performs comprehensive on-chain verification to identify
 * why ragequit is failing with "Insufficient FAO balance"
 */
const { createPublicClient, http, parseEther, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

// ============ CONFIGURATION ============
const FAO_TOKEN_ADDRESS = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17";
const FAO_SALE_ADDRESS = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
const USER_ADDRESS = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";
const RPC_URL = "https://rpc.gnosischain.com";
const TEST_AMOUNT = parseEther("1"); // 1 token in Wei

// ============ ABIS ============
const FAOSaleABI = [
    { inputs: [], name: "TOKEN", outputs: [{ type: "address" }], stateMutability: "view", type: "function" },
    { inputs: [], name: "currentPriceWeiPerToken", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
    { inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" },
];

const FAOTokenABI = [
    { inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
    { inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], name: "allowance", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
];

// ============ MAIN ============
async function main() {
    console.log("========================================");
    console.log("  DEEP DEBUG: Ragequit Failure");
    console.log("========================================\n");

    const publicClient = createPublicClient({ chain: gnosis, transport: http(RPC_URL) });

    // ----- STEP 1: Verify Token Addresses -----
    console.log("STEP 1: Token Address Verification");
    console.log("-".repeat(40));
    console.log(`UI/Config FAO_TOKEN: ${FAO_TOKEN_ADDRESS}`);

    const linkedToken = await publicClient.readContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'TOKEN'
    });
    console.log(`CONTRACT FAOSale.TOKEN(): ${linkedToken}`);

    const tokenMatch = FAO_TOKEN_ADDRESS.toLowerCase() === linkedToken.toLowerCase();
    console.log(`MATCH: ${tokenMatch ? '✅ YES' : '❌ NO'}`);
    if (!tokenMatch) {
        console.log("\n⚠️ CRITICAL MISMATCH FOUND!");
        console.log("The UI is reading balance from a DIFFERENT token than the Sale contract expects.");
        console.log("FIX: Update contracts.js FAO_TOKEN to:", linkedToken);
        return;
    }

    // ----- STEP 2: Read User Balance (from both tokens to be safe) -----
    console.log("\nSTEP 2: User Balance Check");
    console.log("-".repeat(40));

    const userBalance = await publicClient.readContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'balanceOf',
        args: [USER_ADDRESS]
    });
    console.log(`User Balance (Wei): ${userBalance}`);
    console.log(`User Balance (Tokens): ${formatEther(userBalance)}`);
    console.log(`Test Amount (Wei): ${TEST_AMOUNT}`);
    console.log(`Has Sufficient Balance: ${userBalance >= TEST_AMOUNT ? '✅ YES' : '❌ NO'}`);

    // ----- STEP 3: Check Allowance -----
    console.log("\nSTEP 3: Allowance Check");
    console.log("-".repeat(40));

    const allowance = await publicClient.readContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'allowance',
        args: [USER_ADDRESS, FAO_SALE_ADDRESS]
    });
    console.log(`Allowance for Sale (Wei): ${allowance}`);
    console.log(`Allowance for Sale (Tokens): ${formatEther(allowance)}`);
    console.log(`Has Sufficient Allowance: ${allowance >= TEST_AMOUNT ? '✅ YES' : '❌ NO'}`);

    // ----- STEP 4: Simulate Ragequit -----
    console.log("\nSTEP 4: Simulate Ragequit");
    console.log("-".repeat(40));

    try {
        await publicClient.simulateContract({
            address: FAO_SALE_ADDRESS,
            abi: FAOSaleABI,
            functionName: 'ragequit',
            args: [TEST_AMOUNT],
            account: USER_ADDRESS
        });
        console.log(`Simulation: ✅ SUCCESS`);
    } catch (err) {
        console.log(`Simulation: ❌ FAILED`);
        console.log(`Error: ${err.shortMessage || err.message}`);

        // Try to extract more details
        if (err.cause && err.cause.data) {
            console.log(`Decoded Error Data: ${JSON.stringify(err.cause.data)}`);
        }
    }

    // ----- STEP 5: Check Contract xDAI Balance -----
    console.log("\nSTEP 5: Contract Treasury Check");
    console.log("-".repeat(40));

    const contractBalance = await publicClient.getBalance({ address: FAO_SALE_ADDRESS });
    const expectedReturn = (TEST_AMOUNT * await publicClient.readContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'currentPriceWeiPerToken'
    })) / parseEther("1");

    console.log(`FAOSale xDAI Balance: ${formatEther(contractBalance)} xDAI`);
    console.log(`Expected Return for 1 Token: ${formatEther(expectedReturn)} xDAI`);
    console.log(`Can Pay Out: ${contractBalance >= expectedReturn ? '✅ YES' : '❌ NO'}`);

    console.log("\n========================================");
    console.log("  DEBUGGING COMPLETE");
    console.log("========================================");
}

main().catch(console.error);
