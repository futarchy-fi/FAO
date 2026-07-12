#!/usr/bin/env bash
set -euo pipefail

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

metadata_bundle="${ECONOMIC_METADATA_BUNDLE:-metadata/sepolia-site-release/bundle.json}"
bundle_dao_uri="$(jq -er '.deploymentURIs.daoURI' "$metadata_bundle")"
bundle_space_uri="$(jq -er '.deploymentURIs.spaceMetadataURI' "$metadata_bundle")"
bundle_voting_uri="$(jq -er '.deploymentURIs.votingStrategyMetadataURI' "$metadata_bundle")"
bundle_validation_uri="$(jq -er '.deploymentURIs.proposalValidationStrategyMetadataURI' "$metadata_bundle")"
export DAO_URI="${DAO_URI:-$bundle_dao_uri}"
export SPACE_METADATA_URI="${SPACE_METADATA_URI:-$bundle_space_uri}"
export VOTING_STRATEGY_METADATA_URI="${VOTING_STRATEGY_METADATA_URI:-$bundle_voting_uri}"
export PROPOSAL_VALIDATION_STRATEGY_METADATA_URI="${PROPOSAL_VALIDATION_STRATEGY_METADATA_URI:-$bundle_validation_uri}"
if [[ "$DAO_URI" != "$bundle_dao_uri" || "$SPACE_METADATA_URI" != "$bundle_space_uri" \
  || "$VOTING_STRATEGY_METADATA_URI" != "$bundle_voting_uri" \
  || "$PROPOSAL_VALIDATION_STRATEGY_METADATA_URI" != "$bundle_validation_uri" ]]; then
  printf 'Metadata URI environment does not match %s\n' "$metadata_bundle" >&2
  exit 1
fi

expected_deployer="${EXPECTED_DEPLOYER:-0x693E3FB46Bb36eE43C702FE94f9463df0691b43d}"
expected_nonce="${EXPECTED_DEPLOYER_NONCE:-185}"
cast_bin="${CAST_BIN:-cast}"
deployer="$($cast_bin wallet address --private-key "$PRIVATE_KEY")"
if [[ "${deployer,,}" != "${expected_deployer,,}" ]]; then
  printf 'Expected deployer %s, got %s\n' "$expected_deployer" "$deployer" >&2
  exit 1
fi
pending_nonce="$($cast_bin nonce "$deployer" --block pending --rpc-url "$SEPOLIA_RPC_URL")"
if [[ "$pending_nonce" != "$expected_nonce" ]]; then
  printf 'Expected pending nonce %s, got %s\n' "$expected_nonce" "$pending_nonce" >&2
  exit 1
fi
receipt="$($cast_bin compute-address "$deployer" --nonce "$((expected_nonce + 2))" | awk '{print $3}')"
release_strategy="$($cast_bin compute-address "$receipt" --nonce 3 | awk '{print $3}')"
metadata_release="$(jq -er '.properties.execution_strategies[0]' \
  "$(dirname "$metadata_bundle")/space.json")"
if [[ "${release_strategy,,}" != "${metadata_release,,}" ]]; then
  printf 'Metadata release strategy %s does not match predicted %s\n' \
    "$metadata_release" "$release_strategy" >&2
  exit 1
fi

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
