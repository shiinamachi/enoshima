from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
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


class ProcessIdleTimeout(subprocess.TimeoutExpired):
    """A process exceeded its no-output progress budget."""

    def __init__(
        self,
        cmd: Sequence[str],
        timeout: float,
        idle_timeout: float,
        *,
        output: str,
        stderr: str,
    ) -> None:
        super().__init__(cmd, timeout, output=output, stderr=stderr)
        self.idle_timeout = idle_timeout


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # The group leader may exit while a child that ignores SIGTERM remains in
    # the same process group. Check the group itself before deciding cleanup is
    # complete instead of treating a reaped leader as sufficient.
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return
    os.killpg(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


def _decode_capture(stream: object) -> str:
    return stream.decode("utf-8", errors="replace") if isinstance(stream, bytes) else ""


def _run_with_idle_timeout(
    normalized: tuple[str, ...],
    *,
    cwd: Path | None,
    timeout: float,
    idle_timeout: float,
    env: Mapping[str, str] | None,
) -> CommandResult:
    if timeout <= 0 or idle_timeout <= 0:
        raise ValueError("process timeouts must be positive")
    started = time.monotonic()
    last_progress = started
    last_size = 0
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            normalized,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            env=dict(env) if env is not None else None,
            start_new_session=True,
        )
        try:
            timeout_kind: str | None = None
            while process.poll() is None:
                now = time.monotonic()
                size = os.fstat(stdout_file.fileno()).st_size + os.fstat(
                    stderr_file.fileno()
                ).st_size
                if size != last_size:
                    last_size = size
                    last_progress = now
                if now - started >= timeout:
                    timeout_kind = "absolute"
                    break
                if now - last_progress >= idle_timeout:
                    timeout_kind = "idle"
                    break
                time.sleep(min(0.1, idle_timeout / 4))

            if timeout_kind is not None:
                _terminate_process_group(process)
            else:
                process.wait()
            stdout_file.seek(0)
            stderr_file.seek(0)
            stdout_text = _decode_capture(stdout_file.read())
            stderr_text = _decode_capture(stderr_file.read())
            if timeout_kind == "idle":
                raise ProcessIdleTimeout(
                    normalized,
                    timeout,
                    idle_timeout,
                    output=stdout_text,
                    stderr=stderr_text,
                )
            if timeout_kind == "absolute":
                raise subprocess.TimeoutExpired(
                    normalized,
                    timeout,
                    output=stdout_text,
                    stderr=stderr_text,
                )
            return CommandResult(
                normalized, process.returncode, stdout_text, stderr_text
            )
        except BaseException:
            # Durable MCP workers translate SIGTERM/SIGINT into an exception.
            # Reap the entire command group before unwinding so a disconnected
            # or cancelled worker cannot leave SSH/bootstrap descendants alive
            # after its operation lock is released.
            _terminate_process_group(process)
            raise


def run(
    argv: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path | None = None,
    timeout: float | None = None,
    idle_timeout: float | None = None,
    check: bool = True,
    input_bytes: bytes | None = None,
    env: Mapping[str, str] | None = None,
    stdout: BinaryIO | int | None = subprocess.PIPE,
) -> CommandResult:
    normalized = tuple(os.fspath(value) for value in argv)
    if idle_timeout is not None:
        if timeout is None:
            raise ValueError("idle_timeout requires an absolute timeout")
        if input_bytes is not None or stdout != subprocess.PIPE:
            raise ValueError(
                "idle_timeout requires captured output and no stdin payload"
            )
        result = _run_with_idle_timeout(
            normalized,
            cwd=cwd,
            timeout=timeout,
            idle_timeout=idle_timeout,
            env=env,
        )
    else:
        process = subprocess.Popen(
            normalized,
            cwd=cwd,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=stdout,
            stderr=subprocess.PIPE,
            env=dict(env) if env is not None else None,
            start_new_session=True,
        )
        try:
            captured_stdout, captured_stderr = process.communicate(
                input=input_bytes,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            _terminate_process_group(process)
            raise subprocess.TimeoutExpired(
                normalized,
                timeout,
                output=_decode_capture(error.output),
                stderr=_decode_capture(error.stderr),
            ) from error
        except BaseException:
            # A durable worker deadline or cancellation must not strand the
            # currently executing command or any descendant it spawned.
            _terminate_process_group(process)
            raise
        stdout_text = _decode_capture(captured_stdout)
        stderr_text = _decode_capture(captured_stderr or b"")
        result = CommandResult(
            normalized, process.returncode, stdout_text, stderr_text
        )
    if check and result.returncode:
        raise subprocess.CalledProcessError(
            result.returncode,
            normalized,
            output=result.stdout,
            stderr=result.stderr,
        )
    return result
