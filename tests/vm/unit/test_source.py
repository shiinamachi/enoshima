from __future__ import annotations

import subprocess
import tarfile
from pathlib import Path

from enoshima_vm.source import create_source_archive, source_identity


def _git(repository: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repository), *args],
        check=True,
        capture_output=True,
    )


def _repository(tmp_path: Path) -> Path:
    repository = tmp_path / "repository"
    repository.mkdir()
    _git(repository, "init", "--initial-branch=main")
    _git(repository, "config", "user.name", "Enoshima Test")
    _git(repository, "config", "user.email", "enoshima@example.invalid")
    (repository / "tracked.txt").write_text("tracked\n", encoding="utf-8")
    (repository / "target-a").write_text("target a\n", encoding="utf-8")
    (repository / "target-b").write_text("target b\n", encoding="utf-8")
    (repository / "link").symlink_to("target-a")
    _git(repository, "add", ".")
    _git(repository, "commit", "-m", "base")
    return repository


def test_immutable_archive_identity_matches_planned_payload(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    (repository / "untracked.txt").write_text("untracked\n", encoding="utf-8")
    archive = tmp_path / "source.tar"

    planned = source_identity(repository)
    actual = create_source_archive(repository, archive)

    assert actual.commit == planned.commit
    assert actual.tree_hash == planned.tree_hash
    assert actual.files == planned.files
    assert actual.untracked_files == ("untracked.txt",)


def test_source_digest_covers_modes_symlinks_and_untracked_files(
    tmp_path: Path,
) -> None:
    repository = _repository(tmp_path)
    baseline = source_identity(repository).tree_hash

    (repository / "tracked.txt").chmod(0o755)
    executable = source_identity(repository).tree_hash
    (repository / "link").unlink()
    (repository / "link").symlink_to("target-b")
    retargeted = source_identity(repository).tree_hash
    (repository / "untracked.txt").write_text("new\n", encoding="utf-8")
    with_untracked = source_identity(repository).tree_hash

    assert len({baseline, executable, retargeted, with_untracked}) == 4


def test_tracked_deletion_is_absent_from_frozen_archive(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    (repository / "tracked.txt").unlink()
    archive = tmp_path / "source.tar"

    identity = create_source_archive(repository, archive)

    assert "tracked.txt" not in identity.files
    with tarfile.open(archive, mode="r:") as bundle:
        assert "tracked.txt" not in bundle.getnames()


def test_frozen_archive_does_not_follow_later_worktree_changes(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    archive = tmp_path / "source.tar"
    frozen = create_source_archive(repository, archive)

    (repository / "tracked.txt").write_text("changed later\n", encoding="utf-8")

    assert source_identity(repository).tree_hash != frozen.tree_hash
    with tarfile.open(archive, mode="r:") as bundle:
        payload = bundle.extractfile("tracked.txt")
        assert payload is not None
        assert payload.read() == b"tracked\n"
