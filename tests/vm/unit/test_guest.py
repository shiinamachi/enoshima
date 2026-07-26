from __future__ import annotations

from pathlib import Path

from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.guest import (
    INITIAL_SSH_TIMEOUT_SECONDS,
    RETRYABLE_SSH_ATTEMPTS,
    Guest,
)
from enoshima_vm.process import CommandResult


class ConnectedSocket:
    def __enter__(self) -> ConnectedSocket:
        return self

    def __exit__(self, *_args: object) -> None:
        return None


def timeout() -> VMError:
    return VMError(FailureCategory.SSH_TIMEOUT, "not ready")


def success() -> CommandResult:
    return CommandResult(("ssh",), 0, "", "")


def transport_failure() -> CommandResult:
    return CommandResult(("ssh",), 255, "", "Connection reset by peer")


def test_initial_ssh_budget_covers_cloud_bootstrap_deadline() -> None:
    assert INITIAL_SSH_TIMEOUT_SECONDS == 1200


def test_retryable_guest_command_recovers_from_transient_transport_loss(
    monkeypatch,
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    outcomes = iter((transport_failure(), success()))
    calls = 0

    def execute(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return next(outcomes)

    monkeypatch.setattr(guest, "exec", execute)
    monkeypatch.setattr("enoshima_vm.guest.time.sleep", lambda _seconds: None)

    assert guest.exec_retryable(["hyprctl", "-j", "clients"]) == success()
    assert calls == 2


def test_retryable_guest_command_does_not_repeat_remote_failures(monkeypatch) -> None:
    guest = Guest(22022, Path("fixture-key"))
    failure = CommandResult(("ssh",), 1, "", "remote assertion failed")
    calls = 0

    def execute(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return failure

    monkeypatch.setattr(guest, "exec", execute)
    result = guest.exec_retryable(["false"], check=False)

    assert result == failure
    assert calls == 1
    assert RETRYABLE_SSH_ATTEMPTS == 3


def test_wait_ssh_retries_an_initial_command_timeout(monkeypatch) -> None:
    guest = Guest(22022, Path("fixture-key"))
    outcomes = iter((timeout(), success()))

    monkeypatch.setattr(
        "enoshima_vm.guest.socket.create_connection",
        lambda *_args, **_kwargs: ConnectedSocket(),
    )
    monkeypatch.setattr("enoshima_vm.guest.time.sleep", lambda _seconds: None)

    def execute(*_args, **_kwargs):
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(guest, "exec", execute)
    guest.wait_ssh(timeout_seconds=30)


def test_wait_ssh_cycle_treats_a_timeout_as_the_down_phase(monkeypatch) -> None:
    guest = Guest(22022, Path("fixture-key"))
    outcomes = iter((timeout(), success()))
    monkeypatch.setattr("enoshima_vm.guest.time.sleep", lambda _seconds: None)

    def execute(*_args, **_kwargs):
        outcome = next(outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(guest, "exec", execute)
    guest.wait_ssh_cycle(timeout_seconds=30)


def test_wait_cloud_init_polls_instead_of_holding_one_ssh_session(
    monkeypatch,
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    outcomes = iter(
        (
            CommandResult(("cloud-init",), 0, "status: running\n", ""),
            CommandResult(("cloud-init",), 0, "status: done\n", ""),
            CommandResult(("readiness",), 0, "", ""),
        )
    )
    monkeypatch.setattr("enoshima_vm.guest.time.sleep", lambda _seconds: None)
    monkeypatch.setattr(guest, "exec", lambda *_args, **_kwargs: next(outcomes))
    guest.wait_cloud_init(timeout_seconds=30)


def test_wait_cloud_init_fails_immediately_on_reported_error(monkeypatch) -> None:
    guest = Guest(22022, Path("fixture-key"))
    failure = CommandResult(
        ("cloud-init",),
        1,
        "status: error\nerrors: [package failure]\n",
        "",
    )
    monkeypatch.setattr(guest, "exec", lambda *_args, **_kwargs: failure)
    try:
        guest.wait_cloud_init(timeout_seconds=30)
    except VMError as error:
        assert error.category == FailureCategory.VM_BOOT_ERROR
        assert error.details["stdout"] == failure.stdout
    else:
        raise AssertionError("cloud-init error was accepted")


def test_wait_cloud_init_rejects_done_without_required_tools(monkeypatch) -> None:
    guest = Guest(22022, Path("fixture-key"))
    outcomes = iter(
        (
            CommandResult(("cloud-init",), 0, "status: done\n", ""),
            CommandResult(("readiness",), 1, "", "make is unavailable"),
            CommandResult(("tail",), 0, "pacman failed\n", ""),
        )
    )
    monkeypatch.setattr(guest, "exec", lambda *_args, **_kwargs: next(outcomes))

    try:
        guest.wait_cloud_init(timeout_seconds=30)
    except VMError as error:
        assert error.category == FailureCategory.VM_BOOT_ERROR
        assert "pacman failed" in error.details["cloud_init_output"]
    else:
        raise AssertionError("incomplete cloud-init was accepted")
