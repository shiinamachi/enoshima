from __future__ import annotations

import os
import stat
import subprocess
import tarfile
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path, PurePosixPath

from .errors import FailureCategory, VMError


@dataclass(frozen=True, slots=True)
class SourceIdentity:
    commit: str
    dirty: bool
    tree_hash: str
    files: tuple[str, ...]
    untracked_files: tuple[str, ...]


def _git(repository: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"git source identity command failed: git {' '.join(args)}",
            {"stderr": result.stderr.decode(errors="replace")[-4000:]},
        )
    return result.stdout


def _decode_names(payload: bytes) -> tuple[str, ...]:
    if not payload:
        return ()
    return tuple(
        sorted(
            os.fsdecode(value) for value in payload.rstrip(b"\0").split(b"\0") if value
        )
    )


def _safe_source_name(name: str) -> str:
    normalized = PurePosixPath(name.replace("\\", "/"))
    if normalized.is_absolute() or ".." in normalized.parts or not normalized.parts:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"unsafe source archive path: {name!r}",
        )
    return normalized.as_posix()


def _entry_header(digest: object, name: str, kind: str, mode: int) -> None:
    updater = getattr(digest, "update")
    updater(os.fsencode(name) + b"\0")
    updater(kind.encode() + b"\0")
    updater(f"{mode:o}".encode() + b"\0")


def _worktree_hash(repository: Path, files: tuple[str, ...]) -> str:
    digest = sha256()
    for name in files:
        path = repository / name
        try:
            metadata = path.lstat()
        except FileNotFoundError as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"source path disappeared while hashing: {name}",
            ) from error
        permissions = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            _entry_header(digest, name, "symlink", permissions)
            digest.update(os.fsencode(os.readlink(path)) + b"\0")
        elif stat.S_ISREG(metadata.st_mode):
            _entry_header(digest, name, "file", permissions)
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
        else:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"unsupported source path type: {name}",
            )
    return digest.hexdigest()


def source_identity(repository: Path) -> SourceIdentity:
    commit = _git(repository, "rev-parse", "HEAD").decode().strip()
    dirty = bool(_git(repository, "status", "--porcelain", "-z"))
    candidates = _decode_names(
        _git(
            repository,
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        )
    )
    files = tuple(
        name
        for name in candidates
        if (repository / name).is_file() or (repository / name).is_symlink()
    )
    untracked = _decode_names(
        _git(repository, "ls-files", "--others", "--exclude-standard", "-z")
    )
    return SourceIdentity(
        commit=commit,
        dirty=dirty,
        tree_hash=_worktree_hash(repository, files),
        files=files,
        untracked_files=untracked,
    )


def create_source_archive(repository: Path, archive: Path) -> SourceIdentity:
    before = source_identity(repository)
    file_list = b"\0".join(os.fsencode(name) for name in before.files)
    if file_list:
        file_list += b"\0"
    result = subprocess.run(
        [
            "tar",
            "--null",
            "--no-recursion",
            "--files-from=-",
            "--create",
            f"--file={archive}",
        ],
        cwd=repository,
        input=file_list,
        check=False,
        capture_output=True,
    )
    if result.returncode:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "cannot freeze the current worktree into a source archive",
            {
                "exit_code": result.returncode,
                "stderr": result.stderr.decode(errors="replace")[-4000:],
            },
        )
    archive.chmod(0o600)

    digest = sha256()
    names: list[str] = []
    try:
        with tarfile.open(archive, mode="r:") as bundle:
            for member in bundle.getmembers():
                name = _safe_source_name(member.name)
                names.append(name)
                if member.issym():
                    _entry_header(digest, name, "symlink", member.mode)
                    digest.update(os.fsencode(member.linkname) + b"\0")
                    continue
                if member.isreg() or member.islnk():
                    _entry_header(digest, name, "file", member.mode)
                    payload = bundle.extractfile(member)
                    if payload is None:
                        raise VMError(
                            FailureCategory.HARNESS_ERROR,
                            f"source archive member has no payload: {name}",
                        )
                    with payload:
                        for block in iter(lambda: payload.read(1024 * 1024), b""):
                            digest.update(block)
                    digest.update(b"\0")
                    continue
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"unsupported source archive member type: {name}",
                )
    except (OSError, tarfile.TarError) as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "cannot verify the immutable source archive",
            {"error": str(error)},
        ) from error

    after_commit = _git(repository, "rev-parse", "HEAD").decode().strip()
    after_dirty = bool(_git(repository, "status", "--porcelain", "-z"))
    return SourceIdentity(
        commit=after_commit,
        dirty=after_dirty,
        tree_hash=digest.hexdigest(),
        files=tuple(names),
        untracked_files=before.untracked_files,
    )
