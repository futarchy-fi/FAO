"""Read-only wind-tunnel index/replay/report CLI."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Optional, Sequence

from .funding import FundingError, validate_funding_manifest
from .indexer import Indexer, IndexerError, JsonRpc


def _emit(value: Any, output: Optional[Path]) -> None:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    if output is None:
        sys.stdout.buffer.write(raw)
    else:
        output.write_bytes(raw)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    index = sub.add_parser("index", help="index finalized logs without sending transactions")
    index.add_argument("--db", type=Path, required=True)
    index.add_argument("--rpc-url", required=True)
    index.add_argument("--start-block", type=int, required=True)
    index.add_argument("--registrar", action="append", required=True)
    index.add_argument("--output", type=Path)

    replay = sub.add_parser("replay", help="rebuild all derived state from canonical raw logs")
    replay.add_argument("--db", type=Path, required=True)
    replay.add_argument("--output", type=Path)

    report = sub.add_parser("report", help="print deterministic report evidence")
    report.add_argument("--db", type=Path, required=True)
    report.add_argument("--output", type=Path)

    funding = sub.add_parser("funding", help="validate a funding manifest without using keys")
    funding.add_argument("--manifest", type=Path, required=True)
    funding.add_argument("--output", type=Path)

    args = parser.parse_args(argv)
    if args.command == "funding":
        value = json.loads(args.manifest.read_text(encoding="utf-8"))
        _emit(validate_funding_manifest(value), args.output)
        return 0

    with Indexer(args.db) as windtunnel:
        if args.command == "index":
            windtunnel.sync(JsonRpc(args.rpc_url), args.start_block, args.registrar)
        elif args.command == "replay":
            windtunnel.replay()
        _emit(windtunnel.evidence(), args.output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FundingError, IndexerError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        raise SystemExit(1)
