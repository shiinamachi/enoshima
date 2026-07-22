from __future__ import annotations

from pathlib import Path, PurePosixPath

from enoshima_vm.artifacts import collect_fixed_artifacts
from enoshima_vm.errors import FailureCategory, VMError


class UnreachableGuest:
    def exec(self, *_args: object, **_kwargs: object) -> None:
        raise VMError(FailureCategory.SSH_TIMEOUT, "guest is offline")


def test_collection_stops_quickly_when_guest_is_unreachable(tmp_path: Path) -> None:
    collected = collect_fixed_artifacts(
        UnreachableGuest(),
        tmp_path,
        PurePosixPath("/home/kentakang/enoshima-test/artifacts"),
    )

    assert collected == ["guest-unreachable.txt"]
    assert "remote artifact collection was skipped" in (
        tmp_path / "guest-unreachable.txt"
    ).read_text(encoding="utf-8")


def test_collection_preserves_non_ssh_vm_errors(tmp_path: Path) -> None:
    class BrokenHarnessGuest:
        def exec(self, *_args: object, **_kwargs: object) -> None:
            raise VMError(FailureCategory.HARNESS_ERROR, "libvirt failed")

    try:
        collect_fixed_artifacts(
            BrokenHarnessGuest(),
            tmp_path,
            PurePosixPath("/home/kentakang/enoshima-test/artifacts"),
        )
    except VMError as error:
        assert error.category == FailureCategory.HARNESS_ERROR
    else:
        raise AssertionError("non-SSH artifact collection failure was hidden")
