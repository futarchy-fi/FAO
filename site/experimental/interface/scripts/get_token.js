const { createPublicClient, http } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http("https://rpc.gnosischain.com")
    });

    const linkedToken = await publicClient.readContract({
        address: "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2",
        abi: [{ inputs: [], name: "TOKEN", outputs: [{ type: "address" }], stateMutability: "view", type: "function" }],
        functionName: 'TOKEN'
    });

    console.log("LINKED_TOKEN=" + linkedToken);
}

main();
