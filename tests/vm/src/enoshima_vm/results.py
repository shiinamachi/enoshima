from __future__ import annotations

import hashlib
import json
import re
import subprocess
from enum import StrEnum
from typing import Any

from .errors import FailureCategory, VMError

MAX_SUMMARY_BYTES = 32 * 1024
MAX_EXCERPT_LINES = 80
MAX_EXCERPT_CHARS = 16 * 1024
MAX_LIST_ITEMS = 20


class FailureOrigin(StrEnum):
    PRODUCT = "PRODUCT"
    TEST_FIXTURE = "TEST_FIXTURE"
    INFRA = "INFRA"


INFRA_CATEGORIES = {
    FailureCategory.IMAGE_ERROR,
    FailureCategory.VM_BOOT_ERROR,
    FailureCategory.GUEST_AGENT_TIMEOUT,
    FailureCategory.SSH_TIMEOUT,
    FailureCategory.HOST_INFRA_ERROR,
}


def classify_failure(error: BaseException) -> FailureOrigin:
    if isinstance(error, (OSError, subprocess.SubprocessError, TimeoutError)):
        return FailureOrigin.INFRA
    if not isinstance(error, VMError):
        return FailureOrigin.TEST_FIXTURE
    if error.category in INFRA_CATEGORIES:
        return FailureOrigin.INFRA
    if error.category in {
        FailureCategory.HARNESS_ERROR,
        FailureCategory.UNMAPPED_RUNTIME_PATH,
    }:
        return FailureOrigin.TEST_FIXTURE
    return FailureOrigin.PRODUCT


def retryable_infrastructure_failure(record: dict[str, object]) -> bool:
    if record.get("failure_origin") != str(FailureOrigin.INFRA):
        return False
    if record.get("category") != str(FailureCategory.IMAGE_ERROR):
        return True
    message = str(record.get("error") or "").lower()
    integrity_failures = (
        "checksum mismatch",
        "invalid checksum response",
        "signature verification failed",
        "signature is required but missing",
        "signing keyring is unavailable",
        "has no checksum source",
    )
    return not any(fragment in message for fragment in integrity_failures)


def normalize_failure_text(value: str) -> str:
    text = value
    substitutions = (
        (
            r"(--(?:password|token|secret|credential|api[-_]?key)(?:=|\s+))\S+",
            r"\1<redacted>",
        ),
        (r"\b(Bearer)\s+\S+", r"\1 <redacted>"),
        (r"\benoshima-test-run-[0-9a-f]{12}\b", "<domain>"),
        (r"\brun-[0-9a-f]{12}\b", "<run>"),
        (
            r"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-]+(?:Z|[+-][0-9:]+)?\b",
            "<timestamp>",
        ),
        (r"\b(?:pid|PID)[=: ]+\d+\b", "pid=<pid>"),
        (r"127\.0\.0\.1:\d+", "127.0.0.1:<port>"),
        (r"\bport[=: ]+\d+\b", "port=<port>"),
        (r"/tmp/[A-Za-z0-9._/-]+", "/tmp/<path>"),
        (r"/var/tmp/[A-Za-z0-9._/-]+", "/var/tmp/<path>"),
        (r"\b[0-9a-f]{32,}\b", "<hex>"),
    )
    for pattern, replacement in substitutions:
        text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
    return " ".join(text.split())


def failure_fingerprint(
    *,
    suite: str,
    step: str | None,
    category: FailureCategory | str,
    message: str,
    details: dict[str, object] | None = None,
) -> str:
    stable_details: dict[str, object] = {}
    for key in ("assertion", "command", "exit_code", "file", "unit"):
        if details and key in details:
            value = details[key]
            stable_details[key] = (
                normalize_failure_text(value) if isinstance(value, str) else value
            )
    document = {
        "suite": suite,
        "step": step,
        "category": str(category),
        "message": normalize_failure_text(message),
        "details": stable_details,
    }
    payload = json.dumps(document, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


def failure_fields(
    *,
    suite: str,
    step: str | None,
    error: BaseException,
) -> dict[str, object]:
    if isinstance(error, VMError):
        category: FailureCategory | str = error.category
        message = error.message
        details = error.details
    else:
        category = (
            FailureCategory.HOST_INFRA_ERROR
            if isinstance(error, (OSError, subprocess.SubprocessError, TimeoutError))
            else FailureCategory.HARNESS_ERROR
        )
        message = str(error)
        details = None
    return {
        "failure_origin": str(classify_failure(error)),
        "failure_fingerprint": failure_fingerprint(
            suite=suite,
            step=step,
            category=category,
            message=message,
            details=details,
        ),
    }


def _bounded_excerpt(record: dict[str, Any]) -> str | None:
    parts = [str(record.get("error") or "")]
    details = record.get("details")
    if isinstance(details, dict):
        for key in (
            "stderr_tail",
            "stderr",
            "message",
            "missing",
            "checks",
            "log",
            "journal",
        ):
            value = details.get(key)
            if value:
                rendered = (
                    value
                    if isinstance(value, str)
                    else json.dumps(value, sort_keys=True, default=str)
                )
                parts.append(f"{key}: {rendered}")
    text = "\n".join(part for part in parts if part).strip()
    if not text:
        return None
    lines = text.splitlines()[:MAX_EXCERPT_LINES]
    excerpt = "\n".join(lines)
    if len(excerpt) > MAX_EXCERPT_CHARS:
        excerpt = excerpt[: MAX_EXCERPT_CHARS - 14] + "\n<truncated>"
    return excerpt


def _bounded_stream(value: object) -> str:
    text = str(value or "")
    excerpt = "\n".join(text.splitlines()[:MAX_EXCERPT_LINES])
    if len(excerpt) > MAX_EXCERPT_CHARS:
        excerpt = excerpt[: MAX_EXCERPT_CHARS - 14] + "\n<truncated>"
    return excerpt


def _shrink_text(value: str) -> str:
    if not value:
        return value
    if len(value) <= 32:
        return ""
    keep = max(0, len(value) // 2 - 14)
    return value[:keep] + "\n<truncated>"


def summarize_exec_result(
    result: dict[str, object],
    *,
    artifact_path: str,
) -> dict[str, object]:
    summary: dict[str, object] = {
        "schema": 1,
        "exitCode": result.get("exit_code"),
        "durationMs": result.get("duration_ms"),
        "stdoutExcerpt": _bounded_stream(result.get("stdout")),
        "stderrExcerpt": _bounded_stream(result.get("stderr")),
        "artifactPath": artifact_path,
    }
    while len(json.dumps(summary, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        candidates = [
            key
            for key in ("stdoutExcerpt", "stderrExcerpt")
            if isinstance(summary.get(key), str) and summary.get(key)
        ]
        if not candidates:
            break
        largest = max(candidates, key=lambda key: len(str(summary[key])))
        summary[largest] = _shrink_text(str(summary[largest]))
    if len(json.dumps(summary, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "bounded VM exec summary exceeded 32 KiB",
        )
    return summary


def summarize_run_record(record: dict[str, Any]) -> dict[str, object]:
    source = record.get("source") if isinstance(record.get("source"), dict) else {}
    failed_step = next(
        (
            step.get("action")
            for step in record.get("steps", [])
            if isinstance(step, dict) and step.get("status") == "failed"
        ),
        record.get("current_step") if record.get("result") == "failed" else None,
    )
    summary: dict[str, object] = {
        "schema": 1,
        "runId": record.get("run_id"),
        "run_id": record.get("run_id"),
        "suite": record.get("suite"),
        "mode": record.get("verification_mode", "release"),
        "result": record.get("result") or record.get("status"),
        "authoritative": bool(record.get("authoritative", False)),
        "freshOverlay": bool(record.get("fresh_overlay", True)),
        "sourceCommit": source.get("source_commit")
        or record.get("planned_source_commit"),
        "worktreeDigest": record.get("planned_worktree_digest")
        or source.get("worktree_hash"),
        "sourceTreeDigest": record.get("planned_source_tree_digest")
        or source.get("worktree_hash"),
        "uploadedSourceTreeDigest": source.get("worktree_hash"),
        "retryDigest": record.get("planned_retry_digest"),
        "currentStep": record.get("current_step"),
        "currentStepIndex": record.get("current_step_index"),
        "completedSteps": sum(
            1
            for step in record.get("steps", [])
            if isinstance(step, dict) and step.get("status") == "passed"
        ),
        "domainState": record.get("domain_state"),
        "failedStep": failed_step,
        "category": record.get("category"),
        "failureOrigin": record.get("failure_origin"),
        "failureFingerprint": record.get("failure_fingerprint"),
        "artifactRoot": record.get("artifact_dir"),
        "nextVerification": record.get("next_verification"),
    }
    excerpt = _bounded_excerpt(record)
    if excerpt:
        summary["errorExcerpt"] = excerpt
    summary = {key: value for key, value in summary.items() if value is not None}
    while len(
        json.dumps(summary, sort_keys=True).encode()
    ) > MAX_SUMMARY_BYTES and summary.get("errorExcerpt"):
        summary["errorExcerpt"] = _shrink_text(str(summary["errorExcerpt"]))
    if len(json.dumps(summary, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "bounded VM summary exceeded 32 KiB",
        )
    return summary


def summarize_run_list(
    records: list[dict[str, Any]],
    *,
    limit: int = MAX_LIST_ITEMS,
    cursor: str | None = None,
) -> dict[str, object]:
    if not 1 <= limit <= MAX_LIST_ITEMS:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"VM run-list limit must be between 1 and {MAX_LIST_ITEMS}",
        )
    start = 0
    if cursor is not None:
        for index, record in enumerate(records):
            if record.get("run_id") == cursor:
                start = index + 1
                break
        else:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"unknown VM run-list cursor: {cursor}",
            )
    requested = limit
    summaries: list[dict[str, object]] = []
    page = records[start : start + requested]
    for record in page:
        summary = summarize_run_record(record)
        candidate_runs = [*summaries, summary]
        candidate: dict[str, object] = {
            "schema": 1,
            "runs": candidate_runs,
            "total": len(records),
            "returned": len(candidate_runs),
            "truncated": start + len(candidate_runs) < len(records),
        }
        if cursor is not None:
            candidate["cursor"] = cursor
        if len(json.dumps(candidate, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
            summary.pop("errorExcerpt", None)
            candidate_runs = [*summaries, summary]
            candidate["runs"] = candidate_runs
        if len(json.dumps(candidate, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
            break
        summaries.append(summary)
    consumed = len(summaries)
    truncated = start + consumed < len(records)
    envelope: dict[str, object] = {
        "schema": 1,
        "runs": summaries,
        "total": len(records),
        "returned": consumed,
        "truncated": truncated,
    }
    if cursor is not None:
        envelope["cursor"] = cursor
    if truncated and summaries:
        envelope["nextCursor"] = summaries[-1].get("runId")
    if len(json.dumps(envelope, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "bounded VM run list exceeded 32 KiB",
        )
    return envelope


def bound_verification_plan(document: dict[str, object]) -> dict[str, object]:
    if len(json.dumps(document, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES:
        return document
    changed_paths = list(document.get("changedPaths", []))
    reasons = document.get("reasons")
    reason_mapping = reasons if isinstance(reasons, dict) else {}
    bounded = dict(document)
    bounded["truncated"] = True
    bounded["changedPathCount"] = len(changed_paths)
    bounded_paths = changed_paths[:50]
    bounded["changedPaths"] = bounded_paths
    bounded["reasonTargetCount"] = len(reason_mapping)
    bounded["reasons"] = {
        str(target): list(values)[:2]
        for target, values in list(reason_mapping.items())[:30]
        if isinstance(values, (list, tuple))
    }
    while (
        len(json.dumps(bounded, sort_keys=True).encode()) > MAX_SUMMARY_BYTES
        and bounded_paths
    ):
        bounded_paths.pop()
    while len(json.dumps(bounded, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        bounded_reasons = bounded["reasons"]
        if not isinstance(bounded_reasons, dict) or not bounded_reasons:
            break
        bounded_reasons.pop(next(reversed(bounded_reasons)))
    if len(json.dumps(bounded, sort_keys=True).encode()) > MAX_SUMMARY_BYTES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "bounded verification plan exceeded 32 KiB",
        )
    return bounded
