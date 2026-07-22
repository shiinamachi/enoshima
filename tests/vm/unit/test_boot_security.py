from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from enoshima_vm.boot_security import boot_with_recovery
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
    recovery_key.write_text("disposable-recovery-key\n", encoding="utf-8")
    outcomes = iter(
        (
            result("before-boot\n"),
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
        type_text=lambda domain, text: typed.append((domain, text)),
        wait_guest_agent=lambda domain, seconds: waited.append((domain, seconds)),
    )
    service = SimpleNamespace(_guest=lambda _record: guest, backend=backend)
    typed: list[tuple[str, str]] = []
    waited: list[tuple[str, int]] = []
    monotonic_values = iter((0.0, 0.0, 20.0, 20.0, 20.0, 21.0))
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


def test_boot_with_recovery_preserves_non_ssh_vm_errors(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recovery_key = tmp_path / "recovery.key"
    recovery_key.write_text("disposable-recovery-key\n", encoding="utf-8")
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
    backend = SimpleNamespace(reboot=lambda _domain: None)
    service = SimpleNamespace(_guest=lambda _record: guest, backend=backend)
    monkeypatch.setattr("enoshima_vm.boot_security.time.monotonic", lambda: 0.0)

    with pytest.raises(VMError) as caught:
        boot_with_recovery(
            service,
            {"domain": "enoshima-test", "recovery_key": str(recovery_key)},
        )

    assert caught.value.category == FailureCategory.HARNESS_ERROR
