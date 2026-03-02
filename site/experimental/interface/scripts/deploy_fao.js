const fs = require('fs');
const path = require('path');
const solc = require('solc');
const dotenv = require('dotenv');
const { createWalletClient, createPublicClient, http, parseEther, formatEther } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const { gnosis } = require('viem/chains');

// Load environment variables from FAO/.env
dotenv.config({ path: path.join(__dirname, '../FAO/.env') });

const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
    console.error("Error: PRIVATE_KEY not found in FAO/.env");
    process.exit(1);
}

// Ensure private key has 0x prefix
const account = privateKeyToAccount(PRIVATE_KEY.startsWith('0x') ? PRIVATE_KEY : `0x${PRIVATE_KEY}`);

const client = createWalletClient({
    account,
    chain: gnosis,
    transport: http()
});

const publicClient = createPublicClient({
    chain: gnosis,
    transport: http()
});

function findImports(importPath) {
    if (importPath.startsWith('@openzeppelin/')) {
        const libPath = path.join(__dirname, '../FAO/lib/openzeppelin-contracts/contracts', importPath.replace('@openzeppelin/contracts/', ''));
        try {
            return { contents: fs.readFileSync(libPath, 'utf8') };
        } catch (e) {
            return { error: 'File not found: ' + libPath };
        }
    } else {
        // Handle relative imports (e.g. ./FAOToken.sol)
        const localPath = path.join(__dirname, '../FAO/src', importPath);
        try {
            return { contents: fs.readFileSync(localPath, 'utf8') };
        } catch (e) {
            return { error: 'File not found: ' + localPath };
        }
    }
}

async function compileContracts() {
    const tokenPath = path.join(__dirname, '../FAO/src/FAOToken.sol');
    const salePath = path.join(__dirname, '../FAO/src/FAOSale.sol');

    const input = {
        language: 'Solidity',
        sources: {
            'FAOToken.sol': {
                content: fs.readFileSync(tokenPath, 'utf8')
            },
            'FAOSale.sol': {
                content: fs.readFileSync(salePath, 'utf8')
            }
        },
        settings: {
            outputSelection: {
                '*': {
                    '*': ['*']
                }
            }
        }
    };

    console.log("Compiling contracts...");
    const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

    if (output.errors) {
        let hasError = false;
        output.errors.forEach(err => {
            if (err.severity === 'error') {
                console.error(err.formattedMessage);
                hasError = true;
            } else {
                console.warn(err.formattedMessage);
            }
        });
        if (hasError) process.exit(1);
    }

    return {
        FAOToken: output.contracts['FAOToken.sol']['FAOToken'],
        FAOSale: output.contracts['FAOSale.sol']['FAOSale']
    };
}

async function deploy() {
    console.log(`Deploying from address: ${account.address}`);

    // 1. Compile
    const contracts = await compileContracts();
    const TokenArtifact = contracts.FAOToken;
    const SaleArtifact = contracts.FAOSale;

    // 2. Deploy Token
    console.log("\nDeploying FAOToken...");
    const tokenHash = await client.deployContract({
        abi: TokenArtifact.abi,
        bytecode: TokenArtifact.evm.bytecode.object,
        args: [account.address]
    });
    console.log(`Token Tx Hash: ${tokenHash}`);
    const tokenReceipt = await publicClient.waitForTransactionReceipt({ hash: tokenHash });
    const tokenAddress = tokenReceipt.contractAddress;
    console.log(`FAOToken deployed at: ${tokenAddress}`);

    // 3. Deploy Sale
    console.log("\nDeploying FAOSale...");
    const saleHash = await client.deployContract({
        abi: SaleArtifact.abi,
        bytecode: SaleArtifact.evm.bytecode.object,
        args: [
            tokenAddress,
            1000000n, // MIN_INITIAL_PHASE_SOLD (1 million tokens?) 
            // Warning: Ensure config matches. The Solidity code says "e.g. 1_000_000 * 10**decimals". 
            // Wait, the constructor says "uint256 _minInitialPhaseSold".
            // The logic: `initialTokensSold >= MIN_INITIAL_PHASE_SOLD`.
            // initialTokensSold is incremented by `numTokens` in `buy`.
            // `buy` takes `numTokens` (whole tokens).
            // So passing `1000000` means 1 million whole tokens. Correct.
            account.address, // Admin
            "0x0000000000000000000000000000000000000000", // Incentive (can set later)
            "0x0000000000000000000000000000000000000000"  // Insider (can set later)
        ]
    });
    console.log(`Sale Tx Hash: ${saleHash}`);
    const saleReceipt = await publicClient.waitForTransactionReceipt({ hash: saleHash });
    const saleAddress = saleReceipt.contractAddress;
    console.log(`FAOSale deployed at: ${saleAddress}`);

    // 4. Grant Minter Role
    console.log("\nGranting MINTER_ROLE to FAOSale...");
    // MINTER_ROLE is usually keccak256("MINTER_ROLE"). 
    // But let's read it from contract to be safe or just standard hash.
    // Standard AccessControl "MINTER_ROLE" is usually configurable.
    // The contract FAOToken (from ABI snippet) has `public constant MINTER_ROLE = ...` ?
    // No, I need to call the getter or calc it.
    // In Solidity: `bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");`
    // So in JS:
    const { keccak256, toBytes } = require('viem');
    const MINTER_ROLE = keccak256(toBytes('MINTER_ROLE'));

    const grantHash = await client.writeContract({
        address: tokenAddress,
        abi: TokenArtifact.abi,
        functionName: 'grantRole',
        args: [MINTER_ROLE, saleAddress]
    });
    console.log(`Grant Role Tx: ${grantHash}`);
    await publicClient.waitForTransactionReceipt({ hash: grantHash });
    console.log("Role Granted.");

    // 5. Start Sale
    console.log("\nStarting Sale...");
    const startHash = await client.writeContract({
        address: saleAddress,
        abi: SaleArtifact.abi,
        functionName: 'startSale',
        args: []
    });
    console.log(`Start Sale Tx: ${startHash}`);
    await publicClient.waitForTransactionReceipt({ hash: startHash });
    console.log("Sale Started!");

    console.log("\n==============================");
    console.log("DEPLOYMENT COMPLETE");
    console.log(`FAO_TOKEN: "${tokenAddress}"`);
    console.log(`FAO_SALE: "${saleAddress}"`);
    console.log("==============================");

    const configPath = path.join(__dirname, '../src/config/contracts.js');
    const configContent = `export const CONTRACTS = {
    // Gnosis Chain (100)
    FAO_TOKEN: "${tokenAddress}",
    FAO_SALE: "${saleAddress}",
};

export const CHAIN_ID = 100; // Gnosis Chain ID
`;
    fs.writeFileSync(configPath, configContent);
    console.log(`\nUpdated configuration at ${configPath}`);
}

deploy().catch(console.error);
