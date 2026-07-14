from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import agent_documents as documents
from tools import agent_tournament as tournament
from tools import rehearsal_r0 as s1
from tools import rehearsal_r0_agents as agents


def _hash(byte: str = "a") -> str:
    return "0x" + byte * 64


def _payment(
    submission: dict,
    executor_before: int,
    recipient_before: int,
    *,
    tapped: bool,
    cumulative: int = 0,
    window_start: int = 0,
) -> dict:
    amount = int(submission["payment"]["amount"])
    recipient = submission["payment"]["recipient"]
    proposal_id = submission["proposalId"]
    value = {
        "amount": str(amount),
        "executorAfter": str(executor_before - amount),
        "executorBefore": str(executor_before),
        "recipientAfter": str(recipient_before + amount),
        "recipientBefore": str(recipient_before),
        "transactionHash": _hash("b"),
        "transferEvent": {
            "actionHash": "0x" + int(proposal_id).to_bytes(32, "big").hex(),
            "amount": str(amount),
            "asset": s1.WETH,
            "recipient": recipient,
        },
    }
    if tapped:
        value.update(
            {
                "recipient": recipient,
                "tap": {
                    "amount": str(amount),
                    "asset": s1.WETH,
                    "budget": str(200 * 10**15),
                    "spent": str(cumulative),
                    "windowStart": str(window_start),
                },
            }
        )
    else:
        value["tapSpentLogs"] = 0
    return value


def _fixture() -> dict:
    sealed = agents._sealed_s1()["economicProjection"]
    stack = sealed["stack"]
    addresses = stack["addresses"]
    index = "0x3000000000000000000000000000000000000001"
    agent_stack = {
        "chainId": s1.CHAIN_ID,
        "forkBlock": s1.FORK_BLOCK,
        "forkBlockHash": s1.FORK_BLOCK_HASH,
        "observationBlock": s1.FORK_BLOCK + 29,
        "startBlock": s1.FORK_BLOCK + 1,
        "startTimestamp": s1.FORK_TIMESTAMP,
        "asset": s1.WETH,
        "minActivationBond": 2 * agents.WAD,
        "index": index,
        "gateway": addresses["proposalGateway"],
        "arbitration": addresses["arbitration"],
        "vault": addresses["vault"],
        "executor": stack["executor"],
        "runtimeCodeKeccak256": {
            "index": _hash("1"),
            "gateway": stack["runtimeHashes"]["proposalGateway"],
            "arbitration": stack["runtimeHashes"]["arbitration"],
            "vault": stack["runtimeHashes"]["vault"],
            "executor": _hash("2"),
        },
    }
    blobs, submissions, graders = agents._offline_matrix(agent_stack)
    by_id = {item["id"]: item for item in submissions}
    tasks = {}
    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        tasks[task_id] = {
            "digest": publication["documentDigest"],
            "document": "0x" + publication["document"].hex(),
            "transactionHash": _hash("3"),
        }

    base = s1.FORK_TIMESTAMP
    transactions = []

    def transaction(timestamp: int, label: str | None = None, status: int = 1) -> None:
        item = {
            "blockNumber": s1.FORK_BLOCK + len(transactions) + 1,
            "blockTimestamp": timestamp,
            "blockHash": _hash("c"),
            "effectiveGasPriceWei": "1",
            "gasUsed": 10,
            "hash": "0x" + (len(transactions) + 1).to_bytes(32, "big").hex(),
            "status": status,
        }
        if label:
            item["label"] = label
        transactions.append(item)

    for offset in range(1, 7):
        transaction(base + offset)
    transaction(base + 7, "index:deploy")
    for offset in range(8, 85):
        transaction(base + offset, "padding:%d" % offset)
    transaction(base + 86_401, "sale:seal")
    for offset, task_id in enumerate(("T1", "T2", "T3"), 86_402):
        transaction(base + offset, "index:task:" + task_id)
    for offset, submission_id in enumerate(tournament.ROUND_ROBIN_IDS, 86_405):
        transaction(base + offset, "runner:propose:" + submission_id)
    for offset, label in enumerate(
        (
            "runner:publish-receipt:A-T2",
            "runner:publish-payment:A-T2",
            "runner:place-yes-bond:A-T2",
            "challenge:A-T2",
            "graduate:A-T2",
        ),
        86_411,
    ):
        transaction(base + offset, label)
    transaction(base + 433_841, "runner:execute:A-T1")
    transaction(base + 433_842, "runner:execute:A-T3")
    transaction(base + 433_843, "runner:execute:C-T3")
    transaction(base + 433_845, "evaluation:start-market:A-T2")
    transaction(base + 433_846, "negative:active-evaluation", 0)
    transaction(base + 1_038_646, "evaluation:resolve:A-T2")
    transaction(base + 1_038_647, "runner:queue:A-T2")
    transaction(base + 1_040_448, "flm:sync-back-to-spot:A-T2")
    transaction(base + 1_040_449, "runner:execute:A-T2")
    transaction(base + 1_125_049, "evaluation:start-market:B-T2")
    transaction(base + 1_729_850, "evaluation:resolve:B-T2")
    transaction(base + 1_729_851, "negative:queue-rejected:B-T2", 0)
    transaction(base + 1_731_652, "flm:sync-back-to-spot:B-T2")
    transaction(base + 1_731_654, "evaluation:start-market:C-T1")
    transaction(base + 2_336_455, "evaluation:resolve:C-T1")
    transaction(base + 2_336_456, "negative:queue-rejected:C-T1", 0)
    transaction(base + 2_338_257, "flm:sync-back-to-spot:C-T1")
    transactions[-1]["blockNumber"] += 14
    labeled = {item["label"]: item for item in transactions if item.get("label")}

    restart_pins = []
    action_hash = "0x" + int(by_id["A-T2"]["proposalId"]).to_bytes(32, "big").hex()
    for label, lifecycle, accepted, transaction_label, proposal_state in (
        ("publish-receipt", "RECEIPT_PUBLISHED", False, "runner:publish-receipt:A-T2", None),
        ("publish-payment", "PAYMENT_PUBLISHED", False, "runner:publish-payment:A-T2", None),
        ("propose", "PROPOSED", False, "runner:propose:A-T2", "INACTIVE"),
        ("place-yes-bond", "BONDED", False, "runner:place-yes-bond:A-T2", "YES"),
        ("challenged", "BONDED", False, "challenge:A-T2", "NO"),
        ("graduated", "BONDED", False, "graduate:A-T2", "QUEUED"),
        ("evaluating", "BONDED", False, "evaluation:start-market:A-T2", "EVALUATING"),
        ("evaluated", "ACCEPTED", True, "evaluation:resolve:A-T2", "SETTLED"),
        ("queued", "QUEUED", True, "runner:queue:A-T2", "SETTLED"),
        ("paid", "PAID", True, "runner:execute:A-T2", "SETTLED"),
    ):
        state = {
            "actionHash": action_hash,
            "lifecycle": lifecycle,
            "paid": label == "paid",
            "proposal": None if proposal_state is None else {"state": proposal_state},
            "queued": None,
        }
        record = labeled[transaction_label]
        restart_pins.append(
            {
                "accepted": accepted,
                "blockHash": record["blockHash"],
                "blockNumber": str(record["blockNumber"]),
                "label": label,
                "lifecycle": lifecycle,
                "stateSha256": "0x" + hashlib.sha256(agents.runner.canonical_json(state)).hexdigest(),
                "stateView": state,
            }
        )

    timeout_start = base + 433_841
    timeout_payments = {
        "A-T1": _payment(
            by_id["A-T1"], 1_200 * 10**15, 0, tapped=True, cumulative=1 * 10**15, window_start=timeout_start
        ),
        "A-T3": _payment(
            by_id["A-T3"], 1_199 * 10**15, 0, tapped=True, cumulative=4 * 10**15, window_start=timeout_start
        ),
        "C-T3": _payment(
            by_id["C-T3"], 1_196 * 10**15, 0, tapped=True, cumulative=10 * 10**15, window_start=timeout_start
        ),
    }
    for submission_id, payment in timeout_payments.items():
        payment["transactionHash"] = labeled["runner:execute:" + submission_id]["hash"]

    stage_times = {item["stage"]: item["timestamp"] for item in agents._absolute_clock_stages()}
    cycles = []
    for cycle_index, submission_id in enumerate(tournament.EVALUATION_IDS):
        accepted = submission_id == "A-T2"
        winner, loser = ("yes", "no") if accepted else ("no", "yes")
        anchor = stage_times[submission_id + ":anchor"]
        resolved = stage_times[submission_id + ":resolved"]
        restored = stage_times[submission_id + ":restored"]
        amount_out = 100 + cycle_index
        wrappers = {
            "yesCompany": "0x400000000000000000000000000000000000%04x" % (cycle_index * 4 + 1),
            "noCompany": "0x400000000000000000000000000000000000%04x" % (cycle_index * 4 + 2),
            "yesCurrency": "0x400000000000000000000000000000000000%04x" % (cycle_index * 4 + 3),
            "noCurrency": "0x400000000000000000000000000000000000%04x" % (cycle_index * 4 + 4),
        }
        pools = {
            "yesPool": "0x500000000000000000000000000000000000%04x" % (cycle_index * 2 + 1),
            "noPool": "0x500000000000000000000000000000000000%04x" % (cycle_index * 2 + 2),
        }
        official_pools = {}
        for label in ("yes", "no"):
            company_wrapper = wrappers[label + "Company"]
            currency_wrapper = wrappers[label + "Currency"]
            official_pools[label] = {
                "companyPoolBalance": "0",
                "companyTotalSupply": "0",
                "companyWrapper": company_wrapper,
                "currencyPoolBalance": "0",
                "currencyTotalSupply": "0",
                "currencyWrapper": currency_wrapper,
                "expectedInitialSqrtPriceX96": "100",
                "factoryPool": pools[label + "Pool"],
                "fee": s1.FEE,
                "liquidity": 0,
                "slot0": {"sqrtPriceX96": 100, "observationCardinalityNext": 120},
                "tickSpacing": 10,
                "token0": min(company_wrapper, currency_wrapper),
                "token1": max(company_wrapper, currency_wrapper),
            }
        outcomes = {"yesCompany": "0", "yesCurrency": "0", "noCompany": "0", "noCurrency": "0"}
        outcomes[loser + "Company"] = str(amount_out)
        proposal_id = by_id[submission_id]["proposalId"]
        result = {
            "accepted": accepted,
            "burnedNpmPositions": {
                "yes": {"ownerOfReverted": True, "tokenId": str(10 + cycle_index * 2)},
                "no": {"ownerOfReverted": True, "tokenId": str(11 + cycle_index * 2)},
            },
            "managerCurrentConditionOutcomes": outcomes,
            "managerLosingResidue": {
                "amount": str(amount_out),
                "outcome": loser.upper(),
                "roundingVsTraderOutput": "0",
                "token": addresses["companyToken"],
            },
            "negativeQueue": None,
            "payment": None,
            "payout": {
                "yes": "1" if accepted else "0",
                "no": "0" if accepted else "1",
                "denominator": "1",
            },
            "proposalId": proposal_id,
            "resolvedAt": resolved,
            "restore": {
                "restoredAt": restored,
                "traderUnderlying": {"1": "0"},
                "underlyingResidue": {addresses["router"]: {"1": "0"}},
            },
            "route": tournament.EXPECTED_ROUTES[submission_id],
            "runnerAcceptanceRoute": "evaluated",
            "twap": {
                "endAgo": 1,
                "noMeanTick": 0 if accepted else 30,
                "startAgo": 86_401,
                "timeout": 604_800,
                "window": 86_400,
                "windowEnd": anchor + 604_800,
                "yesMeanTick": 30 if accepted else 0,
            },
        }
        if accepted:
            result["payment"] = _payment(by_id[submission_id], 1_190 * 10**15, 3 * 10**15, tapped=False)
            result["payment"]["transactionHash"] = labeled["runner:execute:" + submission_id]["hash"]
        else:
            result["negativeQueue"] = {
                "before": {},
                "after": {},
                "recipient": by_id[submission_id]["payment"]["recipient"],
                "recipientBefore": "0",
                "recipientAfter": "0",
                "trace": {"returnValue": agents.ARBITRATION_NOT_ACCEPTED},
            }
        cycles.append(
            {
                "activeEvaluationNegative": (
                    {"before": {}, "after": {}, "trace": {"returnValue": agents.INVALID_STATE}}
                    if cycle_index == 0
                    else None
                ),
                "market": {
                    "anchorTimestamp": anchor,
                    "binding": pools,
                    "officialPoolsBeforeSync": official_pools,
                    "proposalId": proposal_id,
                    "wrappers": wrappers,
                },
                "migration": {
                    "liquidity": {"yes": "400", "no": "400"},
                    "npmIds": {"yes": 10 + cycle_index * 2, "no": 11 + cycle_index * 2},
                    "spotAfter": "200",
                    "spotBefore": "1000",
                    "trade": {
                        "amount": str(24 * agents.WAD // 10_000),
                        "amountOut": amount_out,
                        "loserTick": 0,
                        "winner": winner,
                        "winnerTickAfter": 30,
                        "winnerTickBefore": 0,
                    },
                },
                "result": result,
                "submission": submission_id,
            }
        )

    proposal_gas = [
        {
            "actor": by_id[submission_id]["agent"],
            "gasCostWei": "10",
            "gasUsed": "10",
            "proposalId": by_id[submission_id]["proposalId"],
            "submission": submission_id,
        }
        for submission_id in tournament.ROUND_ROBIN_IDS
    ]
    latencies = {
        submission_id: str(
            labeled[
                ("runner:execute:" if submission_id in tournament.PAID_IDS else "evaluation:resolve:")
                + submission_id
            ]["blockTimestamp"]
            - labeled["index:task:" + submission["taskId"]]["blockTimestamp"]
        )
        for submission_id, submission in by_id.items()
    }
    p2a_ids = sorted(item["proposalId"] for item in agents._p2a_proposal_bindings())
    hero_ids = sorted(item["proposalId"] for item in submissions)
    matrix = {
        "bondBefore": {name: str(amount) for name, amount in agents.CONTRIBUTIONS.items()},
        "challengeFacts": {
            submission_id: challenger
            for submission_id, challenger in tournament.EXPECTED_CHALLENGES.items()
            if challenger is not None
        },
        "crossStackProposalIds": {"hero": hero_ids, "p2a": p2a_ids, "intersection": []},
        "escrowAfterGraduation": str(718 * agents.WAD),
        "graders": graders,
        "graduation": {
            submission_id: {
                "queuePosition": str(index_ + 1),
                "requiredYesBond": str(100 * agents.WAD * (2**index_)),
            }
            for index_, submission_id in enumerate(tournament.EVALUATION_IDS)
        },
        "metrics": {
            "artifactQuality": {"agentA": "3/3", "agentB": "0/1", "agentC": "1/2"},
            "challengeRate": "3/6",
            "falsePaymentRate": "0/4",
            "proposalGas": proposal_gas,
            "simulatedChainCompletionLatencySeconds": latencies,
            "totalTreasurySpend": str(12 * 10**15),
        },
        "restartPins": restart_pins,
        "roundRobinTicks": [
            {"action": action, "agent": by_id[submission_id]["agent"], "submission": submission_id}
            for action in tournament.ROUND_ROBIN_ACTIONS
            for submission_id in tournament.ROUND_ROBIN_IDS
        ],
        "submissions": agents._reported_submissions(submissions, graders),
        "tasks": tasks,
    }
    projection = {
        "actorPreconditions": {
            name: {
                "address": address,
                "code": "0x",
                "nativeBalance": "0",
                "nonce": "0",
                "provenance": "house-wallet",
            }
            for name, address in agents.ACTORS.items()
        },
        "agentStack": agent_stack,
        "anvilStateMutations": [
            {
                "after": str(2_000 * agents.WAD),
                "before": "0",
                "kind": "native-balance",
                "purpose": "fund disposable Anvil gas and canonical WETH deposits",
                "target": address,
            }
            for address in agents.ACTORS.values()
        ]
        + [
            {
                "after": True,
                "before": False,
                "kind": "impersonation-mode",
                "purpose": "unlock fixed zero-nonce house actors without stored keys",
                "target": "anvil --auto-impersonate",
            }
        ],
        "artifactBlobs": {documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()},
        "artifacts": sealed["artifacts"],
        "bondLedger": {
            "contributions": {name: str(amount) for name, amount in agents.CONTRIBUTIONS.items()},
            "escrow": str(718 * agents.WAD),
            "withdrawable": {name: str(amount) for name, amount in agents.EXPECTED_WITHDRAWABLE.items()},
        },
        "chainId": s1.CHAIN_ID,
        "claims": {
            "externalWork": False,
            "demand": False,
            "liveDeployment": False,
            "livePayment": False,
            "shortfallOnHero": False,
            "wholeConditionClosure": False,
        },
        "clock": {"discipline": "absolute-precomputed", "stages": agents._absolute_clock_stages()},
        "continuity": {
            "s1EvidenceSha256": agents._file_sha256(agents.S1_EVIDENCE_PATH),
            "stackAndBootstrapExact": True,
        },
        "cycles": cycles,
        "fork": {
            "blockHash": s1.FORK_BLOCK_HASH,
            "blockNumber": s1.FORK_BLOCK,
            "selectedFromHead": s1.FORK_SELECTED_FROM_HEAD,
            "selectionRule": "finalized-head-minus-64-rounded-down-1000",
            "timestamp": s1.FORK_TIMESTAMP,
        },
        "graderPolicy": {
            "heroResolution": {
                "authority": "receipt-bound-production-market-pipeline",
                "houseTradeTarget": "objectiveCorrect AND original",
                "resolverInput": "strict 7-day/1-day TWAP inequality",
            },
            "sealedP2aArtifactPolicyReference": tournament.GRADER_POLICY,
        },
        "hero": {
            "bootstrap": sealed["bootstrap"],
            "executor": stack["executor"],
            "raise": sealed["raise"],
            "spotNft": int(sealed["bootstrap"]["spotNpmPosition"]["tokenId"]),
            "terminalPrice": int(sealed["bootstrap"]["terminalPrice"]),
        },
        "index": {"address": index, "authority": "none", "runtimeHash": _hash("1")},
        "inputs": {
            "driverSha256": agents._file_sha256(Path(agents.__file__)),
            "p2aProposalBindingsSha256": agents._p2a_proposal_bindings_sha256(),
            "scriptSha256": agents._file_sha256(agents.SCRIPT),
            "tournamentModuleSha256": agents._file_sha256(agents.ROOT / "tools/agent_tournament.py"),
        },
        "matrix": matrix,
        "publicBroadcasts": 0,
        "resources": {
            "blocks": transactions[-1]["blockNumber"] - transactions[0]["blockNumber"] + 1,
            "failedTransactions": 3,
            "gasUsed": sum(item["gasUsed"] for item in transactions),
            "transactions": len(transactions),
        },
        "shortfallDrill": {
            "status": "not-replayed-in-s3",
            "coverage": [
                "metadata/agent-work-p2a-evidence.json:drills.cT3Shortfall",
                "Rehearsal-R0-S6:critical-drain-S5-shortfall",
            ],
        },
        "stack": stack,
        "tapLedger": {
            "budget": str(200 * 10**15),
            "compositionBoundary": {
                "availableAfterLaterTransferSegment": str(40 * 10**15),
                "executedInS3": False,
                "laterTransferSegment": str(150 * 10**15),
                "stage": "S6",
            },
            "payments": timeout_payments,
            "remaining": str(190 * 10**15),
            "settledAtOrAfter": base + 347_435,
            "spent": str(10 * 10**15),
            "windowStart": timeout_start,
        },
        "transactions": transactions,
        "treasury": {
            "executorFinal": str(1_188 * 10**15),
            "executorInitial": str(1_200 * 10**15),
            "recipients": {
                "agentA": str(1 * 10**15),
                "workerA": str(5 * 10**15),
                "workerB": "0",
                "workerC1": "0",
                "workerC3": str(6 * 10**15),
            },
            "spent": str(12 * 10**15),
        },
    }
    return {
        "comparison": {
            "economicProjectionSha256": "0x" + hashlib.sha256(s1._canonical(projection)).hexdigest(),
            "excludedFields": list(agents.EXCLUDED_FIELDS),
            "identical": True,
        },
        "economicProjection": projection,
        "kind": "fao.rehearsal.r0-s3-evidence",
        "observations": [
            {"port": 19_675, "processId": 1, "providerUrl": "https://example.invalid", "wallDurationMs": 1},
            {"port": 19_676, "processId": 2, "providerUrl": "https://example.invalid", "wallDurationMs": 1},
        ],
        "publicBroadcasts": 0,
        "v": "1",
    }


def _seal_unchecked(path: Path, value: dict) -> None:
    raw = s1._canonical(value)
    path.write_bytes(raw)
    path.with_suffix(path.suffix + ".sha256").write_text(
        "0x" + hashlib.sha256(raw).hexdigest() + "\n", encoding="ascii"
    )


class RehearsalR0AgentsEvidenceTest(unittest.TestCase):
    def test_committed_evidence_and_sidecar_verify(self) -> None:
        expected = agents.EVIDENCE_PATH.with_suffix(".json.sha256").read_text(encoding="ascii").strip()
        self.assertEqual(agents.verify_evidence(), expected)

    def test_check_is_bytes_only_and_offline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "s3.json"
            digest = agents.write_evidence(path, _fixture())
            forbidden_hash = lambda _: (_ for _ in ()).throw(AssertionError("external hash called"))
            agents.documents.keccak256 = forbidden_hash
            for function in (
                agents.documents.document_digest,
                agents.documents.payment_transfer_action,
                agents.documents.transfer_hash,
                agents.documents.validate_payment_binding,
            ):
                function.__defaults__ = (forbidden_hash,)
            with mock.patch.object(agents, "run", side_effect=AssertionError("run called")), mock.patch.object(
                agents.subprocess, "run", side_effect=AssertionError("subprocess.run called")
            ), mock.patch.object(agents.subprocess, "Popen", side_effect=AssertionError("Popen called")):
                self.assertEqual(agents.main(("--check", "--output", str(path))), 0)
            self.assertEqual(digest, agents.verify_evidence(path))

    def test_exact_bytes_and_sidecar_are_both_required(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "s3.json"
            agents.write_evidence(path, _fixture())
            raw = path.read_bytes() + b" "
            path.write_bytes(raw)
            path.with_suffix(".json.sha256").write_text(
                "0x" + hashlib.sha256(raw).hexdigest() + "\n", encoding="ascii"
            )
            with self.assertRaises(agents.AgentsError):
                agents.verify_evidence(path)

    def test_ledger_cycle_clock_and_exclusion_tampering_fail(self) -> None:
        mutations = (
            lambda value: value["economicProjection"]["bondLedger"].update(escrow=str(718 * agents.WAD + 1)),
            lambda value: value["economicProjection"]["tapLedger"].update(spent="1"),
            lambda value: value["economicProjection"]["cycles"][0]["result"]["twap"].update(noMeanTick=30),
            lambda value: value["economicProjection"]["clock"]["stages"][0].update(
                timestamp=s1.FORK_TIMESTAMP + 7
            ),
            lambda value: value["economicProjection"]["hero"].update(providerUrl="excluded"),
        )
        with tempfile.TemporaryDirectory() as directory:
            for index, mutate in enumerate(mutations):
                with self.subTest(index=index):
                    value = copy.deepcopy(_fixture())
                    mutate(value)
                    value["comparison"]["economicProjectionSha256"] = "0x" + hashlib.sha256(
                        s1._canonical(value["economicProjection"])
                    ).hexdigest()
                    path = Path(directory) / ("tamper-%d.json" % index)
                    _seal_unchecked(path, value)
                    with self.assertRaises(agents.AgentsError):
                        agents.verify_evidence(path)

    def test_single_run_cannot_be_sealed(self) -> None:
        value = _fixture()
        value["comparison"]["identical"] = False
        value["observations"].pop()
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(agents.AgentsError):
            agents.write_evidence(Path(directory) / "single.json", value)


if __name__ == "__main__":
    unittest.main()
