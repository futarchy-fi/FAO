from __future__ import annotations

import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tools import fao_metadata


def manifest() -> dict:
    return {
        "schemaVersion": 1,
        "status": "active",
        "network": "sepolia",
        "chainId": fao_metadata.CHAIN_ID,
        "deploymentTransaction": "0x" + "ab" * 32,
        "deploymentBlock": 123,
        "deployer": "0x" + "11" * 20,
        "currencyToken": "0x" + "22" * 20,
        "feeTier": 500,
        "contracts": {
            key: f"0x{index:040x}"
            for index, key in enumerate(fao_metadata.CONTRACTS, start=1)
        },
    }


class Gateway(BaseHTTPRequestHandler):
    responses: dict[str, bytes] = {}
    names_by_bytes: dict[bytes, str] = {}
    posted: list[str] = []
    mismatch_name: str | None = None

    def do_GET(self) -> None:
        cid = self.path.removeprefix("/ipfs/")
        if cid == getattr(self.server, "reject_cid", None):
            self.send_error(415)
            return
        body = self.responses.get(cid)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        data = fao_metadata._json_bytes(request["params"])
        name = self.names_by_bytes[data]
        self.posted.append(name)
        cid = fao_metadata._raw_uri(data).removeprefix("ipfs://")
        self.responses[cid] = data
        returned_cid = (
            fao_metadata._raw_uri(b"wrong").removeprefix("ipfs://")
            if name == self.mismatch_name
            else cid
        )
        response = fao_metadata._json_bytes(
            {
                "jsonrpc": "2.0",
                "result": {"provider": "mock", "cid": returned_cid, "size": len(data)},
                "id": request["id"],
            }
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format: str, *args: object) -> None:
        pass


class MetadataTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.out = Path(self.temporary.name)
        self.avatar = b"avatar"
        self.avatar_uri = fao_metadata._raw_uri(self.avatar)
        Gateway.responses = {}
        Gateway.names_by_bytes = {}
        Gateway.posted = []
        Gateway.mismatch_name = None

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_build_is_deterministic_and_canonical(self) -> None:
        bundle = fao_metadata.build_bundle(manifest(), self.avatar_uri, self.out)
        first = {path.name: path.read_bytes() for path in self.out.iterdir()}
        fao_metadata.build_bundle(manifest(), self.avatar_uri, self.out, check=True)

        self.assertEqual(set(first), {*fao_metadata.FILES, "bundle.json"})
        self.assertEqual(bundle["externalURIs"], {"avatar": self.avatar_uri})
        self.assertEqual(
            bundle["files"]["always-zero-voting-strategy.json"]["uri"],
            "ipfs://bafkreidrtlsjgiarzgjb76opphwgu7flqanrxcijqbh7o3ycefzqz22hs4",
        )
        self.assertTrue(all(not data.endswith(b"\n") for data in first.values()))
        self.assertEqual(
            bundle["deploymentURIs"]["daoURI"], bundle["files"]["dao.json"]["uri"]
        )
        space = json.loads(first["space.json"])
        self.assertEqual(space["properties"]["execution_strategies_types"], [
            "SXArbitrationExecutionStrategy"
        ])
        self.assertEqual(space["properties"]["execution_destinations"], [""])
        self.assertEqual(json.loads(first["members.json"])["members"], [])
        self.assertIn(
            "There is no voting.", json.loads(first["governance.json"])["description"]
        )

    def test_predicted_release_build_needs_no_candidate_schema(self) -> None:
        out = self.out / "predicted"
        release = manifest()["contracts"]["releaseStrategy"]
        bundle = fao_metadata.build_predicted_bundle(release, self.avatar_uri, out)

        self.assertEqual(tuple(bundle["files"]), fao_metadata.CANDIDATE_FILES)
        self.assertNotIn("contracts.json", bundle["files"])
        self.assertNotIn("contractsURI", json.loads((out / "dao.json").read_bytes()))
        space = json.loads((out / "space.json").read_bytes())
        self.assertEqual(
            space["properties"]["execution_strategies"],
            [fao_metadata._checksum_address(release)],
        )
        loaded, _ = fao_metadata._bundle(out / "bundle.json")
        self.assertEqual(tuple(loaded["files"]), fao_metadata.CANDIDATE_FILES)
        fao_metadata.build_predicted_bundle(
            release, self.avatar_uri, out, check=True
        )

    def test_rejects_noncanonical_inputs_and_execution_arrays(self) -> None:
        bad_manifest = manifest()
        bad_manifest["extra"] = True
        with self.assertRaisesRegex(fao_metadata.MetadataError, "exactly"):
            fao_metadata.build_bundle(bad_manifest, self.avatar_uri, self.out)
        with self.assertRaisesRegex(fao_metadata.MetadataError, "ipfs"):
            fao_metadata.build_bundle(manifest(), "https://example.test/avatar", self.out)

        documents = fao_metadata._documents(manifest(), self.avatar_uri)
        space = json.loads(documents["space.json"])
        space["properties"]["execution_strategies_types"] = []
        documents["space.json"] = fao_metadata._json_bytes(space)
        with self.assertRaisesRegex(fao_metadata.MetadataError, "execution arrays"):
            fao_metadata._validate_documents(documents, self.avatar_uri)

    def test_preflight_uses_exact_gateway_bytes(self) -> None:
        bundle = fao_metadata.build_bundle(manifest(), self.avatar_uri, self.out)
        Gateway.responses = {
            entry["uri"].removeprefix("ipfs://"): (self.out / name).read_bytes()
            for name, entry in bundle["files"].items()
        }
        Gateway.responses[self.avatar_uri.removeprefix("ipfs://")] = self.avatar
        server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        gateway = f"http://127.0.0.1:{server.server_port}/ipfs/{{cid}}"
        try:
            self.assertEqual(
                fao_metadata.preflight_bundle(
                    self.out / "bundle.json", [gateway], [gateway], timeout=2
                ),
                len(fao_metadata.FILES) + 1,
            )
            first_cid = next(iter(Gateway.responses))
            Gateway.responses[first_cid] = b"tampered"
            with self.assertRaisesRegex(fao_metadata.MetadataError, "do not match"):
                fao_metadata.preflight_bundle(
                    self.out / "bundle.json", [gateway], [gateway], timeout=2
                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_pin_posts_canonical_json_in_dependency_order_and_checks_cids(self) -> None:
        bundle = fao_metadata.build_bundle(manifest(), self.avatar_uri, self.out)
        Gateway.names_by_bytes = {
            (self.out / name).read_bytes(): name for name in bundle["files"]
        }
        Gateway.responses = {self.avatar_uri.removeprefix("ipfs://"): self.avatar}
        server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f"http://127.0.0.1:{server.server_port}/"
        bundle_bytes = (self.out / "bundle.json").read_bytes()
        try:
            self.assertEqual(
                fao_metadata.pin_bundle(
                    self.out / "bundle.json",
                    endpoint,
                    avatar_gateways=[endpoint],
                    timeout=2,
                ),
                (len(fao_metadata.FILES), len(fao_metadata.FILES) + 1),
            )
            self.assertEqual(Gateway.posted, list(bundle["files"]))
            self.assertEqual(Gateway.posted[-1], "dao.json")

            Gateway.posted = []
            Gateway.mismatch_name = fao_metadata.FILES[0]
            with self.assertRaisesRegex(fao_metadata.MetadataError, "CID mismatch"):
                fao_metadata.pin_bundle(
                    self.out / "bundle.json",
                    endpoint,
                    avatar_gateways=[endpoint],
                    timeout=2,
                )
            self.assertEqual(Gateway.posted, [fao_metadata.FILES[0]])
            self.assertEqual((self.out / "bundle.json").read_bytes(), bundle_bytes)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_json_gateway_415_for_avatar_uses_separate_avatar_gateway(self) -> None:
        bundle = fao_metadata.build_bundle(manifest(), self.avatar_uri, self.out)
        Gateway.responses = {
            entry["uri"].removeprefix("ipfs://"): (self.out / name).read_bytes()
            for name, entry in bundle["files"].items()
        }
        Gateway.names_by_bytes = {
            (self.out / name).read_bytes(): name for name in bundle["files"]
        }
        avatar_cid = self.avatar_uri.removeprefix("ipfs://")
        Gateway.responses[avatar_cid] = self.avatar
        json_server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        json_server.reject_cid = avatar_cid
        avatar_server = ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        json_thread = threading.Thread(target=json_server.serve_forever, daemon=True)
        avatar_thread = threading.Thread(target=avatar_server.serve_forever, daemon=True)
        json_thread.start()
        avatar_thread.start()
        json_endpoint = f"http://127.0.0.1:{json_server.server_port}/"
        json_gateway = f"{json_endpoint}ipfs/{{cid}}"
        avatar_gateway = f"http://127.0.0.1:{avatar_server.server_port}/ipfs/{{cid}}"
        try:
            self.assertEqual(
                fao_metadata.pin_bundle(
                    self.out / "bundle.json",
                    json_endpoint,
                    avatar_gateways=[json_gateway, avatar_gateway],
                    timeout=2,
                ),
                (len(fao_metadata.FILES), len(fao_metadata.FILES) + 1),
            )
        finally:
            json_server.shutdown()
            avatar_server.shutdown()
            json_server.server_close()
            avatar_server.server_close()
            json_thread.join()
            avatar_thread.join()


if __name__ == "__main__":
    unittest.main()
