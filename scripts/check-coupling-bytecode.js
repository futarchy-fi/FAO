#!/usr/bin/env node
/*
 * T5.D1/T5.D2 - compare active Sepolia bytecode against local forge artifacts.
 *
 * Normalization is deliberately narrow:
 *   - constructor immutable reference slots are zeroed using forge artifact metadata;
 *   - Solidity CBOR metadata at the tail is stripped;
 *   - embedded IPFS metadata hashes inside child creation bytecode literals are zeroed.
 *
 * Everything else is hashed byte-for-byte through `cast keccak`.
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = process.cwd();
const RPC_URL = process.env.SEPOLIA_RPC || 'https://ethereum-sepolia.publicnode.com';
const CAST = process.env.CAST || findTool('cast');

const ACTIVE_CONTRACTS = [
  {
    key: 'registry',
    contract: 'FutarchyRegistry',
    artifact: 'out/FutarchyRegistry.sol/FutarchyRegistry.json',
  },
  {
    key: 'proposal_impl_v5',
    contract: 'FAOFutarchyProposal',
    artifact: 'out/FAOFutarchyProposal.sol/FAOFutarchyProposal.json',
    optionalNull: true,
  },
  {
    key: 'token_arb_deployer',
    contract: 'TokenAndArbitrationDeployer',
    artifact: 'out/FutarchyRegistryDeployers.sol/TokenAndArbitrationDeployer.json',
  },
  {
    key: 'futarchy_stack_deployer',
    contract: 'FutarchyStackDeployer',
    artifact: 'out/FutarchyRegistryDeployers.sol/FutarchyStackDeployer.json',
  },
  {
    key: 'uniswap_v3_liquidity_adapter',
    contract: 'UniswapV3LiquidityAdapter',
    artifact: 'out/UniswapV3LiquidityAdapter.sol/UniswapV3LiquidityAdapter.json',
  },
];

function findTool(name) {
  try {
    return execFileSync('bash', ['-lc', `command -v ${name}`], { encoding: 'utf8' }).trim();
  } catch (_) {
    const fallback = path.join(process.env.HOME || '', '.foundry', 'bin', name);
    if (fs.existsSync(fallback)) return fallback;
    throw new Error(`${name} not found on PATH or at ${fallback}`);
  }
}

function onlyHex(output) {
  const lines = String(output).trim().split(/\r?\n/);
  const hex = lines.findLast((line) => /^0x[0-9a-fA-F]*$/.test(line.trim()));
  if (!hex) throw new Error(`expected hex output, got: ${String(output).slice(0, 120)}`);
  return hex.trim();
}

function execHex(cmd, args) {
  return onlyHex(execFileSync(cmd, args, { cwd: ROOT, encoding: 'utf8' }));
}

function bytesFromHex(hex) {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  return Buffer.from(clean, 'hex');
}

function hexFromBytes(bytes) {
  return `0x${bytes.toString('hex')}`;
}

function zeroImmutableReferences(bytes, references) {
  for (const ranges of Object.values(references || {})) {
    for (const { start, length } of ranges) {
      if (start + length > bytes.length) {
        throw new Error(`immutable reference out of range: start=${start} length=${length}`);
      }
      bytes.fill(0, start, start + length);
    }
  }
}

function zeroEmbeddedIpfsMetadataHashes(bytes) {
  const marker = Buffer.from('a2646970667358221220', 'hex');
  for (let i = 0; i <= bytes.length - marker.length - 32; i += 1) {
    if (!bytes.subarray(i, i + marker.length).equals(marker)) continue;
    bytes.fill(0, i + marker.length, i + marker.length + 32);
    i += marker.length + 31;
  }
}

function stripTrailingCborMetadata(bytes) {
  if (bytes.length < 2) return bytes;
  const metadataLength = bytes.readUInt16BE(bytes.length - 2);
  const metadataStart = bytes.length - metadataLength - 2;
  if (metadataStart <= 0 || metadataStart > bytes.length) return bytes;
  return bytes.subarray(0, metadataStart);
}

function normalizedRuntime(hex, immutableReferences) {
  const bytes = bytesFromHex(hex);
  zeroImmutableReferences(bytes, immutableReferences);
  zeroEmbeddedIpfsMetadataHashes(bytes);
  return stripTrailingCborMetadata(bytes);
}

function keccak(bytes) {
  return execHex(CAST, ['keccak', hexFromBytes(bytes)]);
}

function checkActiveContract(manifest, item) {
  const address = manifest.active[item.key];
  if (address === null && item.optionalNull) {
    console.error(`[skip] active.${item.key} is null by manifest contract`);
    return null;
  }
  if (!address) throw new Error(`missing active.${item.key}`);

  const artifact = JSON.parse(fs.readFileSync(path.join(ROOT, item.artifact), 'utf8'));
  const localRuntime = artifact.deployedBytecode.object;
  const onchainRuntime = execHex(CAST, ['code', address, '--rpc-url', RPC_URL]);
  if (onchainRuntime === '0x') throw new Error(`active.${item.key} has no bytecode at ${address}`);

  const immutableReferences = artifact.deployedBytecode.immutableReferences || {};
  const localHash = keccak(normalizedRuntime(localRuntime, immutableReferences));
  const onchainHash = keccak(normalizedRuntime(onchainRuntime, immutableReferences));

  if (localHash !== onchainHash) {
    return {
      item,
      address,
      localHash,
      onchainHash,
    };
  }

  console.error(`[ok] active.${item.key} ${address} ${localHash}`);
  return null;
}

function main() {
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments.json'), 'utf8'));
  const failures = [];

  for (const item of ACTIVE_CONTRACTS) {
    try {
      const failure = checkActiveContract(manifest, item);
      if (failure) failures.push(failure);
    } catch (error) {
      failures.push({ item, error });
    }
  }

  if (!manifest.active.operator) throw new Error('missing active.operator');
  console.error(`[skip] active.operator ${manifest.active.operator} is an EOA, not bytecode`);

  if (failures.length > 0) {
    for (const failure of failures) {
      if (failure.error) {
        console.error(
          `bytecode check error for active.${failure.item.key} (${failure.item.contract}): ${
            failure.error && failure.error.message ? failure.error.message : failure.error
          }`
        );
        continue;
      }
      console.error(
        [
          `bytecode mismatch for active.${failure.item.key} (${failure.item.contract}) at ${failure.address}`,
          `local normalized hash:   ${failure.localHash}`,
          `on-chain normalized hash:${failure.onchainHash}`,
        ].join('\n')
      );
    }
    throw new Error(`${failures.length} active contract bytecode check(s) failed`);
  }

  process.stdout.write(`0x${'0'.repeat(63)}1`);
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
}
