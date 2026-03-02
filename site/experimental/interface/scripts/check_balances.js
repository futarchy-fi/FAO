const { createPublicClient, http, formatEther, parseEther } = require('viem');
const { gnosis } = require('viem/chains');

async function main() {
    const publicClient = createPublicClient({
        chain: gnosis,
        transport: http("https://rpc.gnosischain.com")
    });

    // The exact addresses we're using
    const TOKEN = "0x9494C281a02c9ae5f72b224B514793ad2DD8cA17";
    const SALE = "0x38FF65E8839B581b5ad12383d93206AFcF38D4b2";
    const USER = "0x645A3D9208523bbFEE980f7269ac72C61Dd3b552";

    const TokenABI = [
        { inputs: [{ name: "account", type: "address" }], name: "balanceOf", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
        { inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], name: "allowance", outputs: [{ type: "uint256" }], stateMutability: "view", type: "function" },
    ];

    const userBal = await publicClient.readContract({ address: TOKEN, abi: TokenABI, functionName: 'balanceOf', args: [USER] });
    console.log("USER_BALANCE_WEI=" + userBal.toString());
    console.log("USER_BALANCE=" + formatEther(userBal));

    const allowance = await publicClient.readContract({ address: TOKEN, abi: TokenABI, functionName: 'allowance', args: [USER, SALE] });
    console.log("ALLOWANCE_WEI=" + allowance.toString());
    console.log("ALLOWANCE=" + formatEther(allowance));

    // Also check the contract's xDAI balance for payout
    const contractEth = await publicClient.getBalance({ address: SALE });
    console.log("CONTRACT_XDAI=" + formatEther(contractEth));
}

main();
