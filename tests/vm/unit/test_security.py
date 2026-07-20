from __future__ import annotations

from pathlib import Path

import pytest

from enoshima_vm.security import (
    confined_path,
    redact_argv,
    require_domain,
    require_run_id,
)


def test_managed_identifiers_are_narrow() -> None:
    assert require_run_id("run-012345abcdef") == "run-012345abcdef"
    assert (
        require_domain("enoshima-test-run-012345abcdef")
        == "enoshima-test-run-012345abcdef"
    )
    with pytest.raises(ValueError):
        require_run_id("../../home")
    with pytest.raises(ValueError):
        require_domain("production-vm")


def test_confined_path_rejects_escape_and_root(tmp_path: Path) -> None:
    root = tmp_path / "runs"
    root.mkdir()
    assert confined_path(root, root / "run-012345abcdef").parent == root
    with pytest.raises(ValueError, match="escapes"):
        confined_path(root, tmp_path / "outside")
    with pytest.raises(ValueError, match="root"):
        confined_path(root, root)


def test_audit_argv_redacts_sensitive_values() -> None:
    assert redact_argv(["tool", "--password", "hunter2", "/tmp/id.key"]) == [
        "tool",
        "--password",
        "<redacted>",
        "<redacted>",
    ]
