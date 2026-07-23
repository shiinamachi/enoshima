from __future__ import annotations

import os
import select

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.libvirt_backend import LibvirtBackend
from enoshima_vm.process import CommandResult


def test_type_text_waits_for_each_qemu_key_release(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[tuple[str, ...], int]] = []
    waits: list[float] = []

    monkeypatch.setattr(
        backend,
        "send_keys",
        lambda _domain, keys, *, hold_milliseconds=100: calls.append(
            (tuple(keys), hold_milliseconds)
        ),
    )
    monkeypatch.setattr("enoshima_vm.libvirt_backend.time.sleep", waits.append)

    backend.type_text("enoshima-test-run-012345abcdef", "a7")

    assert calls == [(("KEY_A",), 80), (("KEY_7",), 80), (("KEY_ENTER",), 100)]
    assert waits == [0.12, 0.12]


def test_type_serial_text_uses_libvirt_console_without_argv_secret(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[str, ...]] = []
    processes: list[object] = []
    waits: list[float] = []

    class FakeProcess:
        def __init__(self, argv, *, stdin, stdout, **_kwargs) -> None:
            calls.append(tuple(argv))
            self.console = os.dup(stdin)
            self.returncode: int | None = None
            self.received = b""
            os.write(stdout, b"Connected to domain fixture\nEscape character is ^]\n")
            processes.append(self)

        def poll(self):
            return self.returncode

        def wait(self, *, timeout):
            chunks = []
            while select.select([self.console], [], [], 0)[0]:
                chunks.append(os.read(self.console, 128))
            self.received = b"".join(chunks)
            os.close(self.console)
            self.returncode = 0
            return self.returncode

        def terminate(self):
            self.returncode = 0

        def kill(self):
            self.returncode = -9

    monkeypatch.setattr("enoshima_vm.libvirt_backend.subprocess.Popen", FakeProcess)
    monkeypatch.setattr("enoshima_vm.libvirt_backend.time.sleep", waits.append)

    backend.type_serial_text(
        "enoshima-test-run-012345abcdef", "disposable-recovery-key"
    )

    assert calls == [
        (
            "virsh",
            "--connect",
            "qemu:///session",
            "console",
            "enoshima-test-run-012345abcdef",
            "--safe",
        )
    ]
    assert "disposable-recovery-key" not in calls[0]
    assert processes[0].received == b"disposable-recovery-key\r\x1d"
    assert waits == [0.5]


def test_read_serial_text_uses_the_managed_log_and_reboot_offset(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    log = paths.state / "runs" / "run-012345abcdef" / "serial.log"
    log.parent.mkdir(parents=True)
    log.write_text("old boot output\n", encoding="utf-8")
    offset = backend.serial_log_size("enoshima-test-run-012345abcdef")
    log.write_text(
        "old boot output\nPlease enter passphrase for cryptroot: ", encoding="utf-8"
    )

    assert (
        backend.read_serial_text("enoshima-test-run-012345abcdef", start_offset=offset)
        == "Please enter passphrase for cryptroot: "
    )


def test_type_serial_text_rejects_an_unmanaged_domain(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    with pytest.raises(ValueError):
        backend.type_serial_text("unmanaged-domain", "disposable-recovery-key")


def test_pointer_events_use_the_absolute_qemu_tablet(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[str, ...]] = []

    def virsh(args, **_kwargs):
        calls.append(tuple(args))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.pointer_move_absolute("enoshima-test-run-012345abcdef", 100, 200)
    backend.pointer_button("enoshima-test-run-012345abcdef", "left", True)

    assert calls[0][:2] == (
        "qemu-monitor-command",
        "enoshima-test-run-012345abcdef",
    )
    assert '"type":"abs"' in calls[0][2]
    assert '"axis":"x","value":100' in calls[0][2]
    assert '"axis":"y","value":200' in calls[0][2]
    assert '"button":"left"' in calls[1][2]
    assert '"down":true' in calls[1][2]


def test_reset_uses_libvirt_for_a_managed_disposable_domain(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    calls: list[tuple[tuple[str, ...], int]] = []

    def virsh(args, *, timeout=120, **_kwargs):
        calls.append((tuple(args), timeout))
        return CommandResult(tuple(str(value) for value in args), 0, "", "")

    monkeypatch.setattr(backend, "virsh", virsh)

    backend.reset("enoshima-test-run-012345abcdef")

    assert calls == [(("reset", "enoshima-test-run-012345abcdef"), 30)]
