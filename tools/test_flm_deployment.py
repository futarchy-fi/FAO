from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import flm_deployment, site_deployment


W0_FIXTURE = Path(__file__).parent / "fixtures" / "site-broadcast.json"


def word(value: int) -> bytes:
    return value.to_bytes(32, "big")


def address_word(address: str) -> bytes:
    return word(int(address, 16))


class FixtureHash:
    def __init__(self):
        self.overrides: dict[bytes, str] = {}

    def __call__(self, value: bytes) -> str:
        return self.overrides.get(value, "0x" + hashlib.sha256(value).hexdigest())


class FakeClient:
    def __init__(
        self,
        codes: dict[str, bytes],
        calls: dict[tuple[str, str], str],
        transactions: dict[str, dict],
        receipts: dict[str, dict],
    ):
        self.codes = codes
        self.calls = calls
        self.transactions = transactions
        self.receipts = receipts
        self.chain = flm_deployment.CHAIN_ID

    def code(self, address: str) -> bytes:
        return self.codes.get(address, b"")

    def call(self, address: str, signature: str) -> str:
        try:
            return self.calls[(address, signature)]
        except KeyError as exc:
            raise AssertionError(f"unexpected call: {address}.{signature}") from exc

    def chain_id(self) -> int:
        return self.chain

    def transaction(self, tx_hash: str) -> dict:
        return self.transactions[tx_hash]

    def receipt(self, tx_hash: str) -> dict:
        return self.receipts[tx_hash]


class FlmDeploymentTest(unittest.TestCase):
    IMMUTABLES = {
        "RECEIPT": (
            ("WETH", "contract IERC20"),
            ("COMPANY_TOKEN", "contract IERC20"),
            ("CONDITIONAL_TOKENS", "address"),
            ("WRAPPED_1155_FACTORY", "address"),
            ("UNIV3_FACTORY", "address"),
            ("POSITION_MANAGER", "address"),
            ("SPOT_POOL", "address"),
            ("ARBITRATION", "address"),
            ("PIPELINE", "address"),
            ("ORCHESTRATOR", "address"),
            ("RESOLVER", "address"),
            ("FUTARCHY_FACTORY", "address"),
            ("BOOTSTRAP_COMPANY_AMOUNT", "uint256"),
            ("BOOTSTRAP_WETH_AMOUNT", "uint256"),
        ),
        "RELAY": (
            ("ARBITRATION", "contract IArbitration"),
            ("PIPELINE", "contract IPipeline"),
            ("UNIV3_FACTORY", "contract IFactory"),
            ("CTF", "contract ICTF"),
            ("FEE_TIER", "uint24"),
            ("COMPANY_TOKEN", "address"),
            ("CURRENCY_TOKEN", "address"),
            ("_bindingAuthority", "address"),
        ),
        "ADAPTER": (
            ("POSITION_MANAGER", "contract IPositionManager"),
            ("DEFAULT_TICK_LOWER", "int24"),
            ("DEFAULT_TICK_UPPER", "int24"),
            ("_bindingAuthority", "address"),
        ),
        "GUARD": (("FACTORY", "contract IFactory"), ("FEE", "uint24")),
        "ROUTER": (
            ("CONDITIONAL_TOKENS", "contract ICTF"),
            ("WRAPPED_1155_FACTORY", "contract IW1155"),
        ),
        "MANAGER": (
            ("COMPANY_TOKEN", "contract IERC20"),
            ("WRAPPED_NATIVE", "contract IWETH"),
            ("BOOTSTRAP_RECIPIENT", "address"),
            ("OFFICIAL_PROPOSER", "address"),
            ("PROPOSAL_SOURCE", "contract IProposalSource"),
            ("SPOT_ADAPTER", "contract IAdapter"),
            ("CONDITIONAL_ADAPTER", "contract IAdapter"),
            ("CONDITIONAL_ROUTER", "contract IRouter"),
            ("POOL_STABILITY_GUARD", "contract IGuard"),
            ("TOKEN0", "address"),
            ("TOKEN1", "address"),
            ("COMPANY_IS_TOKEN0", "bool"),
        ),
    }

    def setUp(self) -> None:
        self.hash = FixtureHash()
        self.w0 = site_deployment.manifest_from_broadcast(
            site_deployment.load_json(W0_FIXTURE)
        )
        self.sender = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        self.receipt = flm_deployment._create_address(self.sender, 1, self.hash)
        self.children = {
            name: flm_deployment._create_address(self.receipt, nonce, self.hash)
            for name, nonce, _ in flm_deployment.CHILDREN
        }
        self.creation = {
            target.key: bytes([0x60, index, 0x60, index + 1])
            for index, target in enumerate(flm_deployment.ALL_TARGETS, start=1)
        }
        self.settings = {
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "evmVersion": "shanghai",
            "remappings": ["flm/=lib/futarchy-liquidity-manager/src/"],
        }
        self.dependency_codes = {
            key: b"dependency:" + key.encode() for key in flm_deployment.DEPENDENCY_KEYS
        }
        for key, digest in flm_deployment.PINNED_CODEHASHES.items():
            self.hash.overrides[self.dependency_codes[key]] = digest
        self.dependencies = self.make_dependencies()
        self.code_evidence = self.make_code_evidence()
        self.build_info = self.make_build_info()
        self.broadcast = self.make_broadcast()

    def make_dependencies(self) -> dict[str, flm_deployment.Dependency]:
        contracts = self.w0["contracts"]
        targets = {
            "weth": flm_deployment.WETH,
            "conditionalTokens": flm_deployment.CTF,
            "wrapped1155Factory": flm_deployment.WRAPPED_1155_FACTORY,
            "univ3Factory": flm_deployment.UNIV3_FACTORY,
            "positionManager": flm_deployment.POSITION_MANAGER,
            "companyToken": contracts["siteToken"],
            "spotPool": contracts["spotPool"],
            "arbitration": contracts["arbitration"],
            "pipeline": contracts["evaluator"],
            "orchestrator": contracts["orchestrator"],
            "resolver": contracts["twapResolver"],
            "futarchyFactory": contracts["futarchyFactory"],
        }
        return {
            key: flm_deployment.Dependency(targets[key], self.hash(self.dependency_codes[key]))
            for key in flm_deployment.DEPENDENCY_KEYS
        }

    def make_code_evidence(self) -> dict:
        return {
            "schemaVersion": 2,
            "flmSubmoduleSha": "ab" * 20,
            "compiler": {
                "solcVersion": "0.8.20+commit.a1b79de6",
                "solcSettingsKeccak256": self.hash(
                    flm_deployment._canonical(
                        {
                            "solcVersion": "0.8.20+commit.a1b79de6",
                            "settings": self.settings,
                        }
                    )
                ),
            },
            "receipt": {
                "source": flm_deployment.RECEIPT_TARGET.source,
                "contract": flm_deployment.RECEIPT_TARGET.contract,
                "creationCodeBytes": len(self.creation["RECEIPT"]),
                "creationCodeKeccak256": self.hash(self.creation["RECEIPT"]),
            },
            "contracts": {
                target.key: {
                    "source": target.source,
                    "contract": target.contract,
                    "baseCreationCodePath": (
                        f"metadata/flm-creation-code/{target.key.lower()}.bin"
                    ),
                    "baseCreationCodeBytes": len(self.creation[target.key]),
                    "baseCreationCodeKeccak256": self.hash(self.creation[target.key]),
                }
                for target in flm_deployment.CODE_TARGETS
            },
        }

    def make_build_info(self) -> dict:
        output_sources = {}
        output_contracts = {}
        identifier = 1000
        for target in flm_deployment.ALL_TARGETS:
            nodes = []
            references = {}
            runtime = bytearray(b"\x60")
            for name, type_string in self.IMMUTABLES[target.key]:
                nodes.append(
                    {
                        "nodeType": "VariableDeclaration",
                        "mutability": "immutable",
                        "id": identifier,
                        "name": name,
                        "typeDescriptions": {"typeString": type_string},
                    }
                )
                start = len(runtime)
                runtime.extend(bytes(32))
                references[str(identifier)] = [{"start": start, "length": 32}]
                identifier += 1
            runtime.append(0)
            output_sources[target.source] = {
                "ast": {"nodeType": "SourceUnit", "nodes": nodes}
            }
            metadata_settings = {
                "compilationTarget": {target.source: target.contract},
                **self.settings,
            }
            metadata_settings["remappings"] = [
                ":" + item for item in self.settings["remappings"]
            ]
            output_contracts.setdefault(target.source, {})[target.contract] = {
                "evm": {
                    "bytecode": {
                        "object": "0x" + self.creation[target.key].hex(),
                        "linkReferences": {},
                    },
                    "deployedBytecode": {
                        "object": "0x" + bytes(runtime).hex(),
                        "linkReferences": {},
                        "immutableReferences": references,
                    },
                },
                "metadata": json.dumps(
                    {
                        "compiler": {"version": "0.8.20+commit.a1b79de6"},
                        "settings": metadata_settings,
                    }
                ),
            }
        return {"output": {"sources": output_sources, "contracts": output_contracts}}

    def encode_config(self) -> bytes:
        encoded = bytearray()
        for key in flm_deployment.DEPENDENCY_KEYS:
            dependency = self.dependencies[key]
            encoded.extend(address_word(dependency.target))
            encoded.extend(bytes.fromhex(dependency.codehash[2:]))
        encoded.extend(word(123456))
        encoded.extend(word(654321))
        return bytes(encoded)

    @staticmethod
    def encode_base_codes(values: tuple[bytes, ...]) -> bytes:
        head = bytearray(word(32) + word(len(values)))
        offsets = bytearray()
        body = bytearray()
        cursor = len(values) * 32
        for value in values:
            offsets.extend(word(cursor))
            encoded = word(len(value)) + value + bytes((-len(value)) % 32)
            body.extend(encoded)
            cursor += len(encoded)
        return bytes.fromhex(flm_deployment.DEPLOY_AND_BIND_SELECTOR) + head + offsets + body

    def make_broadcast(self) -> dict:
        base_codes = tuple(self.creation[target.key] for target in flm_deployment.CODE_TARGETS)
        tx_hashes = ["0x" + bytes([index]).hex() * 32 for index in (1, 2, 3)]
        transactions = [
            {
                "hash": tx_hashes[0],
                "transactionType": "CALL",
                "contractName": "IUniswapV3PoolLike",
                "contractAddress": None,
                "transaction": {
                    "from": self.sender,
                    "to": self.w0["contracts"]["spotPool"],
                    "nonce": "0x0",
                    "input": "0x"
                    + flm_deployment.CARDINALITY_SELECTOR
                    + word(120).hex(),
                },
            },
            {
                "hash": tx_hashes[1],
                "transactionType": "CREATE",
                "contractName": flm_deployment.RECEIPT_TARGET.contract,
                "contractAddress": self.receipt,
                "transaction": {
                    "from": self.sender,
                    "to": None,
                    "nonce": "0x1",
                    "input": "0x"
                    + (self.creation["RECEIPT"] + self.encode_config()).hex(),
                },
            },
            {
                "hash": tx_hashes[2],
                "transactionType": "CALL",
                "contractName": flm_deployment.RECEIPT_TARGET.contract,
                "contractAddress": None,
                "transaction": {
                    "from": self.sender,
                    "to": self.receipt,
                    "nonce": "0x9",
                    "input": "0x" + self.encode_base_codes(base_codes).hex(),
                },
            },
        ]
        log = {
            "address": self.receipt,
            "topics": [
                flm_deployment.BUNDLE_SEALED_TOPIC,
                "0x" + address_word(self.children["relay"]).hex(),
                "0x" + address_word(self.children["manager"]).hex(),
                "0x" + address_word(self.children["spotAdapter"]).hex(),
            ],
            "data": "0x"
            + b"".join(
                address_word(self.children[name])
                for name in ("conditionalAdapter", "guard", "router")
            ).hex(),
        }
        receipts = [
            {
                "status": "0x1",
                "transactionHash": tx_hashes[0],
                "blockNumber": "0x64",
                "logs": [],
            },
            {
                "status": "0x1",
                "transactionHash": tx_hashes[1],
                "contractAddress": self.receipt,
                "blockNumber": "0x65",
                "logs": [],
            },
            {
                "status": "0x1",
                "transactionHash": tx_hashes[2],
                "blockNumber": "0x66",
                "logs": [log],
            },
        ]
        return {
            "chain": flm_deployment.CHAIN_ID,
            "transactions": transactions,
            "receipts": receipts,
            "pending": [],
        }

    def write_build_info(self, root: Path, value: dict | None = None) -> Path:
        path = root / "build-info.json"
        path.write_text(json.dumps(value or self.build_info), encoding="utf-8")
        return path

    def manifest(self, root: Path) -> dict:
        return flm_deployment.flm_from_broadcast(
            self.broadcast,
            self.w0,
            self.code_evidence,
            self.write_build_info(root),
            hash_=self.hash,
        )

    def runtime_codes(self, root: Path, section: dict) -> dict[str, bytes]:
        catalog = flm_deployment.BuildCatalog(root / "build-info.json")
        context = flm_deployment._context_from_flm(section)
        compiled = {
            "RECEIPT": catalog.exact(
                flm_deployment.RECEIPT_TARGET, self.creation["RECEIPT"]
            )
        }
        for target in flm_deployment.CODE_TARGETS:
            compiled[target.key] = catalog.exact(target, self.creation[target.key])
        result = {
            "receipt": flm_deployment._patch_runtime(
                compiled["RECEIPT"],
                flm_deployment._immutable_values(
                    flm_deployment.RECEIPT_TARGET, context
                ),
            )
        }
        for name, _, key in flm_deployment.CHILDREN:
            result[name] = flm_deployment._patch_runtime(
                compiled[key],
                flm_deployment._immutable_values(
                    flm_deployment.TARGET_BY_KEY[key], context
                ),
            )
        return result

    def fake_client(self, root: Path, section: dict) -> FakeClient:
        context = flm_deployment._context_from_flm(section)
        c = context.children
        d = context.dependencies
        receipt = context.receipt
        codes = {
            section["contracts"][name]["address"]: code
            for name, code in self.runtime_codes(root, section).items()
        }
        codes.update(
            {dependency.target: self.dependency_codes[key] for key, dependency in d.items()}
        )
        calls: dict[tuple[str, str], str] = {(receipt, "isSealed()(bool)"): "true"}

        def addresses(target: str, values: dict[str, str]) -> None:
            for signature, value in values.items():
                calls[(target, signature)] = value

        addresses(
            receipt,
            {
                "relay()(address)": c["relay"],
                "spotAdapter()(address)": c["spotAdapter"],
                "conditionalAdapter()(address)": c["conditionalAdapter"],
                "guard()(address)": c["guard"],
                "router()(address)": c["router"],
                "manager()(address)": c["manager"],
                "WETH()(address)": d["weth"].target,
                "COMPANY_TOKEN()(address)": d["companyToken"].target,
                "CONDITIONAL_TOKENS()(address)": d["conditionalTokens"].target,
                "WRAPPED_1155_FACTORY()(address)": d["wrapped1155Factory"].target,
                "UNIV3_FACTORY()(address)": d["univ3Factory"].target,
                "POSITION_MANAGER()(address)": d["positionManager"].target,
                "SPOT_POOL()(address)": d["spotPool"].target,
                "ARBITRATION()(address)": d["arbitration"].target,
                "PIPELINE()(address)": d["pipeline"].target,
                "ORCHESTRATOR()(address)": d["orchestrator"].target,
                "RESOLVER()(address)": d["resolver"].target,
                "FUTARCHY_FACTORY()(address)": d["futarchyFactory"].target,
            },
        )
        addresses(
            c["relay"],
            {
                "MANAGER()(address)": c["manager"],
                "ARBITRATION()(address)": d["arbitration"].target,
                "PIPELINE()(address)": d["pipeline"].target,
                "UNIV3_FACTORY()(address)": d["univ3Factory"].target,
                "CTF()(address)": d["conditionalTokens"].target,
                "COMPANY_TOKEN()(address)": d["companyToken"].target,
                "CURRENCY_TOKEN()(address)": d["weth"].target,
            },
        )
        for adapter in (c["spotAdapter"], c["conditionalAdapter"]):
            addresses(
                adapter,
                {
                    "MANAGER()(address)": c["manager"],
                    "POSITION_MANAGER()(address)": d["positionManager"].target,
                },
            )
        addresses(c["guard"], {"FACTORY()(address)": d["univ3Factory"].target})
        addresses(
            c["router"],
            {
                "CONDITIONAL_TOKENS()(address)": d["conditionalTokens"].target,
                "WRAPPED_1155_FACTORY()(address)": d["wrapped1155Factory"].target,
            },
        )
        addresses(
            c["manager"],
            {
                "owner()(address)": flm_deployment.DEAD,
                "BOOTSTRAP_RECIPIENT()(address)": receipt,
                "OFFICIAL_PROPOSER()(address)": c["relay"],
                "PROPOSAL_SOURCE()(address)": c["relay"],
                "SPOT_ADAPTER()(address)": c["spotAdapter"],
                "CONDITIONAL_ADAPTER()(address)": c["conditionalAdapter"],
                "CONDITIONAL_ROUTER()(address)": c["router"],
                "POOL_STABILITY_GUARD()(address)": c["guard"],
                "COMPANY_TOKEN()(address)": d["companyToken"].target,
                "WRAPPED_NATIVE()(address)": d["weth"].target,
            },
        )
        calls[(receipt, "BOOTSTRAP_COMPANY_AMOUNT()(uint256)")] = str(
            context.bootstrap_company
        )
        calls[(receipt, "BOOTSTRAP_WETH_AMOUNT()(uint256)")] = str(
            context.bootstrap_weth
        )
        calls[(c["relay"], "FEE_TIER()(uint24)")] = str(flm_deployment.FEE_TIER)
        for adapter in (c["spotAdapter"], c["conditionalAdapter"]):
            calls[(adapter, "DEFAULT_TICK_LOWER()(int24)")] = str(
                flm_deployment.TICK_LOWER
            )
            calls[(adapter, "DEFAULT_TICK_UPPER()(int24)")] = str(
                flm_deployment.TICK_UPPER
            )
        calls[(c["guard"], "FEE()(uint24)")] = str(flm_deployment.FEE_TIER)
        calls[
            (
                d["spotPool"].target,
                "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)",
            )
        ] = "1\n0\n1\n1\n120\n0\ntrue"

        live_transactions = {}
        live_receipts = {}
        for name, manifest_tx in section["transactions"].items():
            target = None if name == "receiptCreate" else manifest_tx["to"]
            tx_hash = manifest_tx["hash"]
            live_transactions[tx_hash] = {
                "hash": tx_hash,
                "blockNumber": hex(manifest_tx["block"]),
                "nonce": hex(manifest_tx["nonce"]),
                "from": manifest_tx["from"],
                "to": target,
            }
            live_receipts[tx_hash] = {
                "transactionHash": tx_hash,
                "blockNumber": hex(manifest_tx["block"]),
                "from": manifest_tx["from"],
                "to": target,
                "status": "0x1",
                "contractAddress": (
                    manifest_tx["address"] if name == "receiptCreate" else None
                ),
            }
        return FakeClient(codes, calls, live_transactions, live_receipts)

    def rejected(self, broadcast: dict, pattern: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_build_info(Path(directory))
            with self.assertRaisesRegex(flm_deployment.ManifestError, pattern):
                flm_deployment.flm_from_broadcast(
                    broadcast,
                    self.w0,
                    self.code_evidence,
                    path,
                    hash_=self.hash,
                )

    def test_builds_manifest_from_exact_three_transaction_broadcast(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            section = self.manifest(root)
            self.assertEqual(tuple(section["contracts"]), flm_deployment.CONTRACT_KEYS)
            self.assertEqual(section["transactions"]["cardinality"]["block"], 100)
            self.assertEqual(section["transactions"]["cardinality"]["nonce"], 0)
            self.assertEqual(section["transactions"]["receiptCreate"]["nonce"], 1)
            self.assertEqual(section["transactions"]["deployAndBind"]["nonce"], 9)
            self.assertEqual(section["transactions"]["receiptCreate"]["address"], self.receipt)
            self.assertEqual(section["bootstrap"], {"companyAmount": 123456, "wethAmount": 654321})
            self.assertEqual(
                section["codeEvidence"]["flmSubmoduleSha"], "ab" * 20
            )
            self.assertEqual(
                section["codeEvidence"]["compiler"]["solcSettingsKeccak256"],
                self.hash(
                    flm_deployment._canonical(
                        {
                            "solcVersion": "0.8.20+commit.a1b79de6",
                            "settings": self.settings,
                        }
                    )
                ),
            )
            self.assertNotEqual(
                section["codeEvidence"]["compiler"]["solcSettingsKeccak256"],
                self.hash(flm_deployment._canonical(self.settings)),
            )
            for name, nonce, key in flm_deployment.CHILDREN:
                self.assertEqual(section["contracts"][name]["createNonce"], nonce)
                self.assertEqual(section["contracts"][name]["baseCode"], key)
                self.assertEqual(section["contracts"][name]["address"], self.children[name])

            catalog = flm_deployment.BuildCatalog(root / "build-info.json")
            relay = catalog.exact(
                flm_deployment.TARGET_BY_KEY["RELAY"], self.creation["RELAY"]
            )
            self.assertNotEqual(
                self.hash(relay.runtime_template),
                section["contracts"]["relay"]["runtimeCodeKeccak256"],
                "raw unpatched runtime must never be accepted as deployed evidence",
            )

    def test_rejects_transaction_event_and_loader_drift(self) -> None:
        changes = []

        def change(name, mutate, pattern):
            value = copy.deepcopy(self.broadcast)
            mutate(value)
            changes.append((name, value, pattern))

        change("pending", lambda v: v["pending"].append({}), "pending")
        change("missing tx", lambda v: v["transactions"].pop(), "exactly three")
        change("failed", lambda v: v["receipts"][2].update(status="0x0"), "failed")
        change(
            "wrong order",
            lambda v: v["transactions"][0]["transaction"].update(nonce="0x9"),
            "nonces \[0, 1\]",
        )
        change(
            "wrong cardinality selector",
            lambda v: v["transactions"][0]["transaction"].update(
                input="0xdeadbeef" + word(120).hex()
            ),
            "cardinality call",
        )
        change(
            "small cardinality",
            lambda v: v["transactions"][0]["transaction"].update(
                input="0x" + flm_deployment.CARDINALITY_SELECTOR + word(119).hex()
            ),
            "canonical range",
        )
        change(
            "wrong bind target",
            lambda v: v["transactions"][2]["transaction"].update(to="0x" + "77" * 20),
            "deployAndBind",
        )
        change(
            "duplicate event",
            lambda v: v["receipts"][2]["logs"].append(copy.deepcopy(v["receipts"][2]["logs"][0])),
            "found 2",
        )
        change(
            "wrong child nonce",
            lambda v: v["receipts"][2]["logs"][0]["topics"].__setitem__(
                1, "0x" + address_word("0x" + "55" * 20).hex()
            ),
            "CREATE nonce 1",
        )
        change(
            "mutated base code",
            lambda v: v["transactions"][2]["transaction"].update(
                input="0x"
                + self.encode_base_codes(
                    (b"mutated",)
                    + tuple(
                        self.creation[target.key]
                        for target in flm_deployment.CODE_TARGETS[1:]
                    )
                ).hex()
            ),
            "RELAY base code",
        )
        for name, value, pattern in changes:
            with self.subTest(name=name):
                self.rejected(value, pattern)

        helper = copy.deepcopy(self.broadcast)
        helper_address = "0xfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed"
        helper["transactions"][2]["transaction"].update(
            **{"from": helper_address, "nonce": "0x4d"}
        )
        with tempfile.TemporaryDirectory() as directory:
            section = flm_deployment.flm_from_broadcast(
                helper,
                self.w0,
                self.code_evidence,
                self.write_build_info(Path(directory)),
                hash_=self.hash,
            )
        self.assertEqual(section["transactions"]["deployAndBind"]["from"], helper_address)
        self.assertEqual(section["transactions"]["deployAndBind"]["nonce"], 77)

    def test_rejects_constructor_config_and_compiler_evidence_drift(self) -> None:
        broadcast = copy.deepcopy(self.broadcast)
        create = broadcast["transactions"][1]["transaction"]
        encoded = bytearray(bytes.fromhex(create["input"][2:]))
        config_start = len(self.creation["RECEIPT"])
        company_index = flm_deployment.DEPENDENCY_KEYS.index("companyToken")
        start = config_start + company_index * 64
        encoded[start : start + 32] = address_word("0x" + "77" * 20)
        create["input"] = "0x" + bytes(encoded).hex()
        self.rejected(broadcast, "companyToken")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad = copy.deepcopy(self.build_info)
            relay_target = flm_deployment.TARGET_BY_KEY["RELAY"]
            relay = bad["output"]["contracts"][relay_target.source][
                relay_target.contract
            ]
            relay["evm"]["deployedBytecode"]["immutableReferences"]["999999"] = [
                {"start": 1, "length": 32}
            ]
            path = self.write_build_info(root, bad)
            with self.assertRaisesRegex(flm_deployment.ManifestError, "AST id"):
                flm_deployment.flm_from_broadcast(
                    self.broadcast,
                    self.w0,
                    self.code_evidence,
                    path,
                    hash_=self.hash,
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = copy.deepcopy(self.code_evidence)
            evidence["compiler"]["solcSettingsKeccak256"] = "0x" + "00" * 32
            with self.assertRaisesRegex(flm_deployment.ManifestError, "solc settings"):
                flm_deployment.flm_from_broadcast(
                    self.broadcast,
                    self.w0,
                    evidence,
                    self.write_build_info(root),
                    hash_=self.hash,
                )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build-info.json"
            path.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(flm_deployment.ManifestError, "must be an object"):
                flm_deployment.BuildCatalog(path)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = copy.deepcopy(self.code_evidence)
            evidence["receipt"]["creationCodeKeccak256"] = "0x" + "00" * 32
            with self.assertRaisesRegex(flm_deployment.ManifestError, "receipt CREATE prefix"):
                flm_deployment.flm_from_broadcast(
                    self.broadcast,
                    self.w0,
                    evidence,
                    self.write_build_info(root),
                    hash_=self.hash,
                )

    def test_combine_preserves_every_w0_field_and_cross_checks_layers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            section = self.manifest(Path(directory))
        original = copy.deepcopy(self.w0)
        combined = flm_deployment.combine(self.w0, section, hash_=self.hash)
        flm_deployment._require_pinned_evidence(
            section, "ab" * 20, self.code_evidence
        )
        flm_deployment._require_pinned_evidence(
            combined, "ab" * 20, self.code_evidence
        )
        with self.assertRaisesRegex(flm_deployment.ManifestError, "gitlink"):
            flm_deployment._require_pinned_evidence(
                section, "cd" * 20, self.code_evidence
            )
        changed_section = copy.deepcopy(section)
        changed_section["codeEvidence"]["compiler"][
            "solcVersion"
        ] = "attacker-controlled-solc"
        changed_section["codeEvidence"]["contracts"]["RELAY"][
            "baseCreationCodeKeccak256"
        ] = "0x" + "11" * 32
        with self.assertRaisesRegex(flm_deployment.ManifestError, "canonical generated"):
            flm_deployment._require_pinned_evidence(
                changed_section, "ab" * 20, self.code_evidence
            )
        self.assertEqual(self.w0, original)
        expected_w0 = copy.deepcopy(combined)
        expected_w0.pop("flm")
        expected_w0["schemaVersion"] = 1
        self.assertEqual(expected_w0, original)
        self.assertEqual(combined["schemaVersion"], 2)

        changed = copy.deepcopy(section)
        changed["dependencies"]["companyToken"]["target"] = "0x" + "77" * 20
        with self.assertRaisesRegex(flm_deployment.ManifestError, "companyToken"):
            flm_deployment.combine(self.w0, changed, hash_=self.hash)

        changed_w0 = copy.deepcopy(self.w0)
        changed_w0["deployer"] = "0x" + self.sender[2:].upper()
        with self.assertRaisesRegex(flm_deployment.ManifestError, "differ"):
            flm_deployment.combine(changed_w0, section, hash_=self.hash)

        changed = copy.deepcopy(section)
        changed["transactions"]["cardinality"]["to"] = "0x" + "77" * 20
        with self.assertRaisesRegex(flm_deployment.ManifestError, "dependencies.spotPool"):
            flm_deployment._validate_flm(changed, hash_=self.hash)

        changed = copy.deepcopy(section)
        changed["transactions"]["receiptCreate"]["hash"] = changed["transactions"][
            "cardinality"
        ]["hash"]
        with self.assertRaisesRegex(flm_deployment.ManifestError, "hashes must be unique"):
            flm_deployment._validate_flm(changed, hash_=self.hash)

        changed = copy.deepcopy(section)
        uppercase_operator = "0x" + flm_deployment.FORBIDDEN_OPERATOR[2:].upper()
        changed["transactions"]["cardinality"]["from"] = uppercase_operator
        changed["transactions"]["receiptCreate"]["from"] = uppercase_operator
        with self.assertRaisesRegex(flm_deployment.ManifestError, "canonical lowercase"):
            flm_deployment._validate_flm(changed, hash_=self.hash)

    def test_prepare_build_info_creates_and_smokes_durable_union(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence_path = root / "metadata/sepolia-flm-code-hashes.json"
            evidence_path.parent.mkdir(parents=True)
            evidence_path.write_text(json.dumps(self.code_evidence), encoding="utf-8")
            for target in flm_deployment.CODE_TARGETS:
                blob = root / self.code_evidence["contracts"][target.key][
                    "baseCreationCodePath"
                ]
                blob.parent.mkdir(parents=True, exist_ok=True)
                blob.write_bytes(self.creation[target.key])

            commands = []

            def runner(command: list[str], cwd: Path) -> None:
                self.assertEqual(cwd, root)
                commands.append(command)
                destination = root / "out/build-info"
                canonical = copy.deepcopy(self.build_info)
                receipt = copy.deepcopy(self.build_info)
                receipt_source = flm_deployment.RECEIPT_TARGET.source
                canonical["output"]["contracts"].pop(receipt_source)
                for target in flm_deployment.CODE_TARGETS:
                    contracts = receipt["output"]["contracts"]
                    contracts[target.source].pop(target.contract)
                    if not contracts[target.source]:
                        contracts.pop(target.source)
                (destination / "canonical").mkdir(parents=True, exist_ok=True)
                (destination / "receipt").mkdir(parents=True, exist_ok=True)
                (destination / "canonical/children.json").write_text(
                    json.dumps(canonical), encoding="utf-8"
                )
                (destination / "receipt/receipt.json").write_text(
                    json.dumps(receipt), encoding="utf-8"
                )

            destination = flm_deployment.prepare_build_info(
                root,
                runner=runner,
                python_bin="python3",
                hash_=self.hash,
            )
            self.assertEqual(destination, root / "build-info/flm-deployment")
            self.assertTrue((destination / "canonical/children.json").is_file())
            self.assertTrue((destination / "receipt/receipt.json").is_file())
            self.assertEqual(len(commands), 1)
            self.assertEqual(commands[0][-1], "--check")

            catalog = flm_deployment.BuildCatalog(destination)
            for target in flm_deployment.ALL_TARGETS:
                catalog.exact(target, self.creation[target.key])

    def test_operational_gate_ignores_untracked_and_rejects_tracked_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            tracked = root / "tracked"
            tracked.write_text("original", encoding="utf-8")
            subprocess.run(["git", "add", "tracked"], cwd=root, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-qm",
                    "initial",
                ],
                cwd=root,
                check=True,
            )
            (root / "untracked-deployment.json").write_text("{}", encoding="utf-8")
            flm_deployment._require_clean_tracked_root(root)

            tracked.write_text("modified", encoding="utf-8")
            with self.assertRaisesRegex(flm_deployment.ManifestError, "tracked root"):
                flm_deployment._require_clean_tracked_root(root)

    def test_rpc_verifies_patched_code_sealing_and_complete_role_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            section = self.manifest(root)
            client = self.fake_client(root, section)
            flm_deployment.verify_rpc(
                section, root / "build-info.json", client, hash_=self.hash
            )

            client.chain = 1
            with self.assertRaisesRegex(flm_deployment.ManifestError, "Sepolia"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )
            client.chain = flm_deployment.CHAIN_ID

            create_hash = section["transactions"]["receiptCreate"]["hash"]
            client.receipts[create_hash]["blockNumber"] = "0xdead"
            with self.assertRaisesRegex(flm_deployment.ManifestError, "block mismatch"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )
            client.receipts[create_hash]["blockNumber"] = hex(
                section["transactions"]["receiptCreate"]["block"]
            )

            spot = section["dependencies"]["spotPool"]["target"]
            slot0_signature = "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
            client.calls[(spot, slot0_signature)] = "1\n0\n1\n1\n119\n0\ntrue"
            with self.assertRaisesRegex(flm_deployment.ManifestError, "below"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )
            client.calls[(spot, slot0_signature)] = "1\n0\n1\n1\n120\n0\ntrue"

            manager = section["contracts"]["manager"]["address"]
            client.codes[manager] = b"wrong runtime"
            with self.assertRaisesRegex(flm_deployment.ManifestError, "patched compiler"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )
            client.codes[manager] = self.runtime_codes(root, section)["manager"]

            client.calls[(manager, "owner()(address)")] = self.sender
            with self.assertRaisesRegex(flm_deployment.ManifestError, "role/dependency"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )
            client.calls[(manager, "owner()(address)")] = flm_deployment.DEAD

            receipt = section["contracts"]["receipt"]["address"]
            client.calls[(receipt, "isSealed()(bool)")] = "false"
            with self.assertRaisesRegex(flm_deployment.ManifestError, "not sealed"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )

    def test_rpc_rejects_unpatched_runtime_and_dependency_code_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            section = self.manifest(root)
            client = self.fake_client(root, section)
            catalog = flm_deployment.BuildCatalog(root / "build-info.json")
            relay = catalog.exact(
                flm_deployment.TARGET_BY_KEY["RELAY"], self.creation["RELAY"]
            )
            relay_address = section["contracts"]["relay"]["address"]
            client.codes[relay_address] = relay.runtime_template
            with self.assertRaisesRegex(flm_deployment.ManifestError, "patched compiler"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )

            client.codes[relay_address] = self.runtime_codes(root, section)["relay"]
            weth = section["dependencies"]["weth"]["target"]
            client.codes[weth] = b"wrong dependency"
            with self.assertRaisesRegex(flm_deployment.ManifestError, "dependency runtime"):
                flm_deployment.verify_rpc(
                    section, root / "build-info.json", client, hash_=self.hash
                )

    def test_rpc_rejects_live_transaction_provenance_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            section = self.manifest(root)

            def rejected(mutate, pattern: str) -> None:
                client = self.fake_client(root, section)
                mutate(client)
                with self.assertRaisesRegex(flm_deployment.ManifestError, pattern):
                    flm_deployment._verify_live_transactions(section, client)

            cardinality_hash = section["transactions"]["cardinality"]["hash"]
            create_hash = section["transactions"]["receiptCreate"]["hash"]
            bind_hash = section["transactions"]["deployAndBind"]["hash"]
            rejected(
                lambda client: client.transactions[cardinality_hash].update(nonce="0x1"),
                "nonce mismatch",
            )
            rejected(
                lambda client: client.receipts[bind_hash].update(status="0x0"),
                "transaction failed",
            )
            rejected(
                lambda client: client.transactions[bind_hash].update(to="0x" + "77" * 20),
                "target mismatch",
            )
            rejected(
                lambda client: client.receipts[create_hash].update(
                    contractAddress="0x" + "77" * 20
                ),
                "contract address mismatch",
            )
            rejected(
                lambda client: client.receipts[cardinality_hash].update(
                    **{"from": "0x" + "77" * 20}
                ),
                "sender mismatch",
            )

    def test_abi_decoder_rejects_noncanonical_offsets_and_padding(self) -> None:
        values = tuple(self.creation[target.key] for target in flm_deployment.CODE_TARGETS)
        encoded = bytearray(self.encode_base_codes(values))
        self.assertEqual(flm_deployment._decode_base_codes(bytes(encoded)), values)
        encoded[4 + 64 + 31] += 1
        with self.assertRaisesRegex(flm_deployment.ManifestError, "non-canonical offsets"):
            flm_deployment._decode_base_codes(bytes(encoded))

        encoded = bytearray(self.encode_base_codes(values))
        encoded.append(0)
        with self.assertRaisesRegex(flm_deployment.ManifestError, "malformed"):
            flm_deployment._decode_base_codes(bytes(encoded))

    def test_signed_immutable_encoding_is_256_bit_sign_extended(self) -> None:
        encoded = flm_deployment._encode_immutable(-1, "int24")
        self.assertEqual(encoded, b"\xff" * 32)
        encoded = flm_deployment._encode_immutable(flm_deployment.TICK_LOWER, "int24")
        self.assertEqual(int.from_bytes(encoded, "big"), (1 << 256) + flm_deployment.TICK_LOWER)

    def test_runtime_patch_has_independent_address_bool_and_signed_oracle(self) -> None:
        compiled = flm_deployment.CompiledContract(
            flm_deployment.RECEIPT_TARGET,
            b"creation",
            b"\x60" + bytes(96) + b"\x00",
            (
                flm_deployment.Immutable("account", "address", ((1, 32),)),
                flm_deployment.Immutable("enabled", "bool", ((33, 32),)),
                flm_deployment.Immutable("tick", "int24", ((65, 32),)),
            ),
            "test",
            {},
        )
        account = "0x1234567890abcdef1234567890abcdef12345678"
        expected = (
            b"\x60"
            + bytes(12)
            + bytes.fromhex(account[2:])
            + bytes(31)
            + b"\x01"
            + b"\xff" * 32
            + b"\x00"
        )
        self.assertEqual(
            flm_deployment._patch_runtime(
                compiled, {"account": account, "enabled": True, "tick": -1}
            ),
            expected,
        )


if __name__ == "__main__":
    unittest.main()
