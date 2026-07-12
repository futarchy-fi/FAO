#!/usr/bin/env bash
set -euo pipefail

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${DAO_URI:?set DAO_URI}"
: "${SPACE_METADATA_URI:?set SPACE_METADATA_URI}"
: "${VOTING_STRATEGY_METADATA_URI:?set VOTING_STRATEGY_METADATA_URI}"
: "${PROPOSAL_VALIDATION_STRATEGY_METADATA_URI:?set PROPOSAL_VALIDATION_STRATEGY_METADATA_URI}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

"${FORGE_BIN:-forge}" script \
  script/DeployFaoEconomicGenesis.s.sol:DeployFaoEconomicGenesis \
  --rpc-url "$SEPOLIA_RPC_URL" \
  "$@"

run_dir="broadcast/DeployFaoEconomicGenesis.s.sol/11155111/dry-run"
for argument in "$@"; do
  if [[ "$argument" == "--broadcast" ]]; then
    run_dir="broadcast/DeployFaoEconomicGenesis.s.sol/11155111"
  fi
done
run_file="$run_dir/run-latest.json"

jq -e '
  .chain == 11155111
  and (.pending | length == 0)
  and (.transactions | length == 5)
  and ([.transactions[] | select(.transactionType == "CREATE")] | length == 3)
  and ([.transactions[] | select(.transactionType == "CALL")] | length == 2)
' "$run_file" >/dev/null
printf 'Validated five-transaction economic-genesis artifact: %s\n' "$run_file"
