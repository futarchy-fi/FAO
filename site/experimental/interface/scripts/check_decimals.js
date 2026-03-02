const { createPublicClient, http } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http("https://rpc.gnosischain.com")
    });

    const TOKEN = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17";

    const decimals = await publicClient.readContract({
        address: TOKEN,
        abi: [{ inputs: [], name: "decimals", outputs: [{ type: "uint8" }], stateMutability: "view", type: "function" }],
        functionName: 'decimals'
    });
    console.log("TOKEN_DECIMALS=" + decimals);
}

main();
