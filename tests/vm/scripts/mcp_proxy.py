from __future__ import annotations

import argparse
import contextlib
import ctypes
import fcntl
import json
import os
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

_WORKER_BOOTSTRAP = any(
    argument in {"--worker", "--guardian-worker", "--payload-worker"}
    or argument.startswith(
        ("--worker=", "--guardian-worker=", "--payload-worker=")
    )
    for argument in sys.argv[1:]
)

if not _WORKER_BOOTSTRAP:
    import anyio  # noqa: E402
    from mcp.server.fastmcp import FastMCP  # noqa: E402
    from mcp.types import ToolAnnotations  # noqa: E402

INSTRUCTIONS = (
    "Use verification_plan before selecting work. vm_run_suite, "
    "vm_run_affected, and vm_run_plan start a detached, durable worker and return "
    "an operationId immediately. Use one vm_wait_operation call at a time until "
    "the operation reaches a final state; use vm_list_operations only to recover "
    "an operationId after a client or transport restart. Never kill the MCP server "
    "to reload harness source: every tool worker imports the current source in a "
    "fresh process. Keep at most one durable VM operation active."
)

OPERATION_ID_RE = re.compile(r"^operation-[0-9a-f]{12}$")
FINAL_STATES = frozenset({"passed", "failed", "blocked", "completed", "orphaned"})
DURABLE_TOOLS = frozenset({"vm_run_suite", "vm_run_affected", "vm_run_plan"})
MUTATING_FRESH_TOOLS = frozenset(
    {
        "vm_create",
        "vm_wait",
        "vm_upload_worktree",
        "vm_exec",
        "vm_reboot",
        "vm_poweroff",
        "vm_screenshot",
        "vm_collect_artifacts",
        "vm_destroy",
    }
)
MAX_PROTOCOL_BYTES = 128 * 1024
MAX_OPERATION_SUMMARY_BYTES = 32 * 1024
MAX_DIAGNOSTIC_BYTES = 16 * 1024
MAX_DIAGNOSTIC_LINES = 80
MAX_CLEANUP_SURVIVOR_SAMPLE = 8
MAX_WAIT_SECONDS = 55
TERMINAL_INTEGRITY_RETRY_SECONDS = 0.05
TERMINAL_INTEGRITY_ATTEMPTS = 3
DEFAULT_FRESH_WORKER_TIMEOUT_SECONDS = 90
MAX_FRESH_WORKER_TIMEOUT_SECONDS = 3600
DURABLE_START_READY_TIMEOUT_SECONDS = 30
FRESH_WORKER_TERM_GRACE_SECONDS = 2
FRESH_WORKER_KILL_GRACE_SECONDS = 2
DURABLE_FOCUSED_CHECK_BUDGET_SECONDS = 2 * 60 * 60
DURABLE_SUITE_ATTEMPTS = 2
DURABLE_ATTEMPT_OVERHEAD_SECONDS = 30 * 60
DURABLE_FINALIZATION_BUDGET_SECONDS = 60 * 60
MAX_DURABLE_WORKER_TIMEOUT_SECONDS = 7 * 24 * 60 * 60
PR_SET_PDEATHSIG = 1
PR_SET_CHILD_SUBREAPER = 36
_SESSION_ENVIRONMENT_ERROR: str | None = None
_TEST_GLOBAL_MUTATION_LOCK_PATH: Path | None = None

if not _WORKER_BOOTSTRAP:
    mcp = FastMCP("enoshima-vm", instructions=INSTRUCTIONS, json_response=True)

    READ_ONLY = ToolAnnotations(
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    )
    WRITE = ToolAnnotations(
        readOnlyHint=False,
        destructiveHint=False,
        idempotentHint=False,
        openWorldHint=False,
    )
    DESTRUCTIVE = ToolAnnotations(
        readOnlyHint=False,
        destructiveHint=True,
        idempotentHint=True,
        openWorldHint=False,
    )
else:

    class _WorkerMCPShim:
        """Keep worker startup stdlib-only while defining shared callables."""

        @staticmethod
        def tool(*_args: object, **_kwargs: object) -> object:
            def decorate(function: object) -> object:
                return function

            return decorate

    mcp = _WorkerMCPShim()
    READ_ONLY = WRITE = DESTRUCTIVE = None


def _normalize_desktop_session_environment() -> None:
    """Keep fresh workers on the caller's canonical user-session libvirt."""
    global _SESSION_ENVIRONMENT_ERROR
    uid = os.getuid()
    home = Path(pwd.getpwuid(uid).pw_dir)
    runtime = Path(f"/run/user/{uid}")
    try:
        runtime_stat = runtime.stat()
    except OSError:
        runtime_stat = None
    if (
        runtime_stat is not None
        and runtime.is_dir()
        and not runtime.is_symlink()
        and runtime_stat.st_uid == uid
    ):
        os.environ["HOME"] = str(home)
        os.environ["XDG_RUNTIME_DIR"] = str(runtime)
        os.environ["XDG_CACHE_HOME"] = str(home / ".cache")
        os.environ["XDG_CONFIG_HOME"] = str(home / ".config")
        _SESSION_ENVIRONMENT_ERROR = None
        return
    _SESSION_ENVIRONMENT_ERROR = (
        f"canonical desktop runtime {runtime} is unavailable or unsafe; "
        "refusing to select a fallback qemu:///session daemon"
    )


def _require_desktop_session_environment() -> None:
    if _SESSION_ENVIRONMENT_ERROR is not None:
        raise RuntimeError(_SESSION_ENVIRONMENT_ERROR)


def _utc_now() -> str:
    return datetime.now(UTC).isoformat()


def _state_root() -> Path:
    configured = os.environ.get("ENOSHIMA_VM_STATE_ROOT")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".local" / "state" / "enoshima-vm"


def _operations_root() -> Path:
    root = _state_root() / "mcp-operations"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    return root


def _global_mutation_lock_path() -> Path:
    if _TEST_GLOBAL_MUTATION_LOCK_PATH is not None:
        lock_path = _TEST_GLOBAL_MUTATION_LOCK_PATH
        lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path.parent.chmod(0o700)
        return lock_path
    uid = os.getuid()
    runtime = Path(f"/run/user/{uid}")
    try:
        runtime_stat = runtime.lstat()
    except OSError as error:
        raise RuntimeError(
            f"canonical user runtime {runtime} is unavailable: {error}"
        ) from error
    if (
        runtime.is_symlink()
        or not stat.S_ISDIR(runtime_stat.st_mode)
        or runtime_stat.st_uid != uid
        or stat.S_IMODE(runtime_stat.st_mode) != 0o700
    ):
        raise RuntimeError(f"canonical user runtime {runtime} is unsafe")

    lock_dir = runtime / "enoshima-vm"
    try:
        lock_dir.mkdir(mode=0o700)
    except FileExistsError:
        pass
    lock_dir_stat = lock_dir.lstat()
    if (
        lock_dir.is_symlink()
        or not stat.S_ISDIR(lock_dir_stat.st_mode)
        or lock_dir_stat.st_uid != uid
        or stat.S_IMODE(lock_dir_stat.st_mode) != 0o700
    ):
        raise RuntimeError(f"global mutation lock directory {lock_dir} is unsafe")
    lock_path = lock_dir / "active.lock"
    flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        lock_stat = os.fstat(descriptor)
        if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != uid:
            raise RuntimeError(f"global mutation lock {lock_path} is unsafe")
        if stat.S_IMODE(lock_stat.st_mode) != 0o600:
            os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)
    return lock_path


def _validate_global_mutation_lock_fd(descriptor: int) -> None:
    lock_path = _global_mutation_lock_path()
    descriptor_stat = os.fstat(descriptor)
    path_stat = lock_path.lstat()
    if (
        not stat.S_ISREG(descriptor_stat.st_mode)
        or descriptor_stat.st_uid != os.getuid()
        or stat.S_IMODE(descriptor_stat.st_mode) != 0o600
        or stat.S_ISLNK(path_stat.st_mode)
        or not stat.S_ISREG(path_stat.st_mode)
        or path_stat.st_uid != os.getuid()
        or (descriptor_stat.st_dev, descriptor_stat.st_ino)
        != (path_stat.st_dev, path_stat.st_ino)
    ):
        raise RuntimeError(f"global mutation lock {lock_path} is unsafe")


def _open_global_mutation_lock() -> int:
    lock_path = _global_mutation_lock_path()
    flags = os.O_RDWR | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags)
    try:
        _validate_global_mutation_lock_fd(descriptor)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _atomic_write_json(path: Path, document: dict[str, object]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def _read_json(path: Path) -> dict[str, object]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        message = f"cannot read MCP operation record {path}: {error}"
        raise RuntimeError(message) from error
    if not isinstance(document, dict):
        raise RuntimeError(f"MCP operation record is not an object: {path}")
    return document


def _operation_dir(operation_id: str) -> Path:
    if not OPERATION_ID_RE.fullmatch(operation_id):
        raise ValueError("invalid MCP operation id")
    return _operations_root() / operation_id


def _tail_text(path: Path, limit: int = MAX_DIAGNOSTIC_BYTES) -> str:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            text = handle.read(limit).decode("utf-8", errors="replace")
            lines = text.splitlines()
            return "\n".join(lines[-MAX_DIAGNOSTIC_LINES:])
    except OSError:
        return ""


def _json_envelope(result: object) -> dict[str, object]:
    return {"ok": True, "result": result}


def _process_bootstrap_path() -> Path:
    packaged = Path(__file__).resolve().with_name("process_bootstrap.py")
    if packaged.is_file():
        return packaged
    return (
        Path(__file__).resolve().parents[1]
        / "src"
        / "enoshima_vm"
        / "process_bootstrap.py"
    )


def _spawned_python() -> str:
    return os.environ.get("ENOSHIMA_VM_PYTHON", sys.executable)


def _bootstrap_prefix(expected_parent_pid: int) -> list[str]:
    return [
        _spawned_python(),
        "-I",
        "-S",
        str(_process_bootstrap_path()),
        "--expected-parent-pid",
        str(expected_parent_pid),
        str(Path(__file__).resolve()),
    ]


def _bootstrap_argv(
    role: str,
    tool: str,
    *,
    expected_parent_pid: int,
) -> list[str]:
    return [
        *_bootstrap_prefix(expected_parent_pid),
        role,
        tool,
        "--expected-parent-pid",
        str(expected_parent_pid),
    ]


def _error_envelope(error: BaseException) -> dict[str, object]:
    category = getattr(error, "category", "HARNESS_ERROR")
    return {
        "ok": False,
        "error": {
            "category": str(category),
            "type": type(error).__name__,
            "message": str(error)[:4096],
        },
    }


def _call_implementation(tool: str, arguments: dict[str, object]) -> object:
    if tool == "_operation_status":
        operation_id = arguments.get("operation_id")
        if not isinstance(operation_id, str):
            raise ValueError("operation status requires a string operation_id")
        return _operation_summary(operation_id)
    if tool == "_operation_list":
        limit = arguments.get("limit")
        if not isinstance(limit, int) or isinstance(limit, bool):
            raise ValueError("operation list requires an integer limit")
        return _list_operations(limit)
    if tool == "_operation_wait":
        operation_id = arguments.get("operation_id")
        timeout_seconds = arguments.get("timeout_seconds")
        if not isinstance(operation_id, str):
            raise ValueError("operation wait requires a string operation_id")
        if not isinstance(timeout_seconds, int) or isinstance(timeout_seconds, bool):
            raise ValueError("operation wait requires an integer timeout_seconds")
        return _wait_operation(operation_id, timeout_seconds)
    if tool == "_operation_budget":
        from enoshima_vm.config import load_suite
        from enoshima_vm.verification import load_verification_plan

        operation_tool = arguments.get("operation_tool")
        if operation_tool == "vm_run_plan":
            plan_name = str(arguments.get("plan", "release"))
            suites = list(load_verification_plan(plan_name).suites)
        elif operation_tool == "vm_run_suite":
            suites = [str(arguments.get("suite", "smoke"))]
        else:
            raw_suites = arguments.get("suites")
            if not isinstance(raw_suites, list) or not all(
                isinstance(suite, str) for suite in raw_suites
            ):
                raise RuntimeError("operation budget received an invalid suite list")
            suites = list(raw_suites)
        return {
            "suites": suites,
            "suiteBudgetMinutes": {
                suite: load_suite(suite).timeout_minutes for suite in suites
            },
        }
    from enoshima_vm import mcp_server as implementation

    function = getattr(implementation, tool, None)
    if function is None or not callable(function):
        raise RuntimeError(f"fresh worker does not implement {tool}")
    with contextlib.redirect_stdout(sys.stderr):
        return function(**arguments)


def _write_worker_envelope(envelope: dict[str, object]) -> None:
    encoded = json.dumps(envelope, default=str, sort_keys=True).encode()
    if len(encoded) > MAX_PROTOCOL_BYTES:
        raise RuntimeError("fresh worker protocol response exceeded 128 KiB")
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()


def _result_state(result: object) -> str:
    if not isinstance(result, dict):
        return "completed"
    verdict = result.get("result")
    if verdict in {"passed", "failed", "blocked"}:
        return str(verdict)
    return "completed"


def _read_process_stat(pid: int) -> tuple[str, int, int, int, int] | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        suffix = raw[raw.rindex(")") + 2 :].split()
        return (
            suffix[0],
            int(suffix[1]),
            int(suffix[2]),
            int(suffix[3]),
            int(suffix[19]),
        )
    except (OSError, ValueError, IndexError):
        return None


def _process_start_ticks(pid: int) -> int | None:
    stat = _read_process_stat(pid)
    if stat is None or stat[0] == "Z":
        return None
    return stat[4]


def _identity_arguments(tool: str, arguments: dict[str, object]) -> dict[str, object]:
    if tool == "vm_run_plan":
        mode = "release"
    else:
        mode = str(
            arguments.get("mode", arguments.get("verification_mode", "checkpoint"))
        )
    return {
        "base_ref": str(arguments.get("base_ref", "origin/main")),
        "mode": mode,
    }


def _reconcile_actual_identity(
    tool: str,
    arguments: dict[str, object],
    record: dict[str, object],
) -> dict[str, object]:
    actual = _call_implementation(
        "verification_plan", _identity_arguments(tool, arguments)
    )
    if not isinstance(actual, dict):
        raise RuntimeError("final verification plan did not return an identity")
    fields = {
        "SourceCommit": "sourceCommit",
        "WorktreeDigest": "worktreeDigest",
        "SourceTreeDigest": "sourceTreeDigest",
    }
    reconciled: dict[str, object] = {}
    mismatches: list[str] = []
    for suffix, source_key in fields.items():
        planned_key = f"planned{suffix}"
        actual_key = f"actual{suffix}"
        planned_value = record.get(planned_key)
        actual_value = actual.get(source_key)
        if not isinstance(planned_value, str) or not isinstance(actual_value, str):
            raise RuntimeError(
                f"durable operation identity is missing {planned_key} or {source_key}"
            )
        reconciled[actual_key] = actual_value
        if planned_value != actual_value:
            mismatches.append(
                f"{source_key}: planned={planned_value!r}, actual={actual_value!r}"
            )
    record.update(reconciled)
    if mismatches:
        raise RuntimeError(
            "source identity changed during durable operation; refusing stale "
            "verification result: " + "; ".join(mismatches)
        )
    return reconciled


def _payload_main(
    tool: str,
    *,
    operation_dir: Path | None,
    lock_fd: int | None,
    lease_fd: int | None,
    expected_parent_pid: int | None,
) -> int:
    if expected_parent_pid is None:
        raise RuntimeError("payload requires its supervisor identity")

    payload_pid = os.getpid()
    interrupted: dict[str, int] = {}

    def handle_signal(signum: int, _frame: object) -> None:
        if os.getpid() != payload_pid:
            # A fork-only daemon can inherit this handler and the protocol
            # spool descriptor. It must never unwind through the payload
            # result writer and append a second envelope.
            os._exit(128 + signum)
        interrupted["signal"] = signum
        _terminate_payload_descendants()
        raise InterruptedError(f"payload received signal {signum}")

    _unblock_control_signals()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    if not _set_parent_death_signal(expected_parent_pid):
        return 128 + signal.SIGTERM

    if lock_fd is None:
        os.environ.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)
    else:
        os.fstat(lock_fd)
        os.environ["ENOSHIMA_VM_OPERATION_LOCK_FD"] = str(lock_fd)
    _normalize_desktop_session_environment()

    if operation_dir is None:
        try:
            arguments = json.load(sys.stdin)
            if not isinstance(arguments, dict):
                raise ValueError("worker arguments must be a JSON object")
            envelope = _json_envelope(_call_implementation(tool, arguments))
        except BaseException as error:
            traceback.print_exc(file=sys.stderr)
            envelope = _error_envelope(error)
            _write_worker_envelope(envelope)
            return 1
        _write_worker_envelope(envelope)
        return 0

    if lock_fd is None or lease_fd is None:
        raise RuntimeError("durable payload requires inherited active and lease locks")
    os.fstat(lease_fd)

    record_path = operation_dir / "operation.json"
    pending_path = operation_dir / "result.pending.json"
    record = _read_json(record_path)
    arguments = record.get("arguments")
    if not isinstance(arguments, dict):
        raise RuntimeError("durable worker arguments are missing")
    started_at = _utc_now()
    record.update(
        {
            "status": "running",
            "startedAt": started_at,
            "updatedAt": started_at,
            "payloadPid": os.getpid(),
            "payloadStartTicks": _process_start_ticks(os.getpid()),
        }
    )
    _atomic_write_json(record_path, record)

    try:
        result = _call_implementation(tool, arguments)
        actual_identity = _reconcile_actual_identity(tool, arguments, record)
        record.update(actual_identity)
        if isinstance(result, dict):
            result = dict(result)
            result.update(actual_identity)
            for suffix in ("SourceCommit", "WorktreeDigest", "SourceTreeDigest"):
                result[f"planned{suffix}"] = record[f"planned{suffix}"]
        envelope = _json_envelope(result)
        state = _result_state(result)
    except BaseException as error:
        traceback.print_exc(file=sys.stderr)
        envelope = _error_envelope(error)
        state = "orphaned" if interrupted else "failed"
    record_updates: dict[str, object] = {}
    for key in (
        "actualSourceCommit",
        "actualWorktreeDigest",
        "actualSourceTreeDigest",
    ):
        if key in record:
            record_updates[key] = record[key]
    result = envelope.get("result")
    if isinstance(result, dict):
        for key in ("artifactRoot", "category", "failureFingerprint", "result"):
            if key in result:
                record_updates[key] = result[key]
    error = envelope.get("error")
    if isinstance(error, dict):
        record_updates["error"] = error
    _atomic_write_json(
        pending_path,
        {
            "schema": 1,
            "status": state,
            "envelope": envelope,
            "recordUpdates": record_updates,
            "payloadCompletedAt": _utc_now(),
        },
    )
    return 0 if envelope.get("ok") is True else 1


def _set_parent_death_signal(expected_parent_pid: int) -> bool:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return os.getppid() == expected_parent_pid


def _unblock_control_signals() -> None:
    signal.pthread_sigmask(
        signal.SIG_UNBLOCK,
        {signal.SIGTERM, signal.SIGINT},
    )


def _set_child_subreaper() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def _open_secure_append_log(path: Path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise RuntimeError(f"worker log {path} is unsafe")
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "ab")
    except BaseException:
        os.close(descriptor)
        raise


def _guardian_main(
    tool: str,
    *,
    operation_dir: Path | None,
    lock_fd: int | None,
    lease_fd: int | None,
    expected_parent_pid: int | None,
) -> int:
    if expected_parent_pid is None:
        raise RuntimeError("guardian requires its supervisor identity")

    interrupted: dict[str, int] = {}

    def handle_signal(signum: int, _frame: object) -> None:
        interrupted["signal"] = signum

    _unblock_control_signals()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    _set_child_subreaper()
    if not _set_parent_death_signal(expected_parent_pid):
        return 128 + signal.SIGTERM

    if operation_dir is not None:
        payload_stdout_path = operation_dir / "payload.stdout.log"
        payload_stdout = _open_secure_append_log(payload_stdout_path)
    else:
        payload_stdout_path = None
        payload_stdout = tempfile.TemporaryFile(
            mode="w+b", prefix="enoshima-vm-payload-", suffix=".json"
        )

    argv = _bootstrap_argv(
        "--payload-worker",
        tool,
        expected_parent_pid=os.getpid(),
    )
    if lock_fd is not None:
        os.fstat(lock_fd)
        argv.extend(("--lock-fd", str(lock_fd)))
    if operation_dir is not None:
        if lock_fd is None or lease_fd is None:
            raise RuntimeError(
                "durable guardian requires inherited active and lease locks"
            )
        os.fstat(lease_fd)
        argv.extend(
            (
                "--operation-dir",
                str(operation_dir),
                "--lease-fd",
                str(lease_fd),
            )
        )
    inherited_fds = tuple(
        descriptor for descriptor in (lock_fd, lease_fd) if descriptor is not None
    )
    payload_environment = dict(os.environ)
    payload_environment.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)
    if lock_fd is not None:
        payload_environment["ENOSHIMA_VM_OPERATION_LOCK_FD"] = str(lock_fd)
    try:
        payload = subprocess.Popen(
            argv,
            stdin=None if operation_dir is None else subprocess.DEVNULL,
            stdout=payload_stdout,
            stderr=None,
            close_fds=True,
            pass_fds=inherited_fds,
            start_new_session=True,
            env=payload_environment,
        )
    except BaseException:
        payload_stdout.close()
        raise
    else:
        if operation_dir is not None:
            payload_stdout.close()

    while payload.poll() is None and not interrupted:
        try:
            payload.wait(timeout=0.05)
        except subprocess.TimeoutExpired:
            _reap_direct_zombies(exclude=frozenset({payload.pid}))

    if interrupted:
        survivors = _cleanup_descendants_fail_closed(
            os.getpid(), managed_process=payload
        )
        while survivors:
            time.sleep(0.25)
            survivors = _cleanup_descendants_fail_closed(
                os.getpid(), managed_process=payload
            )
        if operation_dir is None:
            payload_stdout.close()
        return 128 + interrupted["signal"]

    returncode = payload.wait()
    survivors = _cleanup_descendants_fail_closed(os.getpid(), managed_process=payload)
    while survivors:
        time.sleep(0.25)
        survivors = _cleanup_descendants_fail_closed(
            os.getpid(), managed_process=payload
        )
    if operation_dir is None:
        try:
            payload_stdout.flush()
            payload_stdout.seek(0)
            output = payload_stdout.read(MAX_PROTOCOL_BYTES + 1)
            if len(output) > MAX_PROTOCOL_BYTES:
                raise RuntimeError(
                    "fresh payload protocol response exceeded 128 KiB"
                )
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
        finally:
            payload_stdout.close()
    return returncode


def _process_snapshot() -> dict[int, tuple[str, int, int, int, int]]:
    snapshot: dict[int, tuple[str, int, int, int, int]] = {}
    for stat_path in Path("/proc").glob("[0-9]*/stat"):
        try:
            pid = int(stat_path.parent.name)
        except ValueError:
            continue
        stat = _read_process_stat(pid)
        if stat is not None:
            snapshot[pid] = stat
    return snapshot


def _descendant_processes(
    root_pid: int,
) -> dict[int, tuple[str, int, int, int, int]]:
    snapshot = _process_snapshot()
    ancestors = {root_pid}
    descendants: dict[int, tuple[str, int, int, int, int]] = {}
    changed = True
    while changed:
        changed = False
        for pid, process_stat in snapshot.items():
            if pid in descendants or pid == root_pid:
                continue
            if process_stat[1] in ancestors:
                descendants[pid] = process_stat
                ancestors.add(pid)
                changed = True
    if root_pid == os.getpid():
        # As a child subreaper we adopt daemonized descendants. Include every
        # direct child even if it reparented between the snapshot and this walk.
        for pid, process_stat in snapshot.items():
            if pid != root_pid and process_stat[1] == root_pid:
                descendants[pid] = process_stat
    return descendants


def _live_descendant_identities(root_pid: int) -> dict[int, int]:
    return {
        pid: stat[4]
        for pid, stat in _descendant_processes(root_pid).items()
        if stat[0] != "Z"
    }


def _signal_process_identity(pid: int, start_ticks: int, signum: int) -> str | None:
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd_open = getattr(libc, "pidfd_open", None)
    pidfd_send_signal = getattr(libc, "pidfd_send_signal", None)
    if pidfd_open is None or pidfd_send_signal is None:
        return "pidfd signaling is unavailable"
    descriptor = int(pidfd_open(pid, 0))
    if descriptor < 0:
        error_number = ctypes.get_errno()
        if error_number in {getattr(os, "ENOSYS", 38), getattr(os, "ESRCH", 3)}:
            return None
        return f"pidfd_open failed: {os.strerror(error_number)}"
    try:
        process_stat = _read_process_stat(pid)
        if (
            process_stat is None
            or process_stat[0] == "Z"
            or process_stat[4] != start_ticks
        ):
            return None
        if pidfd_send_signal(descriptor, signum, None, 0) != 0:
            error_number = ctypes.get_errno()
            if error_number not in {
                getattr(os, "ENOSYS", 38),
                getattr(os, "ESRCH", 3),
            }:
                return f"pidfd_send_signal failed: {os.strerror(error_number)}"
        return None
    finally:
        os.close(descriptor)


def _reap_direct_zombies(*, exclude: frozenset[int] = frozenset()) -> None:
    for pid, process_stat in _process_snapshot().items():
        if pid in exclude or process_stat[0] != "Z" or process_stat[1] != os.getpid():
            continue
        try:
            os.waitpid(pid, os.WNOHANG)
        except (ChildProcessError, ProcessLookupError):
            pass


def _descendant_diagnostics(root_pid: int) -> list[dict[str, object]]:
    return [
        {
            "pid": pid,
            "startTicks": stat[4],
            "state": stat[0],
            "parentPid": stat[1],
            "processGroup": stat[2],
            "sessionId": stat[3],
        }
        for pid, stat in sorted(_descendant_processes(root_pid).items())
        if stat[0] != "Z"
    ]


def _terminate_descendants(
    root_pid: int,
    *,
    managed_process: subprocess.Popen[bytes] | None = None,
) -> list[dict[str, object]]:
    signal_errors: dict[tuple[int, int], str] = {}

    def signal_identity(pid: int, start_ticks: int, signum: int) -> None:
        try:
            error = _signal_process_identity(pid, start_ticks, signum)
        except BaseException as caught:
            error = f"{type(caught).__name__}: {caught}"
        identity = (pid, start_ticks)
        if error:
            signal_errors[identity] = error[:1024]
        else:
            signal_errors.pop(identity, None)

    def diagnostics() -> list[dict[str, object]]:
        values = _descendant_diagnostics(root_pid)
        for value in values:
            identity = (int(value["pid"]), int(value["startTicks"]))
            if identity in signal_errors:
                value["signalError"] = signal_errors[identity]
        return values

    def poll_and_reap() -> None:
        excluded: frozenset[int] = frozenset()
        if managed_process is not None and managed_process.poll() is None:
            excluded = frozenset({managed_process.pid})
        _reap_direct_zombies(exclude=excluded)

    term_deadline = time.monotonic() + FRESH_WORKER_TERM_GRACE_SECONDS
    term_signaled: set[tuple[int, int]] = set()
    while True:
        identities = _live_descendant_identities(root_pid)
        if not identities:
            poll_and_reap()
            if not _live_descendant_identities(root_pid):
                return []
        for pid, start_ticks in identities.items():
            identity = (pid, start_ticks)
            if identity in term_signaled:
                continue
            signal_identity(pid, start_ticks, signal.SIGTERM)
            term_signaled.add(identity)
        poll_and_reap()
        if time.monotonic() >= term_deadline:
            break
        time.sleep(0.05)

    kill_deadline = time.monotonic() + FRESH_WORKER_KILL_GRACE_SECONDS
    while True:
        identities = _live_descendant_identities(root_pid)
        if not identities:
            poll_and_reap()
            if not _live_descendant_identities(root_pid):
                return []
        for pid, start_ticks in identities.items():
            signal_identity(pid, start_ticks, signal.SIGKILL)
        poll_and_reap()
        if time.monotonic() >= kill_deadline:
            break
        time.sleep(0.05)
    poll_and_reap()
    return diagnostics()


def _cleanup_descendants_fail_closed(
    root_pid: int,
    *,
    managed_process: subprocess.Popen[bytes] | None = None,
) -> list[dict[str, object]]:
    try:
        return _terminate_descendants(root_pid, managed_process=managed_process)
    except BaseException as error:
        diagnostic = f"{type(error).__name__}: {error}"[:1024]
        try:
            survivors = _descendant_diagnostics(root_pid)
        except BaseException as diagnostic_error:
            return [
                {
                    "cleanupError": diagnostic,
                    "diagnosticError": (
                        f"{type(diagnostic_error).__name__}: {diagnostic_error}"[:1024]
                    ),
                }
            ]
        for survivor in survivors:
            survivor["cleanupError"] = diagnostic
        return survivors or [{"cleanupError": diagnostic}]


def _terminate_payload_descendants() -> None:
    survivors = _cleanup_descendants_fail_closed(os.getpid())
    while survivors:
        time.sleep(0.25)
        survivors = _cleanup_descendants_fail_closed(os.getpid())


def _monitor_expected_parent(
    expected_parent_pid: int,
    cleanup: Callable[[], list[dict[str, object]]],
) -> None:
    while os.getppid() == expected_parent_pid:
        time.sleep(0.05)
    survivors = cleanup()
    while survivors:
        time.sleep(0.25)
        survivors = cleanup()
    os._exit(128 + signal.SIGTERM)


def _durable_worker_timeout(record: dict[str, object]) -> int:
    configured = os.environ.get("ENOSHIMA_VM_DURABLE_WORKER_TIMEOUT_SECONDS")
    if configured is not None:
        try:
            timeout_seconds = int(configured)
        except ValueError as error:
            raise RuntimeError(
                "ENOSHIMA_VM_DURABLE_WORKER_TIMEOUT_SECONDS must be a positive integer"
            ) from error
        if not 1 <= timeout_seconds <= MAX_DURABLE_WORKER_TIMEOUT_SECONDS:
            raise RuntimeError(
                "ENOSHIMA_VM_DURABLE_WORKER_TIMEOUT_SECONDS must be between 1 "
                f"and {MAX_DURABLE_WORKER_TIMEOUT_SECONDS}"
            )
        return timeout_seconds

    raw_suites = record.get("plannedSuites")
    if not isinstance(raw_suites, list) or not all(
        isinstance(suite, str) for suite in raw_suites
    ):
        raise RuntimeError("durable operation is missing its planned suite list")
    raw_budgets = record.get("plannedSuiteBudgetMinutes")
    if not isinstance(raw_budgets, dict):
        raise RuntimeError("durable operation is missing its planned suite budgets")
    suite_budget_minutes: list[int] = []
    for suite in raw_suites:
        budget = raw_budgets.get(suite)
        if not isinstance(budget, int) or isinstance(budget, bool) or budget <= 0:
            raise RuntimeError(f"durable operation has an invalid budget for {suite}")
        suite_budget_minutes.append(budget)
    suite_budget_seconds = sum(suite_budget_minutes) * 60
    attempt_count = len(raw_suites) * DURABLE_SUITE_ATTEMPTS
    timeout_seconds = (
        DURABLE_FOCUSED_CHECK_BUDGET_SECONDS
        + DURABLE_SUITE_ATTEMPTS * suite_budget_seconds
        + attempt_count * DURABLE_ATTEMPT_OVERHEAD_SECONDS
        + DURABLE_FINALIZATION_BUDGET_SECONDS
    )
    if not 1 <= timeout_seconds <= MAX_DURABLE_WORKER_TIMEOUT_SECONDS:
        raise RuntimeError(
            f"derived durable operation deadline {timeout_seconds}s exceeds the "
            f"reviewed {MAX_DURABLE_WORKER_TIMEOUT_SECONDS}s upper bound"
        )
    return timeout_seconds


def _durable_timeout_pending(timeout_seconds: int) -> dict[str, object]:
    error = RuntimeError(
        "durable VM operation exceeded its transport-independent "
        f"{timeout_seconds}s deadline; all worker descendants were terminated"
    )
    envelope = _error_envelope(error)
    return {
        "schema": 1,
        "status": "failed",
        "envelope": envelope,
        "recordUpdates": {"error": envelope["error"]},
        "payloadCompletedAt": _utc_now(),
    }


def _validated_pending(pending: dict[str, object]) -> dict[str, object]:
    encoded = json.dumps(pending, sort_keys=True).encode()
    if len(encoded) > MAX_PROTOCOL_BYTES:
        raise RuntimeError("durable pending result exceeded 128 KiB")
    if pending.get("schema") != 1:
        raise RuntimeError("durable pending result has an unsupported schema")
    state = pending.get("status")
    if state not in FINAL_STATES:
        raise RuntimeError("durable pending result has a nonterminal status")
    envelope = pending.get("envelope")
    if not isinstance(envelope, dict) or not isinstance(envelope.get("ok"), bool):
        raise RuntimeError("durable pending result has an invalid envelope")
    if envelope["ok"] is True:
        result = envelope.get("result")
        if "error" in envelope:
            raise RuntimeError("successful durable envelope contains an error")
        if state == "orphaned":
            raise RuntimeError(
                "successful durable envelope contradicts its terminal status"
            )
        if not isinstance(result, dict):
            raise RuntimeError("successful durable envelope has no object result")
        result_state = result.get("result")
        expected_result_states = {
            "passed": {"passed"},
            "failed": {"failed"},
            "blocked": {"blocked"},
            "completed": {"completed"},
        }
        if result_state not in expected_result_states[state]:
            raise RuntimeError(
                "successful durable result contradicts its terminal status"
            )
    else:
        if "result" in envelope or not isinstance(envelope.get("error"), dict):
            raise RuntimeError("failed durable envelope has invalid contents")
        if state not in {"failed", "orphaned"}:
            raise RuntimeError(
                "failed durable envelope contradicts its terminal status"
            )
    updates = pending.get("recordUpdates", {})
    if not isinstance(updates, dict):
        raise RuntimeError("durable pending result has invalid record updates")
    allowed_updates = {
        "actualSourceCommit",
        "actualWorktreeDigest",
        "actualSourceTreeDigest",
        "artifactRoot",
        "category",
        "failureFingerprint",
        "result",
        "error",
    }
    unexpected = set(updates) - allowed_updates
    if unexpected:
        raise RuntimeError(
            "durable pending result contains unexpected record updates: "
            + ", ".join(sorted(str(key) for key in unexpected))
        )
    if envelope["ok"] is True:
        result = envelope["result"]
        assert isinstance(result, dict)
        if "error" in updates:
            raise RuntimeError("successful durable record updates contain an error")
        if "result" in updates and updates["result"] != result.get("result"):
            raise RuntimeError(
                "durable record result contradicts its committed envelope"
            )
    else:
        if "result" in updates:
            raise RuntimeError("failed durable record updates contain a result")
        if "error" in updates and updates["error"] != envelope["error"]:
            raise RuntimeError(
                "durable record error contradicts its committed envelope"
            )
    return pending


def _commit_durable_result(
    operation_dir: Path,
    pending: dict[str, object],
) -> int:
    pending = _validated_pending(pending)
    envelope = pending["envelope"]
    assert isinstance(envelope, dict)
    result_path = operation_dir / "result.json"
    if len(json.dumps(envelope, sort_keys=True).encode()) > MAX_PROTOCOL_BYTES:
        raise RuntimeError("durable result exceeded 128 KiB")
    _atomic_write_json(result_path, envelope)
    record_path = operation_dir / "operation.json"
    record = _read_json(record_path)
    if record.get("status") in FINAL_STATES:
        raise RuntimeError("durable operation already has a terminal record")
    completed_at = _utc_now()
    updates = pending.get("recordUpdates", {})
    assert isinstance(updates, dict)
    record.update(updates)
    record.update(
        {
            "status": pending["status"],
            "updatedAt": completed_at,
            "completedAt": completed_at,
            "resultPath": str(result_path),
        }
    )
    for key in ("cleanupStatus", "cleanupDiagnostic", "cleanupSurvivors"):
        record.pop(key, None)
    _atomic_write_json(record_path, record)
    (operation_dir / "result.pending.json").unlink(missing_ok=True)
    return 0 if envelope.get("ok") is True else 1


def _record_cleanup_quarantine(
    operation_dir: Path,
    survivors: list[dict[str, object]],
) -> None:
    record_path = operation_dir / "operation.json"
    record = _read_json(record_path)
    record.update(
        {
            "cleanupStatus": "quarantined",
            "cleanupDiagnostic": (
                "live worker descendants remained after SIGKILL; retaining the "
                "operation lease and global mutation lock"
            ),
            "cleanupSurvivors": survivors,
            "updatedAt": _utc_now(),
        }
    )
    _atomic_write_json(record_path, record)


def _record_supervisor_failure(operation_dir: Path, error: BaseException) -> None:
    record_path = operation_dir / "operation.json"
    record = _read_json(record_path)
    record.update(
        {
            "supervisorDiagnostic": f"{type(error).__name__}: {error}"[:4096],
            "updatedAt": _utc_now(),
        }
    )
    _atomic_write_json(record_path, record)


def _durable_remaining_seconds(
    record: dict[str, object],
    deadline_seconds: int | None,
) -> tuple[int, float]:
    recorded_seconds = record.get("deadlineSeconds")
    raw_deadline = record.get("deadlineAt")
    if (
        not isinstance(recorded_seconds, int)
        or isinstance(recorded_seconds, bool)
        or recorded_seconds <= 0
        or deadline_seconds != recorded_seconds
        or not isinstance(raw_deadline, str)
    ):
        raise RuntimeError("durable supervisor received an invalid parent deadline")
    try:
        deadline_at = datetime.fromisoformat(raw_deadline)
    except ValueError as error:
        raise RuntimeError(
            "durable operation has an invalid absolute deadline"
        ) from error
    if deadline_at.tzinfo is None:
        raise RuntimeError("durable operation deadline must be timezone-aware")
    remaining = max(0.0, (deadline_at - datetime.now(UTC)).total_seconds())
    return recorded_seconds, remaining


def _supervisor_main(
    tool: str,
    *,
    operation_dir: Path | None,
    lock_fd: int | None,
    lease_fd: int | None,
    expected_parent_pid: int | None,
    deadline_seconds: int | None,
) -> int:
    interrupted: dict[str, int] = {}
    cleanup_active = False

    def handle_signal(signum: int, _frame: object) -> None:
        interrupted["signal"] = signum
        if not cleanup_active:
            raise InterruptedError(f"worker supervisor received signal {signum}")

    _unblock_control_signals()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    _set_child_subreaper()
    if operation_dir is None:
        if expected_parent_pid is None:
            raise RuntimeError("fresh supervisor requires its caller identity")
        if not _set_parent_death_signal(expected_parent_pid):
            return 128 + signal.SIGTERM
    os.environ.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)

    if lock_fd is not None:
        os.fstat(lock_fd)
    if operation_dir is not None:
        if lock_fd is None or lease_fd is None:
            raise RuntimeError(
                "durable supervisor requires inherited active and lease locks"
            )
        os.fstat(lease_fd)

    if operation_dir is not None:
        initial_record = _read_json(operation_dir / "operation.json")
        process_record = {
            "operationId": str(initial_record.get("operationId")),
            "workerPid": os.getpid(),
            "workerStartTicks": _process_start_ticks(os.getpid()),
        }
        _atomic_write_json(operation_dir / "process.json", process_record)

    if operation_dir is not None:
        record_path = operation_dir / "operation.json"
        record = _read_json(record_path)
        timeout_seconds, communicate_timeout = _durable_remaining_seconds(
            record, deadline_seconds
        )
        input_bytes = None
    else:
        if deadline_seconds is None or deadline_seconds <= 0:
            raise RuntimeError("fresh supervisor requires a positive deadline")
        timeout_seconds = deadline_seconds
        communicate_timeout = float(timeout_seconds)
        input_bytes = sys.stdin.buffer.read(MAX_PROTOCOL_BYTES + 1)
        if len(input_bytes) > MAX_PROTOCOL_BYTES:
            raise RuntimeError("fresh worker arguments exceeded 128 KiB")

    argv = _bootstrap_argv(
        "--guardian-worker",
        tool,
        expected_parent_pid=os.getpid(),
    )
    if lock_fd is not None:
        argv.extend(("--lock-fd", str(lock_fd)))
    if operation_dir is not None:
        argv.extend(
            (
                "--operation-dir",
                str(operation_dir),
                "--lease-fd",
                str(lease_fd),
            )
        )
    inherited_fds = tuple(
        descriptor for descriptor in (lock_fd, lease_fd) if descriptor is not None
    )
    guardian_environment = dict(os.environ)
    guardian_environment.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)
    if lock_fd is not None:
        guardian_environment["ENOSHIMA_VM_OPERATION_LOCK_FD"] = str(lock_fd)
    guardian = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE if operation_dir is None else subprocess.DEVNULL,
        stdout=subprocess.PIPE if operation_dir is None else None,
        stderr=None,
        close_fds=True,
        pass_fds=inherited_fds,
        start_new_session=True,
        env=guardian_environment,
    )
    cleanup_lock = threading.Lock()

    def cleanup_descendants() -> list[dict[str, object]]:
        nonlocal cleanup_active
        with cleanup_lock:
            cleanup_active = True
            return _cleanup_descendants_fail_closed(
                os.getpid(), managed_process=guardian
            )

    if operation_dir is None:
        assert expected_parent_pid is not None
        threading.Thread(
            target=_monitor_expected_parent,
            args=(expected_parent_pid, cleanup_descendants),
            daemon=True,
        ).start()
    output = b""
    timed_out = False
    supervisor_error: BaseException | None = None
    try:
        if operation_dir is not None:
            process_record.update(
                {
                    "guardianPid": guardian.pid,
                    "guardianStartTicks": _process_start_ticks(guardian.pid),
                    "readyAt": _utc_now(),
                }
            )
            _atomic_write_json(operation_dir / "process.json", process_record)
        output, _stderr = guardian.communicate(
            input=input_bytes,
            timeout=communicate_timeout,
        )
    except subprocess.TimeoutExpired:
        timed_out = True
    except BaseException as error:
        supervisor_error = error

    survivors = cleanup_descendants()
    if operation_dir is not None:
        while survivors:
            try:
                _record_cleanup_quarantine(operation_dir, survivors)
            except BaseException:
                # The durable lease and global mutation lock remain the safety
                # boundary. A ledger write failure must never release either
                # while a live descendant can still mutate VM state.
                pass
            time.sleep(0.25)
            survivors = cleanup_descendants()
    else:
        # A fresh mutating supervisor inherits active.lock. Never unwind and
        # release it while an unkillable descendant can still mutate VM state.
        while survivors:
            time.sleep(0.25)
            survivors = cleanup_descendants()

    if supervisor_error is not None:
        if operation_dir is not None:
            _record_supervisor_failure(operation_dir, supervisor_error)
            return 1
        raise supervisor_error

    if operation_dir is not None:
        if timed_out:
            return _commit_durable_result(
                operation_dir, _durable_timeout_pending(timeout_seconds)
            )
        pending_path = operation_dir / "result.pending.json"
        if not pending_path.exists():
            _record_supervisor_failure(
                operation_dir,
                RuntimeError(
                    "durable payload exited "
                    f"{guardian.returncode} without a pending result"
                ),
            )
            return 1
        try:
            pending = _read_json(pending_path)
            pending = _validated_pending(pending)
            envelope = pending["envelope"]
            assert isinstance(envelope, dict)
            if guardian.returncode != 0 and envelope.get("ok") is True:
                raise RuntimeError(
                    "durable payload exited unsuccessfully after proposing a "
                    "successful result"
                )
            return _commit_durable_result(operation_dir, pending)
        except BaseException as error:
            _record_supervisor_failure(operation_dir, error)
            return 1

    if timed_out:
        envelope = _error_envelope(
            RuntimeError(
                f"fresh worker {tool} exceeded its worker-side "
                f"{timeout_seconds}s deadline and its process group was terminated"
            )
        )
        _write_worker_envelope(envelope)
        return 1
    if operation_dir is None and output:
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
    return guardian.returncode or 0


def _load_envelope(path: Path) -> dict[str, object]:
    try:
        size = path.stat().st_size
    except OSError as error:
        message = f"fresh worker did not create {path.name}: {error}"
        raise RuntimeError(message) from error
    if size > MAX_PROTOCOL_BYTES:
        raise RuntimeError("fresh worker protocol response exceeded 128 KiB")
    return _read_json(path)


def _unwrap_envelope(
    envelope: dict[str, object],
    *,
    diagnostic: str = "",
) -> object:
    if envelope.get("ok") is True:
        return envelope.get("result")
    error = envelope.get("error")
    if isinstance(error, dict):
        category = str(error.get("category", "HARNESS_ERROR"))
        message = str(error.get("message", "fresh worker failed"))
    else:
        category = "HARNESS_ERROR"
        message = "fresh worker failed without a structured error"
    suffix = f"\nworker stderr tail:\n{diagnostic}" if diagnostic else ""
    raise RuntimeError(f"{category}: {message}{suffix}")


def _fresh_worker_timeout(tool: str, arguments: dict[str, object]) -> int:
    configured = os.environ.get("ENOSHIMA_VM_FRESH_WORKER_TIMEOUT_SECONDS")
    if configured is not None:
        try:
            timeout_seconds = int(configured)
        except ValueError as error:
            raise RuntimeError(
                "ENOSHIMA_VM_FRESH_WORKER_TIMEOUT_SECONDS must be a positive integer"
            ) from error
        if not 1 <= timeout_seconds <= MAX_FRESH_WORKER_TIMEOUT_SECONDS:
            raise RuntimeError(
                "ENOSHIMA_VM_FRESH_WORKER_TIMEOUT_SECONDS must be between 1 and "
                f"{MAX_FRESH_WORKER_TIMEOUT_SECONDS}"
            )
        return timeout_seconds

    if tool == "_operation_wait":
        requested = arguments.get("timeout_seconds")
        if not isinstance(requested, int) or isinstance(requested, bool):
            raise RuntimeError("_operation_wait requires an integer timeout_seconds")
        if not 0 <= requested <= MAX_WAIT_SECONDS:
            raise RuntimeError(
                f"_operation_wait timeout_seconds must be between 0 and "
                f"{MAX_WAIT_SECONDS}"
            )
        return max(DEFAULT_FRESH_WORKER_TIMEOUT_SECONDS, requested + 15)

    if tool in {"vm_wait", "vm_exec", "vm_reboot"}:
        requested = arguments.get("timeout_seconds")
        if not isinstance(requested, int) or isinstance(requested, bool):
            raise RuntimeError(f"{tool} requires an integer timeout_seconds")
        if requested < 1:
            raise RuntimeError(f"{tool} timeout_seconds must be positive")
        if tool == "vm_wait":
            timeout_seconds = min(requested, 600) + requested + min(requested, 300) + 60
        elif tool == "vm_reboot":
            timeout_seconds = requested + min(requested, 300) + 690
        else:
            timeout_seconds = requested + 60
        if timeout_seconds > MAX_FRESH_WORKER_TIMEOUT_SECONDS:
            raise RuntimeError(
                f"{tool} requires a fresh-worker deadline above the supported "
                f"{MAX_FRESH_WORKER_TIMEOUT_SECONDS}s maximum"
            )
        return max(DEFAULT_FRESH_WORKER_TIMEOUT_SECONDS, timeout_seconds)
    if tool == "vm_create":
        return 30 * 60
    if tool == "vm_upload_worktree":
        return 15 * 60
    if tool == "vm_collect_artifacts":
        return 36 * 60
    if tool == "vm_query_desktop":
        return 8 * 60
    if tool == "vm_screenshot":
        return 8 * 60
    if tool == "vm_destroy":
        return 3 * 60
    if tool == "vm_status":
        return 2 * 60
    return DEFAULT_FRESH_WORKER_TIMEOUT_SECONDS


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _alive_process_group_members(process_group: int) -> set[int]:
    members: set[int] = set()
    for stat_path in Path("/proc").glob("[0-9]*/stat"):
        try:
            raw = stat_path.read_text(encoding="utf-8")
            suffix = raw[raw.rindex(")") + 2 :].split()
            state = suffix[0]
            group = int(suffix[2])
            if group == process_group and state != "Z":
                members.add(int(stat_path.parent.name))
        except (OSError, ValueError, IndexError):
            continue
    return members


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=FRESH_WORKER_TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass

    if _process_group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=FRESH_WORKER_KILL_GRACE_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"fresh worker process group {process_group} could not be reaped"
        ) from error
    deadline = time.monotonic() + FRESH_WORKER_KILL_GRACE_SECONDS
    while _alive_process_group_members(process_group) and time.monotonic() < deadline:
        time.sleep(0.05)
    remaining = _alive_process_group_members(process_group)
    if remaining:
        raise RuntimeError(
            "fresh worker process group retained live members after SIGKILL: "
            + ", ".join(str(pid) for pid in sorted(remaining))
        )


def _check_async_caller_cancelled() -> None:
    """Cooperate with cancellation of the AnyIO task owning this worker thread."""

    try:
        anyio.from_thread.check_cancelled()
    except anyio.NoEventLoopError:
        # Direct synchronous unit callers do not have an AnyIO host task.
        return


def _invoke_fresh(
    tool: str,
    arguments: dict[str, object],
    *,
    lock_fd: int | None = None,
) -> object:
    _check_async_caller_cancelled()
    _require_desktop_session_environment()
    with tempfile.TemporaryDirectory(prefix="enoshima-vm-mcp-") as temporary:
        temporary_root = Path(temporary)
        stdout_path = temporary_root / "stdout.json"
        stderr_path = temporary_root / "stderr.log"
        environment = dict(os.environ)
        environment.update(
            {
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPYCACHEPREFIX": str(temporary_root / "pycache"),
            }
        )
        environment.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)
        timeout_seconds = _fresh_worker_timeout(tool, arguments)
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            argv = [
                *_bootstrap_prefix(os.getpid()),
                "--worker",
                tool,
                "--deadline-seconds",
                str(timeout_seconds),
                "--expected-parent-pid",
                str(os.getpid()),
            ]
            if lock_fd is not None:
                argv.extend(("--lock-fd", str(lock_fd)))
            process = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE,
                stdout=stdout,
                stderr=stderr,
                close_fds=True,
                pass_fds=(lock_fd,) if lock_fd is not None else (),
                start_new_session=True,
                env=environment,
            )
            communication_input: bytes | None = json.dumps(
                arguments, sort_keys=True
            ).encode()
            caller_deadline = time.monotonic() + (
                timeout_seconds
                + FRESH_WORKER_TERM_GRACE_SECONDS
                + FRESH_WORKER_KILL_GRACE_SECONDS
                + 5
            )
            try:
                while True:
                    _check_async_caller_cancelled()
                    remaining = caller_deadline - time.monotonic()
                    if remaining <= 0:
                        _terminate_process_group(process)
                        diagnostic = _tail_text(stderr_path)
                        suffix = (
                            f"\nworker stderr tail:\n{diagnostic}"
                            if diagnostic
                            else ""
                        )
                        raise RuntimeError(
                            "HARNESS_ERROR: fresh worker "
                            f"{tool} exceeded {timeout_seconds}s and its "
                            f"process group was terminated{suffix}"
                        )
                    try:
                        process.communicate(
                            input=communication_input,
                            timeout=min(0.1, remaining),
                        )
                        break
                    except subprocess.TimeoutExpired:
                        # ``communicate`` retains the first input buffer.  Every
                        # later poll must omit it while the transport task gets
                        # a prompt cancellation point on normal stdio EOF.
                        communication_input = None
            except BaseException:
                if process.poll() is None:
                    _terminate_process_group(process)
                raise
        try:
            envelope = _load_envelope(stdout_path)
        except RuntimeError as error:
            diagnostic = _tail_text(stderr_path)
            raise RuntimeError(
                f"fresh worker {tool} exited {process.returncode}: {error}\n"
                f"worker stderr tail:\n{diagnostic}"
            ) from error
        return _unwrap_envelope(envelope, diagnostic=_tail_text(stderr_path))


def _invoke_mutating_fresh(
    tool: str,
    arguments: dict[str, object],
) -> object:
    if tool not in MUTATING_FRESH_TOOLS:
        raise ValueError(f"{tool} is not a mutating fresh-worker tool")
    _check_async_caller_cancelled()
    root = _operations_root()
    lock_fd = _open_global_mutation_lock()
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            active = _active_operation_id(root) or "unknown"
            raise RuntimeError(
                "a durable VM operation is active; refusing a concurrent "
                f"mutating tool call: {active}"
            ) from error
        return _invoke_fresh(
            tool,
            arguments,
            lock_fd=lock_fd,
        )
    finally:
        os.close(lock_fd)


def _active_operation_id(root: Path) -> str | None:
    active_path = root / "active.json"
    if not active_path.exists():
        return None
    try:
        active = _read_json(active_path)
    except RuntimeError:
        return None
    operation_id = active.get("operationId")
    return str(operation_id) if isinstance(operation_id, str) else None


def _start_operation(
    tool: str,
    arguments: dict[str, object],
) -> dict[str, object]:
    _check_async_caller_cancelled()
    _require_desktop_session_environment()
    if tool not in DURABLE_TOOLS:
        raise ValueError(f"{tool} is not a durable MCP operation")
    root = _operations_root()
    lock_fd = _open_global_mutation_lock()
    lease_fd: int | None = None
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            active = _active_operation_id(root) or "unknown"
            raise RuntimeError(
                f"another durable VM operation is active: {active}"
            ) from error

        if tool == "vm_run_plan":
            base_ref = str(arguments.get("base_ref", "origin/main"))
            mode = "release"
        else:
            base_ref = str(arguments.get("base_ref", "origin/main"))
            mode = str(
                arguments.get("mode", arguments.get("verification_mode", "checkpoint"))
            )
        plan = _invoke_fresh(
            "verification_plan",
            {"base_ref": base_ref, "mode": mode},
        )
        identity = plan if isinstance(plan, dict) else {}
        budget_arguments: dict[str, object] = {
            "operation_tool": tool,
            "suite": arguments.get("suite", "smoke"),
            "plan": arguments.get("plan", "release"),
            "suites": identity.get("suites", []),
        }
        budget = _invoke_fresh("_operation_budget", budget_arguments)
        if not isinstance(budget, dict):
            raise RuntimeError("operation budget worker returned an invalid result")
        planned_suites = budget.get("suites")
        planned_suite_budgets = budget.get("suiteBudgetMinutes")
        if not isinstance(planned_suites, list) or not isinstance(
            planned_suite_budgets, dict
        ):
            raise RuntimeError("operation budget worker omitted suite budgets")
        _check_async_caller_cancelled()
        operation_id = f"operation-{uuid.uuid4().hex[:12]}"
        operation_dir = root / operation_id
        operation_dir.mkdir(mode=0o700)
        operation_dir.chmod(0o700)
        record: dict[str, object] = {
            "schema": 1,
            "operationId": operation_id,
            "tool": tool,
            "arguments": arguments,
            "status": "queued",
            "queuedAt": _utc_now(),
            "updatedAt": _utc_now(),
            "operationRoot": str(operation_dir),
            "plannedSuites": planned_suites,
            "plannedSuiteBudgetMinutes": planned_suite_budgets,
        }
        identity_fields = {
            "sourceCommit": "plannedSourceCommit",
            "worktreeDigest": "plannedWorktreeDigest",
            "sourceTreeDigest": "plannedSourceTreeDigest",
            "suiteRetryDigests": "plannedSuiteRetryDigests",
            "mode": "plannedMode",
            "base": "plannedBase",
        }
        for source_key, record_key in identity_fields.items():
            if source_key in identity:
                record[record_key] = identity[source_key]
        timeout_seconds = _durable_worker_timeout(record)
        record.update(
            {
                "deadlineSeconds": timeout_seconds,
                "deadlineAt": (
                    datetime.now(UTC) + timedelta(seconds=timeout_seconds)
                ).isoformat(),
            }
        )
        lease_fd = os.open(
            operation_dir / "lease.lock",
            os.O_RDWR | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        fcntl.flock(lease_fd, fcntl.LOCK_EX)
        _atomic_write_json(operation_dir / "operation.json", record)
        _atomic_write_json(root / "active.json", {"operationId": operation_id})
        stdout_path = operation_dir / "worker.stdout.log"
        stderr_path = operation_dir / "worker.stderr.log"
        stdout_path.touch(mode=0o600)
        stderr_path.touch(mode=0o600)
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        with stdout_path.open("ab") as stdout, stderr_path.open("ab") as stderr:
            environment = dict(os.environ)
            environment.update(
                {
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "PYTHONPYCACHEPREFIX": str(operation_dir / "pycache"),
                }
            )
            environment.pop("ENOSHIMA_VM_OPERATION_LOCK_FD", None)
            worker_argv = [
                *_bootstrap_prefix(os.getpid()),
                "--worker",
                tool,
                "--operation-dir",
                str(operation_dir),
                "--lock-fd",
                str(lock_fd),
                "--lease-fd",
                str(lease_fd),
                "--deadline-seconds",
                str(timeout_seconds),
            ]
            process = subprocess.Popen(
                [
                    "/usr/bin/systemd-run",
                    "--user",
                    "--scope",
                    "--quiet",
                    "--collect",
                    "--property=KillMode=control-group",
                    "--property=SendSIGKILL=yes",
                    "--property=TimeoutStopSec=5s",
                    f"--property=RuntimeMaxSec={timeout_seconds}s",
                    f"--unit=enoshima-vm-operation-{operation_id}",
                    *worker_argv,
                ],
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                close_fds=True,
                pass_fds=(lock_fd, lease_fd),
                start_new_session=True,
                env=environment,
            )
    finally:
        if lease_fd is not None:
            os.close(lease_fd)
        os.close(lock_fd)

    try:
        deadline = time.monotonic() + DURABLE_START_READY_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            _check_async_caller_cancelled()
            snapshot = _read_json(operation_dir / "operation.json")
            if snapshot.get("status") in FINAL_STATES:
                summary = _operation_summary(operation_id)
                if summary.get("status") == summary.get("recordedStatus"):
                    return summary
            if _durable_worker_ready(operation_id):
                return _operation_summary(operation_id)
            if not _operation_lease_held(operation_id):
                summary = _operation_summary(operation_id)
                raise RuntimeError(
                    "durable VM operation ended before acknowledging "
                    f"disconnect-safe readiness: {operation_id} "
                    f"({summary.get('status', 'unknown')})"
                )
            time.sleep(0.05)
        cleanup_diagnostic = _abort_unready_operation(operation_id, process)
        raise RuntimeError(
            "durable VM operation did not acknowledge disconnect-safe readiness "
            f"within {DURABLE_START_READY_TIMEOUT_SECONDS}s and its isolated scope "
            f"was stopped: {operation_id}{cleanup_diagnostic}"
        )
    finally:
        threading.Thread(target=process.wait, daemon=True).start()


def _operation_lease_held(operation_id: str) -> bool:
    lease_path = _operation_dir(operation_id) / "lease.lock"
    try:
        lease_fd = os.open(lease_path, os.O_RDWR)
    except FileNotFoundError:
        return False
    try:
        try:
            fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(lease_fd)


def _abort_unready_operation(
    operation_id: str,
    process: subprocess.Popen[bytes],
) -> str:
    unit = f"enoshima-vm-operation-{operation_id}.scope"
    diagnostic = ""
    try:
        stopped = subprocess.run(
            ["/usr/bin/systemctl", "--user", "stop", unit],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=False,
            timeout=15,
        )
        if stopped.returncode != 0:
            diagnostic = stopped.stderr[-MAX_DIAGNOSTIC_BYTES:].decode(
                "utf-8", errors="replace"
            ).strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        diagnostic = f"{type(error).__name__}: {error}"
    if process.poll() is None:
        try:
            _terminate_process_group(process)
        except RuntimeError as error:
            suffix = f"; {error}" if diagnostic else str(error)
            diagnostic += suffix

    deadline = time.monotonic() + 10
    while _operation_lease_held(operation_id) and time.monotonic() < deadline:
        time.sleep(0.05)
    if _operation_lease_held(operation_id):
        raise RuntimeError(
            "durable VM operation readiness timed out, but its isolated scope "
            f"still holds the fail-closed mutation lease: {operation_id}"
            + (f" ({diagnostic})" if diagnostic else "")
        )
    failure = RuntimeError(
        "durable operation startup timed out before disconnect-safe readiness"
        + (f": {diagnostic}" if diagnostic else "")
    )
    _record_supervisor_failure(_operation_dir(operation_id), failure)
    return f" ({diagnostic})" if diagnostic else ""


def _durable_worker_ready(operation_id: str) -> bool:
    operation_dir = _operation_dir(operation_id)
    process_path = operation_dir / "process.json"
    try:
        process = _read_json(process_path)
    except RuntimeError:
        return False
    if process.get("operationId") != operation_id:
        return False
    if not isinstance(process.get("readyAt"), str):
        return False
    identities: dict[str, tuple[int, int]] = {}
    for role, pid_key, ticks_key in (
        ("worker", "workerPid", "workerStartTicks"),
        ("guardian", "guardianPid", "guardianStartTicks"),
    ):
        pid = process.get(pid_key)
        start_ticks = process.get(ticks_key)
        if (
            not isinstance(pid, int)
            or isinstance(pid, bool)
            or pid <= 1
            or not isinstance(start_ticks, int)
            or isinstance(start_ticks, bool)
            or start_ticks <= 0
            or _process_start_ticks(pid) != start_ticks
        ):
            return False
        identities[role] = (pid, start_ticks)
    guardian_stat = _read_process_stat(identities["guardian"][0])
    if guardian_stat is None or guardian_stat[1] != identities["worker"][0]:
        return False
    return _operation_lease_held(operation_id)


def _operation_record(operation_id: str) -> dict[str, object]:
    operation_dir = _operation_dir(operation_id)
    record_path = operation_dir / "operation.json"
    record = _read_json(record_path)
    if record.get("operationId") != operation_id:
        raise RuntimeError("MCP operation record id does not match its directory")
    process_path = operation_dir / "process.json"
    if process_path.exists():
        process = _read_json(process_path)
        for key in ("workerPid", "workerStartTicks"):
            if key not in record and key in process:
                record[key] = process[key]
    status = record.get("status")
    lease_held = _operation_lease_held(operation_id)
    if status in {"queued", "running"} and not lease_held:
        # A supervisor atomically commits the terminal record before it exits
        # and releases this lease. Re-read after observing the unlocked lease
        # so a stale first read cannot manufacture a false orphan result.
        record = _read_json(record_path)
        if record.get("operationId") != operation_id:
            raise RuntimeError("MCP operation record id does not match its directory")
        if process_path.exists():
            process = _read_json(process_path)
            for key in ("workerPid", "workerStartTicks"):
                if key not in record and key in process:
                    record[key] = process[key]
        status = record.get("status")
    if status in {"queued", "running"}:
        if lease_held and (
            record.get("cleanupStatus") == "quarantined"
            or (operation_dir / "result.pending.json").exists()
        ):
            record["observedStatus"] = "finalizing"
        else:
            record["observedStatus"] = "running" if lease_held else "orphaned"
    elif status in FINAL_STATES and lease_held:
        record["observedStatus"] = "finalizing"
    elif status in FINAL_STATES:
        result_path = operation_dir / "result.json"
        integrity_error: BaseException | None = None
        for attempt in range(TERMINAL_INTEGRITY_ATTEMPTS):
            try:
                envelope = _load_envelope(result_path)
                _validated_pending(
                    {
                        "schema": 1,
                        "status": status,
                        "envelope": envelope,
                        "recordUpdates": {
                            key: record[key]
                            for key in ("result", "error")
                            if key in record
                        },
                        "payloadCompletedAt": record.get("completedAt", "unknown"),
                    }
                )
                integrity_error = None
                break
            except (OSError, RuntimeError, ValueError) as error:
                integrity_error = error
                if attempt + 1 < TERMINAL_INTEGRITY_ATTEMPTS:
                    # result.json is committed before the terminal ledger and
                    # both use atomic renames.  A transport-independent reader
                    # may nevertheless briefly observe delayed filesystem
                    # visibility after the lease is released.  Require the
                    # integrity failure to be stable before calling a completed
                    # operation orphaned.
                    time.sleep(TERMINAL_INTEGRITY_RETRY_SECONDS)
        if integrity_error is not None:
            record["observedStatus"] = "orphaned"
            record["resultIntegrity"] = (
                "missing" if not result_path.is_file() else "invalid"
            )
            record["resultDiagnostic"] = (
                f"{type(integrity_error).__name__}: {integrity_error}"[
                    :MAX_DIAGNOSTIC_BYTES
                ]
            )
    return record


def _operation_summary(operation_id: str) -> dict[str, object]:
    record = _operation_record(operation_id)
    summary: dict[str, object] = {
        "schema": 1,
        "operationId": operation_id,
        "tool": record.get("tool"),
        "status": record.get("observedStatus", record.get("status")),
        "recordedStatus": record.get("status"),
        "queuedAt": record.get("queuedAt"),
        "startedAt": record.get("startedAt"),
        "updatedAt": record.get("updatedAt"),
        "completedAt": record.get("completedAt"),
        "operationRoot": record.get("operationRoot"),
        "artifactRoot": record.get("artifactRoot"),
        "result": record.get("result"),
        "category": record.get("category"),
        "failureFingerprint": record.get("failureFingerprint"),
        "plannedSourceCommit": record.get("plannedSourceCommit"),
        "plannedWorktreeDigest": record.get("plannedWorktreeDigest"),
        "plannedSourceTreeDigest": record.get("plannedSourceTreeDigest"),
        "actualSourceCommit": record.get("actualSourceCommit"),
        "actualWorktreeDigest": record.get("actualWorktreeDigest"),
        "actualSourceTreeDigest": record.get("actualSourceTreeDigest"),
        "deadlineSeconds": record.get("deadlineSeconds"),
        "deadlineAt": record.get("deadlineAt"),
        "cleanupStatus": record.get("cleanupStatus"),
        "cleanupDiagnostic": record.get("cleanupDiagnostic"),
        "cleanupSurvivors": record.get("cleanupSurvivors"),
        "supervisorDiagnostic": record.get("supervisorDiagnostic"),
        "resultIntegrity": record.get("resultIntegrity"),
        "resultDiagnostic": record.get("resultDiagnostic"),
    }
    summary = {key: value for key, value in summary.items() if value is not None}
    survivors = summary.get("cleanupSurvivors")
    if isinstance(survivors, list):
        summary["cleanupSurvivorCount"] = len(survivors)
        if len(survivors) > MAX_CLEANUP_SURVIVOR_SAMPLE:
            summary["cleanupSurvivors"] = survivors[:MAX_CLEANUP_SURVIVOR_SAMPLE]
            summary["cleanupSurvivorsTruncated"] = True
    for key in (
        "cleanupDiagnostic",
        "supervisorDiagnostic",
        "resultDiagnostic",
    ):
        value = summary.get(key)
        if isinstance(value, str) and len(value.encode()) > MAX_DIAGNOSTIC_BYTES:
            summary[key] = value.encode()[:MAX_DIAGNOSTIC_BYTES].decode(
                errors="replace"
            )
            summary[f"{key}Truncated"] = True
    if len(json.dumps(summary, default=str, sort_keys=True).encode()) > (
        MAX_OPERATION_SUMMARY_BYTES
    ):
        for key in (
            "cleanupDiagnostic",
            "supervisorDiagnostic",
            "cleanupSurvivors",
            "resultDiagnostic",
        ):
            summary.pop(key, None)
        summary["truncated"] = True
    if len(json.dumps(summary, default=str, sort_keys=True).encode()) > (
        MAX_OPERATION_SUMMARY_BYTES
    ):
        raise RuntimeError("bounded operation summary exceeded 32 KiB")
    return summary


def _list_operations(limit: int) -> dict[str, object]:
    if not 1 <= limit <= 50:
        raise ValueError("operation list limit must be between 1 and 50")
    root = _operations_root()
    candidates = [
        path
        for path in root.iterdir()
        if path.is_dir() and OPERATION_ID_RE.fullmatch(path.name)
    ]
    ordered: list[tuple[float, Path]] = []
    for path in candidates:
        try:
            modified_at = (path / "operation.json").stat().st_mtime
        except OSError:
            try:
                modified_at = path.stat().st_mtime
            except OSError:
                continue
        ordered.append((modified_at, path))
    ordered.sort(key=lambda item: item[0], reverse=True)
    summaries: list[dict[str, object]] = []
    for _modified_at, path in ordered[:limit]:
        try:
            candidate = _operation_summary(path.name)
        except (OSError, RuntimeError, ValueError):
            candidate = {
                "schema": 1,
                "operationId": path.name,
                "status": "orphaned",
                "recordedStatus": "corrupt",
                "operationRoot": str(path),
            }
        proposed = {
            "schema": 1,
            "operations": [*summaries, candidate],
            "total": len(ordered),
            "returned": len(summaries) + 1,
            "truncated": len(ordered) > len(summaries) + 1,
        }
        if len(json.dumps(proposed, default=str, sort_keys=True).encode()) > (
            MAX_OPERATION_SUMMARY_BYTES
        ):
            break
        summaries.append(candidate)
    result = {
        "schema": 1,
        "operations": summaries,
        "total": len(ordered),
        "returned": len(summaries),
        "truncated": len(ordered) > len(summaries),
    }
    if len(json.dumps(result, default=str, sort_keys=True).encode()) > (
        MAX_OPERATION_SUMMARY_BYTES
    ):
        raise RuntimeError("bounded operation list exceeded 32 KiB")
    return result


def _wait_operation(operation_id: str, timeout_seconds: int) -> object:
    if not 0 <= timeout_seconds <= MAX_WAIT_SECONDS:
        raise ValueError(f"timeout_seconds must be between 0 and {MAX_WAIT_SECONDS}")
    deadline = time.monotonic() + timeout_seconds
    while True:
        summary = _operation_summary(operation_id)
        status = summary.get("status")
        if status in FINAL_STATES:
            recorded_status = summary.get("recordedStatus")
            result_path = _operation_dir(operation_id) / "result.json"
            if recorded_status in FINAL_STATES and recorded_status == status:
                if not result_path.exists():
                    summary["status"] = "orphaned"
                    summary["resultIntegrity"] = "missing"
                    summary.pop("result", None)
                    return summary
                envelope = _load_envelope(result_path)
                _validated_pending(
                    {
                        "schema": 1,
                        "status": recorded_status,
                        "envelope": envelope,
                        "recordUpdates": {
                            key: summary[key]
                            for key in ("result", "error")
                            if key in summary
                        },
                        "payloadCompletedAt": summary.get(
                            "completedAt", "unknown"
                        ),
                    }
                )
                return _unwrap_envelope(
                    envelope,
                    diagnostic=_tail_text(
                        _operation_dir(operation_id) / "worker.stderr.log"
                    ),
                )
            return summary
        if time.monotonic() >= deadline:
            return summary
        time.sleep(0.25)


async def _fresh(tool: str, arguments: dict[str, object]) -> object:
    return await anyio.to_thread.run_sync(_invoke_fresh, tool, arguments)


async def _mutating_fresh(tool: str, arguments: dict[str, object]) -> object:
    return await anyio.to_thread.run_sync(_invoke_mutating_fresh, tool, arguments)


async def _start(tool: str, arguments: dict[str, object]) -> dict[str, object]:
    return await anyio.to_thread.run_sync(_start_operation, tool, arguments)


@mcp.tool(annotations=WRITE)
async def vm_create(
    suite: str = "smoke", source_ref: str = "working-tree"
) -> dict[str, Any]:
    """Create one constrained disposable VM with a fresh harness worker."""
    return await _mutating_fresh(
        "vm_create", {"suite": suite, "source_ref": source_ref}
    )


@mcp.tool(annotations=WRITE)
async def vm_run_suite(
    suite: str = "smoke",
    keep_on_failure: bool = False,
    verification_mode: str = "checkpoint",
    base_ref: str = "origin/main",
) -> dict[str, object]:
    """Start one durable named suite and return its operation id immediately."""
    return await _start(
        "vm_run_suite",
        {
            "suite": suite,
            "keep_on_failure": keep_on_failure,
            "verification_mode": verification_mode,
            "base_ref": base_ref,
        },
    )


@mcp.tool(annotations=READ_ONLY)
async def verification_plan(
    base_ref: str = "origin/main", mode: str = "checkpoint"
) -> dict[str, object]:
    """Return the trusted affected selection from a fresh harness worker."""
    return await _fresh("verification_plan", {"base_ref": base_ref, "mode": mode})


@mcp.tool(annotations=WRITE)
async def vm_run_affected(
    base_ref: str = "origin/main", mode: str = "checkpoint"
) -> dict[str, object]:
    """Start a durable affected run and return its operation id immediately."""
    return await _start("vm_run_affected", {"base_ref": base_ref, "mode": mode})


@mcp.tool(annotations=WRITE)
async def vm_run_plan(
    plan: str = "release", base_ref: str = "origin/main"
) -> dict[str, object]:
    """Start a durable frozen plan and return its operation id immediately."""
    return await _start("vm_run_plan", {"plan": plan, "base_ref": base_ref})


@mcp.tool(annotations=READ_ONLY)
async def vm_operation_status(operation_id: str) -> dict[str, object]:
    """Return one bounded durable-operation snapshot from current proxy source."""
    return await _fresh("_operation_status", {"operation_id": operation_id})


@mcp.tool(annotations=READ_ONLY)
async def vm_list_operations(limit: int = 20) -> dict[str, object]:
    """List durable operations using the current proxy source."""
    return await _fresh("_operation_list", {"limit": limit})


@mcp.tool(annotations=READ_ONLY)
async def vm_wait_operation(
    operation_id: str, timeout_seconds: int = 45
) -> dict[str, object]:
    """Wait in current proxy source, returning a final result or snapshot."""
    return await _fresh(
        "_operation_wait",
        {"operation_id": operation_id, "timeout_seconds": timeout_seconds},
    )


@mcp.tool(annotations=READ_ONLY)
async def vm_status(run_id: str) -> dict[str, Any]:
    """Return persisted run metadata and current managed-domain state."""
    return await _fresh("vm_status", {"run_id": run_id})


@mcp.tool(annotations=WRITE)
async def vm_wait(run_id: str, timeout_seconds: int = 1200) -> dict[str, Any]:
    """Wait for SSH, cloud-init, and the guest agent with a fresh worker."""
    return await _mutating_fresh(
        "vm_wait", {"run_id": run_id, "timeout_seconds": timeout_seconds}
    )


@mcp.tool(annotations=WRITE)
async def vm_upload_worktree(run_id: str) -> dict[str, object]:
    """Upload tracked and non-ignored untracked worktree files."""
    return await _mutating_fresh("vm_upload_worktree", {"run_id": run_id})


@mcp.tool(annotations=WRITE)
async def vm_exec(
    run_id: str, argv: list[str], timeout_seconds: int = 300
) -> dict[str, object]:
    """Execute a bounded argv vector inside the disposable guest."""
    return await _mutating_fresh(
        "vm_exec",
        {"run_id": run_id, "argv": argv, "timeout_seconds": timeout_seconds},
    )


@mcp.tool(annotations=WRITE)
async def vm_reboot(run_id: str, timeout_seconds: int = 600) -> dict[str, object]:
    """Reboot a managed guest and prove the boot id changed."""
    return await _mutating_fresh(
        "vm_reboot", {"run_id": run_id, "timeout_seconds": timeout_seconds}
    )


@mcp.tool(annotations=WRITE)
async def vm_poweroff(run_id: str) -> dict[str, str]:
    """Request a guest-agent shutdown for a managed disposable VM."""
    return await _mutating_fresh("vm_poweroff", {"run_id": run_id})


@mcp.tool(annotations=WRITE)
async def vm_screenshot(
    run_id: str, name: str = "desktop", output: str | None = None
) -> dict[str, object]:
    """Capture a guest-compositor PNG into the managed artifact root."""
    return await _mutating_fresh(
        "vm_screenshot", {"run_id": run_id, "name": name, "output": output}
    )


@mcp.tool(annotations=READ_ONLY)
async def vm_query_desktop(run_id: str) -> dict[str, object]:
    """Read bounded Hyprland desktop state from a fresh worker."""
    return await _fresh("vm_query_desktop", {"run_id": run_id})


@mcp.tool(annotations=WRITE)
async def vm_collect_artifacts(run_id: str) -> dict[str, object]:
    """Collect the fixed guest evidence set with a fresh worker."""
    return await _mutating_fresh("vm_collect_artifacts", {"run_id": run_id})


@mcp.tool(annotations=DESTRUCTIVE)
async def vm_destroy(run_id: str) -> dict[str, object]:
    """Destroy only the named Enoshima VM and its disposable secrets/disks."""
    return await _mutating_fresh("vm_destroy", {"run_id": run_id})


@mcp.tool(annotations=READ_ONLY)
async def vm_list_runs(cursor: str | None = None, limit: int = 20) -> dict[str, object]:
    """List newest persisted run summaries with a bounded cursor page."""
    return await _fresh("vm_list_runs", {"cursor": cursor, "limit": limit})


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker")
    parser.add_argument("--guardian-worker")
    parser.add_argument("--payload-worker")
    parser.add_argument("--operation-dir", type=Path)
    parser.add_argument("--lock-fd", type=int)
    parser.add_argument("--lease-fd", type=int)
    parser.add_argument("--expected-parent-pid", type=int)
    parser.add_argument("--deadline-seconds", type=int)
    return parser


def main() -> None:
    args = _parser().parse_args()
    if args.guardian_worker:
        raise SystemExit(
            _guardian_main(
                args.guardian_worker,
                operation_dir=args.operation_dir,
                lock_fd=args.lock_fd,
                lease_fd=args.lease_fd,
                expected_parent_pid=args.expected_parent_pid,
            )
        )
    if args.payload_worker:
        raise SystemExit(
            _payload_main(
                args.payload_worker,
                operation_dir=args.operation_dir,
                lock_fd=args.lock_fd,
                lease_fd=args.lease_fd,
                expected_parent_pid=args.expected_parent_pid,
            )
        )
    if args.worker:
        raise SystemExit(
            _supervisor_main(
                args.worker,
                operation_dir=args.operation_dir,
                lock_fd=args.lock_fd,
                lease_fd=args.lease_fd,
                expected_parent_pid=args.expected_parent_pid,
                deadline_seconds=args.deadline_seconds,
            )
        )
    _normalize_desktop_session_environment()
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
