const { createPublicClient, http, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http("https://rpc.gnosischain.com")
    });

    const FAOSALE = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
    const USER = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";

    // Step 1: Get linked TOKEN address from FAOSale
    const linkedToken = await publicClient.readContract({
        address: FAOSALE,
        abi: [{ inputs: [], name: "TOKEN", outputs: [{ type: "address" }], stateMutability: "view", type: "function" }],
        functionName: 'TOKEN'
    });
    console.log("1. LINKED_TOKEN=" + linkedToken);

    // Step 2: Get user's balance on THAT token
    const userBalance = await publicClient.readContract({
        address: linkedToken,
        abi: [{ inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" }],
        functionName: 'balanceOf',
        args: [USER]
    });
    console.log("2. USER_BALANCE_WEI=" + userBalance.toString());
    console.log("   USER_BALANCE_FORMATTED=" + formatEther(userBalance));

    // Step 3: Get user's allowance for FAOSale on THAT token
    const allowance = await publicClient.readContract({
        address: linkedToken,
        abi: [{ inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], name: "allowance", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" }],
        functionName: 'allowance',
        args: [USER, FAOSALE]
    });
    console.log("3. ALLOWANCE_WEI=" + allowance.toString());
    console.log("   ALLOWANCE_FORMATTED=" + formatEther(allowance));

    // Step 4: Check if FAOSALE has ragequit capability
    const treasury = await publicClient.getBalance({ address: FAOSALE });
    console.log("4. TREASURY_XDAI=" + formatEther(treasury));

    // Final conclusion
    if (userBalance === 0n) {
        console.log("\n[DIAGNOSIS] User has 0 balance on the linked token!");
        console.log("This is why ragequit fails.");
    } else if (allowance === 0n) {
        console.log("\n[DIAGNOSIS] Allowance is 0. User needs to approve.");
    } else {
        console.log("\n[DIAGNOSIS] Balance and allowance look ok. Check contract logic.");
    }
}

main();
