from __future__ import annotations

import json
import re
from collections.abc import Iterable
from hashlib import sha256
from pathlib import Path

from .config import DOMAIN_PREFIX, RUN_ID_PATTERN

SENSITIVE_PATTERN = re.compile(
    r"(credential|password|private|recovery|secret|token|\.key$|\.pem$)",
    re.IGNORECASE,
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
