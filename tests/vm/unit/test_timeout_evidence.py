from __future__ import annotations

from pathlib import Path

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.guest import GuestCommandTimeout
from enoshima_vm.process import CommandResult
from enoshima_vm.results import failure_fields, retryable_infrastructure_failure
from enoshima_vm.service import (
    BOOTSTRAP_IDLE_TIMEOUT_SECONDS,
    BOOTSTRAP_TIMEOUT_SECONDS,
    REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS,
    REPEAT_BOOTSTRAP_TIMEOUT_SECONDS,
    VM_CODEX_DESKTOP_BUILD_ATTEMPTS,
    VM_CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS,
    VM_CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS,
    VM_MISE_INSTALL_MAX_ATTEMPTS,
    VM_MISE_INSTALL_RETRY_DELAY_SECONDS,
    VM_MISE_INSTALL_TIMEOUT_SECONDS,
    VMService,
)


def test_bootstrap_has_a_bounded_absolute_deadline() -> None:
    assert BOOTSTRAP_TIMEOUT_SECONDS == 155 * 60
    assert BOOTSTRAP_IDLE_TIMEOUT_SECONDS == 32 * 60
    assert BOOTSTRAP_IDLE_TIMEOUT_SECONDS < BOOTSTRAP_TIMEOUT_SECONDS
    assert REPEAT_BOOTSTRAP_TIMEOUT_SECONDS == 30 * 60
    assert REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS == 10 * 60
    assert REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS < REPEAT_BOOTSTRAP_TIMEOUT_SECONDS
    assert VM_MISE_INSTALL_MAX_ATTEMPTS == 2
    assert VM_MISE_INSTALL_TIMEOUT_SECONDS == 10 * 60
    assert VM_MISE_INSTALL_RETRY_DELAY_SECONDS == 10
    assert VM_CODEX_DESKTOP_BUILD_ATTEMPTS == 2
    assert VM_CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS == 30 * 60
    assert VM_CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS == 15
    observed_non_mise_before_codex = 64 * 60
    bounded_upper_estimate = (
        observed_non_mise_before_codex
        + VM_MISE_INSTALL_MAX_ATTEMPTS * VM_MISE_INSTALL_TIMEOUT_SECONDS
        + (VM_MISE_INSTALL_MAX_ATTEMPTS - 1)
        * VM_MISE_INSTALL_RETRY_DELAY_SECONDS
        + VM_CODEX_DESKTOP_BUILD_ATTEMPTS
        * VM_CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS
        + (VM_CODEX_DESKTOP_BUILD_ATTEMPTS - 1)
        * VM_CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS
        + 4 * 60
    )
    assert bounded_upper_estimate < BOOTSTRAP_TIMEOUT_SECONDS
    assert 15 * 60 < REPEAT_BOOTSTRAP_TIMEOUT_SECONDS


@pytest.mark.parametrize(
    ("config", "expected_timeout", "expected_idle_timeout"),
    (
        (
            {"report": "first"},
            BOOTSTRAP_TIMEOUT_SECONDS,
            BOOTSTRAP_IDLE_TIMEOUT_SECONDS,
        ),
        (
            {"report": "second", "repeat": True},
            REPEAT_BOOTSTRAP_TIMEOUT_SECONDS,
            REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS,
        ),
    ),
)
def test_bootstrap_selects_cold_and_repeat_deadlines(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    config: dict[str, object],
    expected_timeout: int,
    expected_idle_timeout: int,
) -> None:
    discovered = RuntimePaths.discover()
    paths = RuntimePaths(
        discovered.repository,
        discovered.project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    record = {
        "run_id": "run-012345abcdef",
        "suite": "smoke",
        "artifact_dir": str(tmp_path / "artifacts"),
    }
    observed: dict[str, object] = {}

    def run_checked(*_args, **kwargs):
        observed.update(kwargs)

    class Guest:
        def exec(self, argv, **_kwargs):
            return CommandResult(tuple(argv), 0, "", "")

    monkeypatch.setattr(service, "_run_checked", run_checked)
    monkeypatch.setattr(service, "_collect_pacman_cache", lambda _record: None)
    monkeypatch.setattr(service, "_guest", lambda _record: Guest())
    monkeypatch.setattr(service, "_write_record", lambda _record: None)

    service._run_bootstrap(record, config)

    assert observed["timeout_seconds"] == expected_timeout
    assert observed["idle_timeout_seconds"] == expected_idle_timeout


def test_checked_command_forwards_a_call_scoped_idle_deadline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    record = {
        "run_id": "run-012345abcdef",
        "artifact_dir": str(tmp_path / "artifacts"),
    }
    observed: dict[str, object] = {}

    def execute(*_args, **kwargs):
        observed.update(kwargs)
        return {"exit_code": 0, "stdout": "", "stderr": "", "duration_ms": 1}

    monkeypatch.setattr(service, "exec", execute)

    service._run_checked(
        record,
        "bootstrap-first",
        ["bash", "-lc", "bootstrap"],
        FailureCategory.BOOTSTRAP_FAILED,
        timeout_seconds=BOOTSTRAP_TIMEOUT_SECONDS,
        idle_timeout_seconds=BOOTSTRAP_IDLE_TIMEOUT_SECONDS,
    )

    assert observed["timeout_seconds"] == BOOTSTRAP_TIMEOUT_SECONDS
    assert observed["idle_timeout_seconds"] == BOOTSTRAP_IDLE_TIMEOUT_SECONDS


def test_checked_timeout_persists_partial_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    artifact_dir = tmp_path / "artifacts"
    record = {"run_id": "run-012345abcdef", "artifact_dir": str(artifact_dir)}
    timeout = GuestCommandTimeout(
        "guest command timed out: bootstrap",
        {
            "command": "bootstrap",
            "timeout_kind": "absolute",
            "timeout_seconds": BOOTSTRAP_TIMEOUT_SECONDS,
            "stdout_tail": "partial stdout",
            "stderr_tail": "partial stderr",
        },
        stdout="partial stdout",
        stderr="partial stderr",
    )

    monkeypatch.setattr(
        service,
        "exec",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(timeout),
    )

    with pytest.raises(GuestCommandTimeout) as raised:
        service._run_checked(
            record,
            "bootstrap-first",
            ["bash", "-lc", "bootstrap"],
            FailureCategory.BOOTSTRAP_FAILED,
            timeout_seconds=BOOTSTRAP_TIMEOUT_SECONDS,
        )

    log = Path(str(raised.value.details["log"]))
    assert log.read_text(encoding="utf-8") == (
        "partial stdout\n--- stderr ---\npartial stderr"
    )


def _failed_bootstrap(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, stderr: str
) -> VMError:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    record = {
        "run_id": "run-012345abcdef",
        "artifact_dir": str(tmp_path / "artifacts"),
    }
    monkeypatch.setattr(
        service,
        "exec",
        lambda *_args, **_kwargs: {
            "exit_code": 1,
            "stdout": "",
            "stderr": stderr,
            "duration_ms": 1000,
        },
    )

    with pytest.raises(VMError) as raised:
        service._run_checked(
            record,
            "bootstrap-first",
            ["bash", "-lc", "bootstrap"],
            FailureCategory.BOOTSTRAP_FAILED,
            timeout_seconds=BOOTSTRAP_TIMEOUT_SECONDS,
        )
    return raised.value


def test_exhausted_aur_tls_eof_is_retryable_infrastructure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stderr = "\n".join(
        (
            "error: command failed: /cache/clone: git clone --no-progress -- "
            "https://aur.archlinux.org/fzf-tab fzf-tab:",
            "    Cloning into 'fzf-tab'...",
            "    fatal: unable to access "
            "'https://aur.archlinux.org/fzf-tab/': TLS connect error: "
            "unexpected eof while reading",
            "WARNING: approved AUR package base fzf-tab attempt 1/4 failed; "
            "retrying in 10s.",
            "error: error sending request for url "
            "(https://aur.archlinux.org/rpc): error trying to connect: "
            "unexpected EOF",
            "WARNING: approved AUR package base fzf-tab attempt 2/4 failed; "
            "retrying in 10s.",
            "error: command failed: /cache/clone: git clone --no-progress -- "
            "https://aur.archlinux.org/fzf-tab fzf-tab:",
            "    Cloning into 'fzf-tab'...",
            "    fatal: unable to access "
            "'https://aur.archlinux.org/fzf-tab/': OpenSSL SSL_read: "
            "unexpected eof while reading",
            "WARNING: approved AUR package base fzf-tab attempt 3/4 failed; "
            "retrying in 10s.",
            "error: error sending request for url "
            "(https://aur.archlinux.org/rpc): connection closed before message "
            "completed",
            "FAILURE: AUR package base fzf-tab exited with status 1; continuing.",
            "[FAIL] a later product postflight check",
        )
    )

    error = _failed_bootstrap(tmp_path, monkeypatch, stderr)

    assert error.category == FailureCategory.HOST_INFRA_ERROR
    assert error.details is not None
    assert error.details["transport_kind"] == "aur-tls-eof"
    assert error.details["packages"] == ["fzf-tab"]
    fields = failure_fields(suite="smoke", step="run_bootstrap", error=error)
    assert fields["failure_origin"] == "INFRA"
    assert retryable_infrastructure_failure(
        {**fields, "category": str(error.category), "error": str(error)}
    )


def test_protected_aur_fetch_tls_eof_is_retryable_infrastructure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stderr = "\n".join(
        (
            "fatal: unable to access "
            "'https://aur.archlinux.org/hyprshell-bin.git/': TLS connect error: "
            "unexpected eof while reading",
            "AUR provenance error: pinned AUR commit fetch failed with exit status 128",
            "FAILURE: protected AUR package base hyprshell-bin exited with "
            "status 1; continuing.",
            "error: error sending request for url "
            "(https://aur.archlinux.org/rpc): error trying to connect: "
            "Connection reset by peer (os error 104)",
        )
    )

    error = _failed_bootstrap(tmp_path, monkeypatch, stderr)

    assert error.category == FailureCategory.HOST_INFRA_ERROR
    assert error.details is not None
    assert error.details["packages"] == ["hyprshell-bin"]


def test_protected_aur_certificate_failure_is_not_reclassified(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stderr = "\n".join(
        (
            "fatal: unable to access "
            "'https://aur.archlinux.org/hyprshell-bin.git/': "
            "certificate verify failed",
            "AUR provenance error: pinned AUR commit fetch failed with exit status 128",
            "FAILURE: protected AUR package base hyprshell-bin exited with "
            "status 1; continuing.",
        )
    )

    error = _failed_bootstrap(tmp_path, monkeypatch, stderr)

    assert error.category == FailureCategory.BOOTSTRAP_FAILED


@pytest.mark.parametrize(
    "final_error",
    [
        "error: request returned HTTP status 404",
        "fatal: unable to access 'https://aur.archlinux.org/fzf-tab/': "
        "certificate verify failed",
        "==> ERROR: One or more PGP signatures could not be verified!",
        "==> ERROR: A failure occurred in build().",
    ],
)
def test_aur_product_failures_are_not_reclassified(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    final_error: str,
) -> None:
    stderr = f"""\
error: error sending request for url (https://aur.archlinux.org/rpc): unexpected EOF
WARNING: approved AUR package base fzf-tab attempt 1/2 failed; retrying in 0s.
{final_error}
FAILURE: AUR package base fzf-tab exited with status 1; continuing.
"""

    error = _failed_bootstrap(tmp_path, monkeypatch, stderr)

    assert error.category == FailureCategory.BOOTSTRAP_FAILED


def test_earlier_product_failure_prevents_aur_reclassification(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stderr = """\
FAILURE: Building local packages exited with status 1; continuing.
error: error sending request for url (https://aur.archlinux.org/rpc): unexpected EOF
WARNING: approved AUR package base fzf-tab attempt 1/2 failed; retrying in 0s.
error: error sending request for url (https://aur.archlinux.org/rpc): unexpected EOF
FAILURE: AUR package base fzf-tab exited with status 1; continuing.
"""

    error = _failed_bootstrap(tmp_path, monkeypatch, stderr)

    assert error.category == FailureCategory.BOOTSTRAP_FAILED
