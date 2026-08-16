from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

import pytest

from enoshima_vm import watchdog as watchdog_module
from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.libvirt_backend import LibvirtBackend
from enoshima_vm.watchdog import (
    expire_run,
    expire_with_retry,
    publish_ready,
    run_finished,
    wait_and_expire,
)


def _running_record(paths: RuntimePaths, run_id: str) -> tuple[Path, dict[str, object]]:
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    backend = LibvirtBackend(paths)
    record: dict[str, object] = {
        "run_id": run_id,
        "domain": f"enoshima-test-{run_id}",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "running",
        "libvirt_session": backend.session_identity(),
    }
    (run_dir / "run.json").write_text(json.dumps(record), encoding="utf-8")
    return run_dir, record


def test_publish_ready_only_after_libvirt_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir, record = _running_record(paths, run_id)
    ready = run_dir / ".watchdog-ready.json"
    observed: list[tuple[str, ...]] = []

    def virsh(_self, args, **_kwargs):
        assert not ready.exists()
        observed.append(tuple(args))
        return type("Result", (), {"stdout": "qemu:///session\n"})()

    monkeypatch.setattr(LibvirtBackend, "virsh", virsh)

    assert publish_ready(run_id, "qemu:///session", paths) == ready

    document = json.loads(ready.read_text(encoding="utf-8"))
    assert observed == [("uri",)]
    assert document["runId"] == run_id
    assert document["pid"] == os.getpid()
    assert document["libvirtSession"] == record["libvirt_session"]
    assert ready.stat().st_mode & 0o777 == 0o600


def test_watchdog_retries_cleanup_within_finalization_budget(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir, _record = _running_record(paths, run_id)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    attempts: list[int] = []

    def destroy(_self, _domain, _domain_uuid):
        attempts.append(len(attempts) + 1)
        if len(attempts) == 1:
            raise VMError(FailureCategory.HOST_INFRA_ERROR, "libvirt unavailable")

    monkeypatch.setattr(LibvirtBackend, "destroy", destroy)

    assert expire_with_retry(
        run_id,
        "qemu:///session",
        paths,
        finalization_seconds=1,
        retry_seconds=0,
    )

    assert attempts == [1, 2]
    assert not overlay.exists()
    assert json.loads((run_dir / "run.json").read_text())["status"] == "expired"
    assert (
        run_dir / "artifacts" / "runner" / "watchdog-cleanup-error.json"
    ).is_file()


def test_watchdog_exhausts_cleanup_retry_budget(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir, _record = _running_record(paths, run_id)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    ticks = iter((0.0, 0.0, 1.0))
    attempts: list[int] = []
    monkeypatch.setattr(watchdog_module.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(watchdog_module.time, "sleep", lambda _seconds: None)

    def destroy(_self, _domain, _domain_uuid):
        attempts.append(len(attempts) + 1)
        raise VMError(FailureCategory.HOST_INFRA_ERROR, "libvirt unavailable")

    monkeypatch.setattr(LibvirtBackend, "destroy", destroy)

    with pytest.raises(VMError, match="libvirt unavailable"):
        expire_with_retry(
            run_id,
            "qemu:///session",
            paths,
            finalization_seconds=0.5,
            retry_seconds=0.1,
        )

    assert attempts == [1, 2]
    assert overlay.is_file()
    assert json.loads((run_dir / "run.json").read_text())["status"] == "running"
    diagnostic = json.loads(
        (
            run_dir / "artifacts" / "runner" / "watchdog-cleanup-error.json"
        ).read_text()
    )
    assert diagnostic["attempt"] == 2


def test_watchdog_ignores_completed_runs(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_dir = paths.state / "runs" / "run-012345abcdef"
    run_dir.mkdir(parents=True)
    record = {
        "run_id": "run-012345abcdef",
        "domain": "enoshima-test-run-012345abcdef",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "completed",
    }
    (run_dir / "run.json").write_text(json.dumps(record), encoding="utf-8")
    assert expire_run(record["run_id"], "qemu:///session", paths) is False
    assert json.loads((run_dir / "run.json").read_text())["status"] == "completed"


def test_watchdog_exits_immediately_for_a_destroyed_run(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_dir = paths.state / "runs" / "run-012345abcdef"
    run_dir.mkdir(parents=True)
    (run_dir / "run.json").write_text(
        json.dumps({"status": "destroyed"}), encoding="utf-8"
    )

    assert run_finished("run-012345abcdef", paths)
    assert not wait_and_expire(
        "run-012345abcdef", 60, "qemu:///session", paths
    )


def test_watchdog_cleans_an_invalidated_run_without_overwriting_evidence(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_dir = paths.state / "runs" / "run-012345abcdef"
    run_dir.mkdir(parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"preserved diagnostic")
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "run_id": "run-012345abcdef",
                "domain": "enoshima-test-run-012345abcdef",
                "domain_uuid": "12345678-1234-5678-1234-567812345678",
                "status": "invalidated",
                "result": "failed",
                "category": "SOURCE_INVALIDATED",
                "error": "source changed",
                "libvirt_session": LibvirtBackend(paths).session_identity(),
            }
        ),
        encoding="utf-8",
    )

    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        LibvirtBackend,
        "destroy",
        lambda _self, domain, domain_uuid: calls.append((domain, domain_uuid)),
    )

    assert not run_finished("run-012345abcdef", paths)
    assert expire_run("run-012345abcdef", "qemu:///session", paths)

    updated = json.loads((run_dir / "run.json").read_text())
    assert updated["status"] == "invalidated"
    assert updated["result"] == "failed"
    assert updated["category"] == "SOURCE_INVALIDATED"
    assert updated["error"] == "source changed"
    assert "destroyed_at" in updated
    assert run_finished("run-012345abcdef", paths)
    assert not overlay.exists()
    assert calls == [(updated["domain"], updated["domain_uuid"])]


def test_watchdog_never_treats_a_missing_run_as_finished(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")

    with pytest.raises(FileNotFoundError, match="run record is unavailable"):
        run_finished("run-012345abcdef", paths)


@pytest.mark.parametrize("document", (b"\xff", b"[]"))
def test_watchdog_rejects_unreadable_or_nonobject_run_records(
    tmp_path: Path, document: bytes
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    (run_dir / "run.json").write_bytes(document)

    with pytest.raises(RuntimeError, match="UTF-8|JSON object"):
        run_finished(run_id, paths)


@pytest.mark.parametrize("transient", (None, b"\xff", b"[]"))
def test_watchdog_retries_transient_record_failure_at_expiry(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    transient: bytes | None,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir, record = _running_record(paths, run_id)
    record_path = run_dir / "run.json"
    if transient is None:
        record_path.unlink()
    else:
        record_path.write_bytes(transient)
    sleeps: list[float] = []
    destroyed: list[tuple[str, str]] = []

    def restore(seconds: float) -> None:
        sleeps.append(seconds)
        record_path.write_text(json.dumps(record), encoding="utf-8")

    monkeypatch.setattr(watchdog_module.time, "sleep", restore)
    monkeypatch.setattr(
        LibvirtBackend,
        "destroy",
        lambda _self, domain, domain_uuid: destroyed.append((domain, domain_uuid)),
    )

    assert expire_with_retry(
        run_id,
        "qemu:///session",
        paths,
        finalization_seconds=1,
        retry_seconds=0,
    )
    assert sleeps == [0]
    assert destroyed == [(record["domain"], record["domain_uuid"])]
    assert json.loads(record_path.read_text(encoding="utf-8"))["status"] == "expired"


def test_watchdog_retries_a_transient_missing_record_until_cleanup_completes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    record_path = run_dir / "run.json"
    ticks = iter((0.0, 0.0, 0.1, 0.1))
    sleeps: list[float] = []

    monkeypatch.setattr(watchdog_module.time, "monotonic", lambda: next(ticks))

    def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        record_path.write_text(json.dumps({"status": "destroyed"}), encoding="utf-8")

    monkeypatch.setattr(watchdog_module.time, "sleep", sleep)

    assert not wait_and_expire(run_id, 60, "qemu:///session", paths)
    assert sleeps == [1]


def test_watchdog_expiry_still_runs_when_record_remains_unreadable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    (run_dir / "run.json").write_text("{", encoding="utf-8")
    ticks = iter((0.0, 1.0))
    expired: list[tuple[str, str]] = []
    monkeypatch.setattr(watchdog_module.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(
        watchdog_module,
        "expire_with_retry",
        lambda candidate, uri, *_args, **_kwargs: expired.append((candidate, uri))
        or True,
    )

    assert wait_and_expire(run_id, 1, "qemu:///session", paths)
    assert expired == [(run_id, "qemu:///session")]


def test_watchdog_preserves_ephemeral_storage_when_domain_cleanup_fails(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    overlay = run_dir / "root.qcow2"
    seed = run_dir / "seed.iso"
    private_key = run_dir / "ssh" / "id_ed25519"
    private_key.parent.mkdir()
    overlay.write_bytes(b"overlay")
    seed.write_bytes(b"seed")
    private_key.write_text("disposable", encoding="utf-8")
    backend = LibvirtBackend(paths)
    record = {
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "running",
        "libvirt_session": backend.session_identity(),
    }
    (run_dir / "run.json").write_text(json.dumps(record), encoding="utf-8")
    monkeypatch.setattr(
        LibvirtBackend,
        "destroy",
        lambda _self, _domain, _domain_uuid: (_ for _ in ()).throw(
            VMError(FailureCategory.HOST_INFRA_ERROR, "domain remained active")
        ),
    )

    with pytest.raises(VMError, match="domain remained active"):
        expire_run(run_id, "qemu:///session", paths)

    assert overlay.is_file()
    assert seed.is_file()
    assert private_key.is_file()
    assert json.loads((run_dir / "run.json").read_text())["status"] == "running"


def test_watchdog_rechecks_terminal_state_after_waiting_for_cleanup_lock(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    record_path = run_dir / "run.json"
    record = {
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "running",
    }
    record_path.write_text(json.dumps(record), encoding="utf-8")
    calls: list[str] = []
    monkeypatch.setattr(
        LibvirtBackend,
        "destroy",
        lambda _self, _domain, _domain_uuid: calls.append("destroy"),
    )

    from enoshima_vm.security import run_record_lock

    finished = threading.Event()
    outcome: list[bool] = []

    def expire() -> None:
        outcome.append(expire_run(run_id, "qemu:///session", paths))
        finished.set()

    with run_record_lock(run_dir):
        worker = threading.Thread(target=expire)
        worker.start()
        time.sleep(0.05)
        record["status"] = "completed"
        record["result"] = "passed"
        record_path.write_text(json.dumps(record), encoding="utf-8")
        assert not finished.is_set()
    worker.join(timeout=2)

    assert finished.is_set()
    assert outcome == [False]
    assert calls == []
    assert json.loads(record_path.read_text())["status"] == "completed"


def test_watchdog_preserves_a_passed_result_while_finishing_cleanup(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    backend = LibvirtBackend(paths)
    record = {
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "passed",
        "result": "passed",
        "libvirt_session": backend.session_identity(),
    }
    record_path = run_dir / "run.json"
    record_path.write_text(json.dumps(record), encoding="utf-8")
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        LibvirtBackend,
        "destroy",
        lambda _self, domain, domain_uuid: calls.append((domain, domain_uuid)),
    )

    assert expire_run(run_id, "qemu:///session", paths)

    updated = json.loads(record_path.read_text())
    assert updated["status"] == "completed"
    assert updated["result"] == "passed"
    assert "category" not in updated
    assert "error" not in updated
    assert "destroyed_at" in updated
    assert not overlay.exists()
    assert calls == [(record["domain"], record["domain_uuid"])]
