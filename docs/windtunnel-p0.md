# FAO wind tunnel P0

This control plane adds no daemon, signer, production economic bytecode, or runtime dependency. A
local-only Foundry driver exercises the existing pinned production artifacts. One FAO still has
exactly one active arbitration evaluation and one conditional market; scale comes from indexing
multiple registrar-created instances.

## Frozen inputs and state

[`event-schema-v1.json`](../tools/windtunnel/event-schema-v1.json) remains the frozen P0 boundary.
[`event-schema-v2.json`](../tools/windtunnel/event-schema-v2.json) adds trusted EconGateway and
Snapshot X Space payload events plus FLM restore deferral.
It pins event signatures/topics and the minimal registrar, receipt, arbitration, evaluator, and FLM
records. Raw relevant logs use `(chainId, blockHash, logIndex)` as their SQLite key. Blocks and logs
are accepted only through the RPC's `finalized` head.

On every update the indexer compares stored block hashes with the finalized chain, walks back to the
last common ancestor, deletes the orphan suffix, indexes the replacement lineage, and rebuilds all
derived tables from ordered raw logs. Replay output is canonical JSON, so a restart or second replay
has identical bytes. Queue derivation enforces FIFO, a singleton active evaluation, and
`MAX_QUEUE = 16`.

At the same finalized block, the indexer hydrates fixed getters on the registrar, receipt,
arbitration, evaluator, relay, and FLM. Treasury payloads are reconstructed only from a sealed
gateway event; site payload bytes come only from the sealed Space's `ProposalCreated` event and must
name the sealed release strategy. `Indexer.next_action(receipt)` is therefore the supported start
path: callers never supply evaluation bytes.

The stateless keeper consumes that derived and hydrated state. It returns zero or one unsigned
action. Its priority preserves the single-market
invariant: create the active market, migrate/restore FLM when ready, resolve, admit the FIFO head,
finalize timeouts, graduate, then retry idle-liquidity restoration. `StaticCaller` and
`TransactionSender` are boundaries only; the package stores no key and implements no broadcaster.

Static simulations and externally observed send/receipt outcomes are appended to SQLite evidence.
A revert is only upgraded to `benign-race` when one identical action landed and the caller confirms
the postcondition already holds; `InvalidState()` alone is merely a race candidate. Replay never
deletes these observations.

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
python3 -m tools.windtunnel.cli next --db /tmp/fao-windtunnel.sqlite --receipt 0x...
python3 -m tools.windtunnel.cli funding --manifest funding.json
```

`index`, `replay`, and `report` emit a v2 evidence envelope containing the canonical report and its
SHA-256 digest. None sends a transaction. An injected external signer adapter remains a later step.

The explicit post-build Anvil race uses unlocked disposable accounts and stores no key:

```bash
python3 -m tools.windtunnel.anvil_drill race --output /tmp/windtunnel-race.json
```

The capped ten-instance command deploys ten current `FutarchyArbitration` instances locally, pins a
mined block, and performs 20 keeper simulations with zero keeper broadcasts:

```bash
python3 -m tools.windtunnel.anvil_drill prebroadcast-10 \
  --output /tmp/windtunnel-prebroadcast-10.json
```

Its committed fixture says `broadcast: false`; this is deterministic pre-broadcast lifecycle
evidence, not a live ten-FAO economic deployment.

The full-economic gate starts a fresh loopback Anvil chain, rejects any chain other than 31337
before sending, and uses only unlocked disposable Anvil accounts. It stages ten unique receipts
through the real registrar, deploys each full core/evaluator and hash-pinned FLM, and leaves exactly
one typed gateway proposal in `EVALUATING` on each independent arbitration:

```bash
python3 -m tools.windtunnel.anvil_drill economic-10 \
  --output /tmp/windtunnel-economic-10.json
```

Success is written only after SQLite discovers, replays, and hydrates all ten instances; checks
receipt/config hashes, singleton evaluation state, trusted gateway payload provenance, and FLM spot
mode; and repeats replay byte-for-byte. The artifact records committed blob SHA-256 values,
generated on-chain Keccak evidence, receipts, resource/gas/time totals, a deterministic digest that
excludes the observed wall clock, and `publicBroadcasts: 0`.
If a partial local broadcast or reconciliation fails, the requested output is instead an explicit
`success: false` failure artifact. Every rerun owns a fresh zero-nonce Anvil process.

This proves local deployment/reconciliation mechanics, not demand, subsidy viability, or a live
deployment. Injected external signing, RPC fault injection, 100/1000 tiers, subsidy automation, and
UI remain deferred.
