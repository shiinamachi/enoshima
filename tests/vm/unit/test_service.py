from __future__ import annotations

import fcntl
import io
import json
import os
import re
import signal
import subprocess
import tarfile
import xml.etree.ElementTree as ET
import zipfile
from hashlib import sha256
from pathlib import Path

import pytest

import enoshima_vm.service as service_module
from enoshima_vm.cloud_init import CloudInitResult
from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.libvirt_backend import DomainSpec
from enoshima_vm.process import CommandResult
from enoshima_vm.service import (
    UI_SEMANTIC_MIN_NORMALIZED_STDDEV,
    UI_SEMANTIC_MIN_UNIQUE_GRAY_VALUES,
    VMService,
    _write_recovery_key,
    normalized_image_metric,
)


def test_legacy_service_mutation_cannot_bypass_durable_operation_lock(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    lock_path = tmp_path / "mutation.lock"
    monkeypatch.setattr(
        "enoshima_vm.config.global_mutation_lock_path", lambda: lock_path
    )
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        with pytest.raises(VMError, match="durable VM operation owns") as caught:
            service.clean()
    finally:
        os.close(lock_fd)

    assert caught.value.category == FailureCategory.HARNESS_ERROR


def test_durable_payload_can_reenter_service_with_inherited_operation_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    lock_path = tmp_path / "mutation.lock"
    monkeypatch.setattr(
        "enoshima_vm.config.global_mutation_lock_path", lambda: lock_path
    )
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        monkeypatch.setenv("ENOSHIMA_VM_OPERATION_LOCK_FD", str(lock_fd))

        assert service.clean() == {
            "cleaned": [],
            "preserved": [],
            "preserved_reports": True,
        }
    finally:
        os.close(lock_fd)


def test_different_state_roots_share_the_same_mutation_lock(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    first = VMService(
        RuntimePaths(tmp_path, tmp_path, tmp_path / "cache-a", tmp_path / "state-a")
    )
    second = VMService(
        RuntimePaths(tmp_path, tmp_path, tmp_path / "cache-b", tmp_path / "state-b")
    )
    lock_path = tmp_path / "mutation.lock"
    monkeypatch.setattr(
        "enoshima_vm.config.global_mutation_lock_path", lambda: lock_path
    )
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(VMError, match="durable VM operation owns"):
            first.clean()
        with pytest.raises(VMError, match="durable VM operation owns"):
            second.clean()
    finally:
        os.close(lock_fd)


def test_destroy_stops_only_the_recorded_watchdog_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    record = {
        "run_id": "run-012345abcdef",
        "watchdog_pid": 4242,
        "watchdog_start_ticks": 123456,
    }
    signals: list[tuple[int, int]] = []
    monkeypatch.setattr(VMService, "_open_pidfd", lambda _pid: 99)
    monkeypatch.setattr(VMService, "_process_start_ticks", lambda _pid: 123456)
    monkeypatch.setattr(
        Path,
        "read_bytes",
        lambda self: (
            b"python\0-m\0enoshima_vm.watchdog\0run-012345abcdef\0"
            b"600\0qemu:///session\0"
            if self == Path("/proc/4242/cmdline")
            else pytest.fail(f"unexpected path: {self}")
        ),
    )
    monkeypatch.setattr(
        VMService,
        "_pidfd_send_signal",
        lambda descriptor, signum: signals.append((descriptor, signum)) or True,
    )
    monkeypatch.setattr("enoshima_vm.service.os.close", lambda _fd: None)

    VMService._stop_watchdog(record)

    assert signals == [(99, signal.SIGTERM)]


def test_destroy_preserves_a_reused_watchdog_pid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    record = {
        "run_id": "run-012345abcdef",
        "watchdog_pid": 4242,
        "watchdog_start_ticks": 123456,
    }
    monkeypatch.setattr(VMService, "_open_pidfd", lambda _pid: 99)
    monkeypatch.setattr(VMService, "_process_start_ticks", lambda _pid: 654321)
    monkeypatch.setattr(
        VMService,
        "_pidfd_send_signal",
        lambda *_args: pytest.fail("reused PID must not be signaled"),
    )
    monkeypatch.setattr("enoshima_vm.service.os.close", lambda _fd: None)

    VMService._stop_watchdog(record)


def test_stop_watchdog_pins_identity_before_signaling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    record = {
        "run_id": "run-012345abcdef",
        "watchdog_pid": 4242,
        "watchdog_start_ticks": 123456,
    }
    events: list[object] = []
    monkeypatch.setattr(
        VMService, "_open_pidfd", lambda pid: events.append(("open", pid)) or 99
    )
    monkeypatch.setattr(
        VMService,
        "_process_start_ticks",
        lambda pid: events.append(("ticks", pid)) or 123456,
    )
    monkeypatch.setattr(
        Path,
        "read_bytes",
        lambda _self: (
            events.append("cmdline")
            or b"python\0-m\0enoshima_vm.watchdog\0run-012345abcdef\0"
            b"600\0qemu:///session\0"
        ),
    )
    monkeypatch.setattr(
        VMService,
        "_pidfd_send_signal",
        lambda descriptor, signum: (
            events.append(("signal", descriptor, signum)) or True
        ),
    )
    monkeypatch.setattr(
        "enoshima_vm.service.os.close", lambda fd: events.append(("close", fd))
    )

    VMService._stop_watchdog(record)

    assert events == [
        ("open", 4242),
        ("ticks", 4242),
        "cmdline",
        ("signal", 99, signal.SIGTERM),
        ("close", 99),
    ]


def test_start_watchdog_uses_user_transient_service_without_operation_lock(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = paths.state / "runs" / run_id
    run_dir.mkdir(parents=True)
    session = service.backend.session_identity()
    (run_dir / "run.json").write_text(
        json.dumps(
            {
                "run_id": run_id,
                "domain": f"enoshima-test-{run_id}",
                "domain_uuid": "12345678-1234-5678-1234-567812345678",
                "status": "creating",
                "libvirt_session": session,
            }
        ),
        encoding="utf-8",
    )
    calls: list[tuple[tuple[str, ...], dict[str, object]]] = []

    def run(argv, **kwargs):
        normalized = tuple(str(value) for value in argv)
        calls.append((normalized, kwargs))
        if normalized[0] == "/usr/bin/systemd-run":
            ready = run_dir / ".watchdog-ready.json"
            ready.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "runId": run_id,
                        "pid": 4242,
                        "pidStartTicks": 123456,
                        "libvirtSession": session,
                    }
                ),
                encoding="utf-8",
            )
            ready.chmod(0o600)
            return subprocess.CompletedProcess(normalized, 0, "", "")
        assert normalized[:4] == (
            "/usr/bin/systemctl",
            "--user",
            "show",
            "enoshima-vm-watchdog-run-012345abcdef.service",
        )
        return subprocess.CompletedProcess(
            normalized,
            0,
            "MainPID=4242\nActiveState=active\nSubState=running\n",
            "",
        )

    monkeypatch.setattr(service_module.subprocess, "run", run)
    monkeypatch.setattr(service, "_process_start_ticks", lambda pid: 123456)
    monkeypatch.setattr(
        service,
        "_process_executable",
        lambda pid: Path(service_module.sys.executable).resolve(),
    )
    monkeypatch.setenv("ENOSHIMA_VM_OPERATION_LOCK_FD", "77")

    result = service._start_watchdog(run_id, 600)

    assert result == {
        "watchdog_unit": "enoshima-vm-watchdog-run-012345abcdef.service",
        "watchdog_pid": 4242,
        "watchdog_start_ticks": 123456,
    }
    command, kwargs = calls[0]
    assert command[:5] == (
        "/usr/bin/systemd-run",
        "--user",
        "--quiet",
        "--collect",
        "--service-type=exec",
    )
    assert "--property=KillMode=control-group" in command
    assert "--property=Type=exec" not in command
    assert "--property=RuntimeMaxSec=2430s" in command
    assert "--setenv=PATH=/usr/bin" in command
    assert "--setenv=ENOSHIMA_VM_STATE_ROOT=" + str(paths.state) in command
    assert "--setenv=PYTHONPATH=" + str(paths.project / "src") in command
    assert all("ENOSHIMA_VM_OPERATION_LOCK_FD" not in value for value in command)
    environment = kwargs["env"]
    assert isinstance(environment, dict)
    assert "ENOSHIMA_VM_OPERATION_LOCK_FD" not in environment


def test_create_failure_after_watchdog_start_records_cleanup_and_stops_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(
        RuntimePaths.discover().repository,
        RuntimePaths.discover().project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    suite = service_module.load_suite("smoke", paths)
    run_identity: dict[str, object] = {}
    monkeypatch.setattr(service_module, "load_suite", lambda *_args: suite)
    mode = service_module.load_verification_mode("dev", paths)
    monkeypatch.setattr(service_module, "load_verification_mode", lambda *_args: mode)
    monkeypatch.setattr(
        service_module,
        "load_images",
        lambda *_args: {
            suite.base_image: type("Image", (), {"repository_snapshot": None})()
        },
    )
    monkeypatch.setattr(service, "_assert_loaded_harness_current", lambda: None)
    monkeypatch.setattr(service, "preflight", lambda *_args: {})
    base_image = tmp_path / "base.qcow2"
    base_image.write_bytes(b"base")
    monkeypatch.setattr(service.images, "ensure", lambda _definition: base_image)
    run_dir_holder: dict[str, Path] = {}

    def build(run_dir: Path, *_args) -> CloudInitResult:
        run_dir_holder["path"] = run_dir
        private_key = run_dir / "ssh" / "id_ed25519"
        private_key.parent.mkdir(mode=0o700, parents=True)
        private_key.write_text("key", encoding="utf-8")
        public_key = private_key.with_suffix(".pub")
        public_key.write_text("pub", encoding="utf-8")
        seed = run_dir / "seed.iso"
        seed.write_bytes(b"seed")
        return CloudInitResult(seed, private_key, public_key)

    monkeypatch.setattr(service.cloud_init, "build", build)

    def prepare(run_dir: Path, run_id: str, domain_uuid: str, *_args) -> DomainSpec:
        overlay = run_dir / "root.qcow2"
        overlay.write_bytes(b"overlay")
        xml = run_dir / "domain.xml"
        xml.write_text("<domain/>", encoding="utf-8")
        return DomainSpec(
            run_id,
            f"enoshima-test-{run_id}",
            domain_uuid,
            overlay,
            run_dir / "seed.iso",
            2222,
            xml,
        )

    monkeypatch.setattr(service.backend, "prepare_domain", prepare)
    order: list[str] = []
    monkeypatch.setattr(
        service.backend,
        "define_and_start",
        lambda _spec: order.append("domain-start"),
    )
    destroyed: list[tuple[str, str]] = []
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda domain, domain_uuid: destroyed.append((domain, domain_uuid)),
    )

    monkeypatch.setattr(
        service,
        "_start_watchdog",
        lambda run_id, _timeout: (
            order.append("watchdog-start")
            or {
                "watchdog_unit": f"enoshima-vm-watchdog-{run_id}.service",
                "watchdog_pid": 4242,
                "watchdog_start_ticks": 123456,
            }
        ),
    )
    stopped: list[str] = []
    monkeypatch.setattr(
        service,
        "_stop_watchdog",
        lambda record: stopped.append(str(record["run_id"])),
    )
    monkeypatch.setattr(service, "_wait_watchdog_stopped", lambda _record: None)
    audit_calls = 0

    def fail_first_audit(*_args, **_kwargs) -> None:
        nonlocal audit_calls
        audit_calls += 1
        if audit_calls == 1:
            raise OSError("injected audit failure")

    monkeypatch.setattr(service, "_audit", fail_first_audit)

    with pytest.raises(OSError, match="injected audit failure"):
        service.create("smoke")

    records = service.list_runs()
    assert len(records) == 1
    record = records[0]
    run_identity["record"] = record
    assert record["status"] == "destroyed"
    assert record["result"] == "failed"
    assert record["destroyed_at"]
    assert order == ["watchdog-start", "domain-start"]
    assert stopped == [record["run_id"]]
    assert destroyed == [(record["domain"], record["domain_uuid"])]
    assert not (run_dir_holder["path"] / "root.qcow2").exists()
    assert not (run_dir_holder["path"] / "seed.iso").exists()
    assert not (run_dir_holder["path"] / "ssh").exists()


def test_create_failure_preserves_ephemeral_files_when_watchdog_cleanup_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(
        RuntimePaths.discover().repository,
        RuntimePaths.discover().project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    suite = service_module.load_suite("smoke", paths)
    monkeypatch.setattr(service_module, "load_suite", lambda *_args: suite)
    mode = service_module.load_verification_mode("dev", paths)
    monkeypatch.setattr(service_module, "load_verification_mode", lambda *_args: mode)
    monkeypatch.setattr(
        service_module,
        "load_images",
        lambda *_args: {
            suite.base_image: type("Image", (), {"repository_snapshot": None})()
        },
    )
    monkeypatch.setattr(service, "_assert_loaded_harness_current", lambda: None)
    monkeypatch.setattr(service, "preflight", lambda *_args: {})
    base_image = tmp_path / "base.qcow2"
    base_image.write_bytes(b"base")
    monkeypatch.setattr(service.images, "ensure", lambda _definition: base_image)
    run_dir_holder: dict[str, Path] = {}

    def build(run_dir: Path, *_args) -> CloudInitResult:
        run_dir_holder["path"] = run_dir
        private_key = run_dir / "ssh" / "id_ed25519"
        private_key.parent.mkdir(mode=0o700, parents=True)
        private_key.write_text("key", encoding="utf-8")
        public_key = private_key.with_suffix(".pub")
        public_key.write_text("pub", encoding="utf-8")
        seed = run_dir / "seed.iso"
        seed.write_bytes(b"seed")
        return CloudInitResult(seed, private_key, public_key)

    monkeypatch.setattr(service.cloud_init, "build", build)

    def prepare(run_dir: Path, run_id: str, domain_uuid: str, *_args) -> DomainSpec:
        overlay = run_dir / "root.qcow2"
        overlay.write_bytes(b"overlay")
        xml = run_dir / "domain.xml"
        xml.write_text("<domain/>", encoding="utf-8")
        return DomainSpec(
            run_id,
            f"enoshima-test-{run_id}",
            domain_uuid,
            overlay,
            run_dir / "seed.iso",
            2222,
            xml,
        )

    monkeypatch.setattr(service.backend, "prepare_domain", prepare)
    monkeypatch.setattr(service.backend, "define_and_start", lambda _spec: None)
    monkeypatch.setattr(service.backend, "destroy", lambda *_args: None)
    monkeypatch.setattr(
        service,
        "_start_watchdog",
        lambda run_id, _timeout: {
            "watchdog_unit": f"enoshima-vm-watchdog-{run_id}.service",
            "watchdog_pid": 4242,
            "watchdog_start_ticks": 123456,
        },
    )
    monkeypatch.setattr(service, "_stop_watchdog", lambda _record: None)
    monkeypatch.setattr(
        service,
        "_wait_watchdog_stopped",
        lambda _record: (_ for _ in ()).throw(RuntimeError("watchdog remained live")),
    )
    audit_calls = 0

    def fail_first_audit(*_args, **_kwargs) -> None:
        nonlocal audit_calls
        audit_calls += 1
        if audit_calls == 1:
            raise OSError("injected audit failure")

    monkeypatch.setattr(service, "_audit", fail_first_audit)

    with pytest.raises(OSError, match="injected audit failure"):
        service.create("smoke")

    record = service.list_runs()[0]
    assert record["cleanup_errors"] == ["watchdog cleanup: watchdog remained live"]
    assert "destroyed_at" not in record
    assert (run_dir_holder["path"] / "root.qcow2").is_file()
    assert (run_dir_holder["path"] / "seed.iso").is_file()
    assert (run_dir_holder["path"] / "ssh").is_dir()


class ScreenshotGuest:
    def __init__(self) -> None:
        self.commands: list[tuple[str, ...]] = []

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        return CommandResult(tuple(argv), 0, "", "")

    def exec_retryable(self, argv, **kwargs):
        return self.exec(argv, **kwargs)

    def download(self, _remote, local: Path) -> None:
        local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        header = (
            b"\x89PNG\r\n\x1a\n"
            + b"\x00\x00\x00\rIHDR"
            + (1280).to_bytes(4, "big")
            + (800).to_bytes(4, "big")
        )
        local.write_bytes(header)


class ReadyGuest(ScreenshotGuest):
    def __init__(self, sequence: int, missing_translations: int = 0) -> None:
        super().__init__()
        self.sequence = sequence
        self.missing_translations = missing_translations

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        if tuple(argv[:1]) == ("cat",):
            return CommandResult(
                tuple(argv),
                0,
                (
                    f'{{"schema":1,"sequence":{self.sequence},'
                    '"text_overflow_count":0,'
                    f'"missing_translation_count":{self.missing_translations}}}\n'
                ),
                "",
            )
        return CommandResult(tuple(argv), 0, "", "")


class CacheSeedGuest(ScreenshotGuest):
    def __init__(self) -> None:
        super().__init__()
        self.uploads: list[tuple[Path, str, int]] = []

    def upload_file(
        self,
        local: Path,
        remote,
        *,
        mode: int = 0o600,
        timeout: float = 120,
    ) -> None:
        del timeout
        self.uploads.append((local, str(remote), mode))

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        archive = self.uploads[-1][0]
        digest = sha256(archive.read_bytes()).hexdigest()
        return CommandResult(tuple(argv), 0, f"{digest}  {argv[-1]}\n", "")


class PacmanCacheGuest(ScreenshotGuest):
    def __init__(self, packages: dict[str, bytes]) -> None:
        super().__init__()
        self.packages = packages
        self.uploads: list[tuple[Path, str, int]] = []

    def upload_file(
        self,
        local: Path,
        remote,
        *,
        mode: int = 0o600,
        timeout: float = 120,
    ) -> None:
        del timeout
        self.uploads.append((local, str(remote), mode))

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        if tuple(argv[:2]) == ("sudo", "find"):
            output = "".join(
                f"{name}\t{len(payload)}\n"
                for name, payload in sorted(self.packages.items())
            )
            return CommandResult(tuple(argv), 0, output, "")
        return CommandResult(tuple(argv), 0, "", "")

    def download(self, _remote, local: Path, *, timeout: float = 300) -> None:
        del timeout
        local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tarfile.open(local, mode="w") as bundle:
            for name, payload in sorted(self.packages.items()):
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))


class PowerClientGuest(ScreenshotGuest):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            "[]\n",
            (
                '[{"address":"0xabc","class":"com.mitchellh.ghostty",'
                '"title":"Enoshima Power Fixture","pid":42}]\n'
            ),
        ]

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        return CommandResult(tuple(argv), 0, self.responses.pop(0), "")


def test_junit_report_preserves_step_failure_and_duration(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    destination = service._write_junit(
        {
            "suite": "fixture",
            "artifact_dir": str(tmp_path / "artifacts"),
            "category": "POSTFLIGHT_FAILED",
            "error": "postflight failed",
            "steps": [
                {
                    "action": "bootstrap",
                    "status": "passed",
                    "duration_seconds": 1.25,
                },
                {
                    "action": "postflight",
                    "status": "failed",
                    "duration_seconds": 0.75,
                },
            ],
        }
    )
    root = ET.parse(destination).getroot()
    assert root.attrib["tests"] == "2"
    assert root.attrib["failures"] == "1"
    assert root.attrib["time"] == "2.000"
    failed = root.findall("testcase")[1].find("failure")
    assert failed is not None
    assert failed.attrib["type"] == "POSTFLIGHT_FAILED"
    assert failed.text == "postflight failed"


def test_stable_ui_accepts_only_a_bounded_animated_region(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "busy.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    comparisons: list[tuple[str, ...]] = []

    def compare(argv, **_kwargs):
        comparisons.append(tuple(argv))
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="200")

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "busy", "HEADLESS-UI"
    )

    assert captures == 2
    assert capture["stability_changed_pixel_ratio"] == 0.0002
    assert capture["stability_metric"] == "changed-pixel-ratio"
    assert comparisons[0][1:4] == ("compare", "-metric", "AE")
    assert not image.with_name(".busy.png.previous").exists()


def test_stable_ui_retries_after_a_slow_transitional_frame(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "transition.png"
    frames = [b"before-layer-map", b"after-layer-map", b"after-layer-map"]
    captures = 0
    monotonic_values = iter([0.0, 0.0, 30.0, 31.0])

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(frames[captures])
        captures += 1
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {"AE": "1000000", "RMSE": "0.2 (0.2)", "SSIM": "0.2"}
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)
    monkeypatch.setattr(
        "enoshima_vm.service.time.monotonic", lambda: next(monotonic_values)
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"},
        "transition",
        "HEADLESS-UI",
        timeout_seconds=20,
    )

    assert captures == 3
    assert capture["stability_changed_pixel_ratio"] == 0.0
    assert capture["stability_metric"] == "pixel-hash"


def test_stable_ui_does_not_report_a_negative_ratio_for_invalid_ae(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "invalid-ae.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {
            "AE": "not-a-number",
            "RMSE": "64 (0.000976577)",
            "SSIM": "0.0666445",
        }
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "invalid-ae", "HEADLESS-UI"
    )

    assert capture["stability_changed_pixel_ratio"] == 1.0
    assert capture["stability_metric"] == "normalized-rmse"


def test_normalized_image_metric_prefers_parenthesized_value() -> None:
    assert normalized_image_metric("64 (0.000976577)") == 0.000976577
    assert normalized_image_metric("0.9995") == 0.9995


def test_authoritative_vm_entry_rejects_a_stale_mcp_harness(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    monkeypatch.setattr(
        "enoshima_vm.service.LOADED_HARNESS_SOURCE_DIGEST",
        "loaded-digest",
    )
    monkeypatch.setattr(
        "enoshima_vm.service._harness_source_digest",
        lambda: "current-digest",
    )

    with pytest.raises(VMError, match="retry the MCP call") as error:
        service.run_suite_result("smoke", base_ref="HEAD^")

    assert "restart" not in str(error.value).lower()
    assert error.value.details == {
        "loaded_harness_digest": "loaded-digest",
        "current_harness_digest": "current-digest",
    }
    assert not (paths.state / "runs").exists()


def test_destroy_preserves_ephemeral_files_when_domain_cleanup_fails(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    seed = run_dir / "seed.iso"
    private_key = run_dir / "ssh" / "id_ed25519"
    private_key.parent.mkdir(mode=0o700)
    overlay.write_bytes(b"overlay")
    seed.write_bytes(b"seed")
    private_key.write_text("disposable", encoding="utf-8")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": "12345678-1234-5678-1234-567812345678",
            "status": "failed",
            "result": "failed",
            "overlay": str(overlay),
            "seed": str(seed),
            "private_key": str(private_key),
            "libvirt_session": service.backend.session_identity(),
        }
    )
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda _domain, _domain_uuid: (_ for _ in ()).throw(
            VMError(FailureCategory.HOST_INFRA_ERROR, "domain remained active")
        ),
    )

    with pytest.raises(VMError, match="domain remained active"):
        service.destroy(run_id)

    assert overlay.is_file()
    assert seed.is_file()
    assert private_key.is_file()
    assert service.load_record(run_id)["status"] == "failed"


def test_destroy_stops_watchdog_before_removing_ephemeral_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": "12345678-1234-5678-1234-567812345678",
            "status": "failed",
            "result": "failed",
            "overlay": str(overlay),
            "watchdog_pid": 4242,
            "watchdog_start_ticks": 123456,
            "libvirt_session": service.backend.session_identity(),
        }
    )
    events: list[str] = []
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda _domain, _domain_uuid: events.append("domain"),
    )
    monkeypatch.setattr(
        service,
        "_stop_watchdog",
        lambda _record: events.append("watchdog-signal"),
    )
    monkeypatch.setattr(
        service,
        "_wait_watchdog_stopped",
        lambda _record: events.append("watchdog-stopped"),
    )
    original_remove = service._remove_ephemeral

    def remove_ephemeral(record: dict[str, object]) -> list[str]:
        events.append("ephemeral")
        return original_remove(record)

    monkeypatch.setattr(service, "_remove_ephemeral", remove_ephemeral)

    service.destroy(run_id)

    assert events == ["domain", "watchdog-signal", "watchdog-stopped", "ephemeral"]
    assert not overlay.exists()


def test_destroy_preserves_ephemeral_files_when_watchdog_does_not_stop(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": "12345678-1234-5678-1234-567812345678",
            "status": "failed",
            "result": "failed",
            "overlay": str(overlay),
            "watchdog_pid": 4242,
            "watchdog_start_ticks": 123456,
            "libvirt_session": service.backend.session_identity(),
        }
    )
    monkeypatch.setattr(service.backend, "destroy", lambda *_args: None)
    monkeypatch.setattr(service, "_stop_watchdog", lambda _record: None)
    monkeypatch.setattr(
        service,
        "_wait_watchdog_stopped",
        lambda _record: (_ for _ in ()).throw(
            RuntimeError("recorded VM watchdog did not stop")
        ),
    )

    with pytest.raises(RuntimeError, match="watchdog did not stop"):
        service.destroy(run_id)

    assert overlay.is_file()
    assert service.load_record(run_id)["status"] == "failed"


def test_destroy_rejects_an_unknown_libvirt_session_and_preserves_files(
    tmp_path: Path,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    seed = run_dir / "seed.iso"
    private_key = run_dir / "ssh" / "id_ed25519"
    private_key.parent.mkdir(mode=0o700)
    overlay.write_bytes(b"overlay")
    seed.write_bytes(b"seed")
    private_key.write_text("disposable", encoding="utf-8")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": "12345678-1234-5678-1234-567812345678",
            "status": "failed",
            "result": "failed",
            "overlay": str(overlay),
            "seed": str(seed),
            "private_key": str(private_key),
        }
    )

    with pytest.raises(VMError, match="exact recorded libvirt session"):
        service.destroy(run_id)

    assert overlay.is_file()
    assert seed.is_file()
    assert private_key.is_file()


def test_destroy_rejects_a_same_name_replacement_and_preserves_files(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"overlay")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": "12345678-1234-5678-1234-567812345678",
            "status": "failed",
            "result": "failed",
            "overlay": str(overlay),
            "libvirt_session": service.backend.session_identity(),
        }
    )
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda _domain, _uuid: (_ for _ in ()).throw(
            VMError(FailureCategory.HOST_INFRA_ERROR, "UUID does not match")
        ),
    )

    with pytest.raises(VMError, match="UUID does not match"):
        service.destroy(run_id)

    assert overlay.is_file()
    assert service.load_record(run_id)["status"] == "failed"


def test_destroy_cleans_invalidated_run_without_overwriting_result(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    private_key = run_dir / "ssh" / "id_ed25519"
    private_key.parent.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    seed = run_dir / "seed.iso"
    private_key.write_text("disposable", encoding="utf-8")
    overlay.write_bytes(b"overlay")
    seed.write_bytes(b"seed")
    domain_uuid = "12345678-1234-5678-1234-567812345678"
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "domain_uuid": domain_uuid,
            "status": "invalidated",
            "result": "failed",
            "category": "SOURCE_INVALIDATED",
            "error": "source changed",
            "source_invalidated": True,
            "authoritative": False,
            "overlay": str(overlay),
            "seed": str(seed),
            "private_key": str(private_key),
            "libvirt_session": service.backend.session_identity(),
        }
    )
    calls: list[tuple[str, str]] = []
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda domain, uuid_value: calls.append((domain, uuid_value)),
    )

    first = service.destroy(run_id)
    second = service.destroy(run_id)

    record = service.load_record(run_id)
    assert record["status"] == "invalidated"
    assert record["result"] == "failed"
    assert record["category"] == "SOURCE_INVALIDATED"
    assert record["error"] == "source changed"
    assert record["source_invalidated"] is True
    assert record["authoritative"] is False
    assert "destroyed_at" in record
    assert not overlay.exists()
    assert not seed.exists()
    assert not private_key.exists()
    assert first["removed"]
    assert second["removed"] == []
    assert calls == [(record["domain"], domain_uuid)]


def test_legacy_record_is_reported_and_preserved_without_uuid(
    tmp_path: Path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    private_key = run_dir / "ssh" / "id_ed25519"
    private_key.parent.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    private_key.write_text("legacy", encoding="utf-8")
    overlay.write_bytes(b"legacy")
    service._write_record(
        {
            "schema": 1,
            "run_id": run_id,
            "domain": "enoshima-test-run-012345abcdef",
            "status": "failed",
            "result": "failed",
            "private_key": str(private_key),
            "overlay": str(overlay),
            "libvirt_session": service.backend.session_identity(),
        }
    )
    monkeypatch.setattr(
        service.backend,
        "owned_state",
        lambda *_args: (_ for _ in ()).throw(AssertionError("must not query")),
    )
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda *_args: (_ for _ in ()).throw(AssertionError("must not destroy")),
    )

    status = service.status(run_id)
    listed = service.list_runs()
    cleaned = service.clean()

    assert status["domain_state"] == "ownership-unverified"
    assert [record["run_id"] for record in listed] == [run_id]
    assert cleaned["cleaned"] == []
    assert cleaned["preserved"] == [{"run_id": run_id, "reason": "missing-domain-uuid"}]
    assert private_key.is_file()
    assert overlay.is_file()


@pytest.mark.parametrize(
    ("recorded_session", "reason"),
    [
        (None, "missing-libvirt-session"),
        ({"uri": "qemu:///session", "uid": -1}, "mismatched-libvirt-session"),
    ],
)
def test_clean_reports_and_preserves_an_unverifiable_libvirt_session(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    recorded_session: dict[str, object] | None,
    reason: str,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    overlay = run_dir / "root.qcow2"
    overlay.write_bytes(b"legacy")
    record: dict[str, object] = {
        "schema": 1,
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "domain_uuid": "12345678-1234-5678-1234-567812345678",
        "status": "failed",
        "result": "failed",
        "overlay": str(overlay),
    }
    if recorded_session is not None:
        record["libvirt_session"] = recorded_session
    service._write_record(record)
    monkeypatch.setattr(
        service.backend,
        "destroy",
        lambda *_args: pytest.fail("unverified session reached libvirt"),
    )

    cleaned = service.clean()

    assert cleaned["cleaned"] == []
    assert cleaned["preserved"] == [{"run_id": run_id, "reason": reason}]
    assert overlay.is_file()


def test_stale_writer_cannot_replace_an_expired_terminal_record(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    run_dir = service._run_dir(run_id)
    run_dir.mkdir(mode=0o700, parents=True)
    stale = {
        "schema": 1,
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "status": "running",
    }
    service._write_record(stale)
    current = dict(stale, status="expired", result="failed")
    service._write_record(current)

    stale["status"] = "passed"
    stale["result"] = "passed"
    service._write_record(stale)

    assert stale["status"] == "expired"
    assert service.load_record(run_id)["status"] == "expired"


def test_invalidated_terminal_record_rejects_a_stale_writer(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    run_id = "run-012345abcdef"
    stale = {
        "schema": 1,
        "run_id": run_id,
        "domain": "enoshima-test-run-012345abcdef",
        "status": "completed",
        "result": "passed",
    }
    service._write_record(stale)
    invalidated = dict(
        stale,
        status="invalidated",
        result="failed",
        source_invalidated=True,
        authoritative=False,
    )
    service._write_record(invalidated)

    stale["status"] = "running"
    service._write_record(stale)

    assert stale["status"] == "invalidated"
    assert service.load_record(run_id)["source_invalidated"] is True


def test_codex_electron_cache_seed_is_explicit_and_checksum_verified(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = CacheSeedGuest()
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    archive = cache / "electron-v42.3.0-linux-x64.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("electron", "fixture")
    node_archive = tmp_path / "node-v22.22.2-linux-x64.tar.xz"
    with tarfile.open(node_archive, mode="w:xz") as bundle:
        info = tarfile.TarInfo("node-v22.22.2-linux-x64/README.md")
        payload = b"fixture"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{sha256(node_archive.read_bytes()).hexdigest()}  {node_archive.name}\n",
        encoding="utf-8",
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"koly" + (b"\0" * 508))
    digest_lock = tmp_path / "packages" / "codex-desktop-dmg-sha256.txt"
    digest_lock.write_text(
        sha256(dmg.read_bytes()).hexdigest() + "\n", encoding="utf-8"
    )

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(node_archive))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)
    record = {"run_id": "run-012345abcdef"}

    service._seed_codex_electron_cache(record)

    assert guest.uploads == [
        (
            archive,
            "/home/kentakang/.cache/codex-desktop/electron/"
            "electron-v42.3.0-linux-x64.zip",
            0o600,
        ),
        (
            node_archive,
            "/home/kentakang/.cache/codex-desktop/node-runtime/"
            "node-v22.22.2-linux-x64.tar.xz",
            0o600,
        ),
        (
            dmg,
            "/home/kentakang/.cache/codex-desktop/Codex.dmg",
            0o600,
        ),
    ]
    seeded = record["observations"]["codex_electron_cache"]
    assert seeded["status"] == "seeded"
    assert seeded["archives"][0]["sha256"] == sha256(archive.read_bytes()).hexdigest()
    assert seeded["node_runtime"]["status"] == "seeded"
    assert (
        seeded["node_runtime"]["sha256"]
        == sha256(node_archive.read_bytes()).hexdigest()
    )
    assert seeded["dmg"]["status"] == "seeded"
    assert seeded["dmg"]["sha256"] == sha256(dmg.read_bytes()).hexdigest()


def test_codex_node_runtime_seed_rejects_a_stale_valid_archive(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_archive = tmp_path / "node-v22.22.2-linux-x64.tar.xz"
    with tarfile.open(node_archive, mode="w:xz") as bundle:
        info = tarfile.TarInfo("node-v22.22.2-linux-x64/README.md")
        payload = b"fixture"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(f"{'0' * 64}  {node_archive.name}\n", encoding="utf-8")

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(node_archive))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(tmp_path / "missing.dmg"))

    with pytest.raises(VMError, match="does not match its digest lock"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_codex_dmg_cache_seed_rejects_a_stale_valid_cache(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{'0' * 64}  node-v22.22.2-linux-x64.tar.xz\n", encoding="utf-8"
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"koly" + (b"\0" * 508))
    digest_lock = tmp_path / "packages" / "codex-desktop-dmg-sha256.txt"
    digest_lock.write_text(("0" * 64) + "\n", encoding="utf-8")

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv(
        "ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(tmp_path / "missing-node.tar.xz")
    )
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))

    with pytest.raises(VMError, match="does not match the repository digest lock"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_codex_dmg_cache_seed_rejects_an_invalid_udif_trailer(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{'0' * 64}  node-v22.22.2-linux-x64.tar.xz\n", encoding="utf-8"
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"invalid" + (b"\0" * 505))

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv(
        "ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(tmp_path / "missing-node.tar.xz")
    )
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))

    with pytest.raises(VMError, match="no UDIF trailer"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_pacman_cache_round_trip_is_snapshot_scoped_and_bounded(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    record = {
        "run_id": "run-012345abcdef",
        "base_image": str(tmp_path / "arch-cloud-reproducible-f419d4e29aebfc01.qcow2"),
    }
    guest = PacmanCacheGuest(
        {
            "alpha-1.0-1-x86_64.pkg.tar.zst": b"alpha-package",
            "alpha-1.0-1-x86_64.pkg.tar.zst.sig": b"alpha-signature",
            "beta-2.0-1-any.pkg.tar.zst": b"beta-package",
        }
    )
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)
    service._run_dir(record["run_id"]).mkdir(mode=0o700, parents=True)

    service._collect_pacman_cache(record)

    cache_root, package_root, archive, manifest = service._pacman_cache_paths(record)
    assert cache_root.is_relative_to(paths.cache)
    assert sorted(path.name for path in package_root.iterdir()) == [
        "alpha-1.0-1-x86_64.pkg.tar.zst",
        "alpha-1.0-1-x86_64.pkg.tar.zst.sig",
        "beta-2.0-1-any.pkg.tar.zst",
    ]
    assert archive.is_file()
    metadata = json.loads(manifest.read_text(encoding="utf-8"))
    assert metadata["package_count"] == 3
    assert metadata["package_bytes"] == len(b"alpha-packagealpha-signaturebeta-package")
    assert record["observations"]["pacman_cache_collect"]["status"] == "updated"

    seed_guest = CacheSeedGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: seed_guest)
    service._seed_pacman_cache(record)

    assert seed_guest.uploads == [
        (
            archive,
            "/home/kentakang/enoshima-test/cache/pacman-seed.tar",
            0o600,
        )
    ]
    assert record["observations"]["pacman_cache_seed"]["status"] == "seeded"
    assert any(
        command[:3] == ("sudo", "tar", "--extract") for command in seed_guest.commands
    )
    seeded = ("sudo", "touch", "/run/enoshima-pacman-cache-seeded")
    ready = ("sudo", "touch", "/run/enoshima-pacman-cache-seed-ready")
    assert seeded in seed_guest.commands
    assert ready in seed_guest.commands
    assert seed_guest.commands.index(seeded) < seed_guest.commands.index(ready)


def test_absent_pacman_cache_releases_cloud_init_to_the_network_path(
    tmp_path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    record = {
        "run_id": "run-012345abcdef",
        "base_image": str(tmp_path / "arch-cloud-reproducible-fixture.qcow2"),
    }
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)

    service._seed_pacman_cache(record)

    assert record["observations"]["pacman_cache_seed"] == {"status": "absent"}
    assert guest.commands[-2:] == [
        (
            "sudo",
            "rm",
            "-f",
            "--",
            "/run/enoshima-pacman-cache-seeded",
        ),
        ("sudo", "touch", "/run/enoshima-pacman-cache-seed-ready"),
    ]


def test_every_bootstrap_suite_seeds_the_optional_electron_cache() -> None:
    suites = RuntimePaths.discover().project / "suites"
    for path in suites.glob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        if "run_bootstrap" not in text:
            continue
        assert "- seed_codex_electron_cache" in text
        assert text.rindex("- upload_worktree") < text.index("- run_bootstrap")
        assert text.index("- seed_codex_electron_cache") < text.index("- run_bootstrap")
        assert "- seed_pacman_cache" in text
        assert text.index("- wait_for_ssh") < text.index("- seed_pacman_cache")
        assert text.index("- seed_pacman_cache") < text.index("- wait_for_cloud_init")
        assert text.index("- seed_pacman_cache") < text.index("- run_bootstrap")


def test_stable_ui_accepts_perceptually_identical_renderer_noise(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "noisy.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {
            "AE": "1000000",
            "RMSE": "64 (0.000976577)",
            "SSIM": "0.0666445",
        }
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "noisy", "HEADLESS-UI"
    )

    assert captures == 2
    assert capture["stability_changed_pixel_ratio"] == 1.0
    assert capture["stability_normalized_rmse"] == 0.00097658
    assert capture["stability_ssim_error"] == 0.0666445
    assert capture["stability_metric"] == "normalized-rmse"
    assert not image.with_name(".noisy.png.previous").exists()


def test_unstable_ui_retains_the_best_frame_pair_and_difference(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "unstable.png"
    captures = 0
    monotonic_values = iter([0.0, 1.0])

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        if "-metric" in argv:
            metric = argv[argv.index("-metric") + 1]
            outputs = {"AE": "1000000", "RMSE": "0.2 (0.2)", "SSIM": "0.2"}
            return subprocess.CompletedProcess(
                argv, 1, stdout="", stderr=outputs[metric]
            )
        Path(argv[-1]).write_bytes(b"difference")
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)
    monkeypatch.setattr(
        "enoshima_vm.service.time.monotonic", lambda: next(monotonic_values)
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    with pytest.raises(VMError, match="perceptually stable") as failure:
        service._capture_stable_ui(
            {"run_id": "run-012345abcdef"},
            "unstable",
            "HEADLESS-UI",
            timeout_seconds=0.5,
        )

    assert captures == 3
    assert failure.value.details is not None
    assert failure.value.details["best_stability"] == {
        "changed_pixel_ratio": 1.0,
        "normalized_rmse": 0.2,
        "ssim_error": 0.2,
    }
    for key in (
        "diagnostic_previous",
        "diagnostic_current",
        "diagnostic_difference",
    ):
        assert Path(str(failure.value.details[key])).is_file()
    assert not image.with_name(".unstable.png.previous").exists()


def test_greetd_capture_uses_the_guest_wayland_output(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    record = {
        "run_id": "run-012345abcdef",
        "artifact_dir": str(tmp_path / "artifacts"),
    }

    captured = service._capture_greetd_screenshot(record)

    assert captured == tmp_path / "artifacts" / "screenshots" / "greetd.png"
    command = " ".join(guest.commands[-1])
    assert "sudo -u greeter" in command
    assert "XDG_RUNTIME_DIR" in command
    assert "WAYLAND_DISPLAY" in command
    assert "grim" in command
    assert "virsh" not in command
    assert record["observations"]["greetd_screenshot"] == str(captured)


def test_greetd_login_uses_the_two_phase_authentication_flow() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    capture = source.index("self._capture_greetd_screenshot(record)")
    resolve_domain_uuid = source.index(
        "domain_uuid = self._require_recorded_domain_uuid(record)", capture
    )
    create_session = source.index("self.backend.send_keys(", resolve_domain_uuid)
    password = source.index("self.backend.type_text(", create_session)
    keyring = source.index("self._assert_login_keyring(record)", password)
    suppression = source.index(
        "self._assert_deterministic_login_suppression(record)", keyring
    )
    vicinae = source.index(
        "self._start_ui_review_vicinae_after_keyring(record)", suppression
    )
    assert (
        capture
        < resolve_domain_uuid
        < create_session
        < password
        < keyring
        < suppression
        < vicinae
    )


def test_reboot_suite_uses_the_desktop_power_path_ten_times() -> None:
    project = RuntimePaths.discover().project
    suite = (project / "suites" / "reboot.yaml").read_text(encoding="utf-8")
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )
    assert "domain-desktop.xml.j2" in suite
    assert "- reboot_via_desktop_power:" in suite
    assert "iterations: 10" in suite
    assert "timeout_minutes: 195" in suite
    method = source[source.index("def _reboot_via_desktop_power") :]
    assert "desktop-power reboot" in method
    assert "hl.dsp.exec_cmd" in method
    assert "self._hypr_command(launch)" in method
    assert "self._graphical_shell(launch)" not in method
    assert "self._start_power_client_fixture(record)" in method
    fixture = source[
        source.index("def _start_power_client_fixture") : source.index(
            "def _reboot_via_desktop_power"
        )
    ]
    assert "Enoshima Power Fixture" in fixture
    assert "ghostty" in fixture
    assert "desktop-power did not change the guest boot ID" in method
    assert "desktop-power checkpoint was not verified after login" in method


def test_idempotency_diff_excludes_non_filesystem_script_entries() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    method = source[
        source.index("def _assert_idempotent") : source.index(
            "def _assert_expected_skips"
        )
    ]

    assert '"diff",\n                "--exclude",\n                "scripts"' in method


def test_converge_exercises_real_sysstat_schema_migration_before_idempotency() -> None:
    project = RuntimePaths.discover().project
    suite = (project / "suites" / "converge.yaml").read_text(encoding="utf-8")
    seed = suite.index("- seed_sysstat_schema_migration")
    migration = suite.index("report: sysstat-migration")
    assertion = suite.index("- assert_sysstat_schema_migration")
    second = suite.index("report: second")
    idempotent = suite.index("- assert_idempotent")

    assert seed < migration < assertion < second < idempotent
    assert suite.count("repeat: true") == 2


def test_sysstat_schema_fixture_uses_real_optional_activity_boundaries() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    seed = source[
        source.index("def _seed_sysstat_schema_migration") : source.index(
            "def _assert_sysstat_schema_migration"
        )
    ]
    assertion = source[
        source.index("def _assert_sysstat_schema_migration") : source.index(
            "def _assert_idempotent"
        )
    ]

    assert "/usr/lib/sa/sadc -F -L 1 1" in seed
    assert "-S DISK,POWER" not in seed
    assert "sysstat-collect.timer sysstat-collect.service" in seed
    assert "sha256sum" in seed
    assert "sar -d" in assertion
    assert "sar -m CPU,FREQ,TEMP" in assertion
    assert "root:root:700" in assertion
    assert "root:root:600" in assertion
    assert "systemctl is-enabled --quiet sysstat-collect.timer" in assertion
    assert "systemctl is-active --quiet sysstat-collect.timer" in assertion
    assert "REPEAT_BOOTSTRAP_TIMEOUT_SECONDS + 15 * 60" in seed


def test_sysstat_schema_actions_are_dispatched() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    dispatcher = source[source.index("def _execute_step") :]

    assert 'action == "seed_sysstat_schema_migration"' in dispatcher
    assert "self._seed_sysstat_schema_migration(record)" in dispatcher
    assert 'action == "assert_sysstat_schema_migration"' in dispatcher
    assert "self._assert_sysstat_schema_migration(record)" in dispatcher


def test_power_reboot_waits_for_a_real_application_client(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = PowerClientGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    clients = service._wait_for_power_clients(
        {"run_id": "run-012345abcdef"}, timeout_seconds=1
    )

    assert clients == [
        {
            "address": "0xabc",
            "class": "com.mitchellh.ghostty",
            "title": "Enoshima Power Fixture",
            "pid": 42,
        }
    ]
    command = " ".join(guest.commands[0])
    assert "xembed-sni-proxy" in command
    assert "special:tray" in command
    assert "Enoshima Power Fixture" in command


def test_power_reboot_starts_a_closeable_wayland_fixture(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    service._start_power_client_fixture({"run_id": "run-012345abcdef"})

    command = " ".join(guest.commands[-1])
    assert "hl.dsp.exec_cmd" in command
    assert "ghostty" in command
    assert "--confirm-close-surface=false" in command
    assert "Enoshima Power Fixture" in command
    assert "sleep infinity" in command


def test_disposable_login_password_is_newline_free_for_gnome_keyring() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_login") : source.index("def _login_greetd")
    ]
    assert 'write_text(secrets.token_hex(16), encoding="utf-8")' in prepare
    keyring = source[
        source.index("def _assert_login_keyring") : source.index(
            "def _assert_graphical_health"
        )
    ]
    assert "the password for the login keyring was invalid" in keyring
    assert "set -euo pipefail" in keyring
    assert "probe-id" in keyring
    assert "trap cleanup EXIT" in keyring


def test_disposable_luks_recovery_key_is_newline_free(tmp_path: Path) -> None:
    recovery_key = tmp_path / "luks-recovery.key"

    _write_recovery_key(recovery_key)

    value = recovery_key.read_bytes()
    assert len(value) == 64
    assert set(value) <= set(b"0123456789abcdef")
    assert recovery_key.stat().st_mode & 0o777 == 0o600


def test_deterministic_login_suites_suppress_managed_application_autostarts() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_login") : source.index("def _login_greetd")
    ]

    assert 'suite in {"ui-review", "reboot"}' in prepare
    assert "def _suppress_managed_application_autostarts" in prepare
    assert "for entry in discord slack kakaotalk" in prepare
    assert "Hidden=true" in prepare
    assert "systemctl --user mask --force --now codex-update-manager.service" in prepare
    assert "systemctl --user mask --force --now vicinae.service" in prepare
    assert "_assert_deterministic_login_suppression(record)" in source
    suppression_assertion = source[
        source.index("def _assert_deterministic_login_suppression") : source.index(
            "def _assert_login_keyring"
        )
    ]
    assert "is-enabled " in suppression_assertion
    assert "codex-update-manager.service" in suppression_assertion
    assert 'services.append("vicinae.service")' in suppression_assertion
    assert "= masked" in suppression_assertion


def test_ui_review_starts_vicinae_only_after_the_keyring_probe(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    checked: list[tuple[str, tuple[str, ...], int]] = []

    def run_checked(
        _record,
        name,
        argv,
        _category,
        *,
        timeout_seconds,
    ):
        checked.append((name, tuple(argv), timeout_seconds))
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    monkeypatch.setattr(service, "_run_checked", run_checked)
    record = {"run_id": "run-012345abcdef", "suite": "ui-review"}

    service._start_ui_review_vicinae_after_keyring(record)

    assert checked[0][0] == "start-ui-review-vicinae-after-keyring"
    assert checked[0][2] == 40
    command = " ".join(checked[0][1])
    assert "systemctl --user unmask vicinae.service" in command
    assert "timeout --signal=TERM --kill-after=2s 25s" in command
    assert "systemctl --user start vicinae.service" in command
    assert "journalctl --user -u vicinae.service" in command
    assert "vicinae ping" in command
    assert (
        record["observations"]["ui_review_vicinae_started_after_keyring_probe"] is True
    )


def test_postflight_imports_the_live_graphical_environment_after_login() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    helper = source[source.index("def _graphical_shell") :]
    assert "systemctl --user show-environment" in helper
    assert "HYPRLAND_INSTANCE_SIGNATURE" in helper
    assert '"PATH=*|WAYLAND_DISPLAY=*' in helper
    postflight = source[source.index("def _run_postflight") :]
    assert 'get("greetd_login_at")' in postflight
    assert "self._graphical_shell(command)" in postflight


def test_hypr_commands_use_the_managed_user_path() -> None:
    command = VMService._hypr_command("desktop-window-action close --active")

    assert command[:2] == ["bash", "-lc"]
    assert "$HOME/.local/share/mise/shims:$HOME/.local/bin" in command[2]
    assert "systemctl --user show-environment" in command[2]
    assert "hyprctl -j instances" in command[2]
    assert "[.instance, .wl_socket] | @tsv" in command[2]
    assert 'test -S "$runtime/$wayland"' in command[2]
    assert 'test -S "$runtime/hypr/$sig/.socket.sock"' in command[2]
    assert 'find "$runtime"' not in command[2]
    assert command[2].endswith("desktop-window-action close --active")


def test_graphical_suites_reject_latent_session_failures() -> None:
    project = RuntimePaths.discover().project
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )
    method = source[source.index("def _graphical_health_failures") :]
    assert "systemctl --user --failed" in method
    assert "coredumpctl --since" in method
    assert '"$boot_started"' in method or '\\"$boot_started\\"' in method
    assert "TypeError|ReferenceError|Gtk-CRITICAL" in method
    assert "qs\\\\[" in method
    for suite in ("desktop", "login", "ui-review"):
        text = (project / "suites" / f"{suite}.yaml").read_text(encoding="utf-8")
        assert "- assert_graphical_health" in text
    desktop = (project / "suites" / "desktop.yaml").read_text(encoding="utf-8")
    assert "settle_seconds: 310" in desktop
    assert "app-slack@autostart.service" in desktop


def test_desktop_suite_runs_the_full_electron_action_matrix() -> None:
    project = RuntimePaths.discover().project
    desktop = (project / "suites" / "desktop.yaml").read_text(encoding="utf-8")
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )

    assert "run_electron_qualification" in desktop
    assert "iterations: 20" in desktop
    assert "expected_actions = 2 * 3 * iterations * 10" in source
    assert 'document.get("decorationOwner") != "enoshima-system"' in source
    assert "clientNativeMinimizeExposed" in source
    assert "len(fallback_probes) != 2" in source


def test_ui_review_closes_existing_clients_with_exact_addresses() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    cleanup = source.index("def _close_ui_review_clients")
    review = source.index("def _run_ui_review", cleanup)
    body = source[cleanup:review]
    assert "desktop-window-action close --address" in body
    assert "--origin compositor" in body
    assert "--origin vm-review" not in body
    assert "--active" not in body


def test_titlebar_review_uses_the_supported_maximize_action_contract() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    titlebar = source[
        source.index("def _start_titlebar_review") : source.index(
            "def _stop_desktop_shell_review"
        )
    ]

    assert "desktop-window-action maximize --address" in titlebar
    assert "--origin compositor" in titlebar
    assert "--origin vm-review" not in titlebar
    assert "maximize-titlebar-fixture" in titlebar


def test_titlebar_review_waits_for_the_production_menu_layer_transition() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]

    reset = review.index("present=False")
    fixture = review.index('elif case.surface == "system-titlebar"')
    ready = review.index("fixture_ack = self._wait_for_ui_fixture_ready", fixture)
    mapped = review.index("present=True", ready)
    capture = review.index("capture = self._capture_stable_ui", mapped)

    assert reset < fixture < ready < mapped < capture


def test_ui_review_cleanup_preserves_reserved_tray_clients() -> None:
    clients = [
        {
            "address": "0x1",
            "class": "xembed-sni-proxy",
            "workspace": {"id": -98, "name": "special:tray"},
        },
        {
            "address": "0x2",
            "class": "ghostty",
            "workspace": {"id": 1, "name": "1"},
        },
        {
            "address": "0x3",
            "class": "electron",
            "workspace": {"id": -99, "name": "special:minimized"},
        },
    ]

    targets = VMService._ui_review_cleanup_targets(clients)

    assert [client["address"] for client in targets] == ["0x2", "0x3"]


def test_notification_review_owns_the_dbus_daemon_without_systemd_races() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_notification_review") : source.index(
            "def _restore_notification_review"
        )
    ]
    start = source[
        source.index("def _start_notification_review") : source.index(
            "def _stop_titlebar_review"
        )
    ]
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]

    assert "systemctl --user stop swaync.service" in prepare
    assert "systemctl --user mask --runtime --force swaync.service" in prepare
    assert "systemctl --user stop swaync.service" not in start
    assert "org.freedesktop.Notifications" in start
    assert 'test "$owner" = "$pid"' in start
    assert 'if "notification-center" in surfaces:' in review
    assert "self._prepare_notification_review(record)" in review
    assert "self._restore_notification_review" in source


def test_ui_review_resets_quickshell_layers_at_every_surface_boundary() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]
    reset = review.index("self._reset_ui_review_surface(record)")
    branch = review.index('if case.surface == "auth"')
    fixture_reset = review.index('record, "desktop-shell", "default", output', reset)

    assert reset < fixture_reset < branch
    assert "self._wait_for_ui_fixture_ready(record, reset_sequence)" in review


def test_ui_review_rejects_identical_required_states() -> None:
    captures = [
        {
            "surface_id": "notification-center",
            "state": state,
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "image_sha256": "same-image",
        }
        for state in ("empty", "notification", "critical")
    ]
    captures.append(
        {
            "surface_id": "notification-center",
            "state": "empty",
            "locale": "ko_KR.UTF-8",
            "scale": 1.0,
            "image_sha256": "only-one-state",
        }
    )

    failures = VMService._ui_review_identical_state_groups(captures)

    assert failures == [
        {
            "surface": "notification-center",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "states": ["critical", "empty", "notification"],
        }
    ]


def test_external_ui_review_rejects_identical_semantic_state_pairs() -> None:
    captures = [
        {
            "surface_id": "command-palette",
            "state": state,
            "locale": "ko_KR.UTF-8",
            "scale": 1.25,
            "image_sha256": image,
        }
        for state, image in (
            ("default", "default"),
            ("search", "duplicate"),
            ("empty-results", "empty"),
            ("long-title", "duplicate"),
            ("clipboard-history", "clipboard"),
            ("emoji-picker", "emoji"),
        )
    ]

    assert VMService._ui_review_identical_required_pairs(captures) == [
        {
            "surface": "command-palette",
            "locale": "ko_KR.UTF-8",
            "scale": 1.25,
            "states": ["search", "long-title"],
        }
    ]


def test_ui_review_state_comparisons_prefer_semantic_hashes() -> None:
    distinct = [
        {
            "surface_id": "command-palette",
            "state": state,
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "image_sha256": "same-full-frame",
            "semantic_sha256": f"semantic-{state}",
        }
        for state in ("default", "search")
    ]
    identical = [
        {
            "surface_id": "command-palette",
            "state": state,
            "locale": "ko_KR.UTF-8",
            "scale": 1.0,
            "image_sha256": f"full-frame-{state}",
            "semantic_sha256": "same-semantic-region",
        }
        for state in ("default", "search")
    ]

    assert VMService._ui_review_identical_state_groups(distinct) == []
    assert VMService._ui_review_identical_required_pairs(distinct) == []
    assert VMService._ui_review_identical_state_groups(identical)
    assert VMService._ui_review_identical_required_pairs(identical)


def test_command_palette_semantic_hash_ignores_search_caret_only(
    tmp_path: Path,
) -> None:
    baseline = tmp_path / "baseline.png"
    caret = tmp_path / "caret.png"
    changed_result = tmp_path / "changed-result.png"

    def render(path: Path, *drawings: str) -> None:
        command = [
            "magick",
            "-size",
            "1280x800",
            "xc:black",
            "-fill",
            "white",
            "-draw",
            "rectangle 300,300 900,360",
        ]
        for drawing in drawings:
            command.extend(["-draw", drawing])
        subprocess.run([*command, str(path)], check=True, capture_output=True)

    render(baseline)
    render(caret, "rectangle 638,178 641,202")
    render(changed_result, "rectangle 420,420 760,450")

    baseline_hash = VMService._ui_review_semantic_sha256(
        baseline, "command-palette", 1.0
    )
    assert (
        VMService._ui_review_semantic_sha256(caret, "command-palette", 1.0)
        == baseline_hash
    )
    assert (
        VMService._ui_review_semantic_sha256(changed_result, "command-palette", 1.0)
        != baseline_hash
    )


def test_overview_multi_monitor_pair_compares_the_common_primary_output() -> None:
    captures = [
        {
            "surface_id": "overview",
            "state": "all-workspaces",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "semantic_sha256": "single-output-aggregate",
            "semantic_outputs": {"HEADLESS-UI": "same-primary"},
        },
        {
            "surface_id": "overview",
            "state": "multi-monitor",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "semantic_sha256": "two-output-aggregate",
            "semantic_outputs": {
                "HEADLESS-UI": "same-primary",
                "HEADLESS-AUX": "different-auxiliary",
            },
        },
    ]

    assert VMService._ui_review_identical_required_pairs(captures) == [
        {
            "surface": "overview",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "states": ["all-workspaces", "multi-monitor"],
        }
    ]


def test_overview_selected_workspace_must_differ_from_the_baseline() -> None:
    captures = [
        {
            "surface_id": "overview",
            "state": state,
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "semantic_sha256": semantic_hash,
        }
        for state, semantic_hash in (
            ("all-workspaces", "baseline"),
            ("selected-window", "window-selection"),
            ("selected-workspace", "baseline"),
            ("multi-monitor", "multi-monitor"),
            ("no-windows", "no-windows"),
        )
    ]

    assert VMService._ui_review_identical_state_groups(captures) == []
    assert VMService._ui_review_identical_required_pairs(captures) == [
        {
            "surface": "overview",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "states": ["all-workspaces", "selected-workspace"],
        }
    ]


def test_overview_semantic_metrics_reject_blank_aux_and_detect_two_pixel_edge(
    tmp_path: Path,
) -> None:
    blank = tmp_path / "blank.png"
    baseline = tmp_path / "baseline.png"
    selected = tmp_path / "selected.png"
    subprocess.run(
        ["magick", "-size", "1280x800", "xc:#10131a", str(blank)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            "magick",
            "-size",
            "1280x800",
            "xc:#10131a",
            "-fill",
            "#202738",
            "-draw",
            "roundrectangle 110,150 570,620 18,18",
            "-fill",
            "#2d3850",
            "-draw",
            "roundrectangle 650,190 1170,660 18,18",
            "-stroke",
            "#7aa2f7",
            "-strokewidth",
            "3",
            "-draw",
            "line 150,240 520,520",
            str(baseline),
        ],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            "magick",
            str(baseline),
            "-fill",
            "none",
            "-stroke",
            "#bb9af7",
            "-strokewidth",
            "2",
            "-draw",
            "rectangle 105,145 575,625",
            str(selected),
        ],
        check=True,
        capture_output=True,
    )

    blank_metrics = VMService._ui_review_semantic_metrics(blank, "overview", 1.0)
    baseline_metrics = VMService._ui_review_semantic_metrics(baseline, "overview", 1.0)
    assert int(blank_metrics["unique_gray_values"]) < UI_SEMANTIC_MIN_UNIQUE_GRAY_VALUES
    assert (
        float(blank_metrics["normalized_standard_deviation"])
        < UI_SEMANTIC_MIN_NORMALIZED_STDDEV
    )
    assert (
        int(baseline_metrics["unique_gray_values"])
        >= UI_SEMANTIC_MIN_UNIQUE_GRAY_VALUES
    )
    assert (
        float(baseline_metrics["normalized_standard_deviation"])
        >= UI_SEMANTIC_MIN_NORMALIZED_STDDEV
    )
    assert VMService._ui_review_semantic_sha256(
        baseline, "overview", 1.0
    ) != VMService._ui_review_semantic_sha256(selected, "overview", 1.0)


def test_overview_navigation_cue_mask_tracks_only_the_approved_color(
    tmp_path: Path,
) -> None:
    image = tmp_path / "cue.png"
    subprocess.run(
        [
            "magick",
            "-size",
            "1280x800",
            "xc:#f2ecff",
            "-fill",
            "#62d8ff",
            "-draw",
            "rectangle 100,100 119,119",
            "-fill",
            "#9a5cff",
            "-draw",
            "rectangle 200,200 229,229",
            str(image),
        ],
        check=True,
        capture_output=True,
    )

    window = VMService._overview_navigation_cue_mask(image, "selected-window", 1.0)
    workspace = VMService._overview_navigation_cue_mask(
        image, "selected-workspace", 1.0
    )

    assert VMService._overview_navigation_cue_metrics(window)["selected_pixels"] == 400
    assert (
        VMService._overview_navigation_cue_metrics(workspace)["selected_pixels"]
        == 900
    )


def test_ui_review_resets_clients_at_every_surface_boundary() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    reset = source[source.index("def _reset_ui_review_surface") :]
    review = source[source.index("def _run_ui_review") :]

    assert "self._stop_auth_review(record)" in reset
    assert "self._stop_command_palette_review(record)" in reset
    assert "self._stop_notification_review(record)" in reset
    assert "self._stop_overview_review(record)" in reset
    assert "self._stop_titlebar_review(record)" in reset
    assert "self._stop_desktop_shell_review(record)" in reset
    assert "self._close_ui_review_clients(record)" in reset
    assert "for case in matrix:" in review
    assert "self._reset_ui_review_surface(record)" in review


def test_external_ui_review_adapters_use_production_services() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    command_palette = source[
        source.index("def _start_command_palette_review") : source.index(
            "def _restart_overview_service"
        )
    ]
    overview = source[
        source.index("def _open_overview_layers") : source.index(
            "def _ui_review_cleanup_targets"
        )
    ]
    overview_cleanup = source[
        source.index("def _stop_overview_review") : source.index(
            "def _open_overview_layers"
        )
    ]

    assert "systemctl --user restart vicinae.service" in source
    assert "systemctl --user reset-failed vicinae.service" in source
    assert "systemctl --user reset-failed hyprshell.service" in source
    assert "HYPRSHELL_NO_LISTENERS=1" in source
    assert "unset-environment HYPRSHELL_NO_LISTENERS" in source
    assert "old_lang=$(systemctl --user show-environment" in source
    assert 'set-environment "$old_lang"' in source
    assert "command_palette_locale" in source
    assert "overview_environment" in source
    assert 'case.state == "multi-monitor"' in source
    assert 'overview_previous_state == "multi-monitor"' in source
    assert "vicinae://launch/clipboard/history" in command_palette
    assert "vicinae://launch/core/search-emojis" in command_palette
    assert '"search": "resources"' in command_palette
    assert '"empty-results": "zzzzzzzz"' in command_palette
    assert "WAYLAND_DISPLAY" in source
    assert "OpenOverview" in overview
    assert "close-overview-layer" in overview_cleanup
    assert "hyprshell socat" in overview_cleanup
    assert '"KEY_ESC"' in overview_cleanup
    assert "Reload" in overview_cleanup
    assert "hyprshell socat '\"OpenOverview\"'" not in overview_cleanup
    assert "hl.get_layers" in source
    assert "layer.mapped" in source
    assert "__ENOSHIMA_UI_LAYER_MAPPED__" in source
    assert "_acknowledge_overview_navigation" in overview
    assert '["KEY_TAB"]' in overview
    assert '["KEY_RIGHT"]' in overview
    assert 'navigation_output = "HEADLESS-AUX"' in overview
    assert "overview_auxiliary_scale(scale)" in overview
    assert '"HEADLESS-AUX"' in overview
    assert "active_workspace = 1" in overview
    assert "active_workspace = 3" not in overview
    assert "hl.dsp.workspace.move" in overview
    assert "moveworkspacetomonitor" not in overview
    assert '"hyprshell_launcher"' in overview
    assert re.search(r'"hyprshell_launcher",\s+present=False,', overview)
    assert "allow_transparent=True" not in overview
    assert "max_width=256" not in overview
    assert "max_height=256" not in overview
    assert 'service_unit="hyprshell.service"' in overview
    assert 'f"{case.artifact_name}--headless-aux"' in source
    assert '"semantic_outputs": semantic_outputs' in source
    assert "--cursor-opacity=0" in overview
    assert "--confirm-close-surface=false" in overview
    assert "clear-ui-review-notifications" in source
    assert "swaync-client -cp -sw; swaync-client -C -sw" in source


def test_overview_service_quiesces_around_display_reconciliation(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    calls: list[str] = []
    topology = {"converged": True, "service_active": True}

    def stop(_record) -> None:
        calls.append("stop")
        topology["service_active"] = False

    def restart(_record, _locale) -> None:
        calls.append("restart")
        assert topology["converged"] is True
        assert topology["service_active"] is False
        topology["service_active"] = True

    def configure(_record, config) -> None:
        calls.append("configure")
        assert topology["service_active"] is False
        assert config == {
            "disable_unlisted": True,
            "monitors": [
                {
                    "name": "HEADLESS-UI",
                    "mode": "1280x800@60",
                    "position": "0x0",
                    "scale": "1",
                }
            ],
        }
        topology["converged"] = True

    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_stop_overview_service", stop)
    monkeypatch.setattr(service, "_restart_overview_service", restart)
    monkeypatch.setattr(service, "_configure_virtual_displays", configure)
    monkeypatch.setattr(service, "_open_overview_layers", lambda *_args: None)
    monkeypatch.setattr(
        service,
        "_acknowledge_overview_navigation",
        lambda *_args: None,
    )

    service._start_overview_review(
        {},
        "en_US.UTF-8",
        "no-windows",
        1.0,
        "HEADLESS-UI",
        True,
    )

    assert calls == ["stop", "configure", "restart"]
    assert topology["converged"] is True
    assert topology["service_active"] is True


def test_overview_restart_temporarily_owns_monitor_policy(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    checked: list[tuple[str, tuple[str, ...], int]] = []

    def run_checked(
        _record,
        name,
        argv,
        _category,
        *,
        timeout_seconds,
    ):
        checked.append((name, tuple(argv), timeout_seconds))
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    monkeypatch.setattr(service, "_run_checked", run_checked)

    service._restart_overview_service({}, "en_US.UTF-8")

    assert checked[0][0] == "restart-overview-service"
    assert checked[0][2] == 30
    command = " ".join(checked[0][1])
    set_policy = command.index(
        "systemctl --user set-environment HYPRSHELL_NO_LISTENERS=1"
    )
    restart = command.index("systemctl --user restart hyprshell.service")
    assert set_policy < restart
    assert "old_no_listeners=$(systemctl --user show-environment" in command
    assert "restore_manager_locale" in command
    assert "unset-environment HYPRSHELL_NO_LISTENERS" in command
    assert 'set-environment "$old_no_listeners"' in command


def test_command_palette_review_bounds_vicinae_ipc_before_layer_assertion(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    checked: list[tuple[str, tuple[str, ...], int]] = []
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "_prepare_command_palette_review_scripts",
        lambda _record, _state: "Resources",
    )
    monkeypatch.setattr(
        service,
        "_restart_command_palette_service",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_wait_for_ui_review_layer",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    def run_checked(
        _record,
        name,
        argv,
        _category,
        *,
        timeout_seconds,
    ):
        checked.append((name, tuple(argv), timeout_seconds))
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    monkeypatch.setattr(service, "_run_checked", run_checked)

    service._start_command_palette_review(
        {"run_id": "run-012345abcdef"},
        "en_US.UTF-8",
        "default",
        "HEADLESS-UI",
        True,
    )

    assert checked[0][0] == "control-command-palette-default"
    assert checked[0][2] == 10
    assert checked[0][1][:5] == (
        "timeout",
        "--signal=TERM",
        "--kill-after=1s",
        "8s",
        "bash",
    )
    command = " ".join(checked[0][1])
    assert "timeout --signal=TERM --kill-after=1s 5s" in command
    assert "vicinae toggle" in command
    assert "</dev/null >/dev/null 2>&1" in command
    assert "124)" in command
    assert guest.commands == []


def test_command_palette_clipboard_seed_detaches_ssh_output(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "_prepare_command_palette_review_scripts",
        lambda _record, _state: "Resources",
    )
    monkeypatch.setattr(
        service,
        "_restart_command_palette_service",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_run_vicinae_control",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_wait_for_ui_review_layer",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    service._start_command_palette_review(
        {"run_id": "run-012345abcdef"},
        "en_US.UTF-8",
        "clipboard-history",
        "HEADLESS-UI",
        True,
    )

    assert len(guest.commands) == 1
    command = " ".join(guest.commands[0])
    assert "printf 'Enoshima clipboard review' | wl-copy >/dev/null 2>&1" in command
    assert "sleep 0.5" in command


def test_command_palette_readiness_probe_exits_before_ssh_timeout(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    checked: list[tuple[str, tuple[str, ...], int]] = []

    def run_checked(
        _record,
        name,
        argv,
        _category,
        *,
        timeout_seconds,
    ):
        checked.append((name, tuple(argv), timeout_seconds))
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    monkeypatch.setattr(service, "_run_checked", run_checked)

    service._restart_command_palette_service(
        {"run_id": "run-012345abcdef"},
        "en_US.UTF-8",
        "Resources",
        True,
    )

    assert checked[0][0] == "restart-command-palette-en_US.UTF-8"
    assert checked[0][2] == 55
    command = " ".join(checked[0][1])
    assert "timeout --signal=TERM --kill-after=2s 25s" in command
    assert "timeout --signal=TERM --kill-after=1s 1s vicinae ping" in command
    assert "timeout --signal=TERM --kill-after=1s 1s vicinae cmd list" in command
    assert "ping_status=" in command
    assert "command_status=" in command
    assert "systemctl --user show vicinae.service" in command
    assert "journalctl --user -u vicinae.service" in command


def test_overview_navigation_retry_preserves_topology_until_the_approved_cue(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    events: list[str] = []

    class Backend:
        @staticmethod
        def send_keys(_domain: str, domain_uuid: str, keys: list[str]) -> None:
            assert domain_uuid == "11111111-2222-3333-4444-555555555555"
            events.append(f"key:{keys[0]}")

    class Guest:
        commands: list[tuple[str, ...]] = []

        def exec(self, argv, **_kwargs):
            self.commands.append(tuple(argv))
            return CommandResult(tuple(argv), 0, "", "")

    guest = Guest()
    service.backend = Backend()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "_stop_overview_review",
        lambda _record: pytest.fail("navigation retry must preserve review topology"),
    )
    monkeypatch.setattr(
        service,
        "_close_overview_layers",
        lambda _record: events.append("close"),
    )
    monkeypatch.setattr(
        service,
        "_open_overview_layers",
        lambda _record, _state, _output: events.append("open"),
    )
    frames = iter(("baseline", "focus-artifact", "baseline", "selected"))

    def capture(_record, name, _output, **_kwargs):
        path = tmp_path / "screenshots" / f"{name}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(next(frames), encoding="utf-8")
        return {"path": str(path), "width": 1280, "height": 800}

    monkeypatch.setattr(service, "_capture_stable_ui", capture)
    masks = {
        "baseline": bytes([0]) * 1000,
        # A generic semantic/focus change is deliberately below the approved
        # cue threshold and must not acknowledge navigation.
        "focus-artifact": bytes([255]) * 10 + bytes([0]) * 990,
        "selected": bytes([255]) * 400 + bytes([0]) * 600,
    }
    monkeypatch.setattr(
        service,
        "_overview_navigation_cue_mask",
        lambda path, _state, _scale: masks[path.read_text(encoding="utf-8")],
    )
    clock = iter((0.0, 10.0, 20.0))
    monkeypatch.setattr("enoshima_vm.service.time.monotonic", lambda: next(clock))

    service._acknowledge_overview_navigation(
        {
            "domain": "enoshima-vm",
            "domain_uuid": "11111111-2222-3333-4444-555555555555",
            "run_id": "run-012345abcdef",
        },
        "selected-workspace",
        1.0,
        "HEADLESS-UI",
    )

    assert events == ["key:KEY_RIGHT", "close", "open", "key:KEY_RIGHT"]
    assert not list((tmp_path / "screenshots").glob("*.png"))
    assert guest.commands[-1][:2] == ("rm", "-f")


def test_ui_review_layer_rejects_a_service_pid_mismatch(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j layers" in command:
                return CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        {
                            "HEADLESS-UI": {
                                "levels": {
                                    "top": [
                                        {
                                            "namespace": "vicinae",
                                            "w": 770,
                                            "h": 480,
                                            "alpha": 1.0,
                                            "pid": 123,
                                        }
                                    ]
                                }
                            }
                        }
                    ),
                    "",
                )
            if "systemctl --user show --property MainPID" in command:
                return CommandResult(tuple(argv), 0, "999\n", "")
            raise AssertionError(command)

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service,
        "_ui_review_layer_mapping_state",
        lambda _record, _namespace, _output: (True, "mapped"),
    )

    with pytest.raises(VMError, match="production UI layer did not appear"):
        service._wait_for_ui_review_layer(
            {"run_id": "run-012345abcdef"},
            "HEADLESS-UI",
            "vicinae",
            present=True,
            service_unit="vicinae.service",
            timeout_seconds=0.01,
        )


def test_ui_review_layer_accepts_hyprland_057_without_alpha(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j layers" in command:
                return CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        {
                            "HEADLESS-UI": {
                                "levels": {
                                    "top": [
                                        {
                                            "namespace": "vicinae",
                                            "w": 770,
                                            "h": 480,
                                            "pid": 123,
                                        }
                                    ]
                                }
                            }
                        }
                    ),
                    "",
                )
            if "systemctl --user show --property MainPID" in command:
                return CommandResult(tuple(argv), 0, "123\n", "")
            raise AssertionError(command)

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service,
        "_ui_review_layer_mapping_state",
        lambda _record, _namespace, _output: (True, "mapped"),
    )

    service._wait_for_ui_review_layer(
        {"run_id": "run-012345abcdef"},
        "HEADLESS-UI",
        "vicinae",
        present=True,
        service_unit="vicinae.service",
        timeout_seconds=1,
    )


def test_ui_review_layer_accepts_bounded_transparent_keyboard_controller(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j layers" in command:
                return CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        {
                            "HEADLESS-UI": {
                                "levels": {
                                    "overlay": [
                                        {
                                            "namespace": "hyprshell_launcher",
                                            "w": 200,
                                            "h": 200,
                                            "alpha": 0.0,
                                            "pid": 123,
                                        }
                                    ]
                                }
                            }
                        }
                    ),
                    "",
                )
            if "systemctl --user show --property MainPID" in command:
                return CommandResult(tuple(argv), 0, "123\n", "")
            raise AssertionError(command)

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service,
        "_ui_review_layer_mapping_state",
        lambda _record, _namespace, _output: (True, "mapped"),
    )

    service._wait_for_ui_review_layer(
        {"run_id": "run-012345abcdef"},
        "HEADLESS-UI",
        "hyprshell_launcher",
        present=True,
        service_unit="hyprshell.service",
        allow_transparent=True,
        max_width=256,
        max_height=256,
        timeout_seconds=1,
    )


def test_ui_review_layer_rejects_oversized_keyboard_controller(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j layers" in command:
                return CommandResult(
                    tuple(argv),
                    0,
                    json.dumps(
                        {
                            "HEADLESS-UI": {
                                "levels": {
                                    "overlay": [
                                        {
                                            "namespace": "hyprshell_launcher",
                                            "w": 320,
                                            "h": 240,
                                            "alpha": 0.0,
                                            "pid": 123,
                                        }
                                    ]
                                }
                            }
                        }
                    ),
                    "",
                )
            if "systemctl --user show --property MainPID" in command:
                return CommandResult(tuple(argv), 0, "123\n", "")
            raise AssertionError(command)

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service,
        "_ui_review_layer_mapping_state",
        lambda _record, _namespace, _output: (True, "mapped"),
    )

    with pytest.raises(VMError, match="production UI layer did not appear"):
        service._wait_for_ui_review_layer(
            {"run_id": "run-012345abcdef"},
            "HEADLESS-UI",
            "hyprshell_launcher",
            present=True,
            service_unit="hyprshell.service",
            allow_transparent=True,
            max_width=256,
            max_height=256,
            timeout_seconds=0.01,
        )


@pytest.mark.parametrize(
    ("response", "expected"),
    [
        ("error: __ENOSHIMA_UI_LAYER_MAPPED__\n", True),
        ("ok\n", False),
        ("error: unrelated lua failure\n", None),
    ],
)
def test_ui_review_layer_mapping_state_uses_hyprland_lua_contract(
    tmp_path: Path,
    monkeypatch,
    response: str,
    expected: bool | None,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    commands: list[str] = []

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            commands.append(command)
            return CommandResult(tuple(argv), 0, response, "")

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())

    mapped, observed = service._ui_review_layer_mapping_state(
        {"run_id": "run-012345abcdef"},
        "hyprshell_overview",
        "HEADLESS-UI",
    )

    assert mapped is expected
    assert observed == response.strip()
    assert len(commands) == 1
    assert "hyprctl eval" in commands[0]
    assert "hl.get_layers" in commands[0]
    assert "layer.mapped" in commands[0]
    assert "HEADLESS-UI" in commands[0]
    assert "hyprshell_overview" in commands[0]


def test_ui_review_layer_accepts_unmapped_persistent_namespace_as_absent(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    probes = 0

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j layers" not in command:
                raise AssertionError(command)
            return CommandResult(
                tuple(argv),
                0,
                json.dumps(
                    {
                        "HEADLESS-UI": {
                            "levels": {
                                "top": [
                                    {
                                        "namespace": "hyprshell_overview",
                                        "w": 1280,
                                        "h": 800,
                                        "pid": 321,
                                    }
                                ]
                            }
                        }
                    }
                ),
                "",
            )

    def mapping_state(_record, _namespace, _output):
        nonlocal probes
        probes += 1
        return False, "ok"

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(service, "_ui_review_layer_mapping_state", mapping_state)

    service._wait_for_ui_review_layer(
        {"run_id": "run-012345abcdef"},
        "HEADLESS-UI",
        "hyprshell_overview",
        present=False,
        timeout_seconds=1,
    )

    assert probes == 2


def test_overview_cleanup_restores_topology_after_layer_close_failure(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    class Guest:
        def __init__(self) -> None:
            self.aux_present = True
            self.workspace_outputs = {
                1: "HEADLESS-AUX",
                2: "HEADLESS-AUX",
                3: "HEADLESS-UI",
                4: "HEADLESS-AUX",
                5: "HEADLESS-UI",
            }
            self.commands: list[str] = []
            self.events: list[str] = []

        def exec_retryable(self, argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j monitors" in command:
                monitors = [{"name": "HEADLESS-UI"}]
                if self.aux_present:
                    monitors.append({"name": "HEADLESS-AUX"})
                return CommandResult(tuple(argv), 0, json.dumps(monitors), "")
            if "hyprctl -j workspaces" in command:
                workspaces = [
                    {"id": workspace, "monitor": monitor}
                    for workspace, monitor in self.workspace_outputs.items()
                ]
                return CommandResult(tuple(argv), 0, json.dumps(workspaces), "")
            raise AssertionError(command)

        def exec(self, argv, **_kwargs):
            command = " ".join(argv)
            self.commands.append(command)
            if "hl.dsp.workspace.move" in command:
                self.events.append("move-workspace")
                match = re.search(r"workspace = (\d+)", command)
                assert match is not None
                self.workspace_outputs[int(match.group(1))] = "HEADLESS-UI"
            elif "hyprctl output remove HEADLESS-AUX" in command:
                self.events.append("remove-output")
                self.aux_present = False
            return CommandResult(tuple(argv), 0, "", "")

    guest = Guest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "_stop_overview_service",
        lambda _record: guest.events.append("stop-service"),
    )
    monkeypatch.setattr(
        service,
        "_close_ui_review_clients",
        lambda _record: guest.events.append("close-clients"),
    )
    monkeypatch.setattr(service.backend, "send_keys", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(
        service,
        "_run_checked",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            RuntimeError("injected close failure")
        ),
    )
    monkeypatch.setattr(
        service,
        "_ui_review_layer_present",
        lambda _record, namespace: namespace == "hyprshell_overview",
    )
    monkeypatch.setattr(
        service,
        "_wait_for_ui_review_layer",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "injected stale overview layer",
            )
        ),
    )

    with pytest.raises(VMError, match="recoverable errors"):
        service._stop_overview_review(
            {"domain": "enoshima-vm", "run_id": "run-012345abcdef"}
        )

    assert guest.aux_present is False
    assert set(guest.workspace_outputs.values()) == {"HEADLESS-UI"}
    assert any("hyprctl output remove HEADLESS-AUX" in cmd for cmd in guest.commands)
    assert guest.events[-3:] == [
        "close-clients",
        "stop-service",
        "remove-output",
    ]
    assert guest.events.index("move-workspace") < guest.events.index("close-clients")


@pytest.mark.parametrize(
    ("overview_present", "launcher_present"),
    [(True, True), (False, True)],
)
def test_overview_cleanup_uses_escape_to_avoid_reopening_the_model(
    tmp_path: Path,
    monkeypatch,
    overview_present: bool,
    launcher_present: bool,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    events: list[str] = []
    layers = {
        "hyprshell_overview": overview_present,
        "hyprshell_launcher": launcher_present,
    }

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j monitors" in command:
                return CommandResult(tuple(argv), 0, '[{"name":"HEADLESS-UI"}]', "")
            if "hyprctl -j workspaces" in command:
                return CommandResult(tuple(argv), 0, "[]", "")
            raise AssertionError(command)

    def send_keys(domain, domain_uuid, keys):
        assert domain == "enoshima-vm"
        assert domain_uuid == "11111111-2222-3333-4444-555555555555"
        assert keys == ["KEY_ESC"]
        events.append("escape")
        layers["hyprshell_overview"] = False
        layers["hyprshell_launcher"] = False

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(service.backend, "send_keys", send_keys)
    monkeypatch.setattr(
        service,
        "_run_checked",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("reload fallback should not run")
        ),
    )
    monkeypatch.setattr(
        service,
        "_ui_review_layer_present",
        lambda _record, namespace: layers[namespace],
    )
    monkeypatch.setattr(
        service,
        "_wait_for_ui_review_layer",
        lambda _record, _output, namespace, **_kwargs: events.append(
            f"wait:{namespace}"
        ),
    )

    service._stop_overview_review(
        {
            "domain": "enoshima-vm",
            "domain_uuid": "11111111-2222-3333-4444-555555555555",
            "run_id": "run-012345abcdef",
        }
    )

    assert events == [
        "escape",
        "wait:hyprshell_overview",
        "wait:hyprshell_launcher",
    ]


def test_overview_cleanup_reloads_after_escape_does_not_settle(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    events: list[str] = []
    wait_calls = 0

    class Guest:
        @staticmethod
        def exec_retryable(argv, **_kwargs):
            command = " ".join(argv)
            if "hyprctl -j monitors" in command:
                return CommandResult(tuple(argv), 0, '[{"name":"HEADLESS-UI"}]', "")
            if "hyprctl -j workspaces" in command:
                return CommandResult(tuple(argv), 0, "[]", "")
            raise AssertionError(command)

    def wait_for_layer(_record, _output, namespace, **kwargs):
        nonlocal wait_calls
        wait_calls += 1
        events.append(f"wait:{namespace}:{kwargs.get('timeout_seconds', 20)}")
        if wait_calls <= 2:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "injected stale overview layer",
            )

    def run_checked(_record, name, argv, _category, *, timeout_seconds):
        events.append(name)
        assert timeout_seconds == 30
        command = " ".join(argv)
        assert "hyprshell socat" in command
        assert "Reload" in command
        assert "OpenOverview" not in command
        assert "systemctl --user restart" not in command

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service.backend,
        "send_keys",
        lambda domain, domain_uuid, keys: events.append(
            f"escape:{domain}:{domain_uuid}:{keys[0]}"
        ),
    )
    monkeypatch.setattr(service, "_run_checked", run_checked)
    monkeypatch.setattr(
        service,
        "_ui_review_layer_present",
        lambda _record, _namespace: True,
    )
    monkeypatch.setattr(service, "_wait_for_ui_review_layer", wait_for_layer)

    service._stop_overview_review(
        {
            "domain": "enoshima-vm",
            "domain_uuid": "11111111-2222-3333-4444-555555555555",
            "run_id": "run-012345abcdef",
        }
    )

    assert events == [
        "escape:enoshima-vm:11111111-2222-3333-4444-555555555555:KEY_ESC",
        "wait:hyprshell_overview:5",
        "escape:enoshima-vm:11111111-2222-3333-4444-555555555555:KEY_ESC",
        "wait:hyprshell_overview:5",
        "close-overview-layer",
        "wait:hyprshell_overview:20",
        "wait:hyprshell_launcher:20",
    ]


def test_ui_review_cleanup_runs_after_every_exit_path() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    wrapper = source[
        source.index("def _run_ui_review(") : source.index("def _run_ui_review_body")
    ]
    cleanup = source[
        source.index("def _cleanup_ui_review") : source.index("def _run_ui_review(")
    ]

    assert "finally:" in wrapper
    assert "self._cleanup_ui_review(" in wrapper
    assert "best_effort=failure is not None" in wrapper
    assert "ui_review_cleanup_errors" in wrapper
    assert "self._stop_command_palette_review(record)" in cleanup
    assert "self._stop_overview_review(" in cleanup
    assert "self._restore_external_ui_review_services" in cleanup


def test_screenshot_can_target_one_compositor_output(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "load_record",
        lambda _run_id: {
            "run_id": "run-012345abcdef",
            "artifact_dir": str(tmp_path / "artifacts"),
        },
    )
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)

    result = service.screenshot("run-012345abcdef", "launcher-en", "HEADLESS-INTERNAL")

    command = " ".join(guest.commands[-1])
    assert "grim -o HEADLESS-INTERNAL" in command
    assert command.count("hyprctl -j instances") == 1
    assert "wayland=$(find" not in command
    assert result["output"] == "HEADLESS-INTERNAL"


def test_virtual_monitor_uses_the_hyprland_lua_evaluator() -> None:
    expression = VMService._monitor_eval_expression(
        "HEADLESS-EXTERNAL", "2560x1440@60", "-2560x0", "1.25"
    )

    assert expression == (
        'hl.monitor({ output = "HEADLESS-EXTERNAL", '
        'mode = "2560x1440@60", position = "-2560x0", scale = 1.25 })'
    )
    assert VMService._monitor_disable_expression("Virtual-1") == (
        'hl.monitor({ output = "Virtual-1", disabled = true })'
    )


def test_virtual_displays_apply_one_atomic_monitor_rule_batch(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    events: list[tuple[str, str]] = []
    observations = [
        [
            {"name": "HEADLESS-INTERNAL"},
            {"name": "Virtual-1"},
        ],
        [
            {"name": "HEADLESS-INTERNAL"},
            {"name": "HEADLESS-EXTERNAL"},
            {"name": "Virtual-1", "disabled": True},
        ],
        [
            {
                "name": "HEADLESS-INTERNAL",
                "width": 2880,
                "height": 1800,
                "x": 0,
                "y": 0,
                "scale": 1.5,
                "disabled": False,
            },
            {
                "name": "HEADLESS-EXTERNAL",
                "width": 2560,
                "height": 1440,
                "x": 1920,
                "y": 0,
                "scale": 1,
                "disabled": False,
            },
            {"name": "Virtual-1", "disabled": True},
        ],
    ]

    class Guest:
        @staticmethod
        def exec(argv, **_kwargs):
            events.append(("create", " ".join(argv)))
            return CommandResult(tuple(argv), 0, "", "")

        @staticmethod
        def exec_retryable(argv, **_kwargs):
            events.append(("observe", " ".join(argv)))
            observation = (
                observations.pop(0) if len(observations) > 1 else observations[0]
            )
            return CommandResult(
                tuple(argv),
                0,
                json.dumps(observation),
                "",
            )

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_run_checked",
        lambda _record, name, argv, _category, **_kwargs: events.append(
            (name, " ".join(argv))
        ),
    )

    service._configure_virtual_displays(
        {"run_id": "run-012345abcdef"},
        {
            "monitors": [
                {
                    "name": "HEADLESS-INTERNAL",
                    "mode": "2880x1800@60",
                    "position": "0x0",
                    "scale": 1.5,
                },
                {
                    "name": "HEADLESS-EXTERNAL",
                    "mode": "2560x1440@60",
                    "position": "1920x0",
                    "scale": 1,
                },
            ],
            "disable_unlisted": True,
        },
    )

    assert [event[0] for event in events[:4]] == [
        "observe",
        "create",
        "observe",
        "configure-virtual-displays",
    ]
    assert "hyprctl -j monitors all" in events[0][1]
    assert "output create headless HEADLESS-EXTERNAL" in events[1][1]
    assert "output create headless HEADLESS-INTERNAL" not in events[1][1]
    assert "hyprctl -j monitors all" in events[2][1]
    batch = events[3][1]
    assert batch.count("hyprctl eval") == 1
    assert batch.count("hl.monitor({") == 3
    assert 'output = "HEADLESS-INTERNAL"' in batch
    assert 'output = "HEADLESS-EXTERNAL"' in batch
    assert 'output = "Virtual-1", disabled = true' in batch
    assert batch.index("HEADLESS-INTERNAL") < batch.index("HEADLESS-EXTERNAL")
    assert batch.index("HEADLESS-EXTERNAL") < batch.index("Virtual-1")
    assert [event[0] for event in events[4:]] == ["observe"] * 10
    assert all("hyprctl -j monitors all" in event[1] for event in events[4:])


def test_virtual_displays_skip_an_already_converged_topology(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    events: list[tuple[str, str]] = []

    class Guest:
        @staticmethod
        def exec(argv, **_kwargs):
            pytest.fail("an identical topology must not recreate an output")

        @staticmethod
        def exec_retryable(argv, **_kwargs):
            events.append(("observe", " ".join(argv)))
            return CommandResult(
                tuple(argv),
                0,
                json.dumps(
                    [
                        {
                            "name": "HEADLESS-UI",
                            "width": 1280,
                            "height": 800,
                            "x": 0,
                            "y": 0,
                            "scale": 1,
                            "disabled": False,
                        },
                        {"name": "Virtual-1", "disabled": True},
                    ]
                ),
                "",
            )

    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(
        service,
        "_run_checked",
        lambda *_args, **_kwargs: pytest.fail(
            "an identical topology must not register another monitor batch"
        ),
    )

    service._configure_virtual_displays(
        {"run_id": "run-012345abcdef"},
        {
            "monitors": [
                {
                    "name": "HEADLESS-UI",
                    "mode": "1280x800@60",
                    "position": "0x0",
                    "scale": 1,
                }
            ],
            "disable_unlisted": True,
        },
    )

    assert [event[0] for event in events] == ["observe"] * 10
    assert all("hyprctl -j monitors all" in event[1] for event in events)


def test_virtual_display_postcondition_rejects_a_delayed_topology_regression(
    tmp_path: Path,
    monkeypatch,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    observations = [
        [
            {
                "name": "HEADLESS-UI",
                "width": 1920,
                "height": 1080,
                "x": 0,
                "y": 0,
                "scale": 2,
                "disabled": False,
            },
            {"name": "Virtual-1", "disabled": False},
        ],
        [
            {
                "name": "HEADLESS-UI",
                "width": 1280,
                "height": 800,
                "x": 0,
                "y": 0,
                "scale": 1,
                "disabled": False,
            },
            {"name": "Virtual-1", "disabled": True},
        ],
        [
            {
                "name": "HEADLESS-UI",
                "width": 1920,
                "height": 1080,
                "x": 0,
                "y": 0,
                "scale": 2,
                "disabled": False,
            },
            {"name": "Virtual-1", "disabled": False},
        ],
    ]

    class Guest:
        @staticmethod
        def exec(_argv, **_kwargs):
            pytest.fail("the configured headless output already exists")

        @staticmethod
        def exec_retryable(argv, **_kwargs):
            observation = (
                observations.pop(0) if len(observations) > 1 else observations[0]
            )
            return CommandResult(tuple(argv), 0, json.dumps(observation), "")

    ticks = iter(range(100))
    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr("enoshima_vm.service.time.monotonic", lambda: next(ticks))
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)
    monkeypatch.setattr(service, "_run_checked", lambda *_args, **_kwargs: None)

    with pytest.raises(VMError, match="requested topology"):
        service._configure_virtual_displays(
            {"run_id": "run-012345abcdef"},
            {
                "monitors": [
                    {
                        "name": "HEADLESS-UI",
                        "mode": "1280x800@60",
                        "position": "0x0",
                        "scale": 1,
                    }
                ],
                "disable_unlisted": True,
            },
        )


def test_virtual_displays_reject_empty_and_duplicate_topologies(
    tmp_path: Path,
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)

    with pytest.raises(VMError, match="requires at least one monitor"):
        service._configure_virtual_displays(
            {"run_id": "run-012345abcdef"},
            {"monitors": [], "disable_unlisted": True},
        )

    monitor = {
        "name": "HEADLESS-INTERNAL",
        "mode": "2880x1800@60",
        "position": "0x0",
        "scale": 1.5,
    }
    with pytest.raises(VMError, match="duplicate monitor name"):
        service._configure_virtual_displays(
            {"run_id": "run-012345abcdef"},
            {"monitors": [monitor, monitor]},
        )


def test_titlebar_allowlist_uses_the_hyprland_lua_evaluator() -> None:
    expression = VMService._decoration_allowlist_expression(
        "mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture"
    )

    assert expression == (
        "hl.config({ plugin = { enoshima_decoration = { allowlist = "
        '"mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture" } } })'
    )

    with pytest.raises(VMError, match="invalid decoration allowlist"):
        VMService._decoration_allowlist_expression('mpv"; os.execute("id")')


def test_ui_fixture_waits_for_the_exact_qml_ack(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ReadyGuest(42)
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    ack = service._wait_for_ui_fixture_ready({"run_id": "run-012345abcdef"}, 42)

    assert guest.commands[-1][-1].endswith("/ui-fixture/ready.json")
    assert ack["text_overflow_count"] == 0
    assert ack["missing_translation_count"] == 0


def test_ui_fixture_rejects_untranslated_catalog_keys(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ReadyGuest(42, missing_translations=3)
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    with pytest.raises(VMError, match="untranslated catalog keys"):
        service._wait_for_ui_fixture_ready({"run_id": "run-012345abcdef"}, 42)


def test_ui_review_rejects_measured_text_overflow() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    review = source[source.index("def _run_ui_review") :]

    assert 'int(fixture_ack["text_overflow_count"]) > 0' in review
    assert "UI review found visible text outside its allocated bounds" in review


def test_ui_capture_requires_two_identical_frames(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    image = tmp_path / "stable.png"
    image.write_bytes(b"same compositor frame")
    calls = 0

    def screenshot(_run_id, _name, output):
        nonlocal calls
        calls += 1
        return {"path": str(image), "width": 1280, "height": 800, "output": output}

    monkeypatch.setattr(service, "screenshot", screenshot)

    result = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "launcher", "HEADLESS-UI"
    )

    assert calls == 2
    assert result["output"] == "HEADLESS-UI"
    assert result["stability_metric"] == "pixel-hash"
