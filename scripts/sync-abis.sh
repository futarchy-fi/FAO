#!/usr/bin/env bash
# T5.D1/T5.D5 - keep site-testnet ABI bindings generated from forge output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABI_DIR="$ROOT_DIR/site-testnet/abis"
MODE="${1:-sync}"

if [[ "$MODE" != "sync" && "$MODE" != "--check" ]]; then
  echo "usage: $0 [--check]"
  exit 2
fi

if command -v forge >/dev/null 2>&1; then
  FORGE_BIN="$(command -v forge)"
elif [[ -x "$HOME/.foundry/bin/forge" ]]; then
  FORGE_BIN="$HOME/.foundry/bin/forge"
else
  echo "::error::forge not found on PATH or at \$HOME/.foundry/bin/forge"
  exit 1
fi

CONTRACTS=(
  CtfRouter
  EvaluationPipeline
  FAOCreateAndBond
  FAOFutarchyFactory
  FAOFutarchyProposal
  FAOOfficialProposalOrchestrator
  FAOSale
  FAOToken
  FAOTwapResolver
  FutarchyArbitration
  FutarchyCtfSettlementOracle
  FutarchyEvaluator
  FutarchyLiquidityManager
  FutarchyOfficialProposalOrchestrator
  FutarchyOfficialProposalSource
  FutarchyRegistry
  FutarchyStackDeployer
  FutarchyTWAPOracle
  GenericFutarchyToken
  InsiderVesting
  InstanceSale
  ManualEvaluator
  ParameterizedArbitration
  SXArbitrationExecutionStrategy
  SaleSpotSeeder
  SwaprAlgebraLiquidityAdapter
  TokenAndArbitrationDeployer
  UniswapV3LiquidityAdapter
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for contract in "${CONTRACTS[@]}"; do
  "$FORGE_BIN" inspect "$contract" abi --json > "$TMP_DIR/$contract.json"
done

if [[ "$MODE" == "--check" ]]; then
  if [[ ! -d "$ABI_DIR" ]]; then
    echo "::error::missing ABI directory: $ABI_DIR"
    exit 1
  fi

  if ! diff -ru "$ABI_DIR" "$TMP_DIR"; then
    echo "::error::site-testnet/abis is out of sync. Run: bash scripts/sync-abis.sh"
    exit 1
  fi

  echo "[ok] site-testnet ABI bindings match forge output"
  exit 0
fi

mkdir -p "$ABI_DIR"
find "$ABI_DIR" -maxdepth 1 -type f -name '*.json' -delete
cp "$TMP_DIR"/*.json "$ABI_DIR"/
echo "[ok] synced ${#CONTRACTS[@]} ABI files to site-testnet/abis"
