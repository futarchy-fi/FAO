import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools import site_deployment


FIXTURE = Path(__file__).parent / "fixtures" / "site-broadcast.json"


class SiteDeploymentTest(unittest.TestCase):
    def broadcast(self):
        return site_deployment.load_json(FIXTURE)

    def assert_broadcast_rejected(self, broadcast, pattern):
        with self.assertRaisesRegex(site_deployment.ManifestError, pattern):
            site_deployment.manifest_from_broadcast(broadcast)

    def test_builds_canonical_manifest_from_foundry_broadcast(self):
        broadcast = self.broadcast()
        broadcast["chain"] = "0xaa36a7"
        manifest = site_deployment.manifest_from_broadcast(broadcast)

        self.assertEqual(manifest["deploymentBlock"], 123)
        self.assertIs(type(manifest["deploymentBlock"]), int)
        self.assertIs(type(manifest["chainId"]), int)
        self.assertEqual(manifest["deploymentTransaction"], "0x" + "04" * 32)
        self.assertEqual(manifest["deployer"], "0x6900000000000000000000000000000000000069")
        self.assertEqual(manifest["currencyToken"], site_deployment.WETH)
        self.assertEqual(manifest["feeTier"], 500)
        self.assertEqual(tuple(manifest["contracts"]), site_deployment.CONTRACT_KEYS)
        self.assertEqual(manifest["contracts"]["spotPool"], "0x" + "55" * 20)
        self.assertEqual(manifest["contracts"]["twapResolver"], "0x" + "dd" * 20)

    def test_projects_consumers_and_detects_drift(self):
        manifest = site_deployment.manifest_from_broadcast(self.broadcast())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "deployments" / "sepolia-site-release.json"
            publisher = root / "publisher"
            stable = root / "stable"
            publisher.mkdir()
            stable.mkdir()
            (publisher / "deployment.example.json").write_text(
                json.dumps(
                    {
                        "chain_id": 11155111,
                        "strategy_address": "0x" + "00" * 20,
                        "start_block": 0,
                        "confirmations": 12,
                    }
                ),
                encoding="utf-8",
            )
            site_deployment._write_or_check(manifest_path, manifest, False)
            self.assertEqual(
                site_deployment.main(
                    [
                        "project",
                        "--manifest",
                        str(manifest_path),
                        "--publisher",
                        str(publisher),
                        "--stable",
                        str(stable),
                    ]
                ),
                0,
            )
            self.assertEqual(
                json.loads((publisher / "deployment.json").read_text())["strategy_address"],
                manifest["contracts"]["releaseStrategy"],
            )
            stable_path = stable / "deployment.json"
            stable_value = json.loads(stable_path.read_text())
            self.assertEqual(stable_value["status"], "active")
            self.assertEqual(
                stable_value["governedSite"], site_deployment.STABLE_IDENTITY["governedSite"]
            )
            site_deployment.main(
                [
                    "project",
                    "--manifest",
                    str(manifest_path),
                    "--publisher",
                    str(publisher),
                    "--stable",
                    str(stable),
                    "--check",
                ]
            )
            stable_value["governedSite"] = "https://drift.invalid"
            stable_path.write_text(json.dumps(stable_value, indent=2) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(site_deployment.ManifestError, "stale"):
                site_deployment.main(
                    [
                        "project",
                        "--manifest",
                        str(manifest_path),
                        "--publisher",
                        str(publisher),
                        "--stable",
                        str(stable),
                        "--check",
                    ]
                )
            site_deployment.main(
                [
                    "project",
                    "--manifest",
                    str(manifest_path),
                    "--publisher",
                    str(publisher),
                    "--stable",
                    str(stable),
                ]
            )
            (publisher / "deployment.json").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(site_deployment.ManifestError, "stale"):
                site_deployment.main(
                    [
                        "project",
                        "--manifest",
                        str(manifest_path),
                        "--publisher",
                        str(publisher),
                        "--stable",
                        str(stable),
                        "--check",
                    ]
                )

    def test_canonical_manifest_requires_json_ints_and_unique_contracts(self):
        manifest = site_deployment.manifest_from_broadcast(self.broadcast())
        for key, value in (
            ("schemaVersion", "1"),
            ("chainId", "11155111"),
            ("deploymentBlock", "0x7b"),
            ("feeTier", "500"),
        ):
            with self.subTest(key=key):
                changed = copy.deepcopy(manifest)
                changed[key] = value
                with self.assertRaisesRegex(site_deployment.ManifestError, "integer"):
                    site_deployment._validate_manifest(changed)

        manifest["contracts"]["releaseStrategy"] = manifest["contracts"]["space"]
        with self.assertRaisesRegex(site_deployment.ManifestError, "unique"):
            site_deployment._validate_manifest(manifest)

    def test_rejects_incomplete_named_creates(self):
        broadcast = self.broadcast()
        broadcast["receipts"] = broadcast["receipts"][:-1]
        self.assert_broadcast_rejected(broadcast, "missing receipt")

        broadcast = self.broadcast()
        broadcast["receipts"][-1]["status"] = "0x0"
        self.assert_broadcast_rejected(broadcast, "named CREATE failed")

        broadcast = self.broadcast()
        broadcast["pending"] = [{"contractName": "FAOSepoliaSiteReleaseDeployment"}]
        self.assert_broadcast_rejected(broadcast, "pending")

    def test_rejects_unpinned_pool_identity(self):
        broadcast = self.broadcast()
        broadcast["receipts"][0]["logs"][0]["address"] = "0x" + "ab" * 20
        self.assert_broadcast_rejected(broadcast, "pinned Sepolia factory")

        broadcast = self.broadcast()
        broadcast["receipts"][0]["logs"][0]["topics"][2] = "0x" + "00" * 12 + "ee" * 20
        self.assert_broadcast_rejected(broadcast, "pinned Sepolia WETH")

        broadcast = self.broadcast()
        broadcast["receipts"][0]["logs"][0]["topics"][3] = "0x" + f"{3000:064x}"
        self.assert_broadcast_rejected(broadcast, "fee must be 500")

    def test_rejects_duplicate_or_malformed_events_and_addresses(self):
        broadcast = self.broadcast()
        broadcast["receipts"][0]["logs"].append(
            copy.deepcopy(broadcast["receipts"][0]["logs"][0])
        )
        self.assert_broadcast_rejected(broadcast, "found 2")

        broadcast = self.broadcast()
        broadcast["receipts"][-1]["logs"].append(
            copy.deepcopy(broadcast["receipts"][-1]["logs"][0])
        )
        self.assert_broadcast_rejected(broadcast, "found 2")

        broadcast = self.broadcast()
        broadcast["receipts"][-1]["logs"][0]["data"] = "0x00"
        self.assert_broadcast_rejected(broadcast, "192-byte")

        broadcast = self.broadcast()
        site_log = broadcast["receipts"][-1]["logs"][0]
        site_log["data"] = "0x" + "00" * 12 + "66" * 20 + site_log["data"][66:]
        self.assert_broadcast_rejected(broadcast, "unique")

        broadcast = self.broadcast()
        broadcast["receipts"][-1]["logs"][0]["address"] = "0x" + "ab" * 20
        self.assert_broadcast_rejected(broadcast, "unexpected emitter")

    def test_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"chain": 11155111, "chain": 1}', encoding="utf-8")
            with self.assertRaisesRegex(site_deployment.ManifestError, "duplicate JSON key"):
                site_deployment.load_json(path)


if __name__ == "__main__":
    unittest.main()
