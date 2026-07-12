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
  script/DeployFAOSepoliaSiteRelease.s.sol:DeployFAOSepoliaSiteRelease \
  --force \
  --rpc-url "$SEPOLIA_RPC_URL" \
  "$@"

run_dir="broadcast/DeployFAOSepoliaSiteRelease.s.sol/11155111/dry-run"
for argument in "$@"; do
  if [[ "$argument" == "--broadcast" ]]; then
    run_dir="broadcast/DeployFAOSepoliaSiteRelease.s.sol/11155111"
  fi
done
run_file="$run_dir/run-latest.json"

jq -e '
  .chain == 11155111
  and ([.transactions[] | select(.contractName == "FAOSepoliaSiteReleaseDeployment")] | length == 1)
' "$run_file" >/dev/null
printf 'Validated deployment artifact: %s\n' "$run_file"
