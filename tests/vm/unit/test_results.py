from __future__ import annotations

import json
import subprocess

import pytest

from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.results import (
    MAX_EXCERPT_LINES,
    MAX_SUMMARY_BYTES,
    FailureOrigin,
    bound_verification_plan,
    classify_failure,
    failure_fingerprint,
    normalize_failure_text,
    retryable_infrastructure_failure,
    summarize_exec_result,
    summarize_run_list,
    summarize_run_record,
)


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (VMError(FailureCategory.IMAGE_ERROR, "image"), FailureOrigin.INFRA),
        (
            VMError(FailureCategory.HOST_INFRA_ERROR, "libvirt"),
            FailureOrigin.INFRA,
        ),
        (OSError("filesystem unavailable"), FailureOrigin.INFRA),
        (
            subprocess.CalledProcessError(1, ["hyprctl"]),
            FailureOrigin.INFRA,
        ),
        (
            VMError(FailureCategory.HARNESS_ERROR, "fixture"),
            FailureOrigin.TEST_FIXTURE,
        ),
        (
            VMError(FailureCategory.VALIDATION_FAILED, "product"),
            FailureOrigin.PRODUCT,
        ),
        (RuntimeError("unexpected fixture error"), FailureOrigin.TEST_FIXTURE),
    ],
)
def test_failure_origin_classification(
    error: BaseException, expected: FailureOrigin
) -> None:
    assert classify_failure(error) is expected


def test_failure_fingerprint_normalizes_ephemeral_values() -> None:
    secret_a = "a" * 64
    secret_b = "b" * 64
    message_a = (
        "failed at 2026-08-05T01:02:03Z for run-aaaaaaaaaaaa "
        "on enoshima-test-run-bbbbbbbbbbbb pid=123 endpoint 127.0.0.1:45001 "
        f"port=45001 temp /tmp/enoshima-a/state secret {secret_a}"
    )
    message_b = (
        "failed at 2026-08-06T11:12:13Z for run-cccccccccccc "
        "on enoshima-test-run-dddddddddddd pid=987 endpoint 127.0.0.1:55002 "
        f"port=55002 temp /tmp/enoshima-b/state secret {secret_b}"
    )
    details_a: dict[str, object] = {
        "command": f"connect 127.0.0.1:45001 --token {secret_a}",
        "exit_code": 1,
        "stderr": "raw log A is deliberately excluded",
    }
    details_b: dict[str, object] = {
        "command": f"connect 127.0.0.1:55002 --token {secret_b}",
        "exit_code": 1,
        "stderr": "raw log B is deliberately excluded",
    }

    normalized = normalize_failure_text(message_a)
    assert normalized == normalize_failure_text(message_b)
    assert "2026-08-05" not in normalized
    assert "45001" not in normalized
    assert secret_a not in normalized
    assert failure_fingerprint(
        suite="smoke",
        step="wait_for_ssh",
        category=FailureCategory.SSH_TIMEOUT,
        message=message_a,
        details=details_a,
    ) == failure_fingerprint(
        suite="smoke",
        step="wait_for_ssh",
        category=FailureCategory.SSH_TIMEOUT,
        message=message_b,
        details=details_b,
    )


def test_failure_fingerprint_normalizes_secret_arguments() -> None:
    first = failure_fingerprint(
        suite="smoke",
        step="upload",
        category=FailureCategory.HOST_INFRA_ERROR,
        message="request failed --token first-secret Authorization: Bearer alpha",
        details={"command": "client --password first-password"},
    )
    second = failure_fingerprint(
        suite="smoke",
        step="upload",
        category=FailureCategory.HOST_INFRA_ERROR,
        message="request failed --token second-secret Authorization: Bearer beta",
        details={"command": "client --password second-password"},
    )

    assert first == second


def test_image_integrity_failure_is_not_retryable() -> None:
    assert not retryable_infrastructure_failure(
        {
            "failure_origin": "INFRA",
            "category": "IMAGE_ERROR",
            "error": "IMAGE_ERROR: checksum mismatch for arch",
        }
    )
    assert retryable_infrastructure_failure(
        {
            "failure_origin": "INFRA",
            "category": "IMAGE_ERROR",
            "error": "IMAGE_ERROR: cannot download checksum for arch",
        }
    )


def _failed_record(error: str) -> dict[str, object]:
    return {
        "run_id": "run-012345abcdef",
        "suite": "smoke",
        "verification_mode": "checkpoint",
        "result": "failed",
        "authoritative": True,
        "fresh_overlay": True,
        "source": {"source_commit": "f" * 40, "worktree_hash": "e" * 64},
        "steps": [
            {"action": "wait_for_ssh", "status": "passed"},
            {"action": "run_validate", "status": "failed"},
        ],
        "category": "VALIDATION_FAILED",
        "failure_origin": "PRODUCT",
        "failure_fingerprint": "sha256:" + "d" * 64,
        "artifact_dir": "/tmp/enoshima/artifacts/run-012345abcdef",
        "next_verification": "checkpoint:smoke",
        "error": error,
    }


def test_run_summary_excerpt_is_limited_to_eighty_lines() -> None:
    error = "\n".join(f"line-{index:03d}" for index in range(200))

    summary = summarize_run_record(_failed_record(error))
    excerpt = str(summary["errorExcerpt"])

    assert len(excerpt.splitlines()) == MAX_EXCERPT_LINES
    assert excerpt.splitlines()[-1] == "line-079"


def test_run_summary_is_bounded_to_thirty_two_kibibytes() -> None:
    error = "\n".join(f"line-{index:03d}-" + "x" * 1000 for index in range(200))

    summary = summarize_run_record(_failed_record(error))
    encoded = json.dumps(summary, sort_keys=True).encode()

    assert len(encoded) <= MAX_SUMMARY_BYTES
    assert len(str(summary["errorExcerpt"]).splitlines()) <= MAX_EXCERPT_LINES
    assert str(summary["errorExcerpt"]).endswith("<truncated>")


def test_run_summary_adapts_to_multibyte_json_expansion() -> None:
    summary = summarize_run_record(_failed_record("실패" * 12000))

    assert len(json.dumps(summary, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES


def test_run_list_has_an_aggregate_bound() -> None:
    records = [
        _failed_record("\n".join("x" * 500 for _ in range(80))) for _ in range(30)
    ]
    for index, record in enumerate(records):
        record["run_id"] = f"run-{index:012x}"

    summary = summarize_run_list(records)

    assert len(summary["runs"]) <= 20
    assert summary["total"] == 30
    assert summary["truncated"] is True
    assert summary["nextCursor"] == summary["runs"][-1]["runId"]
    assert len(json.dumps(summary, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES


def test_run_list_cursor_returns_the_next_newest_page() -> None:
    records = [_failed_record(f"failure {index}") for index in range(5)]
    for index, record in enumerate(records):
        record["run_id"] = f"run-{index:012x}"

    first = summarize_run_list(records, limit=2)
    second = summarize_run_list(
        records,
        limit=2,
        cursor=str(first["nextCursor"]),
    )

    assert [run["runId"] for run in first["runs"]] == [
        "run-000000000000",
        "run-000000000001",
    ]
    assert [run["runId"] for run in second["runs"]] == [
        "run-000000000002",
        "run-000000000003",
    ]


def test_large_verification_plan_is_bounded() -> None:
    plan: dict[str, object] = {
        "schema": 1,
        "changedPaths": [f"scripts/{index:04d}-" + "x" * 200 for index in range(500)],
        "reasons": {
            f"target-{index}": ["reason-" + "y" * 500 for _ in range(10)]
            for index in range(100)
        },
    }

    bounded = bound_verification_plan(plan)

    assert bounded["truncated"] is True
    assert bounded["changedPathCount"] == 500
    assert len(json.dumps(bounded, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES


def test_exec_summary_is_bounded_and_points_to_raw_artifact() -> None:
    result: dict[str, object] = {
        "exit_code": 1,
        "duration_ms": 123,
        "stdout": "\n".join("out-" + "x" * 500 for _ in range(200)),
        "stderr": "\n".join("err-" + "y" * 500 for _ in range(200)),
    }

    summary = summarize_exec_result(result, artifact_path="/artifacts/manual.log")

    assert summary["artifactPath"] == "/artifacts/manual.log"
    assert len(str(summary["stdoutExcerpt"]).splitlines()) <= MAX_EXCERPT_LINES
    assert len(str(summary["stderrExcerpt"]).splitlines()) <= MAX_EXCERPT_LINES
    assert len(json.dumps(summary, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES


def test_exec_summary_adapts_to_multibyte_json_expansion() -> None:
    summary = summarize_exec_result(
        {
            "exit_code": 1,
            "duration_ms": 123,
            "stdout": "한" * 12000,
            "stderr": "글" * 12000,
        },
        artifact_path="/artifacts/manual-unicode.log",
    )

    assert summary["artifactPath"] == "/artifacts/manual-unicode.log"
    assert len(json.dumps(summary, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES
