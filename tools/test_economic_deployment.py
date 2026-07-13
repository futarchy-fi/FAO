from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import economic_deployment


def address(index: int) -> str:
    return f"0x{index:040x}"


# `cast calldata 'deployFlm(((address,bytes32)),bytes[])' ... '[0x01,...,0x05]'`.
CAST_DEPLOY_FLM_VECTOR = bytes.fromhex(
    "88b5e7840000000000000000000000001111111111111111111111111111111111111111"
    "2222222222222222222222222222222222222222222222222222222222222222"
    "0000000000000000000000000000000000000000000000000000000000000060"
    "0000000000000000000000000000000000000000000000000000000000000005"
    "00000000000000000000000000000000000000000000000000000000000000a0"
    "00000000000000000000000000000000000000000000000000000000000000e0"
    "0000000000000000000000000000000000000000000000000000000000000120"
    "0000000000000000000000000000000000000000000000000000000000000160"
    "00000000000000000000000000000000000000000000000000000000000001a0"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0100000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0200000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0300000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0400000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0500000000000000000000000000000000000000000000000000000000000000"
)


class FixtureHash:
    def __init__(self) -> None:
        self.overrides: dict[bytes, str] = {}

    def __call__(self, value: bytes) -> str:
        return self.overrides.get(value, "0x" + hashlib.sha256(value).hexdigest())


class FakeClient:
    def __init__(self) -> None:
        self.chain = economic_deployment.CHAIN_ID
        self.codes: dict[str, bytes] = {}
        self.calls: dict[tuple[str, ...], str] = {}
        self.transactions: dict[str, dict] = {}
        self.receipts: dict[str, dict] = {}
        self.finalized = 100
        self.finalized_calls = 0
        self.log_queries: list[tuple[str, int, int]] = []

    def chain_id(self) -> int:
        return self.chain

    def code(self, target: str) -> bytes:
        return self.codes.get(target, b"")

    def call(self, target: str, signature: str, *args: str) -> str:
        key = (target, signature, *args)
        try:
            return self.calls[key]
        except KeyError as exc:
            raise AssertionError(f"unexpected call: {key}") from exc

    def transaction(self, tx_hash: str) -> dict:
        return self.transactions[tx_hash]

    def receipt(self, tx_hash: str) -> dict:
        return self.receipts[tx_hash]

    def logs(
        self,
        emitter: str,
        topics: list[str | None],
        from_block: int,
        to_block: int,
    ) -> list[dict]:
        self.log_queries.append((emitter, from_block, to_block))
        matches = []
        for receipt in self.receipts.values():
            for log in receipt.get("logs", []):
                if (
                    log["address"] != emitter
                    or int(log["blockNumber"], 0) < from_block
                    or int(log["blockNumber"], 0) > to_block
                ):
                    continue
                if all(
                    expected is None
                    or index < len(log["topics"])
                    and log["topics"][index] == expected
                    for index, expected in enumerate(topics)
                ):
                    matches.append(copy.deepcopy(log))
        return matches

    def finalized_block(self) -> int:
        self.finalized_calls += 1
        return self.finalized


class EconomicDeploymentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.hash = FixtureHash()
        self.client = FakeClient()
        self.core_hashes, self.flm_hashes, self.creation_evidence = (
            economic_deployment._canonical_blob_hashes()
        )
        self.creation = b"\x60" * int(self.creation_evidence["receipt"]["bytes"])
        self.creation_hash = str(self.creation_evidence["receipt"]["hash"])
        self.hash.overrides[self.creation] = self.creation_hash
        self.registrar_creation = b"\x61" * int(
            self.creation_evidence["registrar"]["bytes"]
        )
        self.hash.overrides[self.registrar_creation] = str(
            self.creation_evidence["registrar"]["hash"]
        )
        self.core_codes = tuple(f"core-{key}".encode() for key in economic_deployment.CORE_BLOBS)
        self.flm_codes = tuple(f"flm-{key}".encode() for key in economic_deployment.FLM_BLOBS)
        for code, key in zip(self.core_codes, economic_deployment.CORE_BLOBS):
            self.hash.overrides[code] = self.core_hashes[key]
        for code, key in zip(self.flm_codes, economic_deployment.FLM_BLOBS):
            self.hash.overrides[code] = self.flm_hashes[key]

        self.deployer = address(0xAAA)
        self.prerequisite_nonces = {"proposalImplementation": 183, "stackDeployer": 184}
        self.receipt_nonce = 185
        self.receipt = economic_deployment._create_address(
            self.deployer, self.receipt_nonce, self.hash
        )
        self.prerequisite_creation = {
            key: bytes([index]) * int(self.creation_evidence[key]["bytes"])
            for index, key in enumerate(economic_deployment.PREREQUISITES, start=1)
        }
        for key, code in self.prerequisite_creation.items():
            self.hash.overrides[code] = str(self.creation_evidence[key]["hash"])
        self.prerequisite_runtime = {
            "proposalImplementation": b"proposal-runtime",
            "stackDeployer": b"stack-runtime",
        }

        self.dependencies = self._dependencies()
        self.core_config = {
            **{key: self.dependencies[key] for key in economic_deployment.CORE_DEPENDENCY_KEYS},
            "graduationThreshold": 100,
            "arbitrationTimeout": 3600,
            "siteMinActivationBond": 10,
            "treasuryMinActivationBond": 20,
            "assetPolicies": [
                {
                    "asset": economic_deployment.ZERO,
                    "c1": 1,
                    "c2": 2,
                    "tapBudget": 3,
                    "tapBudgetMax": 4,
                },
                {
                    "asset": self.dependencies["weth"]["target"],
                    "c1": 5,
                    "c2": 6,
                    "tapBudget": 7,
                    "tapBudgetMax": 8,
                },
            ],
            "twapTimeout": 1800,
            "twapWindow": 900,
            "spaceSaltNonce": 7,
            "daoURI": "ipfs://bafkreiaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "metadataURI": "ipfs://bafkreibbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "votingStrategyMetadataURI": "ipfs://bafkreicccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "proposalValidationStrategyMetadataURI": "ipfs://bafkreidddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "tokenName": "Futarchy Autonomous Organization",
            "tokenSymbol": "FAO",
            "saleEnd": 2_000_000_000,
            "bootstrapDeadline": 2_000_086_400,
            "saleCap": 1_000_000,
            "minimumRaise": 1_000,
            "tokenMaxSupply": 3_000_000,
            "initialPrice": 10**16,
            "slope": 10**12,
            "bootstrapBps": 5000,
        }
        self.grants = [
            {"beneficiary": address(0x301), "start": 1, "duration": 100, "amount": 10},
            {"beneficiary": address(0x302), "start": 2, "duration": 200, "amount": 20},
        ]
        self.flm_config = {"positionManager": self.dependencies["positionManager"]}
        self.core_config_hash = economic_deployment._digest(
            economic_deployment._encode_core_commitment(self.core_config, self.grants), self.hash
        )
        self.flm_config_hash = economic_deployment._digest(
            economic_deployment._encode_flm_config(self.flm_config), self.hash
        )
        derived = {
            name: economic_deployment._create_address(self.receipt, nonce, self.hash)
            for name, nonce in (
                *economic_deployment.CORE_CHILDREN,
                *economic_deployment.FLM_CHILDREN,
            )
        }
        treasury_executor = economic_deployment._create_address(
            derived["vault"], 1, self.hash
        )
        wallets = [
            economic_deployment._create_address(derived["vault"], nonce, self.hash)
            for nonce in (2, 3)
        ]
        company_token = economic_deployment._create_address(derived["vault"], 4, self.hash)
        spot_pool = economic_deployment._pool_address(
            self.dependencies["uniswapV3Factory"]["target"],
            company_token,
            self.dependencies["weth"]["target"],
            self.hash,
        )
        self.contracts = {
            "space": address(0x201),
            "arbitration": derived["arbitration"],
            "vault": derived["vault"],
            "treasuryExecutor": treasury_executor,
            "companyToken": company_token,
            "proposalGateway": derived["proposalGateway"],
            "releaseStrategy": derived["releaseStrategy"],
            "votingStrategy": derived["votingStrategy"],
            "evaluator": derived["evaluator"],
            "orchestrator": address(0x202),
            "resolver": address(0x203),
            "futarchyFactory": address(0x204),
            "spotPool": spot_pool,
            "relay": derived["relay"],
            "spotAdapter": derived["spotAdapter"],
            "conditionalAdapter": derived["conditionalAdapter"],
            "guard": derived["guard"],
            "router": derived["router"],
            "manager": derived["manager"],
            "vestingWallets": wallets,
        }
        self.executor_runtime = economic_deployment._executor_runtime_code(derived["vault"])
        self.executor_runtime_hash = economic_deployment._digest(
            self.executor_runtime, self.hash
        )
        self.manifest = self._manifest()
        self._chain_evidence(live=False)

    def _dependencies(self) -> dict[str, dict[str, str]]:
        pinned_targets = {
            **{key: value for key, value in economic_deployment.SX_PINS.items()},
            "weth": (economic_deployment.flm_deployment.WETH, "weth"),
            "conditionalTokens": (
                economic_deployment.flm_deployment.CTF,
                "conditionalTokens",
            ),
            "wrapped1155Factory": (
                economic_deployment.flm_deployment.WRAPPED_1155_FACTORY,
                "wrapped1155Factory",
            ),
            "uniswapV3Factory": (
                economic_deployment.flm_deployment.UNIV3_FACTORY,
                "univ3Factory",
            ),
            "positionManager": (
                economic_deployment.flm_deployment.POSITION_MANAGER,
                "positionManager",
            ),
        }
        dependencies = {}
        for index, key in enumerate(economic_deployment.DEPENDENCY_KEYS, start=1):
            pinned = pinned_targets.get(key)
            if key in self.prerequisite_nonces:
                target = economic_deployment._create_address(
                    self.deployer, self.prerequisite_nonces[key], self.hash
                )
                code = self.prerequisite_runtime[key]
                code_hash = economic_deployment._digest(code, self.hash)
            else:
                target = pinned[0]
                code_hash = (
                    pinned[1]
                    if key in economic_deployment.SX_PINS
                    else economic_deployment.flm_deployment.PINNED_CODEHASHES[pinned[1]]
                )
                code = f"dependency-{key}".encode()
                self.hash.overrides[code] = code_hash
            self.client.codes[target] = code
            dependencies[key] = {
                "target": target,
                "runtimeCodeKeccak256": code_hash,
            }
        return dependencies

    def _manifest(self) -> dict:
        transactions = {
            "receiptCreate": {
                "hash": "0x" + "a1" * 32,
                "block": 10,
                "nonce": self.receipt_nonce,
                "from": self.deployer,
            },
            "deployCore": {
                "hash": "0x" + "a2" * 32,
                "block": 11,
                "nonce": 186,
                "from": self.deployer,
            },
            "deployFlm": {
                "hash": "0x" + "a3" * 32,
                "block": 12,
                "nonce": 187,
                "from": self.deployer,
            },
        }
        return {
            "schemaVersion": 3,
            "creationRoute": "create",
            "status": "sealed",
            "network": "sepolia",
            "chainId": economic_deployment.CHAIN_ID,
            "transactions": transactions,
            "receipt": {
                "address": self.receipt,
                "source": economic_deployment.RECEIPT_SOURCE,
                "contract": economic_deployment.RECEIPT_CONTRACT,
                "createNonce": self.receipt_nonce,
                "creationCodeBytes": len(self.creation),
                "creationCodeKeccak256": self.creation_hash,
                "coreConfigHash": self.core_config_hash,
                "flmConfigHash": self.flm_config_hash,
            },
            "prerequisites": {
                key: {
                    "address": self.dependencies[key]["target"],
                    "source": economic_deployment.PREREQUISITES[key][0],
                    "contract": economic_deployment.PREREQUISITES[key][1],
                    "transaction": {
                        "hash": "0x" + ("81" if key == "proposalImplementation" else "82") * 32,
                        "block": 8 if key == "proposalImplementation" else 9,
                        "nonce": self.prerequisite_nonces[key],
                        "from": self.deployer,
                    },
                    "creationCodeBytes": len(self.prerequisite_creation[key]),
                    "creationCodeKeccak256": economic_deployment._digest(
                        self.prerequisite_creation[key], self.hash
                    ),
                    "runtimeCodeBytes": len(self.prerequisite_runtime[key]),
                    "runtimeCodeKeccak256": self.dependencies[key]["runtimeCodeKeccak256"],
                }
                for key in economic_deployment.PREREQUISITES
            },
            "coreConfig": self.core_config,
            "grants": self.grants,
            "flmConfig": self.flm_config,
            "feeTier": economic_deployment.FEE_TIER,
            "poolInitCodeHash": economic_deployment.POOL_INIT_CODE_HASH,
            "observationCardinality": economic_deployment.OBSERVATION_CARDINALITY,
            "contracts": self.contracts,
            "codeBlobs": {"core": self.core_hashes, "flm": self.flm_hashes},
            "runtimeCodeHashes": {
                "treasuryExecutor": self.executor_runtime_hash,
            },
            "finalization": None,
        }

    def _record_transaction(
        self, name: str, target: str | None, input_: bytes, contract: str | None = None
    ) -> None:
        if name in self.manifest["transactions"]:
            value = self.manifest["transactions"][name]
        elif name in self.manifest["prerequisites"]:
            value = self.manifest["prerequisites"][name]["transaction"]
        else:
            value = self.manifest[name]
        tx_hash = value["hash"]
        self.client.transactions[tx_hash] = {
            "hash": tx_hash,
            "blockNumber": value["block"],
            "nonce": value["nonce"],
            "from": value["from"],
            "to": target,
            "input": "0x" + input_.hex(),
        }
        block_hash = "0x" + f"{value['block']:064x}"
        self.client.receipts[tx_hash] = {
            "transactionHash": tx_hash,
            "blockNumber": value["block"],
            "blockHash": block_hash,
            "from": value["from"],
            "to": target,
            "status": 1,
            "contractAddress": contract,
            "logs": [],
        }

    def _put(self, target: str, signature: str, value: object, *args: str) -> None:
        self.client.calls[(target, signature, *args)] = str(value).lower() if isinstance(value, bool) else str(value)

    def _chain_evidence(self, *, live: bool) -> None:
        for key, (_, _, constructor_args) in economic_deployment.PREREQUISITES.items():
            self._record_transaction(
                key,
                None,
                self.prerequisite_creation[key] + constructor_args,
                self.dependencies[key]["target"],
            )
        self._record_transaction(
            "receiptCreate",
            None,
            self.creation
            + bytes.fromhex(self.core_config_hash[2:] + self.flm_config_hash[2:]),
            self.receipt,
        )
        self._record_transaction(
            "deployCore",
            self.receipt,
            economic_deployment._encode_deploy_core(
                self.core_config, self.grants, self.core_codes
            ),
        )
        self._record_transaction(
            "deployFlm",
            self.receipt,
            economic_deployment._encode_deploy_flm(self.flm_config, self.flm_codes),
        )
        if live:
            self._record_transaction(
                "finalization",
                self.contracts["vault"],
                bytes.fromhex(economic_deployment.FINALIZE_SELECTOR),
            )

        self.client.codes[self.receipt] = b"receipt-runtime"
        for key, target in self.contracts.items():
            if key != "spotPool":
                if isinstance(target, list):
                    for wallet in target:
                        self.client.codes[wallet] = b"vesting-runtime"
                else:
                    self.client.codes[target] = f"runtime-{key}".encode()
        self.client.codes[self.contracts["treasuryExecutor"]] = self.executor_runtime
        if live:
            self.client.codes[self.contracts["spotPool"]] = b"pool-runtime"

        c, d = self.contracts, {key: value["target"] for key, value in self.dependencies.items()}
        self._put(self.receipt, "coreSealed()(bool)", True)
        self._put(self.receipt, "flmSealed()(bool)", True)
        self._put(self.receipt, "CORE_CONFIG_HASH()(bytes32)", self.core_config_hash)
        self._put(self.receipt, "FLM_CONFIG_HASH()(bytes32)", self.flm_config_hash)
        self._put(
            self.receipt,
            "uniswapV3FactoryCodehash()(bytes32)",
            self.dependencies["uniswapV3Factory"]["runtimeCodeKeccak256"],
        )
        receipt_addresses = {
            "space": c["space"],
            "arbitration": c["arbitration"],
            "vault": c["vault"],
            "companyToken": c["companyToken"],
            "proposalGateway": c["proposalGateway"],
            "releaseStrategy": c["releaseStrategy"],
            "votingStrategy": c["votingStrategy"],
            "evaluator": c["evaluator"],
            "orchestrator": c["orchestrator"],
            "resolver": c["resolver"],
            "futarchyFactory": c["futarchyFactory"],
            "weth": d["weth"],
            "conditionalTokens": d["conditionalTokens"],
            "wrapped1155Factory": d["wrapped1155Factory"],
            "uniswapV3Factory": d["uniswapV3Factory"],
            "spotPool": c["spotPool"],
            "relay": c["relay"],
            "spotAdapter": c["spotAdapter"],
            "conditionalAdapter": c["conditionalAdapter"],
            "guard": c["guard"],
            "router": c["router"],
            "manager": c["manager"],
        }
        for name, expected in receipt_addresses.items():
            self._put(self.receipt, f"{name}()(address)", expected)

        address_calls = (
            (c["space"], "owner()(address)", economic_deployment.ZERO),
            (c["arbitration"], "owner()(address)", economic_deployment.ZERO),
            (c["arbitration"], "pendingOwner()(address)", economic_deployment.ZERO),
            (c["arbitration"], "proposalGateway()(address)", c["proposalGateway"]),
            (c["arbitration"], "evaluator()(address)", c["evaluator"]),
            (c["companyToken"], "vault()(address)", c["vault"]),
            (c["vault"], "WETH()(address)", d["weth"]),
            (c["vault"], "COMPANY_TOKEN()(address)", c["companyToken"]),
            (c["vault"], "ASSEMBLER()(address)", self.receipt),
            (c["vault"], "ARBITRATION()(address)", c["arbitration"]),
            (c["vault"], "BOOTSTRAP_HOOK()(address)", self.receipt),
            (c["vault"], "TREASURY_EXECUTOR()(address)", c["treasuryExecutor"]),
            (c["vault"], "manager()(address)", c["manager"]),
            (c["treasuryExecutor"], "VAULT()(address)", c["vault"]),
            (c["proposalGateway"], "space()(address)", c["space"]),
            (c["proposalGateway"], "executionStrategy()(address)", c["releaseStrategy"]),
            (c["proposalGateway"], "arbitration()(address)", c["arbitration"]),
            (c["proposalGateway"], "vault()(address)", c["vault"]),
            (c["releaseStrategy"], "space()(address)", c["space"]),
            (c["releaseStrategy"], "arbitration()(address)", c["arbitration"]),
            (c["evaluator"], "arbitrationContract()(address)", c["arbitration"]),
            (c["evaluator"], "vault()(address)", c["vault"]),
            (c["evaluator"], "orchestrator()(address)", c["orchestrator"]),
            (c["evaluator"], "resolver()(address)", c["resolver"]),
            (c["evaluator"], "conditionalTokens()(address)", d["conditionalTokens"]),
            (c["resolver"], "CTF()(address)", d["conditionalTokens"]),
            (c["resolver"], "orchestrator()(address)", c["orchestrator"]),
            (c["futarchyFactory"], "conditionalTokens()(address)", d["conditionalTokens"]),
            (c["futarchyFactory"], "wrapped1155Factory()(address)", d["wrapped1155Factory"]),
            (c["futarchyFactory"], "oracle()(address)", c["resolver"]),
            (c["futarchyFactory"], "proposalImpl()(address)", d["proposalImplementation"]),
            (c["orchestrator"], "ADMIN()(address)", c["evaluator"]),
            (c["orchestrator"], "FACTORY()(address)", c["futarchyFactory"]),
            (c["orchestrator"], "UNIV3_FACTORY()(address)", d["uniswapV3Factory"]),
            (c["orchestrator"], "SPOT_POOL()(address)", c["spotPool"]),
            (c["orchestrator"], "COMPANY_TOKEN()(address)", c["companyToken"]),
            (c["orchestrator"], "CURRENCY_TOKEN()(address)", d["weth"]),
            (c["orchestrator"], "RESOLVER()(address)", c["resolver"]),
            (c["relay"], "MANAGER()(address)", c["manager"]),
            (c["relay"], "ARBITRATION()(address)", c["arbitration"]),
            (c["relay"], "PIPELINE()(address)", c["evaluator"]),
            (c["relay"], "UNIV3_FACTORY()(address)", d["uniswapV3Factory"]),
            (c["relay"], "CTF()(address)", d["conditionalTokens"]),
            (c["relay"], "COMPANY_TOKEN()(address)", c["companyToken"]),
            (c["relay"], "CURRENCY_TOKEN()(address)", d["weth"]),
            (c["spotAdapter"], "MANAGER()(address)", c["manager"]),
            (c["conditionalAdapter"], "MANAGER()(address)", c["manager"]),
            (c["spotAdapter"], "POSITION_MANAGER()(address)", d["positionManager"]),
            (c["conditionalAdapter"], "POSITION_MANAGER()(address)", d["positionManager"]),
            (c["guard"], "FACTORY()(address)", d["uniswapV3Factory"]),
            (c["router"], "CONDITIONAL_TOKENS()(address)", d["conditionalTokens"]),
            (c["router"], "WRAPPED_1155_FACTORY()(address)", d["wrapped1155Factory"]),
            (c["manager"], "owner()(address)", economic_deployment.DEAD),
            (c["manager"], "pendingOwner()(address)", economic_deployment.ZERO),
            (c["manager"], "BOOTSTRAP_RECIPIENT()(address)", c["vault"]),
            (c["manager"], "OFFICIAL_PROPOSER()(address)", c["relay"]),
            (c["manager"], "PROPOSAL_SOURCE()(address)", c["relay"]),
            (c["manager"], "SPOT_ADAPTER()(address)", c["spotAdapter"]),
            (c["manager"], "CONDITIONAL_ADAPTER()(address)", c["conditionalAdapter"]),
            (c["manager"], "CONDITIONAL_ROUTER()(address)", c["router"]),
            (c["manager"], "POOL_STABILITY_GUARD()(address)", c["guard"]),
            (c["manager"], "COMPANY_TOKEN()(address)", c["companyToken"]),
            (c["manager"], "WRAPPED_NATIVE()(address)", d["weth"]),
        )
        for target, signature, expected in address_calls:
            self._put(target, signature, expected)

        salt = economic_deployment._digest(
            bytes.fromhex(self.receipt[2:])
            + self.core_config["spaceSaltNonce"].to_bytes(32, "big"),
            self.hash,
        )
        self._put(
            d["proxyFactory"],
            "predictProxyAddress(address,bytes32)(address)",
            c["space"],
            d["spaceImplementation"],
            salt,
        )
        self._put(c["space"], "votingStrategies(uint8)(address,bytes)", c["votingStrategy"], "0")
        self._put(
            c["space"],
            "proposalValidationStrategy()(address,bytes)",
            d["proposalValidationStrategy"],
        )
        self._put(
            c["space"], "authenticators(address)(uint256)", 1, c["proposalGateway"]
        )
        self._put(c["space"], "activeVotingStrategies()(uint256)", 1)
        self._put(
            c["votingStrategy"],
            "getVotingPower(uint32,address,bytes,bytes)(uint256)",
            0,
            "0",
            economic_deployment.DEAD,
            "0x",
            "0x",
        )
        self._put(c["vault"], "grantCount()(uint256)", len(c["vestingWallets"]))
        for index, wallet in enumerate(c["vestingWallets"]):
            self._put(
                c["vault"],
                "grants(uint256)(address,uint64,uint64,uint256)",
                wallet,
                str(index),
            )

        int_calls = (
            (self.receipt, "FEE_TIER()(uint24)", economic_deployment.FEE_TIER),
            (
                self.receipt,
                "OBSERVATION_CARDINALITY()(uint16)",
                economic_deployment.OBSERVATION_CARDINALITY,
            ),
            (c["orchestrator"], "FEE_TIER()(uint24)", economic_deployment.FEE_TIER),
            (
                c["orchestrator"],
                "OBSERVATION_CARDINALITY()(uint16)",
                economic_deployment.OBSERVATION_CARDINALITY,
            ),
            (c["relay"], "FEE_TIER()(uint24)", economic_deployment.FEE_TIER),
            (c["guard"], "FEE()(uint24)", economic_deployment.FEE_TIER),
            (
                c["spotAdapter"],
                "DEFAULT_TICK_LOWER()(int24)",
                economic_deployment.flm_deployment.TICK_LOWER,
            ),
            (
                c["spotAdapter"],
                "DEFAULT_TICK_UPPER()(int24)",
                economic_deployment.flm_deployment.TICK_UPPER,
            ),
            (
                c["conditionalAdapter"],
                "DEFAULT_TICK_LOWER()(int24)",
                economic_deployment.flm_deployment.TICK_LOWER,
            ),
            (
                c["conditionalAdapter"],
                "DEFAULT_TICK_UPPER()(int24)",
                economic_deployment.flm_deployment.TICK_UPPER,
            ),
        )
        for target, signature, expected in int_calls:
            self._put(target, signature, expected)
        self._put(c["orchestrator"], "ADAPTER_REPLACEABLE()(bool)", False)
        self._put(d["stackDeployer"], "ADAPTER_REPLACEABLE()(bool)", False)
        core_getters = {
            "ARBITRATION": "ARBITRATION_CODE_HASH()(bytes32)",
            "VAULT": "VAULT_CODE_HASH()(bytes32)",
            "RELEASE_STRATEGY": "RELEASE_STRATEGY_CODE_HASH()(bytes32)",
            "ZERO_VOTING": "ZERO_VOTING_CODE_HASH()(bytes32)",
            "ECON_GATEWAY": "ECON_GATEWAY_CODE_HASH()(bytes32)",
            "ECON_EVALUATOR": "ECON_EVALUATOR_CODE_HASH()(bytes32)",
        }
        for key, signature in core_getters.items():
            self._put(self.receipt, signature, self.core_hashes[key])

        self._put(c["manager"], "initializedFromBootstrap()(bool)", live)
        if live:
            self._put(c["vault"], "phase()(uint8)", 2)
            self._put(c["companyToken"], "mintingFinished()(bool)", True)
            self._put(
                d["uniswapV3Factory"],
                "getPool(address,address,uint24)(address)",
                c["spotPool"],
                c["companyToken"],
                d["weth"],
                str(economic_deployment.FEE_TIER),
            )
            token0, token1 = sorted((c["companyToken"], d["weth"]))
            self._put(c["spotPool"], "token0()(address)", token0)
            self._put(c["spotPool"], "token1()(address)", token1)
            self._put(c["spotPool"], "fee()(uint24)", economic_deployment.FEE_TIER)
        else:
            self._put(c["manager"], "totalSupply()(uint256)", 0)

    def _broadcast(self) -> dict:
        staged = (
            ("proposalImplementation", "CREATE", "FAOFutarchyProposal"),
            ("stackDeployer", "CREATE", "FAOSiteStackDeployer"),
            ("receiptCreate", "CREATE", economic_deployment.RECEIPT_CONTRACT),
            ("deployCore", "CALL", economic_deployment.RECEIPT_CONTRACT),
            ("deployFlm", "CALL", economic_deployment.RECEIPT_CONTRACT),
        )
        transactions = []
        receipts = []
        for key, kind, contract_name in staged:
            if key in self.manifest["prerequisites"]:
                evidence = self.manifest["prerequisites"][key]["transaction"]
            else:
                evidence = self.manifest["transactions"][key]
            tx = copy.deepcopy(self.client.transactions[evidence["hash"]])
            receipt = copy.deepcopy(self.client.receipts[evidence["hash"]])
            transactions.append(
                {
                    "hash": evidence["hash"],
                    "transactionType": kind,
                    "contractName": contract_name,
                    "contractAddress": receipt["contractAddress"]
                    if kind == "CREATE"
                    else tx["to"],
                    "transaction": tx,
                }
            )
            receipts.append(receipt)
        return {
            "chain": economic_deployment.CHAIN_ID,
            "pending": [],
            "transactions": transactions,
            "receipts": receipts,
        }

    def _operation_broadcast(self) -> dict:
        evidence = self.manifest["finalization"]
        tx = copy.deepcopy(self.client.transactions[evidence["hash"]])
        return {
            "chain": economic_deployment.CHAIN_ID,
            "pending": [],
            "transactions": [
                {
                    "hash": evidence["hash"],
                    "transactionType": "CALL",
                    "contractName": None,
                    "contractAddress": tx["to"],
                    "transaction": tx,
                }
            ],
            "receipts": [copy.deepcopy(self.client.receipts[evidence["hash"]])],
        }

    def _event_log(
        self,
        name: str,
        emitter: str,
        topics: list[str],
        data: bytes,
    ) -> dict:
        evidence = self.manifest["transactions"].get(name, self.manifest.get(name))
        log = {
            "address": emitter,
            "topics": topics,
            "data": "0x" + data.hex(),
            "transactionHash": evidence["hash"],
            "blockNumber": hex(evidence["block"]),
            "blockHash": self.client.receipts[evidence["hash"]]["blockHash"],
            "removed": False,
        }
        self.client.receipts[evidence["hash"]]["logs"].append(copy.deepcopy(log))
        return log

    def _registrar_evidence(self) -> tuple[dict, dict, str]:
        registrar_tx = {
            "hash": "0x" + "70" * 32,
            "block": 7,
            "nonce": 182,
            "from": self.deployer,
        }
        registrar = economic_deployment._create_address(
            self.deployer, registrar_tx["nonce"], self.hash
        )
        commitments = bytes.fromhex(self.core_config_hash[2:] + self.flm_config_hash[2:])
        salt = bytes.fromhex(economic_deployment._digest(commitments, self.hash)[2:])
        initcode_hash = bytes.fromhex(
            economic_deployment._digest(self.creation + commitments, self.hash)[2:]
        )
        create2_payload = (
            b"\xff" + bytes.fromhex(registrar[2:]) + salt + initcode_hash
        )
        self.hash.overrides[create2_payload] = "0x" + "00" * 12 + self.receipt[2:]
        self.assertEqual(
            economic_deployment._create2_address(
                registrar,
                self.core_config_hash,
                self.flm_config_hash,
                self.creation,
                self.hash,
            ),
            self.receipt,
        )

        registrar_code = b"registrar-runtime"
        registrar_hash = economic_deployment._digest(registrar_code, self.hash)
        self.client.codes[registrar] = registrar_code
        registrar_input = self.registrar_creation + bytes.fromhex(self.creation_hash[2:])
        self.client.transactions[registrar_tx["hash"]] = {
            "hash": registrar_tx["hash"],
            "blockNumber": registrar_tx["block"],
            "nonce": registrar_tx["nonce"],
            "from": registrar_tx["from"],
            "to": None,
            "input": "0x" + registrar_input.hex(),
        }
        self.client.receipts[registrar_tx["hash"]] = {
            "transactionHash": registrar_tx["hash"],
            "blockNumber": registrar_tx["block"],
            "blockHash": "0x" + f"{registrar_tx['block']:064x}",
            "from": registrar_tx["from"],
            "to": None,
            "status": 1,
            "contractAddress": registrar,
            "logs": [],
        }
        self._put(
            registrar,
            "RECEIPT_CREATION_CODE_HASH()(bytes32)",
            self.creation_hash,
        )
        stage = self.manifest["transactions"]["receiptCreate"]
        self.client.transactions[stage["hash"]]["to"] = registrar
        self.client.transactions[stage["hash"]]["input"] = "0x" + economic_deployment._encode_stage(
            self.core_config_hash,
            self.flm_config_hash,
            self.creation,
            self.hash,
        ).hex()
        self.client.receipts[stage["hash"]]["to"] = registrar
        self.client.receipts[stage["hash"]]["contractAddress"] = None

        self._event_log(
            "receiptCreate",
            registrar,
            [
                economic_deployment._event_topic(
                    economic_deployment.GENESIS_STAGED_EVENT, self.hash
                ),
                "0x" + economic_deployment._address_word(self.receipt).hex(),
                self.core_config_hash,
                self.flm_config_hash,
            ],
            economic_deployment._address_word(self.deployer),
        )
        self._event_log(
            "deployCore",
            self.receipt,
            [
                economic_deployment._event_topic(
                    economic_deployment.CORE_SEALED_EVENT, self.hash
                ),
                "0x" + economic_deployment._address_word(self.contracts["vault"]).hex(),
                "0x"
                + economic_deployment._address_word(self.contracts["companyToken"]).hex(),
                "0x" + economic_deployment._address_word(self.contracts["space"]).hex(),
            ],
            b"".join(
                economic_deployment._address_word(self.contracts[key])
                for key in ("arbitration", "evaluator", "spotPool")
            ),
        )
        self._event_log(
            "deployFlm",
            self.receipt,
            [
                economic_deployment._event_topic(
                    economic_deployment.FLM_SEALED_EVENT, self.hash
                ),
                "0x" + economic_deployment._address_word(self.contracts["manager"]).hex(),
            ],
            b"".join(
                economic_deployment._address_word(self.contracts[key])
                for key in ("relay", "spotAdapter")
            ),
        )
        expected = copy.deepcopy(self.manifest)
        expected["creationRoute"] = "registrar"
        expected["receipt"]["stageNonce"] = expected["receipt"].pop("createNonce")
        expected["receipt"]["registrar"] = {
            "target": registrar,
            "runtimeCodeKeccak256": registrar_hash,
        }
        shared = {
            "schemaVersion": 1,
            "network": "sepolia",
            "chainId": economic_deployment.CHAIN_ID,
            "registrar": {
                "address": registrar,
                "source": economic_deployment.REGISTRAR_SOURCE,
                "contract": economic_deployment.REGISTRAR_CONTRACT,
                "transaction": registrar_tx,
                "creationCodeBytes": len(self.registrar_creation),
                "creationCodeKeccak256": economic_deployment._digest(
                    self.registrar_creation, self.hash
                ),
                "runtimeCodeBytes": len(registrar_code),
                "runtimeCodeKeccak256": registrar_hash,
            },
            "prerequisites": copy.deepcopy(self.manifest["prerequisites"]),
        }
        return shared, expected, registrar

    def _verify(self) -> None:
        economic_deployment.verify_rpc(
            self.manifest,
            self.creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )

    def test_sealed_manifest_verifies_staged_deployment(self) -> None:
        self._verify()

    def test_executor_address_immutable_and_runtime_hash_are_all_verified(self) -> None:
        self.assertNotEqual(
            self.executor_runtime,
            economic_deployment._executor_runtime_code(address(0xBAD)),
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime_path = root / economic_deployment.economic_code_hashes.EXECUTOR_RUNTIME_PATH
            manifest_path = root / economic_deployment.economic_code_hashes.MANIFEST_PATH
            runtime_path.parent.mkdir(parents=True)
            runtime_bytes = (
                economic_deployment.ROOT
                / economic_deployment.economic_code_hashes.EXECUTOR_RUNTIME_PATH
            ).read_bytes()
            manifest_bytes = (
                economic_deployment.ROOT / economic_deployment.economic_code_hashes.MANIFEST_PATH
            ).read_bytes()
            runtime_path.write_bytes(runtime_bytes)
            manifest_path.write_bytes(manifest_bytes)

            with mock.patch.object(economic_deployment, "ROOT", root):
                self.assertEqual(
                    economic_deployment._executor_runtime_code(self.contracts["vault"]),
                    self.executor_runtime,
                )

                runtime_path.unlink()
                with self.assertRaisesRegex(
                    economic_deployment.ManifestError, "cannot read.*runtime evidence"
                ):
                    economic_deployment._executor_runtime_code(self.contracts["vault"])

                runtime_path.write_bytes(runtime_bytes)
                evidence = json.loads(runtime_bytes)
                evidence["deployedRuntime"]["template"] = (
                    "0x00" + evidence["deployedRuntime"]["template"][4:]
                )
                runtime_path.write_text(json.dumps(evidence), encoding="utf-8")
                with self.assertRaisesRegex(
                    economic_deployment.ManifestError, "template hash mismatch"
                ):
                    economic_deployment._executor_runtime_code(self.contracts["vault"])

                evidence = json.loads(runtime_bytes)
                evidence["deployedRuntime"]["immutableReferences"][0]["length"] = 31
                runtime_path.write_text(json.dumps(evidence), encoding="utf-8")
                with self.assertRaisesRegex(
                    economic_deployment.ManifestError, "immutable references are malformed"
                ):
                    economic_deployment._executor_runtime_code(self.contracts["vault"])

        broken = copy.deepcopy(self.manifest)
        broken["runtimeCodeHashes"]["treasuryExecutor"] = "0x" + "11" * 32
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "executor runtime code hash mismatch"
        ):
            economic_deployment.verify_rpc(
                broken,
                self.creation,
                self.prerequisite_creation,
                self.client,
                hash_=self.hash,
            )

        self.client.codes[self.contracts["treasuryExecutor"]] = b"wrong-runtime"
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "executor runtime code hash mismatch"
        ):
            self._verify()
        self.client.codes[self.contracts["treasuryExecutor"]] = self.executor_runtime

        self._put(
            self.contracts["vault"],
            "TREASURY_EXECUTOR()(address)",
            address(0xBAD),
        )
        with self.assertRaisesRegex(economic_deployment.ManifestError, "public wiring mismatch"):
            self._verify()
        self._put(
            self.contracts["vault"],
            "TREASURY_EXECUTOR()(address)",
            self.contracts["treasuryExecutor"],
        )

        self._put(
            self.contracts["treasuryExecutor"],
            "VAULT()(address)",
            address(0xBAD),
        )
        with self.assertRaisesRegex(economic_deployment.ManifestError, "public wiring mismatch"):
            self._verify()

    def test_builds_and_verifies_manifest_from_exact_five_transaction_broadcast(self) -> None:
        broadcast = self._broadcast()
        broadcast["transactions"][2]["hash"], broadcast["transactions"][3]["hash"] = (
            broadcast["transactions"][3]["hash"],
            broadcast["transactions"][2]["hash"],
        )
        built = economic_deployment.manifest_from_broadcast(
            broadcast,
            self.creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(built, self.manifest)

    def test_reconstructs_registrar_receipt_from_chain_without_broadcast(self) -> None:
        shared, expected, _ = self._registrar_evidence()
        built = economic_deployment.manifest_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(built, expected)
        self.assertEqual(self.client.finalized_calls, 1)
        self.assertTrue(self.client.log_queries)
        self.assertTrue(
            all(
                start == shared["registrar"]["transaction"]["block"]
                and end == self.client.finalized
                for _, start, end in self.client.log_queries
            )
        )

    def test_discovers_each_resumable_registrar_stage_without_weakening_manifest(self) -> None:
        shared, _, _ = self._registrar_evidence()
        core_hash = self.manifest["transactions"]["deployCore"]["hash"]
        flm_hash = self.manifest["transactions"]["deployFlm"]["hash"]

        self.client.receipts[core_hash]["logs"] = []
        self.client.receipts[flm_hash]["logs"] = []
        stage_only = economic_deployment.discovery_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(stage_only["status"], "stage-only")
        self.assertEqual(stage_only["schemaVersion"], 2)
        self.assertEqual(stage_only["nextAction"], "deployCore")
        self.assertIsNone(stage_only["transactions"]["deployCore"])
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "stage-only state"
        ):
            economic_deployment.manifest_from_chain(
                self.receipt,
                shared,
                self.creation,
                self.registrar_creation,
                self.prerequisite_creation,
                self.client,
                hash_=self.hash,
            )

        self._event_log(
            "deployCore",
            self.receipt,
            [
                economic_deployment._event_topic(
                    economic_deployment.CORE_SEALED_EVENT, self.hash
                ),
                "0x" + economic_deployment._address_word(self.contracts["vault"]).hex(),
                "0x"
                + economic_deployment._address_word(self.contracts["companyToken"]).hex(),
                "0x" + economic_deployment._address_word(self.contracts["space"]).hex(),
            ],
            b"".join(
                economic_deployment._address_word(self.contracts[key])
                for key in ("arbitration", "evaluator", "spotPool")
            ),
        )
        core_only = economic_deployment.discovery_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(core_only["status"], "core-only")
        self.assertEqual(core_only["nextAction"], "deployFlm")

        self._event_log(
            "deployFlm",
            self.receipt,
            [
                economic_deployment._event_topic(
                    economic_deployment.FLM_SEALED_EVENT, self.hash
                ),
                "0x" + economic_deployment._address_word(self.contracts["manager"]).hex(),
            ],
            b"".join(
                economic_deployment._address_word(self.contracts[key])
                for key in ("relay", "spotAdapter")
            ),
        )
        full = economic_deployment.discovery_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(full["status"], "full")
        self.assertEqual(full["nextAction"], "finalize")

    def test_discovery_reports_live_after_receipt_verified_finalization(self) -> None:
        self.manifest["status"] = "live"
        self.manifest["finalization"] = {
            "hash": "0x" + "a4" * 32,
            "block": 20,
            "nonce": 188,
            "from": self.deployer,
        }
        self._chain_evidence(live=True)
        shared, _, _ = self._registrar_evidence()
        self._event_log(
            "finalization",
            self.contracts["vault"],
            [economic_deployment._event_topic(economic_deployment.FINALIZED_EVENT, self.hash)],
            b"".join(economic_deployment._word(value) for value in (1, 2, 3, 4, 5)),
        )
        discovered = economic_deployment.discovery_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(discovered["status"], "live")
        self.assertIsNone(discovered["nextAction"])

    def test_shared_manifest_pins_chain_registrar_and_prerequisite_evidence(self) -> None:
        shared, _, _ = self._registrar_evidence()
        cases = (
            ("chain", lambda value: value.__setitem__("chainId", 1), "Sepolia"),
            (
                "registrar",
                lambda value: value["registrar"].__setitem__("address", address(0xBAD)),
                "wrong CREATE address",
            ),
            (
                "prerequisite",
                lambda value: value["prerequisites"]["stackDeployer"].__setitem__(
                    "creationCodeKeccak256", "0x" + "ff" * 32
                ),
                "canonical compiler evidence",
            ),
        )
        for name, mutate, error in cases:
            with self.subTest(name=name):
                broken = copy.deepcopy(shared)
                mutate(broken)
                with self.assertRaisesRegex(economic_deployment.ManifestError, error):
                    economic_deployment.discovery_from_chain(
                        self.receipt,
                        broken,
                        self.creation,
                        self.registrar_creation,
                        self.prerequisite_creation,
                        self.client,
                        hash_=self.hash,
                    )
        registrar_hash = shared["registrar"]["transaction"]["hash"]
        self.client.transactions[registrar_hash]["input"] += "00"
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "CREATE input mismatches compiler evidence"
        ):
            economic_deployment.discovery_from_chain(
                self.receipt,
                shared,
                self.creation,
                self.registrar_creation,
                self.prerequisite_creation,
                self.client,
                hash_=self.hash,
            )

    def test_canonical_shared_manifest_does_not_follow_valid_clone_logs(self) -> None:
        shared, _, registrar = self._registrar_evidence()
        clone = address(0xBAD)
        self.client.codes[clone] = self.client.codes[registrar]
        self._put(clone, "RECEIPT_CREATION_CODE_HASH()(bytes32)", self.creation_hash)
        stage_hash = self.manifest["transactions"]["receiptCreate"]["hash"]
        self.client.transactions[stage_hash]["to"] = clone
        self.client.receipts[stage_hash]["to"] = clone
        self.client.receipts[stage_hash]["logs"][0]["address"] = clone
        with self.assertRaisesRegex(economic_deployment.ManifestError, "found 0"):
            economic_deployment.discovery_from_chain(
                self.receipt,
                shared,
                self.creation,
                self.registrar_creation,
                self.prerequisite_creation,
                self.client,
                hash_=self.hash,
            )

    def test_discovery_rejects_unfinalized_or_reorgable_log_provenance(self) -> None:
        shared, _, _ = self._registrar_evidence()
        stage_hash = self.manifest["transactions"]["receiptCreate"]["hash"]
        stage_log = self.client.receipts[stage_hash]["logs"][0]
        mutations = (
            ("removed", lambda: stage_log.__setitem__("removed", True)),
            ("blockNumber", lambda: stage_log.__setitem__("blockNumber", "0x63")),
            ("blockHash", lambda: stage_log.__setitem__("blockHash", "0x" + "ff" * 32)),
            (
                "transactionHash",
                lambda: stage_log.__setitem__(
                    "transactionHash", self.manifest["transactions"]["deployCore"]["hash"]
                ),
            ),
        )
        original = copy.deepcopy(stage_log)
        for name, mutate in mutations:
            with self.subTest(name=name):
                stage_log.clear()
                stage_log.update(copy.deepcopy(original))
                mutate()
                with self.assertRaises(economic_deployment.ManifestError):
                    economic_deployment.discovery_from_chain(
                        self.receipt,
                        shared,
                        self.creation,
                        self.registrar_creation,
                        self.prerequisite_creation,
                        self.client,
                        hash_=self.hash,
                    )

    def test_schema_v3_names_both_creation_routes_and_rejects_legacy_manifests(self) -> None:
        economic_deployment.validate_manifest(self.manifest, hash_=self.hash)
        shared, registrar_manifest, _ = self._registrar_evidence()
        del shared
        economic_deployment.validate_manifest(registrar_manifest, hash_=self.hash)
        self.assertIn("createNonce", self.manifest["receipt"])
        self.assertEqual(self.manifest["creationRoute"], "create")
        self.assertIn("stageNonce", registrar_manifest["receipt"])
        self.assertNotIn("createNonce", registrar_manifest["receipt"])
        broken = copy.deepcopy(registrar_manifest)
        del broken["creationRoute"]
        with self.assertRaises(economic_deployment.ManifestError):
            economic_deployment.validate_manifest(broken, hash_=self.hash)
        for legacy_version in (1, 2):
            broken = copy.deepcopy(self.manifest)
            broken["schemaVersion"] = legacy_version
            with self.assertRaisesRegex(economic_deployment.ManifestError, "schema version 3"):
                economic_deployment.validate_manifest(broken, hash_=self.hash)

    def test_discovery_cli_has_a_separate_default_output(self) -> None:
        result = {"status": "stage-only"}
        with mock.patch.object(
            economic_deployment,
            "verified_creation_evidence",
            return_value=(self.creation, self.registrar_creation, self.prerequisite_creation),
        ), mock.patch.object(
            economic_deployment.site_deployment,
            "load_json",
            return_value={},
        ), mock.patch.object(
            economic_deployment,
            "CastClient",
            return_value=self.client,
        ), mock.patch.object(
            economic_deployment,
            "discovery_from_chain",
            return_value=result,
        ), mock.patch.object(
            economic_deployment.site_deployment,
            "_write_or_check",
        ) as write:
            self.assertEqual(
                economic_deployment.main(
                    [
                        "--discover-chain-receipt",
                        self.receipt,
                        "--rpc-url",
                        "https://rpc.invalid",
                    ]
                ),
                0,
            )
        write.assert_called_once_with(
            economic_deployment.DISCOVERY_MANIFEST, result, False
        )
        self.assertNotEqual(
            economic_deployment.DISCOVERY_MANIFEST,
            economic_deployment.ECONOMIC_MANIFEST,
        )

    def test_registrar_manifest_rejects_changed_immutable_code_pin(self) -> None:
        shared, manifest, registrar = self._registrar_evidence()
        self._put(
            registrar,
            "RECEIPT_CREATION_CODE_HASH()(bytes32)",
            "0x" + "ff" * 32,
        )
        with self.assertRaisesRegex(
            economic_deployment.ManifestError,
            "does not pin canonical receipt creation code",
        ):
            economic_deployment.verify_rpc(
                manifest,
                self.creation,
                self.prerequisite_creation,
                self.client,
                shared_deployment=shared,
                registrar_creation_code=self.registrar_creation,
                hash_=self.hash,
            )

    def test_persisted_v2_verification_requires_the_canonical_shared_trust_root(self) -> None:
        shared, manifest, _ = self._registrar_evidence()
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "requires the canonical shared manifest"
        ):
            economic_deployment.verify_rpc(
                manifest,
                self.creation,
                self.prerequisite_creation,
                self.client,
                hash_=self.hash,
            )
        economic_deployment.verify_rpc(
            manifest,
            self.creation,
            self.prerequisite_creation,
            self.client,
            shared_deployment=shared,
            registrar_creation_code=self.registrar_creation,
            hash_=self.hash,
        )
        broken = copy.deepcopy(manifest)
        broken["receipt"]["registrar"]["target"] = address(0xBAD)
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "canonical shared manifest"
        ):
            economic_deployment.verify_rpc(
                broken,
                self.creation,
                self.prerequisite_creation,
                self.client,
                shared_deployment=shared,
                registrar_creation_code=self.registrar_creation,
                hash_=self.hash,
            )

    def test_reconstructs_live_registrar_receipt_from_finalized_event(self) -> None:
        self.manifest["status"] = "live"
        self.manifest["finalization"] = {
            "hash": "0x" + "a4" * 32,
            "block": 20,
            "nonce": 188,
            "from": self.deployer,
        }
        self._chain_evidence(live=True)
        shared, expected, _ = self._registrar_evidence()
        self._event_log(
            "finalization",
            self.contracts["vault"],
            [
                economic_deployment._event_topic(
                    economic_deployment.FINALIZED_EVENT, self.hash
                )
            ],
            b"".join(economic_deployment._word(value) for value in (1, 2, 3, 4, 5)),
        )
        built = economic_deployment.manifest_from_chain(
            self.receipt,
            shared,
            self.creation,
            self.registrar_creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(built, expected)

    def test_cast_vector_places_static_flm_tuple_before_bytes_array_offset(self) -> None:
        codes = economic_deployment._decode_bytes_array_argument(
            CAST_DEPLOY_FLM_VECTOR, 64, 5
        )
        self.assertEqual(codes, (b"\x01", b"\x02", b"\x03", b"\x04", b"\x05"))
        config = {
            "positionManager": {
                "target": "0x1111111111111111111111111111111111111111",
                "runtimeCodeKeccak256": "0x" + "22" * 32,
            }
        }
        self.assertEqual(
            economic_deployment._encode_deploy_flm(config, codes), CAST_DEPLOY_FLM_VECTOR
        )
        with self.assertRaises(economic_deployment.ManifestError):
            economic_deployment._decode_bytes_array_argument(CAST_DEPLOY_FLM_VECTOR, 32, 5)

    def test_core_config_round_trips_nested_asset_policies(self) -> None:
        encoded = economic_deployment._encode_core_config(self.core_config)
        self.assertEqual(economic_deployment.DEPLOY_CORE_SELECTOR, "c9b544c1")
        self.assertEqual(economic_deployment._decode_core_config(encoded), self.core_config)
        deploy_core = economic_deployment._encode_deploy_core(
            self.core_config, self.grants, self.core_codes
        )
        self.assertEqual(
            deploy_core[:4],
            bytes.fromhex("c9b544c1"),
        )
        # Golden digest from `cast calldata` with the Solidity deployCore ABI.
        self.assertEqual(
            hashlib.sha256(deploy_core).hexdigest(),
            "8a838654fa54c36287228928cbc552e37b0521f8f51f524ec062eb7e639610dd",
        )
        changed = copy.deepcopy(self.core_config)
        changed["assetPolicies"][0]["tapBudget"] += 1
        self.assertNotEqual(
            economic_deployment._encode_core_commitment(self.core_config, self.grants),
            economic_deployment._encode_core_commitment(changed, self.grants),
        )

    def test_manifest_validates_asset_policy_limits(self) -> None:
        economic_deployment.validate_manifest(self.manifest, hash_=self.hash)
        cases = (
            (
                "too-many",
                [
                    {
                        "asset": address(index),
                        "c1": 1,
                        "c2": 2,
                        "tapBudget": 3,
                        "tapBudgetMax": 4,
                    }
                    for index in range(9)
                ],
                "exceeds the vault maximum",
            ),
            (
                "duplicate",
                [copy.deepcopy(self.core_config["assetPolicies"][0])] * 2,
                "assets must be unique",
            ),
            (
                "c1",
                [{"asset": address(1), "c1": 3, "c2": 2, "tapBudget": 1, "tapBudgetMax": 2}],
                "c1 <= c2",
            ),
            (
                "tap",
                [{"asset": address(1), "c1": 1, "c2": 2, "tapBudget": 3, "tapBudgetMax": 2}],
                "tapBudget <= tapBudgetMax",
            ),
            (
                "uint128",
                [
                    {
                        "asset": address(1),
                        "c1": 1 << 128,
                        "c2": 1 << 128,
                        "tapBudget": 1,
                        "tapBudgetMax": 2,
                    }
                ],
                "outside uint128",
            ),
        )
        for name, policies, error in cases:
            with self.subTest(name=name):
                broken = copy.deepcopy(self.manifest)
                broken["coreConfig"]["assetPolicies"] = policies
                with self.assertRaisesRegex(economic_deployment.ManifestError, error):
                    economic_deployment.validate_manifest(broken, hash_=self.hash)

    def test_manifest_validates_vesting_grant_limit(self) -> None:
        at_limit = copy.deepcopy(self.manifest)
        at_limit["grants"] = [copy.deepcopy(self.grants[0])] * (
            economic_deployment.MAX_VESTING_GRANTS
        )
        _, grants, _ = economic_deployment._validate_config_preimages(at_limit)
        self.assertEqual(len(grants), economic_deployment.MAX_VESTING_GRANTS)

        over_limit = copy.deepcopy(at_limit)
        over_limit["grants"].append(copy.deepcopy(self.grants[0]))
        with self.assertRaisesRegex(
            economic_deployment.ManifestError, "grants exceeds the vault maximum"
        ):
            economic_deployment._validate_config_preimages(over_limit)

    def test_outer_receipt_create_supports_operator_nonce_above_127(self) -> None:
        actual = economic_deployment._create_address(
            address(0xAAA), 185, economic_deployment.flm_code_hashes.keccak256
        )
        self.assertEqual(actual, "0x8b531d483464e7ef234f638eb3b95a0fc56abca8")

    def test_local_creation_evidence_comes_from_checked_isolated_build_info(self) -> None:
        compiled = tuple(
            economic_deployment.economic_code_hashes.CompiledTarget(
                target, target.constant.encode(), "0.8.20", {"viaIR": True}
            )
            for target in economic_deployment.economic_code_hashes.TARGETS
        )
        with mock.patch.object(
            economic_deployment.flm_deployment, "_require_clean_tracked_root"
        ) as clean, mock.patch.object(
            economic_deployment.economic_code_hashes, "generate", return_value=compiled
        ) as generate:
            receipt, registrar, prerequisites = economic_deployment.verified_creation_evidence()
        clean.assert_called_once_with(economic_deployment.ROOT)
        generate.assert_called_once_with(check=True)
        self.assertEqual(receipt, b"RECEIPT")
        self.assertEqual(registrar, b"REGISTRAR")
        self.assertEqual(prerequisites["proposalImplementation"], b"PROPOSAL_IMPLEMENTATION")
        self.assertEqual(prerequisites["stackDeployer"], b"STACK_DEPLOYER")

    def test_live_manifest_verifies_finalization_evidence(self) -> None:
        self.manifest["status"] = "live"
        self.manifest["finalization"] = {
            "hash": "0x" + "a4" * 32,
            "block": 20,
            "nonce": 0,
            "from": address(0xBBB),
        }
        self._chain_evidence(live=True)
        # Legitimate later exits/trading must not rewrite historical finalization evidence.
        self._put(self.contracts["manager"], "totalSupply()(uint256)", 0)
        self._put(
            self.contracts["manager"],
            "balanceOf(address)(uint256)",
            0,
            self.contracts["vault"],
        )
        self._put(
            self.contracts["spotPool"],
            "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)",
            "999\n0\n0\n0\n120\n0\ntrue",
        )
        self._verify()

    def test_promotes_sealed_manifest_from_operation_broadcast(self) -> None:
        sealed = copy.deepcopy(self.manifest)
        self.manifest["status"] = "live"
        self.manifest["finalization"] = {
            "hash": "0x" + "a4" * 32,
            "block": 20,
            "nonce": 188,
            "from": self.deployer,
        }
        self._chain_evidence(live=True)
        operation = self._operation_broadcast()
        tx_hash = economic_deployment.finalization_hash_from_broadcast(
            operation, self.contracts["vault"], self.client
        )
        promoted = economic_deployment.promote_live(
            sealed,
            tx_hash,
            self.creation,
            self.prerequisite_creation,
            self.client,
            hash_=self.hash,
        )
        self.assertEqual(promoted, self.manifest)

    def test_rejects_noncanonical_code_blob_hash(self) -> None:
        broken = copy.deepcopy(self.manifest)
        broken["codeBlobs"]["core"]["VAULT"] = "0x" + "ff" * 32
        with self.assertRaisesRegex(economic_deployment.ManifestError, "VAULT is not canonical"):
            economic_deployment.validate_manifest(broken, hash_=self.hash)

    def test_schema_rejects_self_declared_creation_evidence(self) -> None:
        broken = copy.deepcopy(self.manifest)
        broken["receipt"]["creationCodeKeccak256"] = "0x" + "ff" * 32
        with self.assertRaisesRegex(economic_deployment.ManifestError, "canonical compiler"):
            economic_deployment.validate_manifest(broken, hash_=self.hash)

        broken = copy.deepcopy(self.manifest)
        broken["prerequisites"]["stackDeployer"]["creationCodeBytes"] += 1
        with self.assertRaisesRegex(economic_deployment.ManifestError, "canonical compiler"):
            economic_deployment.validate_manifest(broken, hash_=self.hash)

    def test_rejects_failed_staged_call(self) -> None:
        tx_hash = self.manifest["transactions"]["deployFlm"]["hash"]
        self.client.receipts[tx_hash]["status"] = 0
        with self.assertRaisesRegex(economic_deployment.ManifestError, "deployFlm transaction evidence"):
            self._verify()

    def test_rejects_mutated_constructor_commitment(self) -> None:
        tx_hash = self.manifest["transactions"]["receiptCreate"]["hash"]
        input_ = bytearray.fromhex(self.client.transactions[tx_hash]["input"][2:])
        input_[-1] ^= 1
        self.client.transactions[tx_hash]["input"] = "0x" + input_.hex()
        with self.assertRaisesRegex(economic_deployment.ManifestError, "config commitments"):
            self._verify()

    def test_rejects_disclosed_config_not_used_by_deploy_core(self) -> None:
        self.core_config["saleCap"] += 1
        self.core_config_hash = economic_deployment._digest(
            economic_deployment._encode_core_commitment(self.core_config, self.grants), self.hash
        )
        self.manifest["receipt"]["coreConfigHash"] = self.core_config_hash
        self._put(self.receipt, "CORE_CONFIG_HASH()(bytes32)", self.core_config_hash)
        create_hash = self.manifest["transactions"]["receiptCreate"]["hash"]
        self.client.transactions[create_hash]["input"] = (
            "0x"
            + (
                self.creation
                + bytes.fromhex(self.core_config_hash[2:] + self.flm_config_hash[2:])
            ).hex()
        )
        with self.assertRaisesRegex(economic_deployment.ManifestError, "deployCore calldata"):
            self._verify()

    def test_rejects_unproven_prerequisite_create(self) -> None:
        tx_hash = self.manifest["prerequisites"]["stackDeployer"]["transaction"]["hash"]
        self.client.transactions[tx_hash]["input"] += "00"
        with self.assertRaisesRegex(economic_deployment.ManifestError, "CREATE input"):
            self._verify()

    def test_rejects_wrong_ownerless_authority(self) -> None:
        self._put(self.contracts["manager"], "owner()(address)", address(0xBAD))
        with self.assertRaisesRegex(economic_deployment.ManifestError, "public wiring mismatch"):
            self._verify()

    def test_live_rejects_missing_canonical_pool(self) -> None:
        self.manifest["status"] = "live"
        self.manifest["finalization"] = {
            "hash": "0x" + "a4" * 32,
            "block": 20,
            "nonce": 0,
            "from": address(0xBBB),
        }
        self._chain_evidence(live=True)
        self.client.codes[self.contracts["spotPool"]] = b""
        with self.assertRaisesRegex(economic_deployment.ManifestError, "no deployed code"):
            self._verify()


if __name__ == "__main__":
    unittest.main()
