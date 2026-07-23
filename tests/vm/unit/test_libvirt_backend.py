from __future__ import annotations

import os
import pty

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
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


def test_type_serial_text_writes_only_to_the_managed_console(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    master, slave = pty.openpty()
    console = os.ttyname(slave)

    monkeypatch.setattr(
        backend,
        "virsh",
        lambda args, **_kwargs: CommandResult(
            tuple(str(value) for value in args), 0, f"{console}\n", ""
        ),
    )
    try:
        backend.type_serial_text(
            "enoshima-test-run-012345abcdef", "disposable-recovery-key"
        )
        assert os.read(master, 128) == b"disposable-recovery-key\r"
    finally:
        os.close(master)
        os.close(slave)


def test_read_serial_text_drains_prompt_without_blocking(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    master, slave = pty.openpty()
    console = os.ttyname(slave)
    monkeypatch.setattr(
        backend,
        "virsh",
        lambda args, **_kwargs: CommandResult(
            tuple(str(value) for value in args), 0, f"{console}\n", ""
        ),
    )
    try:
        os.write(master, b"Please enter passphrase for cryptroot: ")
        assert (
            backend.read_serial_text("enoshima-test-run-012345abcdef")
            == "Please enter passphrase for cryptroot: "
        )
        assert backend.read_serial_text("enoshima-test-run-012345abcdef") == ""
    finally:
        os.close(master)
        os.close(slave)


def test_type_serial_text_rejects_an_unmanaged_path(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    backend = LibvirtBackend(paths)
    monkeypatch.setattr(
        backend,
        "virsh",
        lambda args, **_kwargs: CommandResult(
            tuple(str(value) for value in args), 0, "/tmp/console\n", ""
        ),
    )

    with pytest.raises(VMError) as caught:
        backend.type_serial_text(
            "enoshima-test-run-012345abcdef", "disposable-recovery-key"
        )

    assert caught.value.category == FailureCategory.HARNESS_ERROR


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
