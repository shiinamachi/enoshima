from __future__ import annotations

import subprocess
from pathlib import Path, PurePosixPath

import pytest

from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.guest import (
    INITIAL_SSH_TIMEOUT_SECONDS,
    RETRYABLE_SSH_ATTEMPTS,
    Guest,
)
from enoshima_vm.process import CommandResult
from enoshima_vm.source import SourceIdentity


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
    assert RETRYABLE_SSH_ATTEMPTS == 2


def test_retryable_guest_command_classifies_remote_failure_as_product(
    monkeypatch,
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    failure = CommandResult(("ssh",), 1, "", "plugin option unavailable")
    monkeypatch.setattr(guest, "exec", lambda *_args, **_kwargs: failure)

    with pytest.raises(VMError) as raised:
        guest.exec_retryable(["hyprctl", "getoption"])

    assert raised.value.category is FailureCategory.VALIDATION_FAILED
    assert raised.value.details["exit_code"] == 1


def test_upload_rejects_archive_identity_mismatch_before_ssh(
    tmp_path: Path, monkeypatch
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    identity = SourceIdentity(
        commit="a" * 40,
        dirty=True,
        tree_hash="b" * 64,
        files=("tracked.txt",),
        untracked_files=(),
    )
    monkeypatch.setattr(
        "enoshima_vm.guest.create_source_archive",
        lambda *_args, **_kwargs: identity,
    )
    monkeypatch.setattr(
        "enoshima_vm.guest.subprocess.run",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("SSH must not start for a mismatched archive")
        ),
    )

    with pytest.raises(VMError) as raised:
        guest.upload_worktree(
            tmp_path,
            PurePosixPath("/home/kentakang/enoshima-test/source"),
            expected_commit="a" * 40,
            expected_tree_hash="c" * 64,
        )

    assert raised.value.category is FailureCategory.SOURCE_INVALIDATED


def test_worktree_upload_classifies_ssh_exit_255_as_infrastructure(
    tmp_path: Path, monkeypatch
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    identity = SourceIdentity(
        commit="a" * 40,
        dirty=True,
        tree_hash="b" * 64,
        files=("tracked.txt",),
        untracked_files=(),
    )

    def freeze(_repository: Path, archive: Path) -> SourceIdentity:
        archive.write_bytes(b"archive")
        return identity

    monkeypatch.setattr("enoshima_vm.guest.create_source_archive", freeze)
    monkeypatch.setattr(
        "enoshima_vm.guest.subprocess.run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess(
            args=("ssh",), returncode=255, stdout=b"", stderr=b"connection reset"
        ),
    )

    with pytest.raises(VMError) as raised:
        guest.upload_worktree(
            tmp_path,
            PurePosixPath("/home/kentakang/enoshima-test/source"),
            expected_commit=identity.commit,
            expected_tree_hash=identity.tree_hash,
        )

    assert raised.value.category is FailureCategory.SSH_TIMEOUT


@pytest.mark.parametrize("operation", ["download", "upload"])
def test_scp_exit_255_remains_an_ssh_infrastructure_failure(
    tmp_path: Path, monkeypatch, operation: str
) -> None:
    guest = Guest(22022, Path("fixture-key"))
    monkeypatch.setattr(
        "enoshima_vm.guest.run",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            subprocess.CalledProcessError(255, ["scp"])
        ),
    )

    with pytest.raises(VMError) as raised:
        if operation == "download":
            guest.download(PurePosixPath("/tmp/artifact"), tmp_path / "artifact")
        else:
            source = tmp_path / "source"
            source.write_text("fixture", encoding="utf-8")
            monkeypatch.setattr(guest, "exec", lambda *_args, **_kwargs: success())
            guest.upload_file(source, PurePosixPath("/tmp/source"))

    assert raised.value.category is FailureCategory.SSH_TIMEOUT


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
