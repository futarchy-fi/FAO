# FAO wind tunnel P0

This first slice is a read-only control plane. It adds no Solidity, daemon, signer, economic
bytecode, or runtime dependency. One FAO still has exactly one active arbitration evaluation and
one conditional market; scale comes from indexing multiple registrar-created instances.

## Frozen inputs and state

[`event-schema-v1.json`](../tools/windtunnel/event-schema-v1.json) is the v1 log-to-state boundary.
It pins event signatures/topics and the minimal registrar, receipt, arbitration, evaluator, and FLM
records. Raw relevant logs use `(chainId, blockHash, logIndex)` as their SQLite key. Blocks and logs
are accepted only through the RPC's `finalized` head.

On every update the indexer compares stored block hashes with the finalized chain, walks back to the
last common ancestor, deletes the orphan suffix, indexes the replacement lineage, and rebuilds all
derived tables from ordered raw logs. Replay output is canonical JSON, so a restart or second replay
has identical bytes. Queue derivation enforces FIFO, a singleton active evaluation, and
`MAX_QUEUE = 16`.

The stateless keeper consumes that derived state plus current view facts that logs cannot prove:
timeouts, `baseX`, committed evaluation payloads, resolution readiness, and FLM sync/restore
readiness. It returns zero or one unsigned action. Its priority preserves the single-market
invariant: create the active market, migrate/restore FLM when ready, resolve, admit the FIFO head,
finalize timeouts, graduate, then retry idle-liquidity restoration. `StaticCaller` and
`TransactionSender` are boundaries only; the package stores no key and implements no broadcaster.

## Funding manifest v1

The validator accepts exactly this shape (all amounts are canonical decimal wei strings):

```json
{
  "v": 1,
  "kind": "fao.windtunnel.funding",
  "chainId": "11155111",
  "runId": "2026-07-smoke-1",
  "runCapWei": "100000000000000000",
  "roles": [
    {"role": "deployer", "address": "0x1111111111111111111111111111111111111111", "ephemeral": true, "capWei": "40000000000000000"},
    {"role": "proposer", "address": "0x2222222222222222222222222222222222222222", "ephemeral": true, "capWei": "20000000000000000"},
    {"role": "challenger", "address": "0x3333333333333333333333333333333333333333", "ephemeral": true, "capWei": "20000000000000000"},
    {"role": "marketMaker", "address": "0x4444444444444444444444444444444444444444", "ephemeral": true, "capWei": "40000000000000000"},
    {"role": "keeper", "address": "0x5555555555555555555555555555555555555555", "ephemeral": true, "capWei": "10000000000000000"}
  ],
  "instances": [{
    "receipt": "0x6666666666666666666666666666666666666666",
    "capWei": "60000000000000000",
    "markets": [{"proposalId": "1", "capWei": "30000000000000000"}]
  }]
}
```

Every role and address is unique and ephemeral. `FundingBudget.spend` checks the role, market,
instance, and run caps before changing any counter; exhaustion is atomic. It validates allocation
semantics only and never funds, holds, derives, or reads a key.

## Dry-run commands and evidence

```bash
python3 -m tools.windtunnel.cli index \
  --db /tmp/fao-windtunnel.sqlite --rpc-url "$SEPOLIA_RPC_URL" \
  --start-block 123456 --registrar 0x...
python3 -m tools.windtunnel.cli replay --db /tmp/fao-windtunnel.sqlite
python3 -m tools.windtunnel.cli report --db /tmp/fao-windtunnel.sqlite
python3 -m tools.windtunnel.cli funding --manifest funding.json
```

`index`, `replay`, and `report` emit a v1 evidence envelope containing the canonical report and its
SHA-256 digest. None sends a transaction. The next slice should add view hydration and an external
signer adapter, then small 10-instance finalized-fork drills. Live sending, RPC fault injection,
10/100/1000 tiers, and UI stay deferred until that boundary is exercised.
