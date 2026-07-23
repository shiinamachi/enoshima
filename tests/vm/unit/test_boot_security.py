from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
import yaml

from enoshima_vm.boot_security import boot_with_recovery, create_runtime_inventory
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.process import CommandResult


def result(stdout: str = "") -> CommandResult:
    return CommandResult(("ssh",), 0, stdout, "")


def timeout() -> VMError:
    return VMError(FailureCategory.SSH_TIMEOUT, "guest is rebooting")


def test_boot_with_recovery_tolerates_ssh_timeout_and_types_key(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recovery_key = tmp_path / "recovery.key"
    recovery_key.write_text("disposable-recovery-key", encoding="utf-8")
    outcomes = iter(
        (
            result("before-boot\n"),
            timeout(),
            timeout(),
            timeout(),
            result(),
            result("after-boot\n"),
        )
    )

    def execute(*_args: object, **_kwargs: object) -> CommandResult:
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    guest = SimpleNamespace(exec=execute)
    backend = SimpleNamespace(
        reboot=lambda _domain: None,
        serial_log_size=lambda _domain: 128,
        read_serial_text=lambda _domain, *, start_offset: next(serial_output),
        type_serial_text=lambda domain, text: typed.append((domain, text)),
        wait_guest_agent=lambda domain, seconds: waited.append((domain, seconds)),
    )
    service = SimpleNamespace(_guest=lambda _record: guest, backend=backend)
    typed: list[tuple[str, str]] = []
    waited: list[tuple[str, int]] = []
    serial_output = iter(
        (
            "systemd is shutting down\n",
            "Please enter passphrase: ",
            "Please enter passphrase: ",
            "Please enter passphrase: booted\n",
        )
    )
    monotonic_values = iter((0.0, 0.0, 1.0, 2.0, 3.0))
    monkeypatch.setattr(
        "enoshima_vm.boot_security.time.monotonic",
        lambda: next(monotonic_values),
    )
    monkeypatch.setattr("enoshima_vm.boot_security.time.sleep", lambda _seconds: None)

    boot_with_recovery(
        service,
        {"domain": "enoshima-test", "recovery_key": str(recovery_key)},
    )

    assert typed == [("enoshima-test", "disposable-recovery-key")]
    assert waited == [("enoshima-test", 180)]


def test_boot_with_recovery_redacts_and_rejects_echoed_secret(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recovery_value = "disposable-recovery-key"
    recovery_key = tmp_path / "recovery.key"
    recovery_key.write_text(recovery_value, encoding="utf-8")
    serial_log = tmp_path / "serial.log"
    serial_log.write_text(
        f"Please enter passphrase: {recovery_value}\n", encoding="utf-8"
    )
    outcomes = iter((result("before-boot\n"), timeout()))

    def execute(*_args: object, **_kwargs: object) -> CommandResult:
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    typed: list[tuple[str, str]] = []
    guest = SimpleNamespace(exec=execute)
    backend = SimpleNamespace(
        reboot=lambda _domain: None,
        serial_log_size=lambda _domain: 0,
        read_serial_text=lambda _domain, *, start_offset: serial_log.read_text(
            encoding="utf-8"
        ),
        type_serial_text=lambda domain, text: typed.append((domain, text)),
    )
    service = SimpleNamespace(
        _guest=lambda _record: guest,
        _run_dir=lambda _run_id: tmp_path,
        backend=backend,
    )
    monotonic_values = iter((0.0, 0.0))
    monkeypatch.setattr(
        "enoshima_vm.boot_security.time.monotonic",
        lambda: next(monotonic_values),
    )

    with pytest.raises(VMError) as caught:
        boot_with_recovery(
            service,
            {
                "domain": "enoshima-test",
                "recovery_key": str(recovery_key),
                "run_id": "run-test",
            },
        )

    assert caught.value.category == FailureCategory.SECURE_BOOT_FAILED
    assert typed == []
    retained_log = serial_log.read_text(encoding="utf-8")
    assert recovery_value not in retained_log
    assert "[REDACTED_RECOVERY_KEY]" in retained_log


def test_boot_with_recovery_retries_only_without_serial_progress(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recovery_key = tmp_path / "recovery.key"
    recovery_key.write_text("disposable-recovery-key", encoding="utf-8")
    outcomes = iter(
        (
            result("before-boot\n"),
            timeout(),
            timeout(),
            timeout(),
            result(),
            result("after-boot\n"),
        )
    )

    def execute(*_args: object, **_kwargs: object) -> CommandResult:
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    typed: list[tuple[str, str]] = []
    waited: list[tuple[str, int]] = []
    prompt = "Please enter passphrase: "
    serial_output = iter((prompt, prompt, prompt, f"{prompt}booted\n"))
    guest = SimpleNamespace(exec=execute)
    backend = SimpleNamespace(
        reboot=lambda _domain: None,
        serial_log_size=lambda _domain: 0,
        read_serial_text=lambda _domain, *, start_offset: next(serial_output),
        type_serial_text=lambda domain, text: typed.append((domain, text)),
        wait_guest_agent=lambda domain, seconds: waited.append((domain, seconds)),
    )
    service = SimpleNamespace(_guest=lambda _record: guest, backend=backend)
    monotonic_values = iter((0.0, 0.0, 2.0, 4.0, 5.0))
    monkeypatch.setattr(
        "enoshima_vm.boot_security.time.monotonic",
        lambda: next(monotonic_values),
    )
    monkeypatch.setattr("enoshima_vm.boot_security.time.sleep", lambda _seconds: None)

    boot_with_recovery(
        service,
        {"domain": "enoshima-test", "recovery_key": str(recovery_key)},
    )

    assert typed == [
        ("enoshima-test", "disposable-recovery-key"),
        ("enoshima-test", "disposable-recovery-key"),
    ]
    assert waited == [("enoshima-test", 180)]


def test_boot_with_recovery_preserves_non_ssh_vm_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recovery_key = tmp_path / "recovery.key"
    recovery_key.write_text("disposable-recovery-key", encoding="utf-8")
    outcomes = iter(
        (
            result("before-boot\n"),
            VMError(FailureCategory.HARNESS_ERROR, "libvirt failed"),
        )
    )

    def execute(*_args: object, **_kwargs: object) -> CommandResult:
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    guest = SimpleNamespace(exec=execute)
    backend = SimpleNamespace(
        reboot=lambda _domain: None,
        serial_log_size=lambda _domain: 0,
    )
    service = SimpleNamespace(_guest=lambda _record: guest, backend=backend)
    monkeypatch.setattr("enoshima_vm.boot_security.time.monotonic", lambda: 0.0)

    with pytest.raises(VMError) as caught:
        boot_with_recovery(
            service,
            {"domain": "enoshima-test", "recovery_key": str(recovery_key)},
        )

    assert caught.value.category == FailureCategory.HARNESS_ERROR


def test_runtime_inventory_preserves_dedicated_boot_mounts(tmp_path: Path) -> None:
    repository = Path(__file__).resolve().parents[3]
    metadata = {
        "root_luks_uuid": "luks-fixture",
        "root_btrfs_uuid": "btrfs-fixture",
        "esp_partition_uuid": "ESP-FIXTURE",
        "esp_partition_partuuid": "esp-partuuid-fixture",
    }
    uploads: list[tuple[Path, object]] = []
    guest = SimpleNamespace(
        exec=lambda _argv: result(json.dumps(metadata)),
        upload_file=lambda source, destination: uploads.append((source, destination)),
    )
    service = SimpleNamespace(
        _guest=lambda _record: guest,
        _run_dir=lambda _run_id: tmp_path,
        _write_record=lambda _record: None,
        paths=SimpleNamespace(repository=repository),
    )
    record = {"run_id": "run-test"}

    create_runtime_inventory(service, record)

    host_vars = yaml.safe_load(
        (tmp_path / "runtime-inventory/host_vars/enoshima-vm-boot.yml").read_text(
            encoding="utf-8"
        )
    )
    static_entries = host_vars["managed_fstab_static_entries"]
    assert any(
        " /home " in entry and "subvol=@home" in entry for entry in static_entries
    )
    assert any(
        " /var/log " in entry and "subvol=@var_log" in entry for entry in static_entries
    )
    assert any(" /efi vfat " in entry for entry in static_entries)
    assert len(uploads) == 3
