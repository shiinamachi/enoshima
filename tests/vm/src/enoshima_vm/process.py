from __future__ import annotations

import os
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


@dataclass(frozen=True, slots=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


def run(
    argv: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path | None = None,
    timeout: float | None = None,
    check: bool = True,
    input_bytes: bytes | None = None,
    env: Mapping[str, str] | None = None,
    stdout: BinaryIO | int | None = subprocess.PIPE,
) -> CommandResult:
    normalized = tuple(os.fspath(value) for value in argv)
    completed = subprocess.run(
        normalized,
        cwd=cwd,
        timeout=timeout,
        check=False,
        input=input_bytes,
        stdout=stdout,
        stderr=subprocess.PIPE,
        env=dict(env) if env is not None else None,
    )
    stdout_value = completed.stdout
    if isinstance(stdout_value, bytes):
        stdout_text = stdout_value.decode("utf-8", errors="replace")
    else:
        stdout_text = ""
    stderr_text = (completed.stderr or b"").decode("utf-8", errors="replace")
    result = CommandResult(normalized, completed.returncode, stdout_text, stderr_text)
    if check and completed.returncode:
        raise subprocess.CalledProcessError(
            completed.returncode,
            normalized,
            output=stdout_text,
            stderr=stderr_text,
        )
    return result
