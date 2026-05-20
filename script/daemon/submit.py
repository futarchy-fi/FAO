#!/usr/bin/env python3
"""
FAO v0 promote daemon.

Watches FAOFutarchyFactory for new candidate proposals, then races to land
`orchestrator.createOfficialProposalAndMigrate(name, desc, TIP)` via a
Flashbots bundle. On each new block:

  1. Read the next-index proposal that hasn't been promoted yet.
  2. Build a tx to the orchestrator with msg.value = TIP.
  3. Submit as a single-tx Flashbots bundle targeting block N+1.
  4. If revert (e.g. PreCreated), the bundle is dropped by default — no
     gas paid. Retry next slot.

Configuration via env vars:

  RPC_URL                  EL RPC (Sepolia: https://rpc.sepolia.org)
  FLASHBOTS_RELAY          default: https://relay-sepolia.flashbots.net
  PRIVATE_KEY              operator EOA, must hold ETH for TIP + gas
  ORCHESTRATOR             deployed FAOOfficialProposalOrchestrator
  FACTORY                  deployed FAOFutarchyFactory
  TIP_WEI                  wei to forward to block.coinbase on success
  POLL_INTERVAL_SECONDS    default 4

Mainnet operation should additionally submit to BloXroute, Titan, Beaver,
Rsync. This scaffold targets Flashbots Protect alone; multi-builder
fan-out is a TODO.

Dependencies:
  pip install web3 flashbots eth-account
"""
import json
import os
import sys
import time
from typing import Optional

# Soft import so the file is greppable without a venv.
try:
    from web3 import Web3, HTTPProvider
    from eth_account import Account
    from flashbots import flashbot
    from flashbots.types import FlashbotsBundleResponse  # type: ignore
except ImportError as e:
    print(f"Install dependencies first: pip install web3 flashbots eth-account ({e})", file=sys.stderr)
    sys.exit(1)


ORCH_ABI = json.loads("""
[
  {
    "type":"function","name":"createOfficialProposalAndMigrate",
    "inputs":[
      {"name":"marketName","type":"string"},
      {"name":"description","type":"string"},
      {"name":"builderTip","type":"uint256"}
    ],
    "outputs":[
      {"name":"proposalId","type":"uint256"},
      {"name":"proposal","type":"address"}
    ],
    "stateMutability":"payable"
  }
]
""")

FACTORY_ABI = json.loads("""
[
  {"type":"function","name":"marketsCount","inputs":[],"outputs":[{"type":"uint256"}],"stateMutability":"view"},
  {"type":"function","name":"proposals","inputs":[{"type":"uint256"}],"outputs":[{"type":"address"}],"stateMutability":"view"}
]
""")


def load_config():
    return {
        'rpc_url': os.environ['RPC_URL'],
        'flashbots_relay': os.environ.get('FLASHBOTS_RELAY', 'https://relay-sepolia.flashbots.net'),
        'private_key': os.environ['PRIVATE_KEY'],
        'orchestrator': os.environ['ORCHESTRATOR'],
        'factory': os.environ['FACTORY'],
        'tip_wei': int(os.environ.get('TIP_WEI', '10000000000000000')),  # 0.01 ETH default
        'poll_interval': int(os.environ.get('POLL_INTERVAL_SECONDS', '4')),
    }


def build_promote_tx(web3: Web3, orch_contract, name: str, desc: str, tip: int,
                     operator_addr: str, nonce: int, max_fee: int, priority: int) -> dict:
    return orch_contract.functions.createOfficialProposalAndMigrate(name, desc, tip).build_transaction({
        'from': operator_addr,
        'value': tip,
        'maxFeePerGas': max_fee,
        'maxPriorityFeePerGas': priority,
        'nonce': nonce,
        'gas': 5_000_000,
        'chainId': web3.eth.chain_id,
    })


def submit_bundle(w3_flashbots, bundle, target_block):
    response: Optional[FlashbotsBundleResponse] = w3_flashbots.flashbots.send_bundle(
        bundle, target_block_number=target_block
    )
    if response is None:
        return None, "no-response"
    receipts = response.wait()
    return response, "included" if receipts else "dropped"


def needs_promotion(web3: Web3, factory_contract) -> Optional[tuple]:
    """Return (index, name, description) of the next un-promoted proposal, or None.

    NOTE: this stub treats "next proposal" as "the most-recently created candidate
    that doesn't show up as official yet". A real implementation watches
    OfficialProposalPromotedAndMigrated events on the orchestrator to track which
    indices have been promoted.

    For now, returns None until the operator wires up a candidate-watcher
    (out of scope for this scaffold).
    """
    _ = factory_contract.functions.marketsCount().call()
    return None


def main():
    cfg = load_config()
    web3 = Web3(HTTPProvider(cfg['rpc_url']))
    if not web3.is_connected():
        print(f"RPC {cfg['rpc_url']} not reachable", file=sys.stderr)
        sys.exit(2)

    operator = Account.from_key(cfg['private_key'])
    flashbot(web3, operator, cfg['flashbots_relay'])

    orch = web3.eth.contract(address=cfg['orchestrator'], abi=ORCH_ABI)
    factory = web3.eth.contract(address=cfg['factory'], abi=FACTORY_ABI)

    print(f"[daemon] connected to {cfg['rpc_url']} chainId={web3.eth.chain_id}")
    print(f"[daemon] operator={operator.address} TIP={cfg['tip_wei']} wei")
    print(f"[daemon] orchestrator={cfg['orchestrator']} factory={cfg['factory']}")

    while True:
        try:
            cand = needs_promotion(web3, factory)
            if cand is None:
                time.sleep(cfg['poll_interval'])
                continue

            idx, name, desc = cand
            block = web3.eth.block_number
            print(f"[daemon] block={block} promoting candidate #{idx}: {name!r}")

            nonce = web3.eth.get_transaction_count(operator.address)
            base = web3.eth.fee_history(1, 'latest')['baseFeePerGas'][-1]
            priority = web3.to_wei(2, 'gwei')
            max_fee = int(base * 2 + priority)

            tx = build_promote_tx(web3, orch, name, desc, cfg['tip_wei'],
                                  operator.address, nonce, max_fee, priority)
            signed = operator.sign_transaction(tx)
            bundle = [{'signed_transaction': signed.rawTransaction}]

            response, status = submit_bundle(web3, bundle, block + 1)
            print(f"[daemon] block={block + 1} status={status} response={response}")

            time.sleep(cfg['poll_interval'])
        except KeyboardInterrupt:
            print("[daemon] interrupted, exiting")
            break
        except Exception as e:
            print(f"[daemon] error: {e}", file=sys.stderr)
            time.sleep(cfg['poll_interval'])


if __name__ == '__main__':
    main()
