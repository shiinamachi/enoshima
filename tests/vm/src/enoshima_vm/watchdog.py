from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

from .config import (
    WATCHDOG_CLEANUP_RETRY_SECONDS,
    WATCHDOG_FINALIZATION_SECONDS,
    WATCHDOG_READY_NAME,
    RuntimePaths,
)
from .errors import FailureCategory, VMError
from .libvirt_backend import LibvirtBackend
from .security import (
    confined_path,
    require_domain,
    require_run_id,
    run_cleanup_complete,
    run_record_lock,
)

WATCHDOG_POLL_SECONDS = 5
WATCHDOG_RECORD_RETRY_SECONDS = 1


def _run_dir(run_id: str, paths: RuntimePaths) -> Path:
    require_run_id(run_id)
    runs_root = paths.state / "runs"
    return confined_path(runs_root, runs_root / run_id)


def _atomic_write(path: Path, document: dict[str, object]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)


def _process_start_ticks() -> int:
    return int(Path("/proc/self/stat").read_text(encoding="utf-8").split()[21])


def _load_run_record(record_path: Path) -> dict[str, object]:
    try:
        raw = record_path.read_text(encoding="utf-8")
    except UnicodeError as error:
        raise RuntimeError("watchdog run record is not valid UTF-8") from error
    record = json.loads(raw)
    if not isinstance(record, dict):
        raise RuntimeError("watchdog run record is not a JSON object")
    return record


def publish_ready(
    run_id: str,
    uri: str,
    paths: RuntimePaths | None = None,
) -> Path:
    """Publish proof that this watchdog can inspect the recorded libvirt session."""
    paths = paths or RuntimePaths.discover()
    run_dir = _run_dir(run_id, paths)
    record_path = confined_path(run_dir, run_dir / "run.json")
    if not record_path.is_file():
        raise RuntimeError(f"watchdog run record is unavailable: {record_path}")
    record = _load_run_record(record_path)
    if record.get("run_id") != run_id:
        raise RuntimeError("watchdog run record id does not match its directory")
    require_domain(str(record.get("domain", "")))
    uuid.UUID(str(record.get("domain_uuid", "")))
    backend = LibvirtBackend(paths, uri)
    expected_session = backend.session_identity()
    if record.get("libvirt_session") != expected_session:
        raise VMError(
            FailureCategory.HOST_INFRA_ERROR,
            "watchdog run record belongs to a different or unknown libvirt session",
            {
                "recorded_session": record.get("libvirt_session"),
                "expected_session": expected_session,
            },
        )
    backend.virsh(["uri"], timeout=15)
    ready_path = confined_path(run_dir, run_dir / WATCHDOG_READY_NAME)
    _atomic_write(
        ready_path,
        {
            "schema": 1,
            "runId": run_id,
            "pid": os.getpid(),
            "pidStartTicks": _process_start_ticks(),
            "libvirtSession": expected_session,
            "readyAt": datetime.now(UTC).isoformat(),
        },
    )
    return ready_path


def run_finished(run_id: str, paths: RuntimePaths | None = None) -> bool:
    paths = paths or RuntimePaths.discover()
    run_dir = _run_dir(run_id, paths)
    record_path = confined_path(run_dir, run_dir / "run.json")
    if not record_path.is_file():
        raise FileNotFoundError(f"watchdog run record is unavailable: {record_path}")
    record = _load_run_record(record_path)
    return run_cleanup_complete(record)


def wait_and_expire(
    run_id: str,
    timeout_seconds: int,
    uri: str,
    paths: RuntimePaths | None = None,
    *,
    finalization_seconds: int = WATCHDOG_FINALIZATION_SECONDS,
    retry_seconds: float = WATCHDOG_CLEANUP_RETRY_SECONDS,
) -> bool:
    if timeout_seconds <= 0:
        raise ValueError("watchdog timeout must be positive")
    paths = paths or RuntimePaths.discover()
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            if run_finished(run_id, paths):
                return False
        except (OSError, json.JSONDecodeError, RuntimeError):
            # A transient record rename/read failure must not retire the only
            # deadline owner. Continue until the absolute expiry boundary.
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return expire_with_retry(
                run_id,
                uri,
                paths,
                finalization_seconds=finalization_seconds,
                retry_seconds=retry_seconds,
            )
        time.sleep(
            min(
                WATCHDOG_POLL_SECONDS,
                WATCHDOG_RECORD_RETRY_SECONDS,
                remaining,
            )
        )


def _write_cleanup_diagnostic(
    run_id: str,
    paths: RuntimePaths,
    attempt: int,
    error: Exception,
) -> None:
    run_dir = _run_dir(run_id, paths)
    diagnostic = confined_path(
        run_dir, run_dir / "artifacts" / "runner" / "watchdog-cleanup-error.json"
    )
    try:
        diagnostic.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _atomic_write(
            diagnostic,
            {
                "schema": 1,
                "runId": run_id,
                "attempt": attempt,
                "errorType": type(error).__name__,
                "message": str(error),
                "updatedAt": datetime.now(UTC).isoformat(),
            },
        )
    except OSError:
        # Preserve and retry the original cleanup failure even when evidence
        # storage is affected by the same transient host problem.
        pass


def expire_with_retry(
    run_id: str,
    uri: str,
    paths: RuntimePaths | None = None,
    *,
    finalization_seconds: int = WATCHDOG_FINALIZATION_SECONDS,
    retry_seconds: float = WATCHDOG_CLEANUP_RETRY_SECONDS,
) -> bool:
    """Retry expiry cleanup within the watchdog's bounded finalization window."""
    if finalization_seconds < 0 or retry_seconds < 0:
        raise ValueError("watchdog finalization and retry durations cannot be negative")
    paths = paths or RuntimePaths.discover()
    deadline = time.monotonic() + finalization_seconds
    attempt = 0
    retryable = (
        VMError,
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    )
    while True:
        attempt += 1
        try:
            return expire_run(run_id, uri, paths)
        except retryable as error:
            _write_cleanup_diagnostic(run_id, paths, attempt, error)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise
            time.sleep(min(retry_seconds, remaining))


def expire_run(run_id: str, uri: str, paths: RuntimePaths | None = None) -> bool:
    paths = paths or RuntimePaths.discover()
    run_dir = _run_dir(run_id, paths)
    record_path = confined_path(run_dir, run_dir / "run.json")
    with run_record_lock(run_dir, create=False) as acquired:
        if not acquired:
            raise FileNotFoundError(
                f"watchdog run lock is unavailable for {run_id}"
            )
        if not record_path.is_file():
            raise FileNotFoundError(
                f"watchdog run record is unavailable: {record_path}"
            )
        record = _load_run_record(record_path)
        if run_cleanup_complete(record):
            return False
        invalidated = record.get("status") == "invalidated"
        domain = require_domain(record["domain"])
        backend = LibvirtBackend(paths, uri)
        expected_session = backend.session_identity()
        if record.get("libvirt_session") != expected_session:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "watchdog run record belongs to a different or unknown libvirt "
                "session; preserving the domain and ephemeral storage",
                {
                    "recorded_session": record.get("libvirt_session"),
                    "expected_session": expected_session,
                },
            )
        backend.destroy(domain, str(record.get("domain_uuid", "")))
        for name in (
            "root.qcow2",
            "boot.qcow2",
            "seed.iso",
            WATCHDOG_READY_NAME,
        ):
            target = confined_path(run_dir, run_dir / name)
            target.unlink(missing_ok=True)
        for name in ("ssh", "cloud-init", "secrets", "swtpm"):
            target = confined_path(run_dir, run_dir / name)
            if target.exists():
                shutil.rmtree(target)
        passed = record.get("status") == "passed" and record.get("result") == "passed"
        if passed:
            record["status"] = "completed"
        elif not invalidated:
            record["status"] = "expired"
        if not passed and not invalidated:
            record["result"] = "failed"
            record["category"] = "HARNESS_ERROR"
            record["error"] = "maximum VM run duration exceeded"
        record["destroyed_at"] = datetime.now(UTC).isoformat()
        record["updated_at"] = datetime.now(UTC).isoformat()
        record.pop("private_key", None)
        record.pop("recovery_key", None)
        record.pop("login_password", None)
        _atomic_write(record_path, record)
        return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id")
    parser.add_argument("timeout_seconds", type=int)
    parser.add_argument("uri")
    args = parser.parse_args()
    publish_ready(args.run_id, args.uri)
    wait_and_expire(args.run_id, args.timeout_seconds, args.uri)


if __name__ == "__main__":
    main()
