from __future__ import annotations

import fcntl
import json
import os
import re
import stat
from collections.abc import Iterable
from contextlib import contextmanager
from hashlib import sha256
from pathlib import Path

from .config import DOMAIN_PREFIX, RUN_ID_PATTERN

SENSITIVE_PATTERN = re.compile(
    r"(credential|password|private|recovery|secret|token|\.key$|\.pem$)",
    re.IGNORECASE,
)
TERMINAL_RUN_STATES = frozenset(
    {"completed", "destroyed", "expired", "invalidated"}
)
CLEANUP_COMPLETE_RUN_STATES = frozenset({"completed", "destroyed", "expired"})
ALLOWED_TERMINAL_TRANSITIONS = frozenset(
    {
        ("completed", "invalidated"),
        ("destroyed", "invalidated"),
        ("expired", "invalidated"),
    }
)


def require_run_id(run_id: str) -> str:
    if not RUN_ID_PATTERN.fullmatch(run_id):
        raise ValueError(f"invalid run id: {run_id}")
    return run_id


def require_domain(domain: str) -> str:
    if not domain.startswith(DOMAIN_PREFIX) or not RUN_ID_PATTERN.fullmatch(
        domain.removeprefix(DOMAIN_PREFIX)
    ):
        raise ValueError(f"refusing unmanaged libvirt domain: {domain}")
    return domain


def confined_path(root: Path, candidate: Path, *, allow_root: bool = False) -> Path:
    resolved_root = root.resolve()
    resolved = candidate.resolve(strict=False)
    if not resolved.is_relative_to(resolved_root):
        raise ValueError(f"path escapes managed root: {candidate}")
    if not allow_root and resolved == resolved_root:
        raise ValueError(f"managed root is not a valid destructive target: {candidate}")
    return resolved


@contextmanager
def run_record_lock(run_dir: Path, *, create: bool = True):
    """Serialize watchdog cleanup and run-record read/modify/write cycles."""
    if create:
        run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    elif not run_dir.is_dir() or run_dir.is_symlink():
        yield False
        return
    lock_path = confined_path(run_dir, run_dir / ".run.lock")
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise ValueError(f"unsafe managed run lock: {lock_path}")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield True
    finally:
        os.close(descriptor)


def terminal_run_state_preserved(current: object, proposed: object) -> bool:
    """Keep terminal state monotonic except when invalidating stale evidence."""
    return (
        current in TERMINAL_RUN_STATES
        and proposed != current
        and (current, proposed) not in ALLOWED_TERMINAL_TRANSITIONS
    )


def run_cleanup_complete(record: dict[str, object]) -> bool:
    """Return whether a terminal result no longer owns disposable resources."""
    return bool(record.get("synthetic")) or record.get(
        "status"
    ) in CLEANUP_COMPLETE_RUN_STATES or (
        record.get("status") == "invalidated" and bool(record.get("destroyed_at"))
    )


def redact_argv(argv: Iterable[str]) -> list[str]:
    redacted: list[str] = []
    hide_next = False
    for value in argv:
        if hide_next:
            redacted.append("<redacted>")
            hide_next = False
            continue
        if value.lower() in {"--password", "--token", "--secret"}:
            redacted.append(value)
            hide_next = True
        elif SENSITIVE_PATTERN.search(value):
            redacted.append("<redacted>")
        else:
            redacted.append(value)
    return redacted


def append_audit(path: Path, event: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
    path.chmod(0o600)


def argv_digest(argv: Iterable[str]) -> str:
    return sha256("\0".join(argv).encode()).hexdigest()
