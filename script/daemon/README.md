# Promote daemon

Off-chain operator daemon that retries `createOfficialProposalAndMigrate`
on `FAOOfficialProposalOrchestrator` via Flashbots multi-builder bundles
until it lands.

This is the "Submission daemon" from `docs/onchain-futarchy-design.md` §3.4
and §4.2. It implements the asymmetric cost game documented there:

- On every slot, the daemon submits a Flashbots bundle that:
  - Calls `orchestrator.createOfficialProposalAndMigrate(name, desc, TIP)`
    with `msg.value = TIP`.
- Flashbots default behavior drops the bundle on revert, so failed attempts
  cost the defender $0.
- The orchestrator's atomic flow ends with
  `block.coinbase.transfer(builderTip)`. Builder receives the TIP only on
  successful execution.
- A persistent adversary must outbid the TIP every block (or pre-create+
  initialize the conditional pools at the addresses derived from the
  block's prevrandao — see commit 002 / docs §2.5). Defender pays once on
  the eventual successful slot.

## Files

- `submit.py` (TODO) — Python entry point using web3.py + flashbots.py.
- `config.example.toml` (TODO) — operator config (builders list, TIP, etc.).

## Outline

```python
def main(config):
    web3 = Web3(HTTPProvider(config['rpc']))
    orch = web3.eth.contract(address=config['orchestrator'], abi=ORCH_ABI)
    pending = poll_pending_proposals(config['factory'])

    for cand in pending:
        if cand.already_official():
            continue
        while not cand.landed():
            block = web3.eth.block_number
            tx = orch.functions.createOfficialProposalAndMigrate(
                cand.name, cand.description, config['tip_wei']
            ).build_transaction({
                'from': operator_address,
                'value': config['tip_wei'],
                'maxFeePerGas': estimate_max_fee(web3),
                'maxPriorityFeePerGas': estimate_priority(web3),
                'nonce': web3.eth.get_transaction_count(operator_address),
            })
            signed = sign(tx, config['operator_key'])
            bundle = [{'signed_transaction': signed.rawTransaction}]
            for builder_url in config['builders']:
                submit_bundle_to_builder(builder_url, bundle, target_block=block + 1)
            wait_for_block(block + 1)
```

## Builder endpoints (Sepolia / mainnet)

- Flashbots: `https://relay.flashbots.net`
- BloXroute: `https://mev.api.blxrbdn.com`
- Titan: `https://rpc.titanbuilder.xyz`
- Beaver: `https://rpc.beaverbuild.org`
- Rsync: `https://rsync-builder.xyz`

For Sepolia testnet, Flashbots Protect supports Sepolia:
`https://relay-sepolia.flashbots.net`. Other builders may not.

## Why multi-builder

Single-builder submission has a single point of failure: if that builder
is malicious or downtime, the bundle is never included. Submitting to
multiple builders ensures at least one honest builder lands the bundle
when the state allows it.

## Operator wallet

The daemon's operator wallet must hold:
- ETH for gas + TIP.
- Sufficient FAO balance is NOT required — it's only the promoter, not
  the bond holder. Bond actions happen separately via the arbitration
  contract.

## Status

This README documents the intended design. The Python implementation is
out of scope for this commit (commit 007). It will be added in commit 008
as `script/daemon/submit.py`.
