# FAO agent-work documents v1

Lane 5 records work and proposed payment without adding a second governance or custody system.
The reviewed `TransferAction` remains the only payment primitive. The optional `AgentWorkIndex`
is one ownerless, storage-free event log shared by every FAO on a chain; economics never read it.

## Publication

```solidity
publish(bytes32 kind, bytes32 parentDigest, bytes document) returns (bytes32 documentDigest)
```

`documentDigest` is `keccak256(document)`. `Published` indexes the kind, parent, and digest and
carries the publisher and exact document bytes. The contract accepts every kind and every nonempty
byte string. It has no owner, allowlist, size cap, deduplication, custody, withdrawal, endorsement,
or payment authority. Gas is the spam bound; clients filter and deduplicate. Earliest finalized log
ordering is only evidence for humans, challengers, and markets.

The v1 kind values are:

- `keccak256("FAO_AGENT_TASK_V1")`
- `keccak256("FAO_AGENT_RECEIPT_V1")`
- `keccak256("FAO_AGENT_PAYMENT_V1")`

## Canonical JSON bytes

Documents are UTF-8 without a BOM and contain one top-level object. Arrays keep their given order.
Object keys are sorted by Unicode codepoint. There is no insignificant whitespace. Every scalar
leaf is a JSON string: numbers, booleans, and null are forbidden, and an absent optional value means
the key is omitted.

Strings escape only quote, backslash, and U+0000 through U+001F. Every control is the lowercase
six-byte form `\u00xx`, including newline and tab; non-ASCII text is raw UTF-8. Unpaired surrogates
are invalid. Addresses are lowercase 20-byte hex, digests are lowercase 32-byte hex, and integers
are unsigned decimal strings without signs or leading zeroes. The tools normalize semantic builder
input, but validators reject exact event bytes whose schema values are not already canonical.

Raw bytes are authoritative: their digest is always Keccak-256. Canonicalization is required for
the three known schemas, not for arbitrary future index kinds.

## Schemas and lineage

A task uses `parentDigest = bytes32(0)`:

```json
{"v":"1","kind":"fao.task","chainId":"11155111","vault":"0x…","title":"…","spec":"…","salt":"0x…"}
```

It must contain either `spec`, or both `specDigest` and advisory `specUri`. `deadline` is optional.
`reward:{"asset":"0x…","amount":"…"}` is optional and advisory; publication creates no bounty
or obligation.

A receipt uses `parentDigest = taskDigest`:

```json
{"v":"1","kind":"fao.receipt","chainId":"…","vault":"0x…","task":"0x…","worker":"0x…","artifacts":[{"digest":"0x…","uri":"…"}],"summary":"…","salt":"0x…"}
```

Each artifact commits to the exact artifact bytes with Keccak-256. Its URI is advisory and limited
to 256 UTF-8 bytes by the v1 tools; `note` is optional. No CID or IPFS dependency exists.
The on-chain kind is permanently `FAO_AGENT_RECEIPT_V1`. “Submission” is only explanatory prose
for this work receipt; it is not a fourth document kind.

A payment envelope uses `parentDigest = receiptDigest`:

```json
{"v":"1","kind":"fao.payment","chainId":"…","vault":"0x…","asset":"0x…","recipient":"0x…","amount":"…","task":"0x…","receipt":"0x…","salt":"0x…"}
```

`note` is optional. The transfer is exactly
`{asset, recipient, amount, salt: keccak256(envelopeBytes)}`. Envelope chain, vault, asset,
recipient, and amount must match the proposed action. The envelope's own salt permits a fresh
identity when rejected or expired economics are proposed again. The resulting transfer hash is the
proposal ID and remains chain- and vault-domain-separated by `FAOTreasuryActions`.

## Payment meaning

Acceptance means authorized, executable while funded, and never partially paid. Funds are neither
reserved nor escrowed: ragequit, buyback, or another action may consume them before execution. A
shortfall reverts atomically and can be retried before expiry. There are no v1 bids, guaranteed
bounties, slashing, exclusive winners, copying rules, or self-payment exceptions. Every proposer,
worker, and recipient goes through the same immutable transfer limits and futarchy path.

The dependency-free implementations and shared golden vectors are
[`tools/agent_documents.py`](../tools/agent_documents.py) and
[`tools/fixtures/agent-document-golden.json`](../tools/fixtures/agent-document-golden.json).
The separate singleton build, runtime hash, CREATE2 salt, and predicted address are pinned in
[`metadata/agent-work-index.json`](../metadata/agent-work-index.json); verify them with
`python3 tools/agent_work_index_code_hashes.py --check`.
The address is a CREATE2 prediction, not deployment evidence. A pinned runtime hash or predicted
address must never be presented as deployed until a chain receipt and matching live code prove it.

## Stateless reference agent

[`tools/agent_runner.py`](../tools/agent_runner.py) is the dependency-free P1 reference agent. Each
tick starts from finalized logs and views, chooses at most one action, simulates and cap-checks it,
then passes the unsigned transaction to an injected sender. It holds no key or authoritative local
state. Accepted, executable, and paid are deliberately separate: acceptance needs a matching view
and finalized arbitration log; executability needs a live queue window and successful exact
`eth_call`; payment needs the exact execution log and conserved balance deltas.

The executable unit, fake-RPC, Anvil, and Sepolia-fork matrix is:

```sh
python3 -m unittest tools.test_agent_documents tools.test_agent_runner
python3 tools/agent_anvil_drill.py
```

The latter regenerates
[`metadata/agent-work-p1-evidence.json`](../metadata/agent-work-p1-evidence.json) and its SHA-256
sidecar. These are house-wallet engineering fixtures. They do not prove a live index deployment,
live payment, useful work, external demand, or guaranteed payment.
