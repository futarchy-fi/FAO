const { createPublicClient, http, formatEther, parseAbi, formatUnits } = require('viem');
const { gnosis } = require('viem/chains');

const USER_ADDRESS = '0x645A3D9208523bbFEE980f7269ac72C61Dd3b552';
const FAO_SALE_ADDRESS = '0x3f3ab07ad792bb89dff7528d1cef78372b0d8b93';
const FAO_TOKEN_ADDRESS = '0x19c85acb4ca0ff6fed5f8d7b376bfbb37a2d67e9';

const SALE_ABI = parseAbi([
    "function saleStart() view returns (uint256)",
    "function initialPhaseEnd() view returns (uint256)",
    "function initialTokensSold() view returns (uint256)",
    "function MIN_INITIAL_PHASE_SOLD() view returns (uint256)",
    "function initialPhaseFinalized() view returns (bool)",
    "function initialNetSale() view returns (uint256)",
    "function currentPriceWeiPerToken() view returns (uint256)"
]);

const TOKEN_ABI = parseAbi([
    "function balanceOf(address) view returns (uint256)"
]);

async function main() {
    const client = createPublicClient({
        chain: gnosis,
        transport: http()
    });

    console.log(`\n--- DIAGNOSTICS FOR FAO SALE ---`);
    console.log(`User: ${USER_ADDRESS}`);
    console.log(`Contract: ${FAO_SALE_ADDRESS}`);

    // 1. User Balances
    const xdaiBal = await client.getBalance({ address: USER_ADDRESS });
    console.log(`\n[User Balances]`);
    console.log(`xDAI: ${formatEther(xdaiBal)}`);

    try {
        const faoBal = await client.readContract({
            address: FAO_TOKEN_ADDRESS,
            abi: TOKEN_ABI,
            functionName: 'balanceOf',
            args: [USER_ADDRESS]
        });
        console.log(`FAO: ${formatEther(faoBal)}`);
    } catch (e) {
        console.log(`FAO: Error fetching balance (${e.message.split('\n')[0]})`);
    }

    // 2. Sale State
    console.log(`\n[Contract State]`);
    try {
        const [
            saleStart,
            initialPhaseEnd,
            initialTokensSold,
            minInitialSold,
            isFinalized,
            initialNetSale,
            currentPrice
        ] = await Promise.all([
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'saleStart' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'initialPhaseEnd' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'initialTokensSold' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'MIN_INITIAL_PHASE_SOLD' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'initialPhaseFinalized' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'initialNetSale' }),
            client.readContract({ address: FAO_SALE_ADDRESS, abi: SALE_ABI, functionName: 'currentPriceWeiPerToken' })
        ]);

        const now = Math.floor(Date.now() / 1000);

        console.log(`Current Time (Timestamp): ${now}`);
        console.log(`1. Sale Start:          ${new Date(Number(saleStart) * 1000).toISOString()} (${saleStart})`);
        console.log(`2. Initial Phase End:   ${new Date(Number(initialPhaseEnd) * 1000).toISOString()} (${initialPhaseEnd})`);

        const phaseEnded = now >= Number(initialPhaseEnd);
        console.log(`   -> Initial Phase Ended By Time? ${phaseEnded ? 'YES' : 'NO'}`);

        console.log(`3. Initial Tokens Sold: ${initialTokensSold} (Raw Units? Check internal decimals)`);
        console.log(`4. MIN Target Sold:     ${minInitialSold}`);

        const targetMet = initialTokensSold >= minInitialSold;
        console.log(`   -> Target Met?       ${targetMet ? 'YES' : 'NO'}`);

        console.log(`5. Phase Finalized?     ${isFinalized}`);
        console.log(`6. Initial Net Sale:    ${initialNetSale}`);
        console.log(`7. Current Price:       ${formatEther(currentPrice)} xDAI`);

        console.log(`\n[Analysis]`);
        if (phaseEnded && !targetMet) {
            console.log("CRITICAL: The initial phase time caused expiry, but the minimum sales target was NOT met.");
            console.log("Result: The contract cannot finalize the initial phase successfully to transition to the bonding curve.");
            console.log("Reason for 'No initial net sale' error: The code requires `initialNetSale > 0` which acts as the seed.");
            if (initialNetSale == 0n) {
                console.log("CONFIRMED: initialNetSale is 0. Buying is currently impossible.");
            }
        } else if (!phaseEnded) {
            console.log("Initial phase is still active. Errors might be due to other reasons.");
        } else {
            console.log("Phase ended and target met. Should be working.");
        }

    } catch (e) {
        console.error("Error fetching contract state:", e);
    }
}

main();
