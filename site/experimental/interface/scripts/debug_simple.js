const { createPublicClient, http, parseEther, formatEther } = require('viem');
const { gnosis } = require('viem/chains');

const FAO_TOKEN_ADDRESS = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17";
const FAO_SALE_ADDRESS = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
const USER_ADDRESS = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";
const TEST_AMOUNT = parseEther("1");

const FAOSaleABI = [
    { inputs: [], name: "TOKEN", outputs: [{ type: "address" }], stateMutability: "view", type: "function" },
];

const FAOTokenABI = [
    { inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
    { inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], name: "allowance", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
];

async function main() {
    const publicClient = createPublicClient({ chain: gnosis, transport: http("https://rpc.gnosischain.com") });

    console.log("CONFIG FAO_TOKEN: " + FAO_TOKEN_ADDRESS);

    const linkedToken = await publicClient.readContract({
        address: FAO_SALE_ADDRESS,
        abi: FAOSaleABI,
        functionName: 'TOKEN'
    });
    console.log("CONTRACT TOKEN(): " + linkedToken);
    console.log("MATCH: " + (FAO_TOKEN_ADDRESS.toLowerCase() === linkedToken.toLowerCase()));

    const bal = await publicClient.readContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'balanceOf',
        args: [USER_ADDRESS]
    });
    console.log("USER BALANCE: " + formatEther(bal) + " FAO");

    const allow = await publicClient.readContract({
        address: FAO_TOKEN_ADDRESS,
        abi: FAOTokenABI,
        functionName: 'allowance',
        args: [USER_ADDRESS, FAO_SALE_ADDRESS]
    });
    console.log("ALLOWANCE: " + formatEther(allow) + " FAO");

    try {
        await publicClient.simulateContract({
            address: FAO_SALE_ADDRESS,
            abi: [{ inputs: [{ name: "numTokens", type: "uint256" }], name: "ragequit", outputs: [], stateMutability: "nonpayable", type: "function" }],
            functionName: 'ragequit',
            args: [TEST_AMOUNT],
            account: USER_ADDRESS
        });
        console.log("SIMULATION: SUCCESS");
    } catch (err) {
        console.log("SIMULATION: FAILED - " + (err.shortMessage || err.message));
    }
}

main().catch(e => console.log("ERROR: " + e.message));
