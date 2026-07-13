#!/usr/bin/env bash
set -euo pipefail

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

"${FORGE_BIN:-forge}" script \
  script/DeployFaoGenesisRegistrar.s.sol:DeployFaoGenesisRegistrar \
  --rpc-url "$SEPOLIA_RPC_URL" \
  "$@"

run_dir="broadcast/DeployFaoGenesisRegistrar.s.sol/11155111/dry-run"
for argument in "$@"; do
  if [[ "$argument" == "--broadcast" ]]; then
    run_dir="broadcast/DeployFaoGenesisRegistrar.s.sol/11155111"
  fi
done
run_file="$run_dir/run-latest.json"

jq -e '
  .chain == 11155111
  and (.pending | length == 0)
  and (.transactions | length == 1)
  and .transactions[0].transactionType == "CREATE"
' "$run_file" >/dev/null
printf 'Validated singleton registrar artifact: %s\n' "$run_file"
