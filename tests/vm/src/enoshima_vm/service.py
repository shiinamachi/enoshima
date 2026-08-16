from __future__ import annotations

import ctypes
import fcntl
import json
import os
import pwd
import re
import secrets
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import time
import traceback
import uuid
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter
from collections.abc import Callable, Sequence
from contextlib import contextmanager
from dataclasses import replace
from datetime import UTC, datetime
from functools import wraps
from hashlib import sha256
from pathlib import Path, PurePosixPath
from typing import Any

from .artifacts import collect_fixed_artifacts
from .boot_security import (
    assert_secure_boot,
    boot_with_recovery,
    collect_boot_security,
    create_runtime_inventory,
    enroll_tpm,
    prepare_boot_disk,
    test_recovery_path,
    test_unsigned_rejection,
)
from .cloud_init import CloudInitBuilder
from .config import (
    DOMAIN_PREFIX,
    MAX_ACTIVE_DOMAINS,
    WATCHDOG_FINALIZATION_SECONDS,
    WATCHDOG_READY_NAME,
    WATCHDOG_READY_TIMEOUT_SECONDS,
    WATCHDOG_RUNTIME_GRACE_SECONDS,
    RuntimePaths,
    Suite,
    load_images,
    load_suite,
    open_global_mutation_lock,
    validate_global_mutation_lock_fd,
)
from .errors import FailureCategory, VMError
from .guest import Guest, GuestCommandTimeout, parse_json_result, source_identity_json
from .image import ImageCache, file_sha256
from .impact import (
    VerificationSelection,
    assert_selection_unchanged,
    run_focused_checks,
    select_verification,
)
from .libvirt_backend import LibvirtBackend
from .results import (
    MAX_SUMMARY_BYTES,
    FailureOrigin,
    failure_fields,
    failure_fingerprint,
    retryable_infrastructure_failure,
    summarize_exec_result,
    summarize_run_record,
)
from .security import (
    append_audit,
    argv_digest,
    confined_path,
    redact_argv,
    require_domain,
    require_run_id,
    run_cleanup_complete,
    run_record_lock,
    terminal_run_state_preserved,
)
from .ui_review import (
    load_ui_review_identities,
    load_ui_review_matrix,
    overview_auxiliary_scale,
    physical_mode,
    select_ui_review_cases,
)
from .verification import load_verification_mode, load_verification_plan

REMOTE_ROOT = PurePosixPath("/home/kentakang/enoshima-test")
REMOTE_SOURCE = REMOTE_ROOT / "source"
REMOTE_ARTIFACTS = REMOTE_ROOT / "artifacts"
REMOTE_CODEX_ELECTRON_CACHE = PurePosixPath(
    "/home/kentakang/.cache/codex-desktop/electron"
)
REMOTE_CODEX_DMG_CACHE = PurePosixPath("/home/kentakang/.cache/codex-desktop/Codex.dmg")
REMOTE_CODEX_NODE_CACHE = PurePosixPath(
    "/home/kentakang/.cache/codex-desktop/node-runtime"
)
REMOTE_PACMAN_CACHE_ROOT = REMOTE_ROOT / "cache"
REMOTE_PACMAN_CACHE_SEED = REMOTE_PACMAN_CACHE_ROOT / "pacman-seed.tar"
REMOTE_PACMAN_CACHE_DELTA = REMOTE_PACMAN_CACHE_ROOT / "pacman-delta.tar"
REMOTE_PACMAN_CACHE_FILES = REMOTE_PACMAN_CACHE_ROOT / "pacman-files"
REMOTE_SYSTEM_PACMAN_CACHE = PurePosixPath("/var/cache/pacman/pkg")
REMOTE_PACMAN_CACHE_SEED_READY = PurePosixPath("/run/enoshima-pacman-cache-seed-ready")
REMOTE_PACMAN_CACHE_SEEDED = PurePosixPath("/run/enoshima-pacman-cache-seeded")
REMOTE_LOGIN_PASSWORD = REMOTE_ROOT / "secrets" / "login-password"
REMOTE_LOGIN_CREDENTIAL = REMOTE_ROOT / "secrets" / "chpasswd-input"
WATCHDOG_UNIT_PREFIX = "enoshima-vm-watchdog-"
UI_STABILITY_MAX_CHANGED_PIXEL_RATIO = 0.0025
UI_STABILITY_MAX_NORMALIZED_RMSE = 0.004
UI_STABILITY_MAX_SSIM_ERROR = 0.005
UI_STABILITY_TIMEOUT_SECONDS = 20
UI_STABILITY_MINIMUM_FRAME_COUNT = 3
UI_SEMANTIC_MIN_UNIQUE_GRAY_VALUES = 8
UI_SEMANTIC_MIN_NORMALIZED_STDDEV = 0.01
PACMAN_PACKAGE_PATTERN = re.compile(
    r"^[A-Za-z0-9@._+:~-]+\.pkg\.tar\.(?:zst|xz|gz|bz2|lrz|lzo|Z)(?:\.sig)?$"
)
PACMAN_CACHE_MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024
PACMAN_CACHE_MAX_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
BOOTSTRAP_TIMEOUT_SECONDS = 155 * 60
BOOTSTRAP_IDLE_TIMEOUT_SECONDS = 32 * 60
REPEAT_BOOTSTRAP_TIMEOUT_SECONDS = 30 * 60
REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS = 10 * 60
VM_MISE_INSTALL_MAX_ATTEMPTS = 2
VM_MISE_INSTALL_TIMEOUT_SECONDS = 10 * 60
VM_MISE_INSTALL_RETRY_DELAY_SECONDS = 10
VM_CODEX_DESKTOP_BUILD_ATTEMPTS = 2
VM_CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS = 30 * 60
VM_CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS = 15
_ACTIVE_DOMAIN_CAPACITY_ERROR = "maximum active Enoshima VM count reached"

_AUR_PACKAGE_NAME = r"[a-z0-9@._+-]+"
_AUR_FAILURE_RE = re.compile(
    rf"FAILURE: AUR package base (?P<package>{_AUR_PACKAGE_NAME}) "
    r"exited with status [1-9][0-9]*; continuing\."
)
_PROTECTED_AUR_FAILURE_RE = re.compile(
    rf"FAILURE: protected AUR package base (?P<package>{_AUR_PACKAGE_NAME}) "
    r"exited with status [1-9][0-9]*; continuing\."
)
_AUR_RETRY_RE = re.compile(
    rf"WARNING: approved AUR package base (?P<package>{_AUR_PACKAGE_NAME}) "
    r"attempt (?P<attempt>[1-9][0-9]*)/(?P<maximum>[1-9][0-9]*) failed; "
    r"retrying in [0-9]+s\."
)
_AUR_TRANSIENT_TRANSPORT_FRAGMENTS = (
    "unexpected eof",
    "connection closed before message completed",
    "connection reset by peer",
)


def _aur_transport_attempt_line(line: str, package: str) -> bool:
    lowered = line.strip().lower()
    if not lowered:
        return True
    if lowered == f"cloning into '{package}'...":
        return True
    if lowered.startswith("error: command failed:"):
        return f"https://aur.archlinux.org/{package}" in lowered and lowered.endswith(
            f" {package}:"
        )
    if lowered.startswith("fatal: unable to access "):
        return f"https://aur.archlinux.org/{package}/" in lowered and any(
            fragment in lowered for fragment in _AUR_TRANSIENT_TRANSPORT_FRAGMENTS
        )
    if lowered.startswith("error: error sending request for url "):
        return "https://aur.archlinux.org/rpc" in lowered and any(
            fragment in lowered for fragment in _AUR_TRANSIENT_TRANSPORT_FRAGMENTS
        )
    return False


def _aur_transport_attempt_has_failure(lines: Sequence[str]) -> bool:
    return any(
        line.strip().lower().startswith(("fatal:", "error: error sending"))
        and any(
            fragment in line.lower() for fragment in _AUR_TRANSIENT_TRANSPORT_FRAGMENTS
        )
        for line in lines
    )


def _exhausted_aur_transport_packages(stderr: str) -> tuple[str, ...]:
    """Return the first exhausted AUR package only for proven TLS/RPC EOFs.

    Bootstrap deliberately continues after independent failures. Classifying
    its first actionable failure lets a fresh overlay retry transient AUR
    transport without treating a later product failure as resolved. Every
    attempt for the exhausted package must match this narrow transport grammar;
    HTTP, certificate, integrity, and build failures remain product failures.
    """

    lines = stderr.splitlines()
    first_failure_index = next(
        (
            index
            for index, line in enumerate(lines)
            if line.strip().startswith("FAILURE:")
        ),
        None,
    )
    if first_failure_index is None:
        return ()
    first_failure = lines[first_failure_index].strip()
    protected_failure = _PROTECTED_AUR_FAILURE_RE.fullmatch(first_failure)
    if protected_failure is not None:
        package = protected_failure.group("package")
        protected_attempt = lines[max(0, first_failure_index - 2) : first_failure_index]
        if len(protected_attempt) != 2:
            return ()
        fatal, provenance = (line.strip().lower() for line in protected_attempt)
        if not (
            fatal.startswith("fatal: unable to access ")
            and f"https://aur.archlinux.org/{package}.git/" in fatal
            and any(
                fragment in fatal for fragment in _AUR_TRANSIENT_TRANSPORT_FRAGMENTS
            )
            and re.fullmatch(
                r"aur provenance error: pinned aur commit fetch failed "
                r"with exit status [1-9][0-9]*",
                provenance,
            )
        ):
            return ()
        return (package,)

    failure = _AUR_FAILURE_RE.fullmatch(first_failure)
    if failure is None:
        return ()
    package = failure.group("package")

    retry_points: list[tuple[int, int, int]] = []
    for index, line in enumerate(lines[:first_failure_index]):
        retry = _AUR_RETRY_RE.fullmatch(line.strip())
        if retry is None or retry.group("package") != package:
            continue
        retry_points.append(
            (index, int(retry.group("attempt")), int(retry.group("maximum")))
        )
    if not retry_points:
        return ()
    maximums = {maximum for _, _, maximum in retry_points}
    if len(maximums) != 1:
        return ()
    maximum = maximums.pop()
    if [attempt for _, attempt, _ in retry_points] != list(range(1, maximum)):
        return ()

    first_retry_index = retry_points[0][0]
    first_attempt_start = first_retry_index
    while first_attempt_start > 0 and _aur_transport_attempt_line(
        lines[first_attempt_start - 1], package
    ):
        first_attempt_start -= 1

    delimiters = [index for index, _, _ in retry_points] + [first_failure_index]
    attempt_start = first_attempt_start
    for delimiter in delimiters:
        attempt_lines = lines[attempt_start:delimiter]
        if not attempt_lines or not all(
            _aur_transport_attempt_line(line, package) for line in attempt_lines
        ):
            return ()
        if not _aur_transport_attempt_has_failure(attempt_lines):
            return ()
        attempt_start = delimiter + 1
    return (package,)


def _harness_source_digest() -> str:
    digest = sha256()
    source_root = Path(__file__).resolve().parent
    for path in sorted(source_root.glob("*.py")):
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


LOADED_HARNESS_SOURCE_DIGEST = _harness_source_digest()


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


def _write_recovery_key(path: Path) -> None:
    # This file is both a cryptsetup key file and a value typed at the initrd
    # prompt. A trailing newline would become key material only in the former.
    path.write_text(secrets.token_hex(32), encoding="utf-8")
    path.chmod(0o600)


def normalized_image_metric(output: str) -> float:
    """Return ImageMagick's normalized metric value.

    Metrics such as RMSE can include both an absolute quantum value and a
    normalized value in parentheses.  SSIM normally emits only the normalized
    value, so prefer the parenthesized form and otherwise use the final number.
    """

    parenthesized = re.findall(r"\(([-+0-9.eE]+)\)", output)
    if parenthesized:
        return float(parenthesized[-1])
    values = re.findall(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", output)
    if not values:
        raise ValueError(f"image metric did not contain a number: {output!r}")
    return float(values[-1])


def mutation_guard(function):
    """Make a public service mutation honor the global operation lease."""

    @wraps(function)
    def guarded(self, *args, **kwargs):
        with self._mutation_lease():
            return function(self, *args, **kwargs)

    return guarded


class VMService:
    def __init__(
        self,
        paths: RuntimePaths | None = None,
        *,
        libvirt_uri: str | None = None,
    ) -> None:
        self.paths = paths or RuntimePaths.discover()
        self.uri = libvirt_uri or os.environ.get(
            "ENOSHIMA_VM_LIBVIRT_URI", "qemu:///session"
        )
        self.backend = LibvirtBackend(self.paths, self.uri)
        self.images = ImageCache(self.paths)
        self.cloud_init = CloudInitBuilder(self.paths)
        self.runs_root = self.paths.state / "runs"
        self.audit_path = self.paths.state / "audit.jsonl"
        self._mutation_lease_depth = 0

    @contextmanager
    def _mutation_lease(self):
        """Serialize every service mutation, including legacy MCP/CLI callers."""
        if self._mutation_lease_depth:
            self._mutation_lease_depth += 1
            try:
                yield
            finally:
                self._mutation_lease_depth -= 1
            return

        inherited_raw = os.environ.get("ENOSHIMA_VM_OPERATION_LOCK_FD")
        inherited_fd: int | None = None
        if inherited_raw is not None:
            try:
                inherited_fd = int(inherited_raw)
                validate_global_mutation_lock_fd(inherited_fd)
                fcntl.flock(inherited_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, ValueError, VMError) as error:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "invalid inherited VM operation lease; refusing mutation",
                    {"error": str(error)},
                ) from error

        acquired_fd: int | None = None
        if inherited_fd is None:
            acquired_fd = open_global_mutation_lock()
            try:
                fcntl.flock(acquired_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                os.close(acquired_fd)
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "a durable VM operation owns the mutation lease; use its "
                    "operation ID instead of a legacy MCP or CLI mutation",
                ) from error

        self._mutation_lease_depth = 1
        try:
            yield
        finally:
            self._mutation_lease_depth = 0
            if acquired_fd is not None:
                os.close(acquired_fd)

    @staticmethod
    def _recorded_domain_uuid(record: dict[str, Any]) -> str | None:
        value = record.get("domain_uuid")
        if not isinstance(value, str) or not value:
            return None
        try:
            return str(uuid.UUID(value))
        except ValueError:
            return None

    def _require_recorded_domain_uuid(self, record: dict[str, Any]) -> str:
        domain_uuid = self._recorded_domain_uuid(record)
        if domain_uuid is None:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "run record has no verifiable domain UUID; preserving the domain "
                "and ephemeral storage",
                {"run_id": record.get("run_id"), "domain": record.get("domain")},
            )
        return domain_uuid

    @staticmethod
    def _process_start_ticks(pid: int) -> int | None:
        try:
            raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        except OSError:
            return None
        closing = raw.rfind(")")
        if closing < 0:
            return None
        fields = raw[closing + 2 :].split()
        try:
            return int(fields[19])
        except (IndexError, ValueError):
            return None

    @staticmethod
    def _process_executable(pid: int) -> Path | None:
        try:
            return Path(f"/proc/{pid}/exe").resolve(strict=True)
        except OSError:
            return None

    @staticmethod
    def _open_pidfd(pid: int) -> int | None:
        """Pin a process identity, failing closed when pidfd is unavailable."""
        libc = ctypes.CDLL(None, use_errno=True)
        pidfd_open = getattr(libc, "pidfd_open", None)
        if pidfd_open is None:
            return None
        descriptor = int(pidfd_open(pid, 0))
        if descriptor >= 0:
            return descriptor
        error_number = ctypes.get_errno()
        if error_number in {getattr(os, "ENOSYS", 38), getattr(os, "ESRCH", 3)}:
            return None
        raise OSError(error_number, os.strerror(error_number))

    @staticmethod
    def _pidfd_send_signal(descriptor: int, signum: int) -> bool:
        libc = ctypes.CDLL(None, use_errno=True)
        sender = getattr(libc, "pidfd_send_signal", None)
        if sender is None:
            return False
        if sender(descriptor, signum, None, 0) == 0:
            return True
        error_number = ctypes.get_errno()
        if error_number in {getattr(os, "ENOSYS", 38), getattr(os, "ESRCH", 3)}:
            return False
        raise OSError(error_number, os.strerror(error_number))

    @classmethod
    def _stop_watchdog(cls, record: dict[str, Any]) -> None:
        """Signal only the exact watchdog identity recorded for this run."""
        pid = record.get("watchdog_pid")
        start_ticks = record.get("watchdog_start_ticks")
        if not isinstance(pid, int) or pid <= 1 or not isinstance(start_ticks, int):
            return
        pidfd = cls._open_pidfd(pid)
        if pidfd is None:
            return
        try:
            if cls._process_start_ticks(pid) != start_ticks:
                return
            expected = f"enoshima_vm.watchdog {record.get('run_id')} "
            try:
                command = (
                    Path(f"/proc/{pid}/cmdline")
                    .read_bytes()
                    .replace(b"\0", b" ")
                    .decode(errors="replace")
                )
            except OSError:
                return
            if expected not in command:
                return
            cls._pidfd_send_signal(pidfd, signal.SIGTERM)
        finally:
            os.close(pidfd)

    @classmethod
    def _watchdog_identity_alive(cls, record: dict[str, Any]) -> bool:
        pid = record.get("watchdog_pid")
        start_ticks = record.get("watchdog_start_ticks")
        if not isinstance(pid, int) or pid <= 1 or not isinstance(start_ticks, int):
            return False
        if cls._process_start_ticks(pid) != start_ticks:
            return False
        try:
            command = (
                Path(f"/proc/{pid}/cmdline")
                .read_bytes()
                .replace(b"\0", b" ")
                .decode(errors="replace")
            )
        except OSError:
            return False
        return f"enoshima_vm.watchdog {record.get('run_id')} " in command

    @classmethod
    def _wait_watchdog_stopped(
        cls, record: dict[str, Any], timeout_seconds: float = 10
    ) -> None:
        deadline = time.monotonic() + timeout_seconds
        while cls._watchdog_identity_alive(record) and time.monotonic() < deadline:
            time.sleep(0.05)
        if cls._watchdog_identity_alive(record):
            raise RuntimeError("recorded VM watchdog did not stop after SIGTERM")

    @staticmethod
    def _watchdog_unit_name(run_id: str) -> str:
        require_run_id(run_id)
        return f"{WATCHDOG_UNIT_PREFIX}{run_id}.service"

    def _start_watchdog(
        self, run_id: str, timeout_seconds: int
    ) -> dict[str, object]:
        """Start a VM deadline owner outside the disposable worker ancestry."""
        if timeout_seconds <= 0:
            raise ValueError("watchdog timeout must be positive")
        unit = self._watchdog_unit_name(run_id)
        uid = os.getuid()
        home = Path(pwd.getpwuid(uid).pw_dir)
        runtime = Path(f"/run/user/{uid}")
        # Preserve the virtual-environment launcher path. Resolving this
        # symlink selects the base interpreter and drops project dependencies.
        watchdog_launcher = Path(sys.executable).absolute()
        watchdog_executable = watchdog_launcher.resolve()
        watchdog_pythonpath = (self.paths.project / "src").resolve()
        cache_root = self.paths.cache.resolve()
        state_root = self.paths.state.resolve()
        runtime_max_seconds = (
            timeout_seconds
            + WATCHDOG_FINALIZATION_SECONDS
            + WATCHDOG_RUNTIME_GRACE_SECONDS
        )
        run_dir = self._run_dir(run_id)
        ready_path = confined_path(run_dir, run_dir / WATCHDOG_READY_NAME)
        ready_path.unlink(missing_ok=True)
        environment = {
            "HOME": str(home),
            "PATH": "/usr/bin",
            "XDG_RUNTIME_DIR": str(runtime),
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus",
        }
        command = [
            "/usr/bin/systemd-run",
            "--user",
            "--quiet",
            "--collect",
            "--service-type=exec",
            f"--unit={unit}",
            "--property=KillMode=control-group",
            "--property=SendSIGKILL=yes",
            "--property=Restart=no",
            "--property=TimeoutStopSec=10s",
            "--property=NoNewPrivileges=yes",
            f"--property=RuntimeMaxSec={runtime_max_seconds}s",
            f"--setenv=HOME={home}",
            "--setenv=PATH=/usr/bin",
            f"--setenv=XDG_RUNTIME_DIR={runtime}",
            f"--setenv=XDG_CACHE_HOME={home / '.cache'}",
            f"--setenv=XDG_CONFIG_HOME={home / '.config'}",
            f"--setenv=ENOSHIMA_VM_CACHE_ROOT={cache_root}",
            f"--setenv=ENOSHIMA_VM_STATE_ROOT={state_root}",
            f"--setenv=PYTHONPATH={watchdog_pythonpath}",
            "--setenv=PYTHONDONTWRITEBYTECODE=1",
            str(watchdog_launcher),
            "-m",
            "enoshima_vm.watchdog",
            run_id,
            str(timeout_seconds),
            self.uri,
        ]
        started = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=30,
            check=False,
            text=True,
            env=environment,
        )
        if started.returncode:
            raise subprocess.CalledProcessError(
                started.returncode,
                command,
                output=started.stdout,
                stderr=started.stderr,
            )
        def stop_unit() -> None:
            subprocess.run(
                ["/usr/bin/systemctl", "--user", "stop", unit],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=15,
                check=False,
                env=environment,
            )
        try:
            shown = subprocess.run(
                [
                    "/usr/bin/systemctl",
                    "--user",
                    "show",
                    unit,
                    "--property=MainPID",
                    "--property=ActiveState",
                    "--property=SubState",
                ],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=15,
                check=False,
                text=True,
                env=environment,
            )
            properties = dict(
                line.split("=", 1)
                for line in shown.stdout.splitlines()
                if "=" in line
            )
            try:
                pid = int(properties.get("MainPID", "0"))
            except ValueError:
                pid = 0
            start_ticks = self._process_start_ticks(pid) if pid > 1 else None
            executable = self._process_executable(pid) if pid > 1 else None
            if (
                shown.returncode
                or properties.get("ActiveState") != "active"
                or properties.get("SubState") != "running"
                or pid <= 1
                or start_ticks is None
                or executable != watchdog_executable
            ):
                raise RuntimeError(
                    "watchdog transient service did not expose a live main process: "
                    + (shown.stderr.strip() or shown.stdout.strip() or unit)
                )
            deadline = time.monotonic() + WATCHDOG_READY_TIMEOUT_SECONDS
            ready: dict[str, object] | None = None
            while time.monotonic() < deadline:
                if self._process_start_ticks(pid) != start_ticks:
                    raise RuntimeError("watchdog exited before publishing readiness")
                if ready_path.exists():
                    metadata = ready_path.lstat()
                    if (
                        not stat.S_ISREG(metadata.st_mode)
                        or stat.S_ISLNK(metadata.st_mode)
                        or metadata.st_uid != uid
                        or stat.S_IMODE(metadata.st_mode) != 0o600
                    ):
                        raise RuntimeError("watchdog readiness proof is unsafe")
                    ready = json.loads(ready_path.read_text(encoding="utf-8"))
                    break
                time.sleep(0.05)
            if ready is None:
                raise RuntimeError("watchdog readiness proof timed out")
            if (
                ready.get("runId") != run_id
                or ready.get("pid") != pid
                or ready.get("pidStartTicks") != start_ticks
                or ready.get("libvirtSession") != self.backend.session_identity()
            ):
                raise RuntimeError("watchdog readiness proof does not match this run")
            if self._process_start_ticks(pid) != start_ticks:
                raise RuntimeError("watchdog exited after publishing readiness")
        except Exception:
            stop_unit()
            raise
        return {
            "watchdog_unit": unit,
            "watchdog_pid": pid,
            "watchdog_start_ticks": start_ticks,
        }

    @staticmethod
    def _assert_loaded_harness_current() -> None:
        current = _harness_source_digest()
        if current != LOADED_HARNESS_SOURCE_DIGEST:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "MCP harness source changed while this worker was loading; retry "
                "the MCP call so the durable proxy can start a new worker",
                {
                    "loaded_harness_digest": LOADED_HARNESS_SOURCE_DIGEST,
                    "current_harness_digest": current,
                },
            )

    def _audit(
        self,
        tool: str,
        *,
        run_id: str | None = None,
        argv: Sequence[str] | None = None,
        result: str = "ok",
        duration_ms: int | None = None,
    ) -> None:
        event: dict[str, object] = {
            "timestamp": utc_now(),
            "actor": "codex",
            "tool": tool,
            "result": result,
        }
        if run_id:
            event["run_id"] = run_id
        if argv:
            event["argv"] = redact_argv(argv)
            event["argv_sha256"] = argv_digest(argv)
        if duration_ms is not None:
            event["duration_ms"] = duration_ms
        append_audit(self.audit_path, event)

    def _run_dir(self, run_id: str) -> Path:
        require_run_id(run_id)
        return confined_path(self.runs_root, self.runs_root / run_id)

    def _record_path(self, run_id: str) -> Path:
        return self._run_dir(run_id) / "run.json"

    def _write_record_unlocked(self, record: dict[str, Any]) -> None:
        path = self._record_path(record["run_id"])
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = path.with_suffix(".json.new")
        temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(temporary, path)

    def _write_record(self, record: dict[str, Any]) -> None:
        run_dir = self._run_dir(record["run_id"])
        with run_record_lock(run_dir):
            path = self._record_path(record["run_id"])
            if path.is_file():
                current = json.loads(path.read_text(encoding="utf-8"))
                if terminal_run_state_preserved(
                    current.get("status"), record.get("status")
                ):
                    record.clear()
                    record.update(current)
                    return
            self._write_record_unlocked(record)

    def load_record(self, run_id: str) -> dict[str, Any]:
        path = self._record_path(run_id)
        if not path.is_file():
            raise VMError(FailureCategory.HARNESS_ERROR, f"unknown run: {run_id}")
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("run_id") != run_id:
            raise VMError(FailureCategory.HARNESS_ERROR, f"corrupt run record: {path}")
        require_domain(record["domain"])
        if not record.get("synthetic") and record.get("libvirt_session") is not None:
            expected_session = self.backend.session_identity()
            recorded_session = record.get("libvirt_session")
            if recorded_session != expected_session:
                raise VMError(
                    FailureCategory.HOST_INFRA_ERROR,
                    "run record belongs to a different or unknown libvirt session; "
                    "refusing domain or ephemeral-storage access",
                    {
                        "recorded_session": recorded_session,
                        "expected_session": expected_session,
                    },
                )
        return record

    def _require_recorded_libvirt_session(self, record: dict[str, Any]) -> None:
        if record.get("synthetic"):
            return
        expected_session = self.backend.session_identity()
        recorded_session = record.get("libvirt_session")
        if recorded_session != expected_session:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "destructive cleanup requires the exact recorded libvirt session; "
                "preserving the domain and ephemeral storage",
                {
                    "recorded_session": recorded_session,
                    "expected_session": expected_session,
                },
            )

    def _guest(self, record: dict[str, Any]) -> Guest:
        private_key = confined_path(
            self._run_dir(record["run_id"]), Path(record["private_key"])
        )
        if not private_key.is_file():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "disposable SSH key is unavailable; the run has already been destroyed",
            )
        return Guest(int(record["ssh_host_port"]), private_key)

    def preflight(self, suite_name: str) -> dict[str, object]:
        suite = load_suite(suite_name, self.paths)
        checks = self.backend.preflight(suite)
        images = load_images(self.paths)
        if suite.base_image not in images:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"suite references unknown image: {suite.base_image}",
            )
        checks["image"] = suite.base_image
        checks["state_root"] = str(self.paths.state)
        checks["cache_root"] = str(self.paths.cache)
        return checks

    @mutation_guard
    def create(
        self,
        suite_name: str,
        *,
        source_ref: str = "working-tree",
        verification_mode: str = "dev",
        planned_source_commit: str | None = None,
        planned_worktree_digest: str | None = None,
        planned_source_tree_digest: str | None = None,
        planned_retry_digest: str | None = None,
    ) -> dict[str, Any]:
        self._assert_loaded_harness_current()
        if source_ref != "working-tree":
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "only the current working tree may be supplied to a VM run",
            )
        suite = load_suite(suite_name, self.paths)
        mode = load_verification_mode(verification_mode, self.paths)
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        domain_uuid = str(uuid.uuid4())
        run_dir = self._run_dir(run_id)
        run_dir.mkdir(mode=0o700, parents=True)
        record: dict[str, Any] = {
            "schema": 1,
            "run_id": run_id,
            "domain": f"{DOMAIN_PREFIX}{run_id}",
            "domain_uuid": domain_uuid,
            "suite": suite.name,
            "status": "creating",
            "category": None,
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "libvirt_uri": self.uri,
            "libvirt_session": self.backend.session_identity(),
            "artifact_dir": str(run_dir / "artifacts"),
            "source_ref": source_ref,
            "verification_mode": mode.name,
            "authoritative": False,
            "fresh_overlay": False,
            "current_step": "vm_create",
            "fresh_overlay_required": mode.fresh_overlay_required,
            "planned_source_commit": planned_source_commit,
            "planned_worktree_digest": planned_worktree_digest,
            "planned_source_tree_digest": planned_source_tree_digest,
            "planned_retry_digest": planned_retry_digest,
        }
        self._write_record(record)
        watchdog_started = False
        try:
            if suite.name == "boot-security":
                secret_dir = run_dir / "secrets"
                secret_dir.mkdir(mode=0o700)
                recovery_key = secret_dir / "luks-recovery.key"
                _write_recovery_key(recovery_key)
                record["recovery_key"] = str(recovery_key)
                self._write_record(record)
            self.preflight(suite_name)
            definitions = load_images(self.paths)
            definition = definitions[suite.base_image]
            base_image = self.images.ensure(definition)
            cloud = self.cloud_init.build(
                run_dir,
                run_id,
                "kentakang",
                definition.repository_snapshot,
            )
            spec = self.backend.prepare_domain(
                run_dir, run_id, domain_uuid, suite, base_image, cloud.seed
            )
            record.update(
                {
                    "domain": spec.domain,
                    "domain_uuid": spec.domain_uuid,
                    "base_image": str(base_image),
                    "overlay": str(spec.overlay),
                    "seed": str(spec.seed),
                    "private_key": str(cloud.private_key),
                    "ssh_host_port": spec.ssh_host_port,
                    "domain_xml": str(spec.xml),
                    "fresh_overlay": True,
                    "authoritative": mode.authoritative,
                }
            )
            if spec.boot_disk:
                record["boot_disk"] = str(spec.boot_disk)
            self._write_record(record)
            record.update(
                self._start_watchdog(run_id, suite.timeout_minutes * 60)
            )
            watchdog_started = True
            record["maximum_duration_minutes"] = suite.timeout_minutes
            self._write_record(record)
            self.backend.define_and_start(spec)
            record["status"] = "running"
            record["updated_at"] = utc_now()
            self._write_record(record)
            self._audit("vm_create", run_id=run_id)
            return record
        except Exception as error:
            record["result"] = "failed"
            record["status"] = "failed"
            category = (
                error.category
                if isinstance(error, VMError)
                else (
                    FailureCategory.HOST_INFRA_ERROR
                    if isinstance(
                        error,
                        (OSError, subprocess.SubprocessError, TimeoutError),
                    )
                    else FailureCategory.HARNESS_ERROR
                )
            )
            record["category"] = str(category)
            record["error"] = str(error)
            record.update(
                failure_fields(
                    suite=suite_name,
                    step="vm_create",
                    error=error,
                )
            )
            record["next_verification"] = (
                "restore VM infrastructure or change the relevant fixture source"
            )
            record["updated_at"] = utc_now()
            artifact_root = Path(str(record["artifact_dir"])) / "runner"
            artifact_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            create_error = artifact_root / "create-error.json"
            create_error.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "suite": suite_name,
                        "category": str(category),
                        "message": str(error),
                        "details": (
                            error.details if isinstance(error, VMError) else None
                        ),
                        "traceback": "".join(traceback.format_exception(error)),
                    },
                    indent=2,
                    default=str,
                )
                + "\n",
                encoding="utf-8",
            )
            create_error.chmod(0o600)
            record["create_error_artifact"] = str(create_error)
            self._write_record(record)
            cleanup_errors: list[str] = []
            domain_removed = False
            try:
                self.backend.destroy(
                    record["domain"], str(record.get("domain_uuid", ""))
                )
                domain_removed = True
            except Exception as cleanup_error:
                cleanup_errors.append(f"domain cleanup: {cleanup_error}")
            if domain_removed and watchdog_started:
                try:
                    self._stop_watchdog(record)
                    self._wait_watchdog_stopped(record)
                except Exception as cleanup_error:
                    cleanup_errors.append(f"watchdog cleanup: {cleanup_error}")
            if domain_removed and not cleanup_errors:
                try:
                    self._remove_ephemeral(record)
                except Exception as cleanup_error:
                    cleanup_errors.append(f"ephemeral cleanup: {cleanup_error}")
                else:
                    record["status"] = "destroyed"
                    record["destroyed_at"] = utc_now()
                    record.pop("private_key", None)
                    record.pop("recovery_key", None)
                    record.pop("login_password", None)
            if cleanup_errors:
                record["cleanup_errors"] = cleanup_errors
            self._write_record(record)
            try:
                self._audit("vm_create", run_id=run_id, result="failed")
            except Exception as audit_error:
                record["audit_error"] = str(audit_error)
                self._write_record(record)
            raise

    @mutation_guard
    def wait(self, run_id: str, timeout_seconds: int = 1200) -> dict[str, Any]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        guest.wait_ssh(min(timeout_seconds, 600))
        guest.wait_cloud_init(timeout_seconds)
        self.backend.wait_guest_agent(
            record["domain"],
            self._require_recorded_domain_uuid(record),
            min(timeout_seconds, 300),
        )
        record["status"] = "ready"
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_wait", run_id=run_id)
        return record

    @mutation_guard
    def upload_worktree(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        identity = self._guest(record).upload_worktree(
            self.paths.repository,
            REMOTE_SOURCE,
            expected_commit=(
                str(record["planned_source_commit"])
                if record.get("planned_source_commit")
                else None
            ),
            expected_tree_hash=(
                str(record["planned_source_tree_digest"])
                if record.get("planned_source_tree_digest")
                else None
            ),
        )
        source = source_identity_json(identity)
        artifact_root = Path(str(record["artifact_dir"])) / "runner"
        artifact_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        manifest = artifact_root / "source-manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "source": source,
                    "files": list(identity.files),
                    "untrackedFiles": list(identity.untracked_files),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        manifest.chmod(0o600)
        source["manifest_artifact"] = str(manifest)
        record["source"] = source
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_upload_worktree", run_id=run_id)
        return source

    @mutation_guard
    def exec(
        self,
        run_id: str,
        argv: Sequence[str],
        *,
        timeout_seconds: int = 300,
        idle_timeout_seconds: int | None = None,
    ) -> dict[str, object]:
        if not argv:
            raise VMError(FailureCategory.HARNESS_ERROR, "argv must not be empty")
        record = self.load_record(run_id)
        start = time.monotonic()
        guest_options: dict[str, object] = {
            "timeout": timeout_seconds,
            "check": False,
        }
        if idle_timeout_seconds is not None:
            guest_options["idle_timeout"] = idle_timeout_seconds
        result = self._guest(record).exec(list(argv), **guest_options)
        duration_ms = int((time.monotonic() - start) * 1000)
        self._audit(
            "vm_exec",
            run_id=run_id,
            argv=list(argv),
            result="ok" if result.returncode == 0 else "failed",
            duration_ms=duration_ms,
        )
        return {
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "duration_ms": duration_ms,
        }

    @mutation_guard
    def exec_bounded(
        self,
        run_id: str,
        argv: Sequence[str],
        *,
        timeout_seconds: int = 300,
    ) -> dict[str, object]:
        result = self.exec(run_id, argv, timeout_seconds=timeout_seconds)
        record = self.load_record(run_id)
        log = self._write_step_log(
            record,
            f"manual-exec-{uuid.uuid4().hex[:12]}",
            result,
        )
        return summarize_exec_result(result, artifact_path=str(log))

    def _write_step_log(
        self,
        record: dict[str, Any],
        name: str,
        result: dict[str, object],
    ) -> Path:
        path = Path(record["artifact_dir"]) / "runner" / f"{name}.log"
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        stderr = (
            "\n--- stderr ---\n" + str(result["stderr"]) if result["stderr"] else ""
        )
        path.write_text(str(result["stdout"]) + stderr, encoding="utf-8")
        return path

    def _write_junit(self, record: dict[str, Any]) -> Path:
        steps = record.get("steps", [])
        failures = sum(1 for step in steps if step.get("status") == "failed")
        elapsed = sum(float(step.get("duration_seconds", 0)) for step in steps)
        suite = ET.Element(
            "testsuite",
            {
                "name": f"enoshima-vm.{record['suite']}",
                "tests": str(len(steps)),
                "failures": str(failures),
                "errors": "0",
                "skipped": "0",
                "time": f"{elapsed:.3f}",
            },
        )
        for step in steps:
            case = ET.SubElement(
                suite,
                "testcase",
                {
                    "classname": f"enoshima_vm.{record['suite']}",
                    "name": str(step["action"]),
                    "time": f"{float(step.get('duration_seconds', 0)):.3f}",
                },
            )
            if step.get("status") == "failed":
                failure = ET.SubElement(
                    case,
                    "failure",
                    {
                        "type": str(record.get("category") or "HARNESS_ERROR"),
                        "message": str(record.get("error") or "suite step failed"),
                    },
                )
                failure.text = str(record.get("error") or "suite step failed")
        destination = Path(record["artifact_dir"]) / "junit.xml"
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        ET.ElementTree(suite).write(destination, encoding="utf-8", xml_declaration=True)
        return destination

    def _run_checked(
        self,
        record: dict[str, Any],
        name: str,
        argv: Sequence[str],
        category: FailureCategory,
        *,
        timeout_seconds: int = 7200,
        idle_timeout_seconds: int | None = None,
    ) -> dict[str, object]:
        try:
            result = self.exec(
                record["run_id"],
                argv,
                timeout_seconds=timeout_seconds,
                idle_timeout_seconds=idle_timeout_seconds,
            )
        except GuestCommandTimeout as error:
            log = self._write_step_log(
                record,
                name,
                {
                    "exit_code": 124,
                    "stdout": error.stdout,
                    "stderr": error.stderr,
                    "duration_ms": timeout_seconds * 1000,
                },
            )
            details = dict(error.details or {})
            details["log"] = str(log)
            error.details = details
            raise
        log = self._write_step_log(record, name, result)
        if result["exit_code"]:
            failure_category = category
            message = f"suite step failed: {name}"
            details: dict[str, object] = {
                "exit_code": result["exit_code"],
                "log": str(log),
                "stderr_tail": str(result["stderr"])[-4000:],
            }
            if category == FailureCategory.BOOTSTRAP_FAILED:
                packages = _exhausted_aur_transport_packages(str(result["stderr"]))
                if packages:
                    failure_category = FailureCategory.HOST_INFRA_ERROR
                    message = "AUR transport attempts were exhausted for: " + ", ".join(
                        packages
                    )
                    details.update(
                        {
                            "underlying_category": str(category),
                            "transport_kind": "aur-tls-eof",
                            "packages": list(packages),
                        }
                    )
            raise VMError(
                failure_category,
                message,
                details,
            )
        return result

    def _remote_shell(self, command: str) -> list[str]:
        return ["bash", "-lc", command]

    def _graphical_shell(self, command: str) -> list[str]:
        environment = (
            "uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
            "while IFS= read -r entry; do case $entry in "
            "PATH=*|WAYLAND_DISPLAY=*|DISPLAY=*|HYPRLAND_INSTANCE_SIGNATURE=*|"
            "XDG_CURRENT_DESKTOP=*|XDG_SESSION_DESKTOP=*|XDG_SESSION_TYPE=*) "
            'export "$entry" ;; esac; done < <(systemctl --user show-environment); '
        )
        return self._remote_shell(environment + command)

    def _run_validate(self, record: dict[str, Any]) -> None:
        self._run_checked(
            record,
            "validate",
            self._remote_shell(f"cd {REMOTE_SOURCE} && make validate"),
            FailureCategory.VALIDATION_FAILED,
        )

    def _seed_codex_electron_cache(self, record: dict[str, Any]) -> None:
        cache_root = Path(
            os.environ.get(
                "ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR",
                Path.home() / ".cache" / "codex-desktop" / "electron",
            )
        ).expanduser()
        archives = sorted(cache_root.glob("electron-v*-linux-*.zip"))
        dmg = Path(
            os.environ.get(
                "ENOSHIMA_VM_CODEX_DMG",
                Path.home()
                / ".cache"
                / "enoshima"
                / "codex-desktop-linux"
                / "source"
                / "Codex.dmg",
            )
        ).expanduser()
        node_lock = (
            self.paths.repository / "packages" / "codex-desktop-node-runtime.sha256"
        )
        try:
            node_lock_fields = node_lock.read_text(encoding="utf-8").split()
        except OSError as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "Codex managed Node runtime lock could not be read",
                {"path": str(node_lock), "error": str(error)},
            ) from error
        if (
            len(node_lock_fields) != 2
            or not re.fullmatch(r"[0-9a-f]{64}", node_lock_fields[0])
            or not re.fullmatch(
                r"node-v[0-9]+\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz",
                node_lock_fields[1],
            )
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "Codex managed Node runtime lock is invalid",
                {"path": str(node_lock)},
            )
        expected_node_digest, node_archive_name = node_lock_fields
        node_archive = Path(
            os.environ.get(
                "ENOSHIMA_VM_CODEX_NODE_ARCHIVE",
                Path.home()
                / ".cache"
                / "codex-desktop"
                / "node-runtime"
                / node_archive_name,
            )
        ).expanduser()
        observation: dict[str, object] = {
            "status": "absent",
            "archives": [],
            "node_runtime": {"status": "absent"},
            "dmg": {"status": "absent"},
        }

        if archives:
            total_size = 0
            uploaded: list[dict[str, object]] = []
            guest = self._guest(record)
            for archive in archives:
                if archive.is_symlink() or not archive.is_file():
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        f"invalid Codex Electron cache entry: {archive}",
                    )
                size = archive.stat().st_size
                total_size += size
                if size > 512 * 1024 * 1024 or total_size > 1024 * 1024 * 1024:
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "Codex Electron cache exceeds the VM seed limit",
                    )
                if not zipfile.is_zipfile(archive):
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        f"Codex Electron cache is not a valid ZIP archive: {archive}",
                    )

                digest = file_sha256(archive)
                remote = REMOTE_CODEX_ELECTRON_CACHE / archive.name
                guest.upload_file(archive, remote, mode=0o600)
                remote_result = guest.exec(
                    ["sha256sum", "--", str(remote)], timeout=180
                )
                remote_digest = remote_result.stdout.split(maxsplit=1)[0]
                if remote_digest != digest:
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "Codex Electron cache transfer checksum mismatch: "
                        f"{archive.name}",
                    )
                uploaded.append({"name": archive.name, "size": size, "sha256": digest})

            observation["status"] = "seeded"
            observation["archives"] = uploaded

        if node_archive.exists() or node_archive.is_symlink():
            if (
                node_archive.is_symlink()
                or not node_archive.is_file()
                or node_archive.name != node_archive_name
            ):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"invalid Codex managed Node runtime cache: {node_archive}",
                )
            node_size = node_archive.stat().st_size
            if node_size <= 0 or node_size > 256 * 1024 * 1024:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex managed Node runtime cache has an invalid size",
                    {"path": str(node_archive), "size": node_size},
                )
            if not tarfile.is_tarfile(node_archive):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex managed Node runtime cache is not a tar archive",
                    {"path": str(node_archive)},
                )
            node_digest = file_sha256(node_archive)
            if node_digest != expected_node_digest:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex managed Node runtime cache does not match its digest lock",
                    {
                        "path": str(node_archive),
                        "actual": node_digest,
                        "expected": expected_node_digest,
                    },
                )
            guest = self._guest(record)
            remote_node_archive = REMOTE_CODEX_NODE_CACHE / node_archive_name
            guest.upload_file(node_archive, remote_node_archive, mode=0o600)
            remote_result = guest.exec(
                ["sha256sum", "--", str(remote_node_archive)], timeout=180
            )
            remote_digest = remote_result.stdout.split(maxsplit=1)[0]
            if remote_digest != node_digest:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex managed Node runtime transfer checksum mismatch",
                )
            observation["status"] = "seeded"
            observation["node_runtime"] = {
                "status": "seeded",
                "name": node_archive_name,
                "size": node_size,
                "sha256": node_digest,
            }

        if dmg.exists() or dmg.is_symlink():
            if dmg.is_symlink() or not dmg.is_file():
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"invalid Codex DMG cache entry: {dmg}",
                )
            size = dmg.stat().st_size
            if size < 512 or size > 1024 * 1024 * 1024:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex DMG cache has an invalid size",
                    {"path": str(dmg), "size": size},
                )
            with dmg.open("rb") as handle:
                handle.seek(-512, os.SEEK_END)
                if handle.read(4) != b"koly":
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        f"Codex DMG cache has no UDIF trailer: {dmg}",
                    )

            digest = file_sha256(dmg)
            digest_lock = (
                self.paths.repository / "packages" / "codex-desktop-dmg-sha256.txt"
            )
            try:
                expected_digest = digest_lock.read_text(encoding="utf-8").strip()
            except OSError as error:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex DMG digest lock could not be read",
                    {"path": str(digest_lock), "error": str(error)},
                ) from error
            if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex DMG digest lock is invalid",
                    {"path": str(digest_lock)},
                )
            if digest != expected_digest:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex DMG cache does not match the repository digest lock",
                    {
                        "path": str(dmg),
                        "actual": digest,
                        "expected": expected_digest,
                    },
                )
            guest = self._guest(record)
            guest.upload_file(dmg, REMOTE_CODEX_DMG_CACHE, mode=0o600)
            remote_result = guest.exec(
                ["sha256sum", "--", str(REMOTE_CODEX_DMG_CACHE)], timeout=300
            )
            remote_digest = remote_result.stdout.split(maxsplit=1)[0]
            if remote_digest != digest:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "Codex DMG cache transfer checksum mismatch",
                )
            observation["status"] = "seeded"
            observation["dmg"] = {
                "status": "seeded",
                "name": dmg.name,
                "size": size,
                "sha256": digest,
            }

        record.setdefault("observations", {})["codex_electron_cache"] = observation
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_seed_codex_electron_cache", run_id=record["run_id"])

    def _pacman_cache_paths(
        self, record: dict[str, Any]
    ) -> tuple[Path, Path, Path, Path]:
        base_image = Path(str(record.get("base_image", ""))).name
        if not base_image:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "VM record has no base image for the pacman cache",
            )
        readable = re.sub(r"[^A-Za-z0-9._-]+", "-", Path(base_image).stem)[:80]
        identity = sha256(base_image.encode()).hexdigest()[:16]
        root = confined_path(
            self.paths.cache,
            self.paths.cache / "pacman" / f"{readable}-{identity}",
        )
        return (
            root,
            root / "packages",
            root / "seed.tar",
            root / "manifest.json",
        )

    @staticmethod
    def _validate_pacman_package_name(name: str) -> None:
        if not PACMAN_PACKAGE_PATTERN.fullmatch(name):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid pacman cache package name: {name!r}",
            )

    def _host_pacman_packages(self, package_root: Path) -> list[Path]:
        if not package_root.exists():
            return []
        if package_root.is_symlink() or not package_root.is_dir():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid pacman cache directory: {package_root}",
            )
        packages: list[Path] = []
        total_size = 0
        for package in sorted(package_root.iterdir()):
            if not PACMAN_PACKAGE_PATTERN.fullmatch(package.name):
                continue
            if package.is_symlink() or not package.is_file():
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"invalid pacman cache entry: {package}",
                )
            size = package.stat().st_size
            if size <= 0 or size > PACMAN_CACHE_MAX_FILE_BYTES:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"pacman cache entry has an invalid size: {package}",
                )
            total_size += size
            if total_size > PACMAN_CACHE_MAX_TOTAL_BYTES:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman package cache exceeds the managed size limit",
                )
            packages.append(package)
        return packages

    def _rebuild_pacman_seed_archive(
        self, record: dict[str, Any], package_root: Path, archive: Path, manifest: Path
    ) -> dict[str, object]:
        packages = self._host_pacman_packages(package_root)
        cache_root = archive.parent
        cache_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = cache_root / f".{archive.name}.{uuid.uuid4().hex}.new"
        total_size = 0
        package_manifest: list[dict[str, object]] = []
        try:
            with tarfile.open(temporary, mode="w") as bundle:
                for package in packages:
                    size = package.stat().st_size
                    total_size += size
                    info = tarfile.TarInfo(package.name)
                    info.size = size
                    info.mode = 0o644
                    info.uid = 0
                    info.gid = 0
                    info.mtime = 0
                    with package.open("rb") as source:
                        bundle.addfile(info, source)
                    package_manifest.append({"name": package.name, "size": size})
            temporary.chmod(0o600)
            os.replace(temporary, archive)
        finally:
            temporary.unlink(missing_ok=True)

        payload: dict[str, object] = {
            "schema": 1,
            "base_image": Path(str(record["base_image"])).name,
            "archive_sha256": file_sha256(archive),
            "archive_size": archive.stat().st_size,
            "package_count": len(packages),
            "package_bytes": total_size,
            "packages": package_manifest,
        }
        temporary_manifest = manifest.with_suffix(".json.new")
        temporary_manifest.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_manifest.chmod(0o600)
        os.replace(temporary_manifest, manifest)
        return payload

    def _seed_pacman_cache(self, record: dict[str, Any]) -> None:
        _, _, archive, manifest = self._pacman_cache_paths(record)
        observation: dict[str, object] = {"status": "absent"}
        if archive.exists() or manifest.exists():
            if (
                archive.is_symlink()
                or manifest.is_symlink()
                or not archive.is_file()
                or not manifest.is_file()
            ):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed cache is incomplete or unsafe",
                )
            if (
                archive.stat().st_size <= 0
                or archive.stat().st_size > PACMAN_CACHE_MAX_TOTAL_BYTES
            ):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed archive exceeds the managed size limit",
                )
            try:
                metadata = json.loads(manifest.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed manifest is unreadable",
                    {"error": str(error)},
                ) from error
            raw_packages = metadata.get("packages")
            if not isinstance(raw_packages, list):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed manifest has no package list",
                )
            expected_packages: dict[str, int] = {}
            expected_bytes = 0
            for entry in raw_packages:
                if (
                    not isinstance(entry, dict)
                    or not isinstance(entry.get("name"), str)
                    or not isinstance(entry.get("size"), int)
                ):
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "pacman seed manifest contains an invalid package entry",
                    )
                name = entry["name"]
                size = entry["size"]
                self._validate_pacman_package_name(name)
                if (
                    name in expected_packages
                    or size <= 0
                    or size > PACMAN_CACHE_MAX_FILE_BYTES
                ):
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        f"pacman seed manifest contains an invalid package: {name!r}",
                    )
                expected_packages[name] = size
                expected_bytes += size
                if expected_bytes > PACMAN_CACHE_MAX_TOTAL_BYTES:
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "pacman seed manifest exceeds the managed size limit",
                    )
            observed_packages: dict[str, int] = {}
            try:
                with tarfile.open(archive, mode="r") as bundle:
                    for member in bundle.getmembers():
                        if (
                            member.name not in expected_packages
                            or member.name in observed_packages
                            or not member.isreg()
                            or member.size != expected_packages[member.name]
                        ):
                            raise VMError(
                                FailureCategory.HARNESS_ERROR,
                                "pacman seed archive contains an unsafe member: "
                                f"{member.name!r}",
                            )
                        observed_packages[member.name] = member.size
            except (OSError, tarfile.TarError) as error:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed archive is unreadable",
                    {"error": str(error)},
                ) from error
            if (
                metadata.get("schema") != 1
                or metadata.get("base_image") != Path(str(record["base_image"])).name
                or metadata.get("archive_size") != archive.stat().st_size
                or metadata.get("archive_sha256") != file_sha256(archive)
                or metadata.get("package_count") != len(expected_packages)
                or metadata.get("package_bytes") != expected_bytes
                or observed_packages != expected_packages
            ):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "pacman seed archive does not match its manifest",
                )

            guest = self._guest(record)
            guest.upload_file(
                archive,
                REMOTE_PACMAN_CACHE_SEED,
                mode=0o600,
                timeout=30 * 60,
            )
            try:
                remote_digest = guest.exec(
                    ["sha256sum", "--", str(REMOTE_PACMAN_CACHE_SEED)],
                    timeout=10 * 60,
                ).stdout.split(maxsplit=1)[0]
                if remote_digest != metadata["archive_sha256"]:
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "pacman seed archive transfer checksum mismatch",
                    )
                guest.exec(
                    [
                        "sudo",
                        "install",
                        "-d",
                        "-m",
                        "0755",
                        str(REMOTE_SYSTEM_PACMAN_CACHE),
                    ]
                )
                guest.exec(
                    [
                        "sudo",
                        "tar",
                        "--extract",
                        "--file",
                        str(REMOTE_PACMAN_CACHE_SEED),
                        "--directory",
                        str(REMOTE_SYSTEM_PACMAN_CACHE),
                        "--no-same-owner",
                        "--no-same-permissions",
                    ],
                    timeout=30 * 60,
                )
            finally:
                guest.exec(
                    ["rm", "-f", "--", str(REMOTE_PACMAN_CACHE_SEED)],
                    check=False,
                )
            observation = {
                "status": "seeded",
                "package_count": metadata["package_count"],
                "package_bytes": metadata["package_bytes"],
                "archive_sha256": metadata["archive_sha256"],
            }

        # cloud-final starts concurrently with the first SSH connection.  It
        # waits for this marker before deciding whether the immutable package
        # cache can replace the network download phase.  Publish `seeded`
        # first so the ready marker can never expose a partial extraction.
        guest = self._guest(record)
        if observation["status"] == "seeded":
            guest.exec(["sudo", "touch", str(REMOTE_PACMAN_CACHE_SEEDED)])
        else:
            guest.exec(["sudo", "rm", "-f", "--", str(REMOTE_PACMAN_CACHE_SEEDED)])
        guest.exec(["sudo", "touch", str(REMOTE_PACMAN_CACHE_SEED_READY)])

        record.setdefault("observations", {})["pacman_cache_seed"] = observation
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_seed_pacman_cache", run_id=record["run_id"])

    def _remote_pacman_packages(self, record: dict[str, Any]) -> dict[str, int]:
        guest = self._guest(record)
        result = guest.exec(
            [
                "sudo",
                "find",
                str(REMOTE_SYSTEM_PACMAN_CACHE),
                "-maxdepth",
                "1",
                "-type",
                "f",
                "-printf",
                "%f\t%s\n",
            ],
            timeout=120,
        )
        packages: dict[str, int] = {}
        total_size = 0
        for line in result.stdout.splitlines():
            try:
                name, raw_size = line.rsplit("\t", 1)
                size = int(raw_size)
            except (ValueError, TypeError) as error:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"invalid guest pacman cache manifest line: {line!r}",
                ) from error
            if not PACMAN_PACKAGE_PATTERN.fullmatch(name):
                continue
            self._validate_pacman_package_name(name)
            if name in packages or size <= 0 or size > PACMAN_CACHE_MAX_FILE_BYTES:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"invalid guest pacman cache entry: {name!r}",
                )
            total_size += size
            if total_size > PACMAN_CACHE_MAX_TOTAL_BYTES:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "guest pacman package cache exceeds the managed size limit",
                )
            packages[name] = size
        return packages

    def _collect_pacman_cache(self, record: dict[str, Any]) -> None:
        cache_root, package_root, archive, manifest = self._pacman_cache_paths(record)
        remote_packages = self._remote_pacman_packages(record)
        package_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        host_packages = {
            package.name: package.stat().st_size
            for package in self._host_pacman_packages(package_root)
        }
        missing = sorted(
            name
            for name, size in remote_packages.items()
            if host_packages.get(name) != size
        )
        added_bytes = sum(remote_packages[name] for name in missing)
        observation: dict[str, object] = {
            "status": "current",
            "remote_package_count": len(remote_packages),
            "added_package_count": 0,
            "added_package_bytes": 0,
        }
        if missing:
            run_dir = self._run_dir(record["run_id"])
            local_files = run_dir / "pacman-cache-files"
            local_delta = run_dir / "pacman-cache-delta.tar"
            local_files.write_bytes(
                b"\0".join(name.encode() for name in missing) + b"\0"
            )
            local_files.chmod(0o600)
            guest = self._guest(record)
            guest.exec(
                [
                    "install",
                    "-d",
                    "-m",
                    "0700",
                    str(REMOTE_PACMAN_CACHE_ROOT),
                ]
            )
            guest.upload_file(
                local_files,
                REMOTE_PACMAN_CACHE_FILES,
                mode=0o600,
                timeout=120,
            )
            try:
                guest.exec(
                    [
                        "sudo",
                        "tar",
                        "--create",
                        "--file",
                        str(REMOTE_PACMAN_CACHE_DELTA),
                        "--directory",
                        str(REMOTE_SYSTEM_PACMAN_CACHE),
                        "--null",
                        "--verbatim-files-from",
                        "--files-from",
                        str(REMOTE_PACMAN_CACHE_FILES),
                    ],
                    timeout=30 * 60,
                )
                guest.exec(
                    [
                        "sudo",
                        "chown",
                        "kentakang:kentakang",
                        str(REMOTE_PACMAN_CACHE_DELTA),
                    ]
                )
                guest.download(
                    REMOTE_PACMAN_CACHE_DELTA,
                    local_delta,
                    timeout=30 * 60,
                )
                expected = set(missing)
                observed: set[str] = set()
                with tarfile.open(local_delta, mode="r") as bundle:
                    for member in bundle.getmembers():
                        if (
                            member.name not in expected
                            or member.name in observed
                            or not member.isreg()
                            or member.size != remote_packages.get(member.name)
                            or member.size <= 0
                            or member.size > PACMAN_CACHE_MAX_FILE_BYTES
                        ):
                            raise VMError(
                                FailureCategory.HARNESS_ERROR,
                                f"unsafe pacman cache archive member: {member.name!r}",
                            )
                        self._validate_pacman_package_name(member.name)
                        source = bundle.extractfile(member)
                        if source is None:
                            raise VMError(
                                FailureCategory.HARNESS_ERROR,
                                f"pacman cache archive member is unreadable: "
                                f"{member.name!r}",
                            )
                        destination = package_root / member.name
                        temporary = package_root / (
                            f".{member.name}.{uuid.uuid4().hex}.new"
                        )
                        try:
                            with source, temporary.open("wb") as output:
                                shutil.copyfileobj(source, output, length=1024 * 1024)
                            if temporary.stat().st_size != member.size:
                                raise VMError(
                                    FailureCategory.HARNESS_ERROR,
                                    "pacman cache archive member was truncated: "
                                    f"{member.name!r}",
                                )
                            temporary.chmod(0o600)
                            os.replace(temporary, destination)
                        finally:
                            temporary.unlink(missing_ok=True)
                        observed.add(member.name)
                if observed != expected:
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "pacman cache archive omitted requested packages",
                    )
                metadata = self._rebuild_pacman_seed_archive(
                    record, package_root, archive, manifest
                )
                observation = {
                    "status": "updated",
                    "remote_package_count": len(remote_packages),
                    "added_package_count": len(missing),
                    "added_package_bytes": added_bytes,
                    "package_count": metadata["package_count"],
                    "package_bytes": metadata["package_bytes"],
                    "archive_sha256": metadata["archive_sha256"],
                }
            finally:
                local_files.unlink(missing_ok=True)
                local_delta.unlink(missing_ok=True)
                guest.exec(
                    [
                        "rm",
                        "-f",
                        "--",
                        str(REMOTE_PACMAN_CACHE_FILES),
                        str(REMOTE_PACMAN_CACHE_DELTA),
                    ],
                    check=False,
                )
        elif remote_packages and (not archive.is_file() or not manifest.is_file()):
            metadata = self._rebuild_pacman_seed_archive(
                record, package_root, archive, manifest
            )
            observation = {
                "status": "rebuilt",
                "remote_package_count": len(remote_packages),
                "added_package_count": 0,
                "added_package_bytes": 0,
                "package_count": metadata["package_count"],
                "package_bytes": metadata["package_bytes"],
                "archive_sha256": metadata["archive_sha256"],
            }

        record.setdefault("observations", {})["pacman_cache_collect"] = observation
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_collect_pacman_cache", run_id=record["run_id"])

    def _run_bootstrap(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        report = str(values.get("report", "current"))
        if not re.fullmatch(r"[a-z0-9-]+", report):
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid bootstrap report name"
            )
        repeat = values.get("repeat", False)
        if not isinstance(repeat, bool):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "bootstrap repeat flag must be a boolean",
            )
        timeout_seconds = (
            REPEAT_BOOTSTRAP_TIMEOUT_SECONDS if repeat else BOOTSTRAP_TIMEOUT_SECONDS
        )
        idle_timeout_seconds = (
            REPEAT_BOOTSTRAP_IDLE_TIMEOUT_SECONDS
            if repeat
            else BOOTSTRAP_IDLE_TIMEOUT_SECONDS
        )
        suite = load_suite(record["suite"], self.paths)
        remote_report = REMOTE_ARTIFACTS / f"bootstrap-{report}"
        inventory = f"{REMOTE_SOURCE}/ansible/inventory/hosts.yml"
        if values.get("inventory") == "runtime":
            inventory = str(record.get("observations", {}).get("runtime_inventory", ""))
            if not inventory:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "runtime inventory has not been generated",
                )
        apply_boot_artifacts = (
            " --apply-boot-artifacts" if values.get("apply_boot_artifacts") else ""
        )
        command = (
            f"cd {REMOTE_SOURCE} && "
            f"MISE_INSTALL_MAX_ATTEMPTS={VM_MISE_INSTALL_MAX_ATTEMPTS} "
            f"MISE_INSTALL_TIMEOUT_SECONDS={VM_MISE_INSTALL_TIMEOUT_SECONDS} "
            "MISE_INSTALL_RETRY_DELAY_SECONDS="
            f"{VM_MISE_INSTALL_RETRY_DELAY_SECONDS} "
            f"CODEX_DESKTOP_BUILD_ATTEMPTS={VM_CODEX_DESKTOP_BUILD_ATTEMPTS} "
            "CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS="
            f"{VM_CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS} "
            "CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS="
            f"{VM_CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS} "
            f"./bootstrap.sh --profile {suite.profile} "
            f"--inventory {inventory} "
            f"--conflict-policy backup --report-dir {remote_report} "
            f"--report-format json{apply_boot_artifacts}"
        )
        try:
            self._run_checked(
                record,
                f"bootstrap-{report}",
                self._remote_shell(command),
                FailureCategory.BOOTSTRAP_FAILED,
                timeout_seconds=timeout_seconds,
                idle_timeout_seconds=idle_timeout_seconds,
            )
        finally:
            try:
                self._collect_pacman_cache(record)
            except VMError as error:
                record.setdefault("observations", {})["pacman_cache_collect"] = {
                    "status": "failed",
                    "error": str(error),
                }
                record["updated_at"] = utc_now()
                self._write_record(record)
                self._audit(
                    "vm_collect_pacman_cache",
                    run_id=record["run_id"],
                    result="failed",
                )
        packages = (
            self._guest(record)
            .exec(self._remote_shell("pacman -Qq | LC_ALL=C sort"), timeout=120)
            .stdout
        )
        package_hash = sha256(packages.encode()).hexdigest()
        observations = record.setdefault("observations", {})
        observations[f"package_hash_{report}"] = package_hash
        self._write_record(record)

    def _run_postflight(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        report = str(values.get("report", "current"))
        if not re.fullmatch(r"[a-z0-9-]+", report):
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid postflight report name"
            )
        suite = load_suite(record["suite"], self.paths)
        destination = REMOTE_ARTIFACTS / f"postflight-{report}.json"
        inventory = f"{REMOTE_SOURCE}/ansible/inventory/hosts.yml"
        if values.get("inventory") == "runtime":
            inventory = str(record.get("observations", {}).get("runtime_inventory", ""))
            if not inventory:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "runtime inventory has not been generated",
                )
        command = (
            f"cd {REMOTE_SOURCE} && scripts/postflight.sh --profile {suite.profile} "
            f"--inventory {inventory} "
            f"--format json --output {destination}"
        )
        argv = self._remote_shell(command)
        if record.get("observations", {}).get("greetd_login_at"):
            argv = self._graphical_shell(command)
        self._run_checked(
            record,
            f"postflight-{report}",
            argv,
            FailureCategory.POSTFLIGHT_FAILED,
        )
        record.setdefault("observations", {})["last_postflight"] = str(destination)
        self._write_record(record)

    def _seed_sysstat_schema_migration(self, record: dict[str, Any]) -> None:
        minimum_seconds_before_midnight = REPEAT_BOOTSTRAP_TIMEOUT_SECONDS + 15 * 60
        script = f"""
set -euo pipefail

day=$(date +%d)
now=$(date +%s)
next_midnight=$(date -d tomorrow +%s)
((next_midnight - now > {minimum_seconds_before_midnight})) || {{
  echo 'Not enough time remains before midnight for the sysstat fixture.' >&2
  exit 1
}}

current=/var/log/sa/sa${{day}}
managed_before=/var/log/sa/.enoshima-fixture-managed-before-sa${{day}}
[[ -s $current && ! -e $managed_before ]]

restore_fixture() {{
  status=$?
  if ((status != 0)); then
    if [[ -e $managed_before ]]; then
      mv -f -- "$managed_before" "$current"
      chown root:root "$current"
      chmod 0600 "$current"
    fi
    systemctl start sysstat-collect.timer >/dev/null 2>&1 || true
  fi
  exit "$status"
}}
trap restore_fixture EXIT

systemctl stop sysstat-collect.timer sysstat-collect.service
mv -- "$current" "$managed_before"
timeout 30 /usr/lib/sa/sadc -F -L 1 1 "$current"
chown root:root "$current"
chmod 0600 "$current"

set +e
timeout 30 /usr/bin/sar -d -f "$current" >/dev/null 2>&1
disk_status=$?
timeout 30 /usr/bin/sar -m CPU,FREQ,TEMP -f "$current" >/dev/null 2>&1
power_status=$?
set -e
((disk_status != 0 && disk_status != 124))
((power_status != 0 && power_status != 124))

fixture_sha=$(sha256sum "$current" | awk '{{print $1}}')
[[ $fixture_sha =~ ^[0-9a-f]{{64}}$ ]]
printf '{{"day":"%s","sha256":"%s"}}\n' "$day" "$fixture_sha"
trap - EXIT
"""
        result = self._run_checked(
            record,
            "seed-sysstat-schema-migration",
            ["sudo", "-n", "bash", "-ceu", script],
            FailureCategory.HARNESS_ERROR,
            timeout_seconds=120,
        )
        try:
            fixture = json.loads(str(result["stdout"]))
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "sysstat schema fixture returned invalid metadata",
            ) from error
        if (
            not isinstance(fixture, dict)
            or not re.fullmatch(r"[0-9]{2}", str(fixture.get("day", "")))
            or not re.fullmatch(r"[0-9a-f]{64}", str(fixture.get("sha256", "")))
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "sysstat schema fixture metadata is invalid",
                {"fixture": fixture},
            )
        record.setdefault("observations", {})["sysstat_schema_fixture"] = fixture
        self._write_record(record)

    def _assert_sysstat_schema_migration(self, record: dict[str, Any]) -> None:
        fixture = record.get("observations", {}).get("sysstat_schema_fixture")
        if not isinstance(fixture, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "sysstat schema fixture metadata is unavailable",
            )
        day = str(fixture.get("day", ""))
        fixture_sha = str(fixture.get("sha256", ""))
        if not re.fullmatch(r"[0-9]{2}", day) or not re.fullmatch(
            r"[0-9a-f]{64}", fixture_sha
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "sysstat schema fixture metadata is invalid",
            )

        script = f"""
set -euo pipefail

day={shlex.quote(day)}
expected_sha={shlex.quote(fixture_sha)}
current=/var/log/sa/sa${{day}}
managed_before=/var/log/sa/.enoshima-fixture-managed-before-sa${{day}}
[[ -s $current ]]
[[ $(sha256sum "$current" | awk '{{print $1}}') != "$expected_sha" ]]

match=
matches=0
while IFS= read -r -d '' candidate; do
  if [[ $(sha256sum "$candidate" | awk '{{print $1}}') == "$expected_sha" ]]; then
    match=$candidate
    ((matches += 1))
  fi
done < <(
  find /var/log/sa -mindepth 2 -maxdepth 2 -type f \
    -path "/var/log/sa/.enoshima-migrated-*/sa${{day}}" -print0
)
((matches == 1))
archive_dir=$(dirname -- "$match")
[[ $(stat -c '%U:%G:%a' "$archive_dir") == root:root:700 ]]
[[ $(stat -c '%U:%G:%a' "$match") == root:root:600 ]]

set +e
timeout 30 /usr/bin/sar -d -f "$match" >/dev/null 2>&1
disk_status=$?
timeout 30 /usr/bin/sar -m CPU,FREQ,TEMP -f "$match" >/dev/null 2>&1
power_status=$?
set -e
((disk_status != 0 && disk_status != 124))
((power_status != 0 && power_status != 124))

timeout 30 /usr/bin/sar -d -f "$current" >/dev/null
timeout 30 /usr/bin/sar -m CPU,FREQ,TEMP -f "$current" >/dev/null
systemctl is-enabled --quiet sysstat-collect.timer
systemctl is-active --quiet sysstat-collect.timer
[[ $(systemctl show sysstat-collect.service -P Result) == success ]]

rm -f -- "$managed_before"
printf '%s\n' "$match"
"""
        result = self._run_checked(
            record,
            "assert-sysstat-schema-migration",
            ["sudo", "-n", "bash", "-ceu", script],
            FailureCategory.POSTFLIGHT_FAILED,
            timeout_seconds=120,
        )
        migrated_path = str(result["stdout"]).strip()
        if not migrated_path.startswith("/var/log/sa/.enoshima-migrated-"):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "sysstat migration assertion returned an invalid archive path",
                {"path": migrated_path},
            )
        record.setdefault("observations", {})["sysstat_schema_migrated_path"] = (
            migrated_path
        )
        self._write_record(record)

    def _assert_idempotent(self, record: dict[str, Any]) -> None:
        observations = record.get("observations", {})
        if observations.get("package_hash_first") != observations.get(
            "package_hash_second"
        ):
            raise VMError(
                FailureCategory.IDEMPOTENCY_FAILED,
                "installed package set changed during the second bootstrap",
            )
        report_path = REMOTE_ARTIFACTS / "bootstrap-second" / "bootstrap.json"
        report = parse_json_result(
            self._guest(record).exec(["cat", str(report_path)]),
            "second bootstrap report",
        )
        assert isinstance(report, dict)
        changes: list[dict[str, object]] = []
        for step in report.get("steps", []):
            label = str(step.get("label", ""))
            if (
                "Ansible desired state" not in label
                and "desktop expansion" not in label
            ):
                continue
            log_path = step.get("log")
            if not log_path:
                continue
            body = self._guest(record).exec(["cat", str(log_path)]).stdout
            counts = [int(value) for value in re.findall(r"changed=(\d+)", body)]
            if not counts:
                changes.append({"step": label, "reason": "missing Ansible recap"})
            elif any(counts):
                changes.append({"step": label, "changed": counts})

        diff = self._guest(record).exec(
            [
                "chezmoi",
                "--config",
                "/dev/null",
                "--config-format",
                "toml",
                "--source",
                str(REMOTE_SOURCE),
                "--persistent-state",
                "/home/kentakang/.enoshima/chezmoi-state.boltdb",
                "diff",
                "--exclude",
                "scripts",
            ],
            timeout=180,
            check=False,
        )
        if diff.returncode or diff.stdout.strip():
            changes.append(
                {
                    "step": "chezmoi diff",
                    "exit_code": diff.returncode,
                    "output": diff.stdout[-4000:],
                }
            )
        if changes:
            raise VMError(
                FailureCategory.IDEMPOTENCY_FAILED,
                "the second bootstrap was not idempotent",
                {"unexpected_changes": changes},
            )

    def _assert_expected_skips(self, record: dict[str, Any]) -> None:
        suite = load_suite(record["suite"], self.paths)
        path = record.get("observations", {}).get("last_postflight")
        if not path:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "no postflight report is available for skip validation",
            )
        report = parse_json_result(
            self._guest(record).exec(["cat", str(path)]), "postflight report"
        )
        assert isinstance(report, dict)
        actual = {
            check["id"]
            for check in report.get("checks", [])
            if check.get("status") == "skip"
        }
        unexpected = sorted(actual - suite.allowed_skips)
        if suite.fail_on_unexpected_skip and unexpected:
            raise VMError(
                FailureCategory.POSTFLIGHT_FAILED,
                "postflight contains unexpected skipped checks",
                {
                    "unexpected_skips": unexpected,
                    "allowed": sorted(suite.allowed_skips),
                },
            )

    @mutation_guard
    def reboot(self, run_id: str, timeout_seconds: int = 600) -> dict[str, object]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        before = guest.exec(["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
        domain_uuid = self._require_recorded_domain_uuid(record)
        self.backend.reboot(record["domain"], domain_uuid)
        guest.wait_ssh_cycle(timeout_seconds)
        self.backend.wait_guest_agent(
            record["domain"], domain_uuid, min(timeout_seconds, 300)
        )
        after = guest.exec(["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
        if not before or before == after:
            raise VMError(
                FailureCategory.REBOOT_FAILED,
                "guest boot ID did not change after reboot",
            )
        self._audit("vm_reboot", run_id=run_id)
        return {"before_boot_id": before, "after_boot_id": after}

    def _wait_for_power_clients(
        self,
        record: dict[str, Any],
        *,
        timeout_seconds: int = 90,
    ) -> list[dict[str, Any]]:
        command = self._hypr_command(
            "hyprctl -j clients | jq -c '[.[] | "
            "select((.mapped // true) == true) | "
            'select((.class // "") != "xembed-sni-proxy") | '
            'select((.initialClass // "") != "xembed-sni-proxy") | '
            'select((.workspace.name // "") != "special:tray") | '
            'select((.title // "") == "Enoshima Power Fixture") | '
            "{address,class,initialClass,title,pid}]'"
        )
        deadline = time.monotonic() + timeout_seconds
        last_clients: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            result = self._guest(record).exec_retryable(
                command, timeout=15, check=False
            )
            if result.returncode == 0:
                try:
                    document = json.loads(result.stdout)
                except json.JSONDecodeError:
                    document = []
                if isinstance(document, list):
                    last_clients = [
                        client for client in document if isinstance(client, dict)
                    ]
                    if last_clients:
                        return last_clients
            time.sleep(1)
        raise VMError(
            FailureCategory.REBOOT_FAILED,
            "no closeable application client appeared after graphical login",
            {"last_clients": last_clients},
        )

    def _start_power_client_fixture(self, record: dict[str, Any]) -> None:
        """Open a real Wayland client instead of relying on app first-run UI."""
        fixture_command = (
            "ghostty --confirm-close-surface=false "
            "--title='Enoshima Power Fixture' "
            "-e sh -lc 'exec sleep infinity'"
        )
        launch = self._hypr_dispatch(f"hl.dsp.exec_cmd({json.dumps(fixture_command)})")
        result = self._guest(record).exec(
            self._hypr_command(launch), timeout=30, check=False
        )
        if result.returncode != 0:
            raise VMError(
                FailureCategory.REBOOT_FAILED,
                "could not start the closeable desktop-power fixture",
                {"stderr": result.stderr[-2000:]},
            )

    def _reboot_via_desktop_power(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        iterations = values.get("iterations", 1)
        if not isinstance(iterations, int) or not 1 <= iterations <= 10:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "desktop power reboot iterations must be between 1 and 10",
            )
        guest = self._guest(record)
        results: list[dict[str, object]] = []
        for iteration in range(1, iterations + 1):
            self._start_power_client_fixture(record)
            clients_before = self._wait_for_power_clients(record)
            before = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"]
            ).stdout.strip()
            log_path = REMOTE_ARTIFACTS / f"desktop-power-reboot-{iteration}.jsonl"
            guest.exec(
                ["install", "-d", "-m", "0700", str(REMOTE_ARTIFACTS)],
                timeout=15,
            )
            # Dispatch through the compositor so login1/polkit evaluates the
            # request as coming from the active local Wayland session. A
            # process forked directly by SSH is correctly classified as a
            # remote session and cannot exercise the real Power Menu path.
            power_command = f"desktop-power reboot >{log_path} 2>&1"
            launch = self._hypr_dispatch(
                f"hl.dsp.exec_cmd({json.dumps(power_command)})"
            )
            launched = guest.exec(self._hypr_command(launch), timeout=30, check=False)
            if launched.returncode != 0:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "could not dispatch reboot through desktop-power",
                    {
                        "iteration": iteration,
                        "stderr": launched.stderr[-2000:],
                    },
                )
            guest.wait_ssh_cycle(600)
            self.backend.wait_guest_agent(
                record["domain"], self._require_recorded_domain_uuid(record), 300
            )
            after = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"]
            ).stdout.strip()
            if not before or before == after:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "desktop-power did not change the guest boot ID",
                    {"iteration": iteration, "boot_id": before},
                )
            self._login_greetd(record)
            verify_command = self._remote_shell(
                "test ! -e ~/.local/state/enoshima/power/pending.json; "
                "jq -e --arg before "
                + shlex.quote(before)
                + " --arg after "
                + shlex.quote(after)
                + ' \'.status == "succeeded" and .action == "reboot" '
                "and .boot_id_before == $before and .boot_id_after == $after' "
                "~/.local/state/enoshima/power/last-result.json"
            )
            verify_deadline = time.monotonic() + 30
            while True:
                verification = guest.exec(verify_command, timeout=15, check=False)
                if verification.returncode == 0 or time.monotonic() >= verify_deadline:
                    break
                time.sleep(1)
            if verification.returncode != 0:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "desktop-power checkpoint was not verified after login",
                    {
                        "iteration": iteration,
                        "stderr": verification.stderr[-2000:],
                    },
                )
            results.append(
                {
                    "before_boot_id": before,
                    "after_boot_id": after,
                    "closeable_clients": clients_before,
                }
            )
        record.setdefault("observations", {})["desktop_power_reboots"] = results
        self._write_record(record)

    @staticmethod
    def _hypr_command(command: str) -> list[str]:
        shell = (
            "uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "manager_wayland=; manager_sig=; "
            "while IFS= read -r entry; do case $entry in "
            "WAYLAND_DISPLAY=*) manager_wayland=${entry#*=} ;; "
            "HYPRLAND_INSTANCE_SIGNATURE=*) manager_sig=${entry#*=} ;; "
            "esac; done < <(systemctl --user show-environment); "
            "instances=$(hyprctl -j instances 2>/dev/null); "
            'pair=$(printf %s "$instances" | jq -r '
            '--arg sig "$manager_sig" --arg wl "$manager_wayland" '
            "'map(select(.instance == $sig and .wl_socket == $wl)) | first | "
            "if . == null then empty else [.instance, .wl_socket] | @tsv end'); "
            'if test -z "$pair"; then pair=$(printf %s "$instances" | jq -r '
            '\'map(select((.instance | type) == "string" and '
            '(.wl_socket | type) == "string")) | sort_by(.time // 0) | last | '
            "if . == null then empty else [.instance, .wl_socket] | @tsv end'); fi; "
            'read -r sig wayland <<<"$pair"; '
            "case $sig in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac; "
            "case $wayland in wayland-[0-9]*) ;; *) exit 1 ;; esac; "
            'test -S "$runtime/$wayland"; '
            'test -S "$runtime/hypr/$sig/.socket.sock"; '
            "export WAYLAND_DISPLAY=$wayland; "
            "export HYPRLAND_INSTANCE_SIGNATURE=$sig; "
            'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:'
            '/usr/local/bin:/usr/bin"; ' + command
        )
        return ["bash", "-lc", shell]

    @staticmethod
    def _hypr_dispatch(expression: str) -> str:
        """Build a Hyprland 0.55+ Lua dispatcher command for the guest shell."""
        return f"hyprctl dispatch {shlex.quote(expression)}"

    def query_desktop(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        result: dict[str, object] = {}
        for name in (
            "monitors",
            "workspaces",
            "clients",
            "activewindow",
            "activeworkspace",
            "devices",
        ):
            command = self._hypr_command(f"hyprctl -j {name}")
            value = guest.exec_retryable(command, timeout=30, check=False)
            if value.returncode:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    f"hyprctl query failed: {name}",
                    {"stderr": value.stderr[-2000:]},
                )
            result[name] = json.loads(value.stdout)
        self._audit("vm_query_desktop", run_id=run_id)
        return result

    def query_desktop_bounded(self, run_id: str) -> dict[str, object]:
        result = self.query_desktop(run_id)
        record = self.load_record(run_id)
        artifact = (
            Path(record["artifact_dir"])
            / "hyprctl"
            / f"manual-query-{uuid.uuid4().hex[:12]}.json"
        )
        artifact.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        artifact.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        artifact.chmod(0o600)
        response: dict[str, object] = {
            "schema": 1,
            "artifactPath": str(artifact),
            "desktop": result,
        }
        if len(json.dumps(response, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES:
            return response

        def count(value: object) -> int:
            return len(value) if isinstance(value, (dict, list)) else 0

        def compact(value: object) -> dict[str, object]:
            if not isinstance(value, dict):
                return {}
            result: dict[str, object] = {}
            for key in ("address", "class", "title", "id", "name", "monitor"):
                candidate = value.get(key)
                if isinstance(candidate, str):
                    result[key] = candidate[:1024]
                elif isinstance(candidate, (int, float, bool)):
                    result[key] = candidate
            return result

        return {
            "schema": 1,
            "truncated": True,
            "artifactPath": str(artifact),
            "counts": {
                key: count(result.get(key))
                for key in ("monitors", "workspaces", "clients", "devices")
            },
            "activeWindow": compact(result.get("activewindow")),
            "activeWorkspace": compact(result.get("activeworkspace")),
        }

    def _configure_virtual_displays(self, record: dict[str, Any], config: Any) -> None:
        if not isinstance(config, dict) or not isinstance(config.get("monitors"), list):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "configure_virtual_displays requires a monitor list",
            )
        if not config["monitors"]:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "configure_virtual_displays requires at least one monitor",
            )
        configured_names: set[str] = set()
        validated_monitors: list[tuple[str, str, str, str]] = []
        for monitor in config["monitors"]:
            if not isinstance(monitor, dict):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor")
            name = str(monitor.get("name", ""))
            mode = str(monitor.get("mode", ""))
            position = str(monitor.get("position", ""))
            scale = str(monitor.get("scale", ""))
            if not re.fullmatch(r"HEADLESS-[A-Z]+", name):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor name")
            if name in configured_names:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "duplicate monitor name",
                    {"name": name},
                )
            configured_names.add(name)
            if not re.fullmatch(r"[0-9]{3,5}x[0-9]{3,5}@[0-9]{2,3}", mode):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor mode")
            if not re.fullmatch(r"-?[0-9]{1,5}x-?[0-9]{1,5}", position):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor position")
            if not re.fullmatch(r"[0-9](?:\.[0-9]+)?", scale):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor scale")
            validated_monitors.append((name, mode, position, scale))

        expected_topology: dict[str, dict[str, int | float]] = {}
        for name, mode, position, scale in validated_monitors:
            width, height = (int(value) for value in mode.split("@", 1)[0].split("x"))
            x, y = (int(value) for value in position.split("x"))
            expected_topology[name] = {
                "width": width,
                "height": height,
                "x": x,
                "y": y,
                "scale": float(scale),
            }

        def topology_failures(monitors: list[dict[str, Any]]) -> list[str]:
            by_name = {str(monitor.get("name", "")): monitor for monitor in monitors}
            failures: list[str] = []
            for name, expected in expected_topology.items():
                actual = by_name.get(name)
                if actual is None:
                    failures.append(f"missing configured output {name}")
                    continue
                if bool(actual.get("disabled", False)):
                    failures.append(f"configured output {name} is disabled")
                    continue
                for key in ("width", "height", "x", "y"):
                    try:
                        observed = int(actual.get(key, -1))
                    except (TypeError, ValueError):
                        observed = -1
                    if observed != expected[key]:
                        failures.append(
                            f"{name}.{key}={observed}, expected {expected[key]}"
                        )
                try:
                    observed_scale = float(actual.get("scale", 0))
                except (TypeError, ValueError):
                    observed_scale = 0
                if abs(observed_scale - float(expected["scale"])) > 0.01:
                    failures.append(
                        f"{name}.scale={observed_scale}, expected {expected['scale']}"
                    )
            if config.get("disable_unlisted"):
                for name, actual in by_name.items():
                    if name not in configured_names and not bool(
                        actual.get("disabled", False)
                    ):
                        failures.append(f"unlisted output {name} is active")
            return failures

        guest = self._guest(record)
        deadline = time.monotonic() + 30
        monitor_state: list[dict[str, Any]] = []
        observed_names: set[str] = set()
        last_query_error = ""
        while time.monotonic() < deadline:
            monitors = guest.exec_retryable(
                self._hypr_command("hyprctl -j monitors all"),
                timeout=10,
                check=False,
            )
            if monitors.returncode:
                last_query_error = monitors.stderr[-2000:]
            else:
                try:
                    candidate = json.loads(monitors.stdout)
                except json.JSONDecodeError as error:
                    last_query_error = str(error)
                else:
                    if isinstance(candidate, list):
                        monitor_state = [
                            monitor
                            for monitor in candidate
                            if isinstance(monitor, dict)
                        ]
                        observed_names = {
                            str(monitor.get("name", "")) for monitor in monitor_state
                        }
                        break
                    else:
                        last_query_error = "monitor response is not a list"
            time.sleep(0.1)
        else:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "cannot inspect virtual outputs before configuration",
                {
                    "observed": sorted(observed_names),
                    "error": last_query_error,
                },
            )

        # An identical live topology needs no compositor mutation. In
        # particular, avoid reissuing output creation before this comparison:
        # Hyprland can deliver that wl_output event after the command returns.
        if not topology_failures(monitor_state):
            consecutive_ready = 1
            deadline = time.monotonic() + 30
            while consecutive_ready < 10 and time.monotonic() < deadline:
                time.sleep(0.1)
                monitors = guest.exec_retryable(
                    self._hypr_command("hyprctl -j monitors all"),
                    timeout=10,
                    check=False,
                )
                if monitors.returncode:
                    consecutive_ready = 0
                    last_query_error = monitors.stderr[-2000:]
                    continue
                try:
                    candidate = json.loads(monitors.stdout)
                except json.JSONDecodeError as error:
                    consecutive_ready = 0
                    last_query_error = str(error)
                    continue
                if not isinstance(candidate, list):
                    consecutive_ready = 0
                    last_query_error = "monitor response is not a list"
                    continue
                monitor_state = [
                    monitor for monitor in candidate if isinstance(monitor, dict)
                ]
                observed_names = {
                    str(monitor.get("name", "")) for monitor in monitor_state
                }
                if topology_failures(monitor_state):
                    break
                consecutive_ready += 1
            if consecutive_ready >= 10:
                return
            if not topology_failures(monitor_state):
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    "cannot confirm a stable virtual output topology",
                    {"error": last_query_error, "monitors": monitor_state},
                )

        # Only create outputs that are genuinely absent. Reissuing `output
        # create` for an existing headless output can emit a delayed wl_output
        # event after an otherwise successful monitor-rule batch.
        missing_names = configured_names - observed_names
        for name, _mode, _position, _scale in validated_monitors:
            if name not in missing_names:
                continue
            create = guest.exec(
                self._hypr_command(f"hyprctl output create headless {name}"),
                timeout=30,
                check=False,
            )
            if create.returncode:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    f"cannot create virtual output: {name}",
                    {"stderr": create.stderr[-2000:]},
                )

        if missing_names:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                monitors = guest.exec_retryable(
                    self._hypr_command("hyprctl -j monitors all"),
                    timeout=10,
                    check=False,
                )
                if monitors.returncode:
                    last_query_error = monitors.stderr[-2000:]
                else:
                    try:
                        candidate = json.loads(monitors.stdout)
                    except json.JSONDecodeError as error:
                        last_query_error = str(error)
                    else:
                        if isinstance(candidate, list):
                            monitor_state = [
                                monitor
                                for monitor in candidate
                                if isinstance(monitor, dict)
                            ]
                            observed_names = {
                                str(monitor.get("name", ""))
                                for monitor in monitor_state
                            }
                            if configured_names.issubset(observed_names):
                                break
                        else:
                            last_query_error = "monitor response is not a list"
                time.sleep(0.1)
            else:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    "virtual outputs did not appear before configuration",
                    {
                        "expected": sorted(configured_names),
                        "observed": sorted(observed_names),
                        "error": last_query_error,
                    },
                )

        monitor_expressions = [
            self._monitor_eval_expression(name, mode, position, scale)
            for name, mode, position, scale in validated_monitors
        ]
        if config.get("disable_unlisted"):
            for monitor in monitor_state:
                output = str(monitor.get("name", ""))
                if output in configured_names:
                    continue
                if not re.fullmatch(r"[A-Za-z0-9._-]+", output):
                    raise VMError(
                        FailureCategory.DESKTOP_SESSION_FAILED,
                        "Hyprland reported an unsafe output name",
                        {"output": output},
                    )
                monitor_expressions.append(self._monitor_disable_expression(output))

        # Register every rule in one compositor turn. Hyprland coalesces their
        # deferred monitor-state refresh so wildcard geometry cannot win
        # between per-output updates.
        monitor_batch = "; ".join(monitor_expressions)
        if monitor_batch:
            self._run_checked(
                record,
                "configure-virtual-displays",
                self._hypr_command("hyprctl eval " + shlex.quote(monitor_batch)),
                FailureCategory.DESKTOP_SESSION_FAILED,
                timeout_seconds=30,
            )

        # Retain disable rules for already inactive outputs and require a quiet
        # window after applying them. A single successful sample can precede a
        # delayed wl_output event and wildcard preferred/auto reconfiguration.
        deadline = time.monotonic() + 30
        last_topology: list[dict[str, Any]] = []
        last_failures: list[str] = []
        consecutive_ready = 0
        while time.monotonic() < deadline:
            monitors = guest.exec_retryable(
                self._hypr_command("hyprctl -j monitors all"),
                timeout=10,
                check=False,
            )
            if monitors.returncode:
                last_failures = [monitors.stderr[-2000:]]
                time.sleep(0.1)
                continue
            try:
                candidate = json.loads(monitors.stdout)
            except json.JSONDecodeError as error:
                last_failures = [str(error)]
                time.sleep(0.1)
                continue
            if not isinstance(candidate, list):
                last_failures = ["monitor response is not a list"]
                time.sleep(0.1)
                continue
            last_topology = [
                monitor for monitor in candidate if isinstance(monitor, dict)
            ]
            failures = topology_failures(last_topology)
            if not failures:
                consecutive_ready += 1
                if consecutive_ready >= 10:
                    return
            else:
                consecutive_ready = 0
                last_failures = failures
            time.sleep(0.1)

        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            "virtual outputs did not reach the requested topology",
            {"failures": last_failures, "monitors": last_topology},
        )

    @staticmethod
    def _monitor_eval_expression(
        name: str, mode: str, position: str, scale: str
    ) -> str:
        return (
            'hl.monitor({ output = "'
            + name
            + '", mode = "'
            + mode
            + '", position = "'
            + position
            + '", scale = '
            + scale
            + " })"
        )

    @staticmethod
    def _monitor_disable_expression(name: str) -> str:
        return f'hl.monitor({{ output = "{name}", disabled = true }})'

    @staticmethod
    def _decoration_allowlist_expression(allowlist: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9._,*?-]+(?:,[A-Za-z0-9._,*?-]+)*", allowlist):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid decoration allowlist",
            )
        return (
            'hl.config({ plugin = { enoshima_decoration = { allowlist = "'
            + allowlist
            + '" } } })'
        )

    def _wait_for_client(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        pattern = str(values.get("class", ""))
        workspace = str(values.get("workspace", ""))
        if not pattern or not workspace:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "wait_for_client requires class and workspace",
            )
        try:
            matcher = re.compile(pattern, re.IGNORECASE)
        except re.error as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid client regex"
            ) from error
        guest = self._guest(record)
        deadline = time.monotonic() + int(values.get("timeout_seconds", 120))
        last: list[object] = []
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j clients"), timeout=15, check=False
            )
            if result.returncode == 0:
                last = json.loads(result.stdout)
                for client in last:
                    class_name = str(client.get("class", ""))
                    initial_class = str(client.get("initialClass", ""))
                    client_workspace = str(client.get("workspace", {}).get("name", ""))
                    if (
                        matcher.search(class_name) or matcher.search(initial_class)
                    ) and client_workspace == workspace:
                        return
            time.sleep(2)
        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            "expected client did not appear on its routed workspace",
            {"class": pattern, "workspace": workspace, "clients": last},
        )

    def _assert_desktop_state(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        expected_monitors = values.get("monitors", [])
        if not isinstance(expected_monitors, list):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor assertions")
        desktop = self.query_desktop(record["run_id"])
        actual = {monitor["name"]: monitor for monitor in desktop["monitors"]}
        failures: list[str] = []
        if "monitor_count" in values and len(actual) != int(values["monitor_count"]):
            failures.append(
                f"monitor count={len(actual)}, expected {values['monitor_count']}"
            )
        for expected in expected_monitors:
            name = str(expected["name"])
            monitor = actual.get(name)
            if monitor is None:
                failures.append(f"missing monitor {name}")
                continue
            for key in ("width", "height", "x", "y"):
                if key in expected and int(monitor.get(key, -1)) != int(expected[key]):
                    failures.append(
                        f"{name}.{key}={monitor.get(key)!r}, expected {expected[key]!r}"
                    )
            if (
                "scale" in expected
                and abs(float(monitor.get("scale", 0)) - float(expected["scale"]))
                > 0.01
            ):
                failures.append(
                    f"{name}.scale={monitor.get('scale')!r}, "
                    f"expected {expected['scale']!r}"
                )
        active_workspace = str(desktop.get("activeworkspace", {}).get("name", ""))
        if values.get("active_workspace") and active_workspace != str(
            values["active_workspace"]
        ):
            failures.append(
                f"active workspace={active_workspace!r}, "
                f"expected {values['active_workspace']!r}"
            )
        devices = desktop.get("devices", {})
        if values.get("require_keyboard") and not devices.get("keyboards"):
            failures.append("no keyboard reported by Hyprland")
        if failures:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "desktop structural assertions failed",
                {"failures": failures, "desktop": desktop},
            )

    def _wait_for_layer(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        namespace = str(values.get("namespace", ""))
        if not re.fullmatch(r"[a-z0-9-]+", namespace):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid layer namespace")
        guest = self._guest(record)
        deadline = time.monotonic() + int(values.get("timeout_seconds", 60))
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j layers"), timeout=15, check=False
            )
            if result.returncode == 0:
                layers = json.loads(result.stdout)
                namespaces: list[str] = []

                def visit(value: object) -> None:
                    if isinstance(value, dict):
                        if isinstance(value.get("namespace"), str):
                            namespaces.append(value["namespace"])
                        for child in value.values():
                            visit(child)
                    elif isinstance(value, list):
                        for child in value:
                            visit(child)

                visit(layers)
                if namespace in namespaces:
                    return
            time.sleep(1)
        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            f"expected layer did not appear: {namespace}",
        )

    def _wait_for_ui_review_layer(
        self,
        record: dict[str, Any],
        output: str,
        namespace: str,
        *,
        present: bool,
        timeout_seconds: float = 20,
        service_unit: str | None = None,
        allow_transparent: bool = False,
        max_width: float | None = None,
        max_height: float | None = None,
    ) -> None:
        if service_unit not in {None, "hyprshell.service", "vicinae.service"}:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid UI review layer service",
            )
        if (max_width is None) != (max_height is None) or (
            max_width is not None and (max_width <= 0 or max_height <= 0)
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid UI review layer geometry bound",
            )
        if not present and (allow_transparent or max_width is not None):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "absent UI layers cannot have appearance constraints",
            )
        guest = self._guest(record)
        deadline = time.monotonic() + timeout_seconds
        last_layers: object = {}
        last_service_pid = 0
        last_mapping_state: bool | None = None
        last_mapping_response = ""
        consecutive_ready = 0
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j layers"), timeout=15, check=False
            )
            if result.returncode == 0:
                try:
                    last_layers = json.loads(result.stdout)
                except json.JSONDecodeError:
                    last_layers = {}
                output_layers = (
                    last_layers.get(output, {}) if isinstance(last_layers, dict) else {}
                )
                output_known = isinstance(last_layers, dict) and output in last_layers
                matching_layers: list[dict[str, object]] = []

                def visit(value: object) -> None:
                    if isinstance(value, dict):
                        candidate = value.get("namespace")
                        if candidate == namespace:
                            matching_layers.append(value)
                        for child in value.values():
                            visit(child)
                    elif isinstance(value, list):
                        for child in value:
                            visit(child)

                visit(output_layers)
                if output_known:
                    last_mapping_state, last_mapping_response = (
                        self._ui_review_layer_mapping_state(
                            record,
                            namespace,
                            output,
                        )
                    )
                else:
                    last_mapping_state = None
                    last_mapping_response = "output is absent from hyprctl layers"

                if not present:
                    ready = last_mapping_state is False
                    consecutive_ready = consecutive_ready + 1 if ready else 0
                    if consecutive_ready >= 2:
                        return
                    time.sleep(0.1)
                    continue
                if present:

                    def numeric(value: object) -> float:
                        try:
                            return float(value)
                        except (TypeError, ValueError):
                            return 0.0

                    if service_unit is not None:
                        service = guest.exec_retryable(
                            self._hypr_command(
                                "systemctl --user show --property MainPID --value "
                                + service_unit
                            ),
                            timeout=10,
                            check=False,
                        )
                        if service.returncode == 0:
                            try:
                                last_service_pid = int(service.stdout.strip())
                            except ValueError:
                                last_service_pid = 0
                    ready = (
                        any(
                            numeric(layer.get("w")) > 0
                            and numeric(layer.get("h")) > 0
                            and (
                                allow_transparent
                                or "alpha" not in layer
                                or numeric(layer.get("alpha")) > 0
                            )
                            and (
                                max_width is None
                                or (
                                    numeric(layer.get("w")) <= max_width
                                    and numeric(layer.get("h")) <= max_height
                                )
                            )
                            and numeric(layer.get("pid")) > 0
                            and (
                                service_unit is None
                                or numeric(layer.get("pid")) == last_service_pid
                            )
                            for layer in matching_layers
                        )
                        and last_mapping_state is True
                    )
                    consecutive_ready = consecutive_ready + 1 if ready else 0
                    if consecutive_ready >= 2:
                        return
            time.sleep(0.1)
        expected = "appear" if present else "disappear"
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            f"production UI layer did not {expected}",
            {
                "output": output,
                "namespace": namespace,
                "expected_present": present,
                "layers": last_layers,
                "mapped": last_mapping_state,
                "mapping_probe": last_mapping_response,
                "service_unit": service_unit,
                "service_main_pid": last_service_pid,
                "allow_transparent": allow_transparent,
                "max_width": max_width,
                "max_height": max_height,
            },
        )

    def _ui_review_layer_mapping_state(
        self,
        record: dict[str, Any],
        namespace: str,
        output: str | None = None,
    ) -> tuple[bool | None, str]:
        """Return the compositor's mapped state for a production layer.

        Hyprland 0.55's ``hyprctl -j layers`` output retains an unmapped layer
        shell resource, including its previous geometry, so namespace presence
        is not a visibility contract.  The Lua layer object exposes the actual
        ``mapped`` bit.  ``hyprctl eval`` does not return Lua values, therefore
        a private error sentinel represents the mapped branch; a plain ``ok``
        means that no matching layer is mapped.  Any other response is
        inconclusive and must never satisfy an appearance or disappearance
        postcondition.
        """

        if not re.fullmatch(r"[A-Za-z0-9._:+-]+", namespace):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid UI review layer namespace",
            )
        if output is not None and not re.fullmatch(r"[A-Za-z0-9._:+-]+", output):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid UI review layer output",
            )

        filters = [f"namespace = {json.dumps(namespace)}"]
        if output is not None:
            filters.insert(0, f"monitor = {json.dumps(output)}")
        sentinel = "__ENOSHIMA_UI_LAYER_MAPPED__"
        lua = (
            "for _, layer in ipairs(hl.get_layers({ "
            + ", ".join(filters)
            + " })) do "
            + f"if layer.mapped then error({json.dumps(sentinel)}) end "
            + "end"
        )
        result = self._guest(record).exec_retryable(
            self._hypr_command("hyprctl eval " + shlex.quote(lua)),
            timeout=15,
            check=False,
        )
        response = "\n".join(
            value.strip() for value in (result.stdout, result.stderr) if value.strip()
        )
        if result.returncode != 0:
            return None, response
        if sentinel in response:
            return True, response
        if response == "ok":
            return False, response
        return None, response

    def _ui_review_layer_present(
        self,
        record: dict[str, Any],
        namespace: str,
        output: str | None = None,
    ) -> bool:
        mapped, _response = self._ui_review_layer_mapping_state(
            record,
            namespace,
            output,
        )
        if mapped is not None:
            return mapped

        # Fail closed when the Lua probe is temporarily unavailable.  Raw
        # namespace presence can over-report a hidden GTK layer, but treating
        # it as present merely triggers the bounded close path; it can never
        # make cleanup pass.
        result = self._guest(record).exec_retryable(
            self._hypr_command("hyprctl -j layers"), timeout=15, check=False
        )
        if result.returncode != 0:
            return True
        try:
            layers: object = json.loads(result.stdout)
        except json.JSONDecodeError:
            return True
        if output is not None and isinstance(layers, dict):
            layers = layers.get(output, {})

        def contains(value: object) -> bool:
            if isinstance(value, dict):
                if value.get("namespace") == namespace:
                    return True
                return any(contains(child) for child in value.values())
            if isinstance(value, list):
                return any(contains(child) for child in value)
            return False

        return contains(layers)

    def _prepare_login(self, record: dict[str, Any]) -> None:
        secret_dir = self._run_dir(record["run_id"]) / "secrets"
        secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        password_path = secret_dir / "login-password"
        # gnome-keyring-daemon consumes every byte from stdin as the keyring
        # password.  Keep this file newline-free; chpasswd gets its own
        # line-oriented credential below.
        password_path.write_text(secrets.token_hex(16), encoding="utf-8")
        password_path.chmod(0o600)
        credential = secret_dir / "chpasswd-input"
        credential.write_text(
            f"kentakang:{password_path.read_text(encoding='utf-8').strip()}\n",
            encoding="utf-8",
        )
        credential.chmod(0o600)
        guest = self._guest(record)
        guest.upload_file(password_path, REMOTE_LOGIN_PASSWORD)
        guest.upload_file(credential, REMOTE_LOGIN_CREDENTIAL)
        try:
            self._run_checked(
                record,
                "prepare-greetd-login",
                self._remote_shell(f"sudo chpasswd < {REMOTE_LOGIN_CREDENTIAL}"),
                FailureCategory.LOGIN_SESSION_FAILED,
            )
            self._run_checked(
                record,
                "prepare-login-keyring",
                self._remote_shell(
                    "export HOME=/home/kentakang; "
                    "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
                    "export GNOME_KEYRING_CONTROL=$XDG_RUNTIME_DIR/keyring; "
                    f"gnome-keyring-daemon --unlock < {REMOTE_LOGIN_PASSWORD}"
                ),
                FailureCategory.LOGIN_SESSION_FAILED,
            )
        finally:
            credential.unlink(missing_ok=True)
            guest.exec(["unlink", str(REMOTE_LOGIN_PASSWORD)], check=False)
            guest.exec(["unlink", str(REMOTE_LOGIN_CREDENTIAL)], check=False)
        record["login_password"] = str(password_path)
        suite = record.get("suite")
        if suite in {"ui-review", "reboot"}:
            self._suppress_managed_application_autostarts(record, str(suite))
        self._write_record(record)

    def _suppress_managed_application_autostarts(
        self,
        record: dict[str, Any],
        suite: str,
    ) -> None:
        """Keep unrelated first-run apps out of deterministic acceptance lanes."""
        if suite not in {"ui-review", "reboot"}:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "application autostart suppression is not allowed for this suite",
            )
        autostart_dir = "/home/kentakang/.config/autostart"
        vicinae_suppression = (
            "systemctl --user mask --force --now vicinae.service; "
            if suite == "ui-review"
            else ""
        )
        shell = (
            "set -eu; export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            "systemctl --user mask --force --now codex-update-manager.service; "
            + vicinae_suppression
            + f"install -d -m 0700 {autostart_dir}; "
            "for entry in discord slack kakaotalk; do "
            f"printf '[Desktop Entry]\\nType=Application\\nHidden=true\\n' "
            f">{autostart_dir}/$entry.desktop; "
            f"chmod 0600 {autostart_dir}/$entry.desktop; "
            "done"
        )
        self._run_checked(
            record,
            f"suppress-{suite}-autostart",
            self._remote_shell(shell),
            (
                FailureCategory.VISUAL_ASSERTION_FAILED
                if suite == "ui-review"
                else FailureCategory.REBOOT_FAILED
            ),
        )
        record.setdefault("observations", {})[
            "managed_application_autostarts_suppressed"
        ] = {
            "suite": suite,
            "applications": ["discord", "slack", "kakaotalk"],
            "services": ["codex-update-manager.service"]
            + (["vicinae.service"] if suite == "ui-review" else []),
        }

    def _login_greetd(self, record: dict[str, Any]) -> None:
        password_path = confined_path(
            self._run_dir(record["run_id"]), Path(record.get("login_password", ""))
        )
        if not password_path.is_file():
            raise VMError(
                FailureCategory.LOGIN_SESSION_FAILED,
                "disposable greetd password is unavailable",
            )
        guest = self._guest(record)
        self._run_checked(
            record,
            "assert-greetd-active",
            ["systemctl", "is-active", "greetd.service"],
            FailureCategory.LOGIN_SESSION_FAILED,
        )
        time.sleep(10)
        self._capture_greetd_screenshot(record)
        # Enoshima Auth is intentionally password-first but still follows the
        # greetd protocol's two phases: create the managed-user session, then
        # answer the PAM password prompt. Typing before the first Enter only
        # reaches the focused Continue button and leaves the password empty.
        domain_uuid = self._require_recorded_domain_uuid(record)
        self.backend.send_keys(record["domain"], domain_uuid, ["KEY_ENTER"])
        time.sleep(1)
        self.backend.type_text(
            record["domain"],
            domain_uuid,
            password_path.read_text(encoding="utf-8").strip(),
        )
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j monitors"), timeout=15, check=False
            )
            if result.returncode == 0:
                self._assert_login_keyring(record)
                self._assert_deterministic_login_suppression(record)
                self._start_ui_review_vicinae_after_keyring(record)
                record.setdefault("observations", {})["greetd_login_at"] = utc_now()
                self._write_record(record)
                return
            time.sleep(2)
        journal = guest.exec(
            ["sudo", "journalctl", "-u", "greetd.service", "-b", "--no-pager"],
            check=False,
        )
        raise VMError(
            FailureCategory.LOGIN_SESSION_FAILED,
            "greetd did not start the user Hyprland session",
            {"journal": journal.stdout[-8000:]},
        )

    def _assert_deterministic_login_suppression(
        self,
        record: dict[str, Any],
    ) -> None:
        suite = str(record.get("suite", ""))
        if suite not in {"ui-review", "reboot"}:
            return
        services = ["codex-update-manager.service"]
        if suite == "ui-review":
            services.append("vicinae.service")
        self._run_checked(
            record,
            f"assert-{suite}-autostart-suppression",
            self._hypr_command(
                "for service in "
                + " ".join(services)
                + '; do test "$(systemctl --user is-enabled "$service")" '
                "= masked; done"
            ),
            (
                FailureCategory.VISUAL_ASSERTION_FAILED
                if suite == "ui-review"
                else FailureCategory.REBOOT_FAILED
            ),
            timeout_seconds=15,
        )

    def _start_ui_review_vicinae_after_keyring(
        self,
        record: dict[str, Any],
    ) -> None:
        """Serialize the ui-review keyring probe ahead of Vicinae startup."""
        if str(record.get("suite", "")) != "ui-review":
            return
        shell = (
            "set -u; uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
            "systemctl --user unmask vicinae.service; "
            "systemctl --user reset-failed vicinae.service; "
            "start_status=0; "
            "timeout --signal=TERM --kill-after=2s 25s "
            "systemctl --user start vicinae.service || start_status=$?; "
            "if (( start_status != 0 )); then "
            "printf 'Vicinae serialized startup failed: status=%s\\n' "
            '"$start_status" >&2; '
            "timeout 5s systemctl --user status vicinae.service --no-pager "
            ">&2 || true; "
            "timeout 5s journalctl --user -u vicinae.service -b -n 120 "
            "--no-pager -o short-monotonic >&2 || true; "
            'exit "$start_status"; fi; '
            "timeout --signal=TERM --kill-after=1s 3s "
            "vicinae ping >/dev/null"
        )
        self._run_checked(
            record,
            "start-ui-review-vicinae-after-keyring",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=40,
        )
        record.setdefault("observations", {})[
            "ui_review_vicinae_started_after_keyring_probe"
        ] = True

    def _assert_login_keyring(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        probe_id = f"{record['run_id']}-{secrets.token_hex(8)}"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus; "
            "timeout 12s bash -c 'set -euo pipefail; "
            f"probe_id={shlex.quote(probe_id)}; "
            "cleanup() { secret-tool clear enoshima-vm probe "
            'probe-id "$probe_id" >/dev/null 2>&1 || true; }; '
            "trap cleanup EXIT; "
            "printf vm-probe | secret-tool store "
            "--label=Enoshima-VM-Probe enoshima-vm probe "
            'probe-id "$probe_id" >/dev/null; '
            "value=$(secret-tool lookup enoshima-vm probe "
            'probe-id "$probe_id"); '
            'test "$value" = vm-probe; '
            "cleanup; trap - EXIT'"
        )
        result = guest.exec(self._remote_shell(shell), timeout=20, check=False)
        clients_result = guest.exec_retryable(
            self._hypr_command("hyprctl -j clients"), timeout=10, check=False
        )
        clients = (
            json.loads(clients_result.stdout) if clients_result.returncode == 0 else []
        )
        keyring_journal = guest.exec(
            self._remote_shell(
                "sudo journalctl -u greetd.service -b -o cat --no-pager | "
                "grep -F 'the password for the login keyring was invalid' || true"
            ),
            timeout=15,
            check=False,
        )
        prompts = [
            client
            for client in clients
            if "gcr-prompter" in str(client.get("class", "")).lower()
            or "unlock login keyring" in str(client.get("title", "")).lower()
        ]
        if result.returncode != 0 or prompts or keyring_journal.stdout.strip():
            raise VMError(
                FailureCategory.LOGIN_SESSION_FAILED,
                "greetd login did not unlock the GNOME login keyring",
                {
                    "secret_tool_exit_code": result.returncode,
                    "stderr": result.stderr[-2000:],
                    "prompts": prompts,
                    "journal": keyring_journal.stdout[-2000:],
                },
            )

    def _graphical_health_failures(self, record: dict[str, Any]) -> dict[str, str]:
        """Reject latent session failures that screenshots alone can hide."""
        guest = self._guest(record)
        checks = {
            "failed_system_units": [
                "systemctl",
                "--failed",
                "--no-legend",
                "--plain",
                "--state=failed",
            ],
            "failed_user_units": self._remote_shell(
                "uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
                "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
                "systemctl --user --failed --no-legend --plain --state=failed"
            ),
            "coredumps": self._remote_shell(
                "command -v coredumpctl >/dev/null || exit 0; "
                "boot_started=$(uptime -s); "
                'coredumpctl --since "$boot_started" --no-pager --no-legend '
                "list 2>/dev/null || true"
            ),
            "fatal_graphical_logs": self._remote_shell(
                "journalctl -b --no-pager -o cat 2>/dev/null | "
                "grep -Eai "
                "'(Hyprland|quickshell|qs\\[|swaync|enoshima-greeter|greetd).*'"
                "'(segmentation fault|segfault|core dumped|coredump|fatal|'"
                "'TypeError|ReferenceError|Gtk-CRITICAL)' || true"
            ),
        }
        failures: dict[str, str] = {}
        for name, argv in checks.items():
            result = guest.exec(argv, timeout=30, check=False)
            output = "\n".join(
                part.strip() for part in (result.stdout, result.stderr) if part.strip()
            )
            if result.returncode != 0 or output:
                failures[name] = output[-8000:] or f"exit code {result.returncode}"
        return failures

    def _assert_graphical_health(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        settle_seconds = values.get("settle_seconds", 0)
        required_user_units = values.get("required_user_units", [])
        if (
            not isinstance(settle_seconds, int)
            or not 0 <= settle_seconds <= 600
            or not isinstance(required_user_units, list)
            or not all(
                isinstance(unit, str)
                and re.fullmatch(r"[A-Za-z0-9@_.:-]+\.service", unit)
                for unit in required_user_units
            )
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "assert_graphical_health has invalid configuration",
            )
        deadline = time.monotonic() + settle_seconds
        while True:
            failures = self._graphical_health_failures(record)
            if failures:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    "graphical session health assertions failed",
                    failures,
                )
            if time.monotonic() >= deadline:
                break
            time.sleep(min(10.0, max(0.0, deadline - time.monotonic())))

        inactive: list[str] = []
        for unit in required_user_units:
            result = self._guest(record).exec(
                self._graphical_shell(
                    f"systemctl --user is-active --quiet {shlex.quote(unit)}"
                ),
                timeout=15,
                check=False,
            )
            if result.returncode != 0:
                inactive.append(unit)
        if inactive:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "required graphical autostart units are inactive",
                {"units": inactive},
            )

    def _capture_greetd_screenshot(self, record: dict[str, Any]) -> Path:
        """Capture the accelerated production greeter through Wayland."""
        remote = REMOTE_ARTIFACTS / "screenshots" / "greetd.png"
        guest = self._guest(record)
        guest.exec(["install", "-d", "-m", "0700", str(remote.parent)])
        shell = (
            "set -eu; "
            "uid=$(id -u greeter); runtime=/run/user/$uid; "
            'wayland=$(sudo find "$runtime" -maxdepth 1 -type s '
            "-name 'wayland-*' -printf '%f\\n' | LC_ALL=C sort | head -n1); "
            'test -n "$wayland"; '
            "capture_dir=$(mktemp -d /tmp/enoshima-greetd.XXXXXX); "
            'trap \'sudo unlink "$capture_dir/capture.png" 2>/dev/null || true; '
            'sudo rmdir "$capture_dir" 2>/dev/null || true\' EXIT; '
            'sudo chown greeter:greeter "$capture_dir"; '
            'sudo -u greeter env XDG_RUNTIME_DIR="$runtime" '
            'WAYLAND_DISPLAY="$wayland" '
            'grim "$capture_dir/capture.png"; '
            f"sudo install -o kentakang -g kentakang -m 0600 "
            f'"$capture_dir/capture.png" {remote}'
        )
        result = guest.exec(self._remote_shell(shell), timeout=60, check=False)
        if result.returncode:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "greetd compositor screenshot failed",
                {
                    "stdout": result.stdout[-3000:],
                    "stderr": result.stderr[-3000:],
                },
            )
        local = Path(record["artifact_dir"]) / "screenshots" / "greetd.png"
        guest.download(remote, local)
        self._validate_png(local)
        record.setdefault("observations", {})["greetd_screenshot"] = str(local)
        self._write_record(record)
        return local

    @staticmethod
    def _validate_png(path: Path) -> tuple[int, int]:
        header = path.read_bytes()[:24]
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "captured compositor evidence is not a PNG",
            )
        width, height = struct.unpack(">II", header[16:24])
        if width < 1280 or height < 720:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "captured compositor evidence is unexpectedly small",
                {"width": width, "height": height},
            )
        return width, height

    @mutation_guard
    def screenshot(
        self,
        run_id: str,
        name: str = "desktop",
        output: str | None = None,
    ) -> dict[str, object]:
        if not re.fullmatch(r"[a-z0-9-]+", name):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid screenshot name")
        if output is not None and not re.fullmatch(r"[A-Za-z0-9._-]+", output):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid screenshot output")
        record = self.load_record(run_id)
        remote = REMOTE_ARTIFACTS / "screenshots" / f"{name}.png"
        output_argument = f" -o {output}" if output else ""
        command = self._hypr_command(
            f"install -d -m 0700 {remote.parent}; grim{output_argument} {remote}"
        )
        result = self._guest(record).exec_retryable(command, timeout=60, check=False)
        if result.returncode:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "guest screenshot failed",
                {"stderr": result.stderr[-3000:]},
            )
        local = Path(record["artifact_dir"]) / "screenshots" / f"{name}.png"
        self._guest(record).download(remote, local)
        width, height = self._validate_png(local)
        self._audit("vm_screenshot", run_id=run_id)
        return {
            "path": str(local),
            "width": width,
            "height": height,
            "output": output,
        }

    def _write_ui_fixture_state(
        self,
        record: dict[str, Any],
        surface: str,
        state: str,
        output: str,
        extra: dict[str, object] | None = None,
    ) -> int:
        observations = record.setdefault("observations", {})
        sequence = int(observations.get("ui_fixture_sequence", 0)) + 1
        observations["ui_fixture_sequence"] = sequence
        fixture_dir = self._run_dir(record["run_id"]) / "ui-fixture"
        fixture_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        local = fixture_dir / "state.json"
        temporary = fixture_dir / "state.json.new"
        document: dict[str, object] = {
            "schema": 1,
            "surface": surface,
            "state": state,
            "output": output,
            "sequence": sequence,
        }
        if extra:
            document.update(extra)
        temporary.write_text(
            json.dumps(document, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, local)
        guest = self._guest(record)
        remote_dir = REMOTE_ROOT / "ui-fixture"
        remote_new = remote_dir / "state.json.new"
        guest.exec(["install", "-d", "-m", "0700", str(remote_dir)])
        guest.upload_file(local, remote_new)
        guest.exec(["mv", "-f", str(remote_new), str(remote_dir / "state.json")])
        return sequence

    def _wait_for_ui_fixture_ready(
        self,
        record: dict[str, Any],
        sequence: int,
        *,
        timeout_seconds: float = 15,
    ) -> dict[str, object]:
        guest = self._guest(record)
        ready = REMOTE_ROOT / "ui-fixture" / "ready.json"
        deadline = time.monotonic() + timeout_seconds
        last_error = "ready file was not created"
        while time.monotonic() < deadline:
            result = guest.exec_retryable(["cat", str(ready)], timeout=5, check=False)
            if result.returncode == 0:
                try:
                    document = json.loads(result.stdout)
                    if (
                        document.get("schema") == 1
                        and int(document.get("sequence", 0)) == sequence
                    ):
                        overflow = document.get("text_overflow_count")
                        if not isinstance(overflow, int) or overflow < 0:
                            last_error = (
                                "fixture ACK lacks a valid text overflow count: "
                                f"{document!r}"
                            )
                        else:
                            missing_translations = document.get(
                                "missing_translation_count"
                            )
                            if (
                                not isinstance(missing_translations, int)
                                or missing_translations < 0
                            ):
                                last_error = (
                                    "fixture ACK lacks a valid missing translation "
                                    f"count: {document!r}"
                                )
                            elif missing_translations > 0:
                                raise VMError(
                                    FailureCategory.VISUAL_ASSERTION_FAILED,
                                    "production UI exposed untranslated catalog keys",
                                    {
                                        "sequence": sequence,
                                        "surface": document.get("surface"),
                                        "missing_translation_count": (
                                            missing_translations
                                        ),
                                    },
                                )
                            else:
                                return document
                    else:
                        last_error = f"stale fixture ACK: {document!r}"
                except (json.JSONDecodeError, TypeError, ValueError) as error:
                    last_error = f"invalid fixture ACK: {error}"
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "production UI did not acknowledge the requested review state",
            {"sequence": sequence, "reason": last_error},
        )

    def _capture_stable_ui(
        self,
        record: dict[str, Any],
        name: str,
        output: str,
        *,
        timeout_seconds: float = UI_STABILITY_TIMEOUT_SECONDS,
    ) -> dict[str, object]:
        deadline = time.monotonic() + timeout_seconds
        frame_count = 0
        previous_hash = ""
        previous_path: Path | None = None
        last_capture: dict[str, object] | None = None
        best_stability: dict[str, float] | None = None
        best_previous_path: Path | None = None
        best_current_path: Path | None = None
        # A fixture ACK confirms that the production model accepted the state,
        # while the compositor can still need one more frame to map a new
        # layer-shell surface.  Always permit one comparison after that first
        # transitional pair, even when a slow screenshot crossed the deadline.
        while (
            frame_count < UI_STABILITY_MINIMUM_FRAME_COUNT
            or time.monotonic() < deadline
        ):
            last_capture = self.screenshot(record["run_id"], name, output)
            frame_count += 1
            image_path = Path(str(last_capture["path"]))
            current_hash = sha256(image_path.read_bytes()).hexdigest()
            if current_hash == previous_hash:
                last_capture["stability_changed_pixel_ratio"] = 0.0
                last_capture["stability_metric"] = "pixel-hash"
                if previous_path is not None:
                    previous_path.unlink(missing_ok=True)
                if best_previous_path is not None:
                    best_previous_path.unlink(missing_ok=True)
                if best_current_path is not None:
                    best_current_path.unlink(missing_ok=True)
                return last_capture
            if previous_path is not None:
                comparison = subprocess.run(
                    [
                        "magick",
                        "compare",
                        "-metric",
                        "AE",
                        str(previous_path),
                        str(image_path),
                        "null:",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if comparison.returncode in {0, 1}:
                    try:
                        changed_pixels = float(comparison.stderr.strip())
                    except ValueError:
                        changed_pixels = -1.0
                    total_pixels = int(last_capture["width"]) * int(
                        last_capture["height"]
                    )
                    changed_ratio = (
                        changed_pixels / total_pixels if changed_pixels >= 0 else None
                    )
                    if (
                        changed_ratio is not None
                        and changed_ratio <= UI_STABILITY_MAX_CHANGED_PIXEL_RATIO
                    ):
                        last_capture["stability_changed_pixel_ratio"] = round(
                            changed_ratio, 8
                        )
                        last_capture["stability_metric"] = "changed-pixel-ratio"
                        previous_path.unlink(missing_ok=True)
                        if best_previous_path is not None:
                            best_previous_path.unlink(missing_ok=True)
                        if best_current_path is not None:
                            best_current_path.unlink(missing_ok=True)
                        return last_capture

                    rmse_result = subprocess.run(
                        [
                            "magick",
                            "compare",
                            "-metric",
                            "RMSE",
                            str(previous_path),
                            str(image_path),
                            "null:",
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    ssim_result = subprocess.run(
                        [
                            "magick",
                            "compare",
                            "-metric",
                            "SSIM",
                            str(previous_path),
                            str(image_path),
                            "null:",
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    if rmse_result.returncode in {0, 1} and ssim_result.returncode in {
                        0,
                        1,
                    }:
                        try:
                            normalized_rmse = normalized_image_metric(
                                rmse_result.stderr.strip()
                            )
                            ssim_error = normalized_image_metric(
                                ssim_result.stderr.strip()
                            )
                        except ValueError:
                            pass
                        else:
                            diagnostic_changed_ratio = (
                                changed_ratio if changed_ratio is not None else 1.0
                            )
                            stability = {
                                "changed_pixel_ratio": round(
                                    diagnostic_changed_ratio, 8
                                ),
                                "normalized_rmse": round(normalized_rmse, 8),
                                "ssim_error": round(ssim_error, 8),
                            }
                            if (
                                best_stability is None
                                or normalized_rmse < best_stability["normalized_rmse"]
                            ):
                                best_stability = stability
                                best_previous_path = image_path.with_name(
                                    f".{image_path.name}.best-previous"
                                )
                                best_current_path = image_path.with_name(
                                    f".{image_path.name}.best-current"
                                )
                                shutil.copyfile(previous_path, best_previous_path)
                                shutil.copyfile(image_path, best_current_path)
                            if (
                                normalized_rmse <= UI_STABILITY_MAX_NORMALIZED_RMSE
                                or ssim_error <= UI_STABILITY_MAX_SSIM_ERROR
                            ):
                                last_capture["stability_changed_pixel_ratio"] = round(
                                    diagnostic_changed_ratio, 8
                                )
                                last_capture["stability_normalized_rmse"] = round(
                                    normalized_rmse, 8
                                )
                                last_capture["stability_ssim_error"] = round(
                                    ssim_error, 8
                                )
                                last_capture["stability_metric"] = (
                                    "normalized-rmse"
                                    if normalized_rmse
                                    <= UI_STABILITY_MAX_NORMALIZED_RMSE
                                    else "ssim-error"
                                )
                                previous_path.unlink(missing_ok=True)
                                if best_previous_path is not None:
                                    best_previous_path.unlink(missing_ok=True)
                                if best_current_path is not None:
                                    best_current_path.unlink(missing_ok=True)
                                return last_capture
            previous_hash = current_hash
            stable_probe = image_path.with_name(f".{image_path.name}.previous")
            shutil.copyfile(image_path, stable_probe)
            previous_path = stable_probe
            time.sleep(0.1)
        diagnostic_previous: str | None = None
        diagnostic_current: str | None = None
        diagnostic_difference: str | None = None
        if last_capture is not None and best_previous_path is not None:
            image_path = Path(str(last_capture["path"]))
            diagnostic_path = image_path.with_name(
                f"{image_path.stem}.stability-previous{image_path.suffix}"
            )
            current_diagnostic_path = image_path.with_name(
                f"{image_path.stem}.stability-current{image_path.suffix}"
            )
            shutil.move(best_previous_path, diagnostic_path)
            if best_current_path is None:
                raise AssertionError("best stability frame pair is incomplete")
            shutil.move(best_current_path, current_diagnostic_path)
            diagnostic_previous = str(diagnostic_path)
            diagnostic_current = str(current_diagnostic_path)
            difference_path = image_path.with_name(
                f"{image_path.stem}.stability-difference{image_path.suffix}"
            )
            difference = subprocess.run(
                [
                    "magick",
                    "compare",
                    str(diagnostic_path),
                    str(current_diagnostic_path),
                    str(difference_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if difference.returncode in {0, 1} and difference_path.is_file():
                diagnostic_difference = str(difference_path)
        if previous_path is not None:
            previous_path.unlink(missing_ok=True)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "compositor output did not settle to two perceptually stable frames",
            {
                "name": name,
                "output": output,
                "last_capture": last_capture,
                "frame_count": frame_count,
                "best_stability": best_stability,
                "diagnostic_previous": diagnostic_previous,
                "diagnostic_current": diagnostic_current,
                "diagnostic_difference": diagnostic_difference,
            },
        )

    def _restart_ui_review_shell(
        self,
        record: dict[str, Any],
        locale: str,
    ) -> None:
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"}:
            raise VMError(FailureCategory.HARNESS_ERROR, "unsupported UI review locale")
        log_name = locale.replace(".", "-") + ".log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            'wayland=$WAYLAND_DISPLAY; test -n "$wayland"; '
            "pkill -TERM -x qs 2>/dev/null || true; "
            "for attempt in $(seq 1 50); do pgrep -x qs >/dev/null || break; "
            "sleep 0.1; done; ! pgrep -x qs >/dev/null; "
            f"install -d -m 0700 {REMOTE_ARTIFACTS}/ui-review; "
            f"nohup env LANG={locale} LC_ALL={locale} "
            "ENOSHIMA_VM_UI_TEST=1 "
            f"ENOSHIMA_UI_FIXTURE_DIR={REMOTE_ROOT}/ui-fixture "
            "PATH=/home/kentakang/.local/share/mise/shims:"
            "/home/kentakang/.local/bin:/usr/local/bin:/usr/bin "
            "XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$wayland "
            "HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE "
            "/usr/bin/qs -p /home/kentakang/.config/quickshell/cyberdock "
            f">{REMOTE_ARTIFACTS}/ui-review/{log_name} 2>&1 </dev/null &"
        )
        self._run_checked(
            record,
            "restart-ui-review-shell",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        self._wait_for_layer(
            record,
            {"namespace": "cyberdock", "timeout_seconds": 60},
        )

    def _stop_auth_review(self, record: dict[str, Any]) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / "auth.pid"
        shell = (
            f"if test -s {pid_path}; then "
            f"pid=$(cat {pid_path}); "
            "case $pid in (*[!0-9]*|'') exit 2;; esac; "
            "if test -e /proc/$pid/exe && "
            'test "$(readlink -f /proc/$pid/exe)" = /usr/bin/enoshima-greeter; '
            "then kill -TERM $pid; fi; "
            f"rm -f {pid_path}; fi"
        )
        self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    def _start_auth_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        allowed_states = {
            "password",
            "fingerprint-ready",
            "fingerprint-progress",
            "success",
            "failure",
            "caps-lock",
            "busy",
            "power-confirmation",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid Auth review state")
        self._stop_auth_review(record)
        pid_path = REMOTE_ROOT / "ui-fixture" / "auth.pid"
        log_path = REMOTE_ARTIFACTS / "ui-review" / "auth-review.log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            'wayland=$WAYLAND_DISPLAY; test -n "$wayland"; '
            f"nohup env LANG={locale} LC_ALL={locale} GDK_BACKEND=wayland "
            "ENOSHIMA_VM_UI_TEST=1 XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland /usr/bin/enoshima-greeter "
            f"--user kentakang --review-state {state} "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"start-auth-review-{state}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        deadline = time.monotonic() + 20
        last_clients: list[object] = []
        while time.monotonic() < deadline:
            result = self._guest(record).exec_retryable(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                last_clients = json.loads(result.stdout)
                if any(
                    str(client.get("title", "")) == "Enoshima Auth"
                    for client in last_clients
                ):
                    return
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "production Enoshima Greeter did not render its review state",
            {"state": state, "clients": last_clients},
        )

    def _prepare_notification_review(self, record: dict[str, Any]) -> None:
        self._run_checked(
            record,
            "isolate-notification-review-daemon",
            self._hypr_command(
                "systemctl --user stop swaync.service; "
                "systemctl --user reset-failed swaync.service || true; "
                "systemctl --user mask --runtime --force swaync.service"
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _restore_notification_review(self, record: dict[str, Any]) -> None:
        self._stop_notification_review(record)
        self._run_checked(
            record,
            "restore-notification-review-daemon",
            self._hypr_command(
                "systemctl --user unmask --runtime swaync.service; "
                "systemctl --user reset-failed swaync.service || true; "
                "systemctl --user start swaync.service"
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _stop_notification_review(self, record: dict[str, Any]) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / "swaync.pid"
        shell = (
            f"if test -s {pid_path}; then "
            f"pid=$(cat {pid_path}); "
            "case $pid in (*[!0-9]*|'') exit 2;; esac; "
            "if test -e /proc/$pid/exe && "
            'test "$(readlink -f /proc/$pid/exe)" = /usr/bin/swaync; '
            "then kill -TERM $pid; fi; "
            "for attempt in $(seq 1 60); do "
            "owner=$(timeout 2s busctl --user --no-pager --no-legend list "
            "| awk '$1 == \"org.freedesktop.Notifications\" { print $2 }'); "
            'test "$owner" != "$pid" && break; '
            "sleep 0.05; "
            "done; "
            "owner=$(timeout 2s busctl --user --no-pager --no-legend list "
            "| awk '$1 == \"org.freedesktop.Notifications\" { print $2 }'); "
            'if test "$owner" = "$pid" && test -e /proc/$pid/exe && '
            'test "$(readlink -f /proc/$pid/exe)" = /usr/bin/swaync; '
            "then kill -KILL $pid; fi; "
            f"rm -f {pid_path}; fi"
        )
        self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    def _start_notification_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        allowed_states = {
            "default",
            "empty",
            "do-not-disturb",
            "notification",
            "critical",
            "action-error",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid notification review state"
            )
        self._stop_notification_review(record)
        pid_path = REMOTE_ROOT / "ui-fixture" / "swaync.pid"
        log_path = REMOTE_ARTIFACTS / "ui-review" / "swaync-review.log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus; "
            'wayland=$WAYLAND_DISPLAY; test -n "$wayland"; '
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus WAYLAND_DISPLAY=$wayland "
            "/home/kentakang/.local/bin/enoshima-swaync "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"start-notification-review-{state}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        guest = self._guest(record)
        ready_deadline = time.monotonic() + 20
        while time.monotonic() < ready_deadline:
            ready = guest.exec_retryable(
                self._hypr_command(
                    f"pid=$(cat {pid_path}); "
                    "owner=$(timeout 2s busctl --user --no-pager --no-legend list "
                    "| awk '$1 == \"org.freedesktop.Notifications\" { print $2 }'); "
                    'test "$owner" = "$pid"'
                ),
                timeout=5,
                check=False,
            )
            if ready.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "production SwayNC did not acquire its session bus",
                {"state": state},
            )

        guest.exec(
            self._hypr_command(
                "swaync-client -cp -sw; swaync-client -C -sw; swaync-client -df -sw"
            ),
            timeout=15,
        )
        korean = locale.startswith("ko")
        messages = {
            "default": (
                "Enoshima Desktop" if not korean else "Enoshima 데스크탑",
                (
                    "Your workspace is ready."
                    if not korean
                    else "작업 공간을 사용할 수 있습니다."
                ),
                "normal",
            ),
            "notification": (
                "Build finished" if not korean else "빌드 완료",
                (
                    "All checks passed successfully."
                    if not korean
                    else "모든 검증을 통과했습니다."
                ),
                "normal",
            ),
            "critical": (
                "Battery needs attention" if not korean else "배터리 확인 필요",
                (
                    "Connect power to continue safely."
                    if not korean
                    else "안전하게 계속하려면 전원을 연결하세요."
                ),
                "critical",
            ),
            "action-error": (
                (
                    "Action could not be completed"
                    if not korean
                    else "작업을 완료할 수 없음"
                ),
                (
                    "The requested action failed. Try again."
                    if not korean
                    else "요청한 작업이 실패했습니다. 다시 시도하세요."
                ),
                "critical",
            ),
        }
        if state == "do-not-disturb":
            guest.exec(self._hypr_command("swaync-client -dn -sw"), timeout=10)
        elif state not in {"empty"}:
            summary, body, urgency = messages[state]
            action_label = "다시 시도" if korean else "Retry"
            action = (
                f" --action=retry={shlex.quote(action_label)}"
                if state == "action-error"
                else ""
            )
            command = (
                "nohup notify-send --app-name=Enoshima "
                f"--urgency={urgency}{action} "
                f"{shlex.quote(summary)} {shlex.quote(body)} "
                ">/dev/null 2>&1 </dev/null &"
            )
            guest.exec(self._hypr_command(command), timeout=10)
            expected = 1
            count_deadline = time.monotonic() + 10
            while time.monotonic() < count_deadline:
                count = guest.exec_retryable(
                    self._hypr_command("swaync-client -c"), timeout=5, check=False
                )
                if count.returncode == 0 and int(count.stdout.strip() or 0) >= expected:
                    break
                time.sleep(0.1)
            else:
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "SwayNC did not render the requested notification",
                    {"state": state},
                )
        guest.exec(self._hypr_command("swaync-client -op -sw"), timeout=10)
        self._wait_for_layer(
            record,
            {"namespace": "swaync-control-center", "timeout_seconds": 20},
        )

    def _stop_titlebar_review(self, record: dict[str, Any]) -> None:
        for name in ("titlebar-primary.pid", "titlebar-secondary.pid"):
            pid_path = REMOTE_ROOT / "ui-fixture" / name
            shell = (
                f"if test -s {pid_path}; then "
                f"pid=$(cat {pid_path}); "
                "case $pid in (*[!0-9]*|'') exit 2;; esac; "
                "if test -e /proc/$pid/exe && "
                'test "$(readlink -f /proc/$pid/exe)" = '
                f"{REMOTE_ROOT}/ui-fixture/titlebar-window; "
                "then kill -TERM $pid; fi; "
                f"rm -f {pid_path}; fi"
            )
            self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)
        self.backend.pointer_button(
            record["domain"],
            self._require_recorded_domain_uuid(record),
            "left",
            False,
        )

    def _compile_titlebar_fixture(self, record: dict[str, Any]) -> None:
        binary = REMOTE_ROOT / "ui-fixture" / "titlebar-window"
        source = REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "titlebar-window.c"
        command = (
            f"test -x {binary} || cc -std=c17 -O2 -Wall -Wextra -Werror "
            f"$(pkg-config --cflags gtk4) {source} -o {binary} "
            "$(pkg-config --libs gtk4)"
        )
        self._run_checked(
            record,
            "compile-titlebar-fixture",
            self._remote_shell(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=120,
        )

    def _launch_titlebar_fixture(
        self,
        record: dict[str, Any],
        locale: str,
        pid_name: str,
    ) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / pid_name
        log_path = REMOTE_ARTIFACTS / "ui-review" / f"{pid_name}.log"
        binary = REMOTE_ROOT / "ui-fixture" / "titlebar-window"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            'wayland=$WAYLAND_DISPLAY; test -n "$wayland"; '
            f"nohup env LANG={locale} LC_ALL={locale} GDK_BACKEND=wayland "
            f"XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$wayland {binary} "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"launch-{pid_name}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _titlebar_clients(self, record: dict[str, Any]) -> list[dict[str, Any]]:
        result = self._guest(record).exec_retryable(
            self._hypr_command("hyprctl -j clients"), timeout=10
        )
        return [
            client
            for client in json.loads(result.stdout)
            if str(client.get("class", "")) == "org.enoshima.TitlebarFixture"
            or str(client.get("initialClass", "")) == "org.enoshima.TitlebarFixture"
        ]

    def _wait_for_titlebar_clients(
        self,
        record: dict[str, Any],
        count: int,
    ) -> list[dict[str, Any]]:
        deadline = time.monotonic() + 20
        clients: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            clients = self._titlebar_clients(record)
            if len(clients) >= count:
                return clients
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "undecorated titlebar fixture did not become a Hyprland client",
            {"expected": count, "clients": clients},
        )

    def _start_titlebar_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> dict[str, Any]:
        allowed_states = {
            "active",
            "inactive",
            "keyboard-focus",
            "hover",
            "pressed",
            "maximized",
            "close-hover",
            "system-menu",
            "action-running",
            "action-error",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid system titlebar review state"
            )
        self._stop_titlebar_review(record)
        self._compile_titlebar_fixture(record)
        allowlist = "mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture"
        self._run_checked(
            record,
            "allow-titlebar-fixture",
            self._hypr_command(
                "hyprctl eval "
                + shlex.quote(self._decoration_allowlist_expression(allowlist))
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=20,
        )
        self._launch_titlebar_fixture(record, locale, "titlebar-primary.pid")
        clients = self._wait_for_titlebar_clients(record, 1)
        primary = clients[-1]
        address = str(primary.get("address", ""))
        if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "titlebar fixture returned an invalid Hyprland address",
                {"client": primary},
            )
        guest = self._guest(record)
        guest.exec(
            self._hypr_command(
                self._hypr_dispatch(f'hl.dsp.focus({{ window = "address:{address}" }})')
            ),
            timeout=10,
        )
        if state == "inactive":
            self._launch_titlebar_fixture(record, locale, "titlebar-secondary.pid")
            clients = self._wait_for_titlebar_clients(record, 2)
            secondary = next(
                client for client in clients if client.get("address") != address
            )
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch(
                        'hl.dsp.focus({ window = "address:'
                        + str(secondary["address"])
                        + '" })'
                    )
                ),
                timeout=10,
            )
        elif state == "maximized":
            self._run_checked(
                record,
                "maximize-titlebar-fixture",
                self._hypr_command(
                    "desktop-window-action maximize --address "
                    f"{address} --origin compositor"
                ),
                FailureCategory.VISUAL_ASSERTION_FAILED,
                timeout_seconds=15,
            )
        if state in {"hover", "pressed", "close-hover"}:
            current = next(
                client
                for client in self._titlebar_clients(record)
                if client.get("address") == address
            )
            at = current.get("at", [0, 0])
            size = current.get("size", [900, 560])
            button_offset = 22 if state == "close-hover" else 72
            cursor_x = int(at[0]) + int(size[0]) - button_offset
            cursor_y = max(4, int(at[1]) - 18)
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch(
                        f"hl.dsp.cursor.move({{ x = {cursor_x}, y = {cursor_y} }})"
                    )
                ),
                timeout=10,
            )
            if state == "pressed":
                self.backend.pointer_button(
                    record["domain"],
                    self._require_recorded_domain_uuid(record),
                    "left",
                    True,
                )
        return primary

    def _stop_desktop_shell_review(self, record: dict[str, Any]) -> None:
        for name, executable in (
            ("desktop-ghostty.pid", "/usr/bin/ghostty"),
            ("desktop-thunar.pid", "/usr/bin/thunar"),
        ):
            pid_path = REMOTE_ROOT / "ui-fixture" / name
            shell = (
                f"if test -s {pid_path}; then "
                f"pid=$(cat {pid_path}); "
                "case $pid in (*[!0-9]*|'') exit 2;; esac; "
                "if test -e /proc/$pid/exe && "
                f'test "$(readlink -f /proc/$pid/exe)" = {executable}; '
                "then kill -TERM $pid; fi; "
                f"rm -f {pid_path}; fi"
            )
            self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    def _run_vicinae_control(
        self,
        record: dict[str, Any],
        name: str,
        action: str,
    ) -> None:
        command = (
            "status=0; "
            "timeout --signal=TERM --kill-after=1s 5s "
            f"{action} </dev/null >/dev/null 2>&1 || status=$?; "
            "case $status in "
            "0) ;; "
            "124) printf '%s\\n' 'Vicinae accepted the request but its IPC reply "
            "did not close within 5 seconds.' ;; "
            "*) exit $status ;; "
            "esac"
        )
        self._run_checked(
            record,
            f"control-command-palette-{name}",
            [
                "timeout",
                "--signal=TERM",
                "--kill-after=1s",
                "8s",
                *self._hypr_command(command),
            ],
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=10,
        )

    def _stop_command_palette_review(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        if self._ui_review_layer_present(record, "vicinae"):
            self._run_vicinae_control(record, "close", "vicinae close")
            self._wait_for_ui_review_layer(
                record,
                "HEADLESS-UI",
                "vicinae",
                present=False,
            )
        guest.exec(
            self._hypr_command(
                "wl-copy --clear >/dev/null 2>&1 || true; "
                "rm -f -- $HOME/.local/share/vicinae/scripts/"
                "executable_ui-review-long-title.sh"
            ),
            timeout=15,
            check=False,
        )

    def _prepare_command_palette_review_scripts(
        self,
        record: dict[str, Any],
        state: str,
    ) -> str:
        title = (
            "Review Retained Performance History Across a Very Long Incident Timeline"
        )
        path = "$HOME/.local/share/vicinae/scripts/executable_ui-review-long-title.sh"
        if state != "long-title":
            self._guest(record).exec(
                self._hypr_command(f"rm -f -- {path}"),
                timeout=15,
                check=False,
            )
            return "Resources"
        script = (
            "#!/usr/bin/env bash\n"
            "# @vicinae.schemaVersion 1\n"
            f"# @vicinae.title {title}\n"
            "# @vicinae.mode silent\n"
            "# @vicinae.packageName Performance Qualification\n"
            "# @vicinae.icon utilities-system-monitor\n"
            "# @vicinae.description Deterministic long-title visual evidence.\n"
            '# @vicinae.exec ["/bin/bash"]\n\n'
            "exit 0\n"
        )
        command = (
            "install -d -m 0755 $HOME/.local/share/vicinae/scripts; "
            f"printf %s {shlex.quote(script)} > {path}; chmod 0755 {path}"
        )
        self._run_checked(
            record,
            "prepare-command-palette-long-title",
            self._hypr_command(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=15,
        )
        return title

    @staticmethod
    def _temporary_user_manager_locale(locale: str) -> str:
        return (
            "old_lang=$(systemctl --user show-environment | "
            "grep -m1 '^LANG=' || true); "
            "old_lc_all=$(systemctl --user show-environment | "
            "grep -m1 '^LC_ALL=' || true); "
            "restore_manager_locale() { "
            "systemctl --user unset-environment LANG LC_ALL; "
            'test -z "$old_lang" || systemctl --user set-environment "$old_lang"; '
            'test -z "$old_lc_all" || systemctl --user set-environment "$old_lc_all"; '
            "}; trap restore_manager_locale EXIT; "
            f"systemctl --user set-environment LANG={locale} LC_ALL={locale}; "
        )

    def _restart_command_palette_service(
        self,
        record: dict[str, Any],
        locale: str,
        expected_command: str,
        restart: bool,
    ) -> None:
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"}:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "unsupported command-palette review locale",
            )
        locale_setup = self._temporary_user_manager_locale(locale) if restart else ""
        service_setup = (
            "systemctl --user reset-failed vicinae.service; "
            "restart_status=0; "
            "timeout --signal=TERM --kill-after=2s 25s "
            "systemctl --user restart vicinae.service || restart_status=$?; "
            "if (( restart_status != 0 )); then "
            'diagnose_vicinae restart "$restart_status" not-run; '
            'exit "$restart_status"; fi; '
            if restart
            else ""
        )
        readiness_probe = (
            "deadline=$((SECONDS + 15)); "
            "while (( SECONDS < deadline )); do "
            "ping_status=0; "
            "ping_output=$(timeout --signal=TERM --kill-after=1s 1s "
            "vicinae ping 2>&1) || ping_status=$?; "
            "if (( ping_status == 0 )); then "
            "command_status=0; "
            "command_output=$(timeout --signal=TERM --kill-after=1s 1s "
            "vicinae cmd list --json 2>&1) || command_status=$?; "
            "if (( command_status == 0 )) && "
            f"grep -Fq -- {shlex.quote(expected_command)} "
            '<<<"$command_output"; then ready=true; break; fi; '
            "fi; sleep 0.1; done; "
            "if [[ $ready == true ]]; then exit 0; fi; "
            'diagnose_vicinae readiness "$ping_status" '
            '"$command_status"; exit 1'
        )
        probe_state = (
            "ping_status=not-run; command_status=not-run; "
            "ping_output=; command_output=; ready=false; "
        )
        diagnostics = (
            "diagnose_vicinae() { "
            "printf 'Vicinae %s failure: ping_status=%s command_status=%s "
            f'expected_command=%s\\n\' "$1" "$2" "$3" '
            f"{shlex.quote(expected_command)} >&2; "
            "printf 'last ping output: %.2000s\\n' \"$ping_output\" >&2; "
            "printf 'last command output: %.4000s\\n' \"$command_output\" >&2; "
            "timeout 5s systemctl --user show vicinae.service --no-pager "
            "--property=ActiveState --property=SubState --property=Result "
            "--property=ExecMainPID >&2 || true; "
            "timeout 5s systemctl --user status vicinae.service --no-pager "
            ">&2 || true; "
            "timeout 5s journalctl --user -u vicinae.service -b -n 120 "
            "--no-pager -o short-monotonic >&2 || true; "
            "timeout 5s ps -C vicinae -o pid=,stat=,etime=,time=,cmd= "
            ">&2 || true; }; "
        )
        command = (
            "set -u; uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            + locale_setup
            + probe_state
            + diagnostics
            + service_setup
            + readiness_probe
        )
        self._run_checked(
            record,
            f"restart-command-palette-{locale}",
            self._hypr_command(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=55,
        )

    def _start_command_palette_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
        output: str,
        restart_service: bool,
    ) -> None:
        allowed_states = {
            "default",
            "search",
            "clipboard-history",
            "emoji-picker",
            "empty-results",
            "long-title",
        }
        if state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid command-palette review state",
            )
        expected_command = self._prepare_command_palette_review_scripts(record, state)
        self._restart_command_palette_service(
            record,
            locale,
            expected_command,
            restart_service,
        )
        guest = self._guest(record)
        if state == "clipboard-history":
            guest.exec(
                self._hypr_command(
                    "printf 'Enoshima clipboard review' | "
                    "wl-copy >/dev/null 2>&1; sleep 0.5"
                ),
                timeout=15,
            )
            action = "vicinae deeplink 'vicinae://launch/clipboard/history?toggle=true'"
        elif state == "emoji-picker":
            action = (
                "vicinae deeplink 'vicinae://launch/core/search-emojis?toggle=true'"
            )
        else:
            action = "vicinae toggle"
        # Vicinae can wait indefinitely for the IPC reply after the
        # server has already accepted a deeplink.  Bound only that control
        # client; the compositor layer below remains the authoritative result.
        self._run_vicinae_control(record, state, action)
        self._wait_for_ui_review_layer(
            record,
            output,
            "vicinae",
            present=True,
            service_unit="vicinae.service",
        )
        # Layer mapping precedes the search field's keyboard-focus handoff by
        # a short Qt event-loop turn. Avoid racing the production window.
        time.sleep(0.3)
        query = {
            "search": "resources",
            "empty-results": "zzzzzzzz",
            "long-title": "retained performance history",
        }.get(state)
        if query is not None:
            self.backend.type_text(
                record["domain"],
                self._require_recorded_domain_uuid(record),
                query,
                submit=False,
            )
            time.sleep(0.5)

    def _restart_overview_service(
        self,
        record: dict[str, Any],
        locale: str | None = None,
    ) -> None:
        locale_setup = ""
        if locale is not None:
            if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"}:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "unsupported overview review locale",
                )
            locale_setup = self._temporary_user_manager_locale(locale)
        # Hyprshell normally reloads the complete Hyprland configuration on
        # every process start.  During UI review that would replace the exact
        # named-output rules above with the workstation wildcard rule and can
        # resurrect Virtual-1 at its preferred mode.  The reviewed package
        # extends its existing no-listeners mode to suppress that one eager
        # reload.  Scope the flag to this service spawn and restore the user
        # manager environment as soon as the process has inherited it.
        restore_locale = "restore_manager_locale; " if locale is not None else ""
        topology_owner_setup = (
            "old_no_listeners=$(systemctl --user show-environment | "
            "grep -m1 '^HYPRSHELL_NO_LISTENERS=' || true); "
            "restore_overview_manager_environment() { "
            + restore_locale
            + "systemctl --user unset-environment HYPRSHELL_NO_LISTENERS; "
            'test -z "$old_no_listeners" || systemctl --user '
            'set-environment "$old_no_listeners"; '
            "}; trap restore_overview_manager_environment EXIT; "
            "systemctl --user set-environment HYPRSHELL_NO_LISTENERS=1; "
        )
        command = (
            "set -eu; uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            + locale_setup
            + topology_owner_setup
            + "systemctl --user reset-failed hyprshell.service; "
            + "systemctl --user restart hyprshell.service; "
            + "for attempt in $(seq 1 100); do "
            + "systemctl --user is-active --quiet hyprshell.service && "
            + "hyprshell config check >/dev/null 2>&1 && exit 0; "
            + "sleep 0.1; done; exit 1"
        )
        self._run_checked(
            record,
            "restart-overview-service",
            self._hypr_command(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _stop_overview_service(self, record: dict[str, Any]) -> None:
        """Quiesce Hyprshell before changing the compositor output topology.

        Hyprshell owns one GTK window per GDK monitor.  Removing a wl_output
        while those objects are alive can race GTK's Wayland dispatch before
        Hyprshell's delayed monitor reload runs.  A bounded systemd stop makes
        topology reconciliation deterministic and leaves restart policy to the
        caller once every output has settled.
        """

        command = (
            "set -eu; uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            "systemctl --user stop hyprshell.service; "
            "for attempt in $(seq 1 100); do "
            "state=$(systemctl --user show hyprshell.service "
            "--property=ActiveState --value); "
            "main_pid=$(systemctl --user show hyprshell.service "
            "--property=MainPID --value); "
            'case "$state:$main_pid" in inactive:0|failed:0) exit 0;; esac; '
            "sleep 0.1; done; exit 1"
        )
        self._run_checked(
            record,
            "stop-overview-service-for-topology",
            self._hypr_command(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _stop_overview_review(
        self,
        record: dict[str, Any],
        *,
        best_effort: bool = False,
    ) -> None:
        cleanup_errors: list[str] = []

        def cleanup_step(label: str, action: Callable[[], Any]) -> Any:
            try:
                return action()
            except Exception as error:
                cleanup_errors.append(f"{label}: {error}")
                return None

        overview_present = cleanup_step(
            "inspect overview layer",
            lambda: self._ui_review_layer_present(record, "hyprshell_overview"),
        )
        launcher_present = cleanup_step(
            "inspect overview launcher",
            lambda: self._ui_review_layer_present(record, "hyprshell_launcher"),
        )
        if overview_present is not False or launcher_present is not False:
            cleanup_step(
                "close overview layers",
                lambda: self._close_overview_layers(record),
            )
        guest = self._guest(record)
        monitors = guest.exec_retryable(
            self._hypr_command("hyprctl -j monitors"), timeout=15, check=False
        )
        aux_present = True
        if monitors.returncode != 0:
            cleanup_errors.append(
                "inspect outputs: hyprctl monitors failed: " + monitors.stderr[-1000:]
            )
        else:
            try:
                monitor_state = json.loads(monitors.stdout)
                if not isinstance(monitor_state, list):
                    raise TypeError("monitor response is not a list")
            except (json.JSONDecodeError, TypeError):
                cleanup_errors.append("inspect outputs: invalid monitor JSON")
            else:
                aux_present = any(
                    str(monitor.get("name", "")) == "HEADLESS-AUX"
                    for monitor in monitor_state
                    if isinstance(monitor, dict)
                )

        workspaces = guest.exec_retryable(
            self._hypr_command("hyprctl -j workspaces"), timeout=15, check=False
        )
        managed_workspaces: list[int] = []
        if workspaces.returncode != 0:
            cleanup_errors.append(
                "inspect workspaces: hyprctl workspaces failed: "
                + workspaces.stderr[-1000:]
            )
        else:
            try:
                workspace_state = json.loads(workspaces.stdout)
                if not isinstance(workspace_state, list):
                    raise TypeError("workspace response is not a list")
                observed_workspaces: set[int] = set()
                for workspace in workspace_state:
                    if not isinstance(workspace, dict):
                        continue
                    try:
                        workspace_id = int(workspace.get("id", -1))
                    except (TypeError, ValueError):
                        continue
                    if 1 <= workspace_id <= 5:
                        observed_workspaces.add(workspace_id)
                managed_workspaces = sorted(observed_workspaces)
            except (json.JSONDecodeError, TypeError, ValueError):
                cleanup_errors.append("inspect workspaces: invalid workspace JSON")

        # Restore every extant review workspace even when the auxiliary output
        # already disappeared or an earlier layer-close step failed.
        for workspace in managed_workspaces:
            cleanup_step(
                f"restore workspace {workspace}",
                lambda workspace=workspace: guest.exec(
                    self._hypr_command(
                        self._hypr_dispatch(
                            "hl.dsp.workspace.move({ workspace = "
                            f'{workspace}, monitor = "HEADLESS-UI" }})'
                        )
                    ),
                    timeout=10,
                    check=True,
                ),
            )
        if aux_present:
            # The overview fixture opens real GTK clients on the auxiliary
            # output.  Close them before withdrawing wl_output; otherwise
            # Ghostty can still be dispatching that output while GTK tears it
            # down and crash in the Wayland event queue.
            cleanup_step(
                "close fixture clients before output removal",
                lambda: self._close_ui_review_clients(record),
            )
            cleanup_step(
                "stop overview service before output removal",
                lambda: self._stop_overview_service(record),
            )
            cleanup_step(
                "remove auxiliary output",
                lambda: guest.exec(
                    self._hypr_command("hyprctl output remove HEADLESS-AUX"),
                    timeout=15,
                    check=True,
                ),
            )
        deadline = time.monotonic() + 20
        last_monitors: list[dict[str, Any]] = []
        last_workspaces: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            monitors = guest.exec_retryable(
                self._hypr_command("hyprctl -j monitors"), timeout=10, check=False
            )
            workspaces = guest.exec_retryable(
                self._hypr_command("hyprctl -j workspaces"), timeout=10, check=False
            )
            if monitors.returncode == 0 and workspaces.returncode == 0:
                try:
                    monitor_state = json.loads(monitors.stdout)
                    workspace_state = json.loads(workspaces.stdout)
                    if not isinstance(monitor_state, list) or not isinstance(
                        workspace_state, list
                    ):
                        raise TypeError("topology response is not a list")
                except (json.JSONDecodeError, TypeError):
                    time.sleep(0.1)
                    continue
                last_monitors = monitor_state
                last_workspaces = workspace_state
                aux_absent = all(
                    str(monitor.get("name", "")) != "HEADLESS-AUX"
                    for monitor in last_monitors
                    if isinstance(monitor, dict)
                )
                workspace_outputs: dict[int, str] = {}
                for workspace in last_workspaces:
                    if not isinstance(workspace, dict):
                        continue
                    try:
                        workspace_id = int(workspace.get("id", -1))
                    except (TypeError, ValueError):
                        continue
                    if 1 <= workspace_id <= 5:
                        workspace_outputs[workspace_id] = str(
                            workspace.get("monitor", "")
                        )
                workspaces_restored = all(
                    monitor == "HEADLESS-UI" for monitor in workspace_outputs.values()
                )
                if aux_absent and workspaces_restored:
                    if cleanup_errors:
                        raise VMError(
                            FailureCategory.VISUAL_ASSERTION_FAILED,
                            "overview cleanup completed with recoverable errors",
                            {
                                "errors": cleanup_errors,
                                "best_effort": best_effort,
                            },
                        )
                    return
            time.sleep(0.1)
        cleanup_errors.append("topology postcondition did not settle")
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "overview topology did not cleanly restore",
            {
                "monitors": last_monitors,
                "workspaces": last_workspaces,
                "errors": cleanup_errors,
                "best_effort": best_effort,
            },
        )

    def _close_overview_layers(self, record: dict[str, Any]) -> None:
        """Close Hyprshell without racing its asynchronous monitor reload.

        ``OpenOverview`` is a toggle.  A monitor/config reload can set the
        internal model to closed a moment before Hyprland unmaps the old layer
        surfaces, so choosing the toggle from layer presence can reopen the
        overview.  Escape is idempotent for the production launcher: it closes
        an open model and cannot reopen a model that is already closing.  If
        two real keyboard attempts do not settle, reload the production model
        in place so its locale-bearing service process is preserved.
        """

        errors: list[str] = []
        for attempt in range(1, 3):
            self.backend.send_keys(
                record["domain"],
                self._require_recorded_domain_uuid(record),
                ["KEY_ESC"],
            )
            try:
                self._wait_for_ui_review_layer(
                    record,
                    "HEADLESS-UI",
                    "hyprshell_overview",
                    present=False,
                    timeout_seconds=5,
                )
                self._wait_for_ui_review_layer(
                    record,
                    "HEADLESS-UI",
                    "hyprshell_launcher",
                    present=False,
                    timeout_seconds=5,
                )
                return
            except VMError as error:
                errors.append(f"escape attempt {attempt}: {error}")

        self._run_checked(
            record,
            "close-overview-layer",
            self._hypr_command(
                "for attempt in $(seq 1 10); do "
                "timeout --signal=TERM --kill-after=1s 2s "
                "hyprshell socat '\"Reload\"' && exit 0; "
                "sleep 0.1; done; exit 1"
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        try:
            self._wait_for_ui_review_layer(
                record,
                "HEADLESS-UI",
                "hyprshell_overview",
                present=False,
            )
            self._wait_for_ui_review_layer(
                record,
                "HEADLESS-UI",
                "hyprshell_launcher",
                present=False,
            )
        except VMError as error:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "production overview layers did not close",
                {"errors": [*errors, f"reload fallback: {error}"]},
            ) from error

    def _open_overview_layers(
        self,
        record: dict[str, Any],
        state: str,
        output: str,
    ) -> None:
        self._run_checked(
            record,
            f"open-overview-{state}",
            self._hypr_command(
                "for attempt in $(seq 1 100); do "
                "hyprshell socat '\"OpenOverview\"' && exit 0; "
                "sleep 0.1; done; exit 1"
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        self._wait_for_ui_review_layer(
            record,
            output,
            "hyprshell_overview",
            present=True,
            service_unit="hyprshell.service",
        )
        # The Enoshima source patch installs the key controller on the mapped
        # overview itself. Controller-only mode must never create the old
        # transparent launcher layer; real Tab/arrow cue changes below prove
        # that the visible surface owns input.
        self._wait_for_ui_review_layer(
            record,
            output,
            "hyprshell_launcher",
            present=False,
        )
        if state == "multi-monitor":
            self._wait_for_ui_review_layer(
                record,
                "HEADLESS-AUX",
                "hyprshell_overview",
                present=True,
                service_unit="hyprshell.service",
            )

    def _acknowledge_overview_navigation(
        self,
        record: dict[str, Any],
        state: str,
        scale: float,
        output: str,
    ) -> None:
        keys = {
            "selected-window": ["KEY_TAB"],
            "selected-workspace": ["KEY_RIGHT"],
            "multi-monitor": ["KEY_RIGHT"],
        }.get(state)
        if keys is None:
            return

        navigation_output = "HEADLESS-AUX" if state == "multi-monitor" else output
        navigation_scale = (
            overview_auxiliary_scale(scale) if state == "multi-monitor" else scale
        )
        before_name = f"overview-{state}-input-before"
        after_name = f"overview-{state}-input-after"
        captured_paths: set[Path] = set()
        acknowledged = False
        before_cue: dict[str, object] = {}
        after_cue: dict[str, object] = {}
        changed_pixels = 0
        minimum_changed_pixels = max(64, round(200 * navigation_scale**2))
        attempts = 2
        try:
            for attempt in range(attempts):
                before = self._capture_stable_ui(
                    record,
                    before_name,
                    navigation_output,
                    timeout_seconds=5,
                )
                before_path = Path(str(before["path"]))
                captured_paths.add(before_path)
                before_mask = self._overview_navigation_cue_mask(
                    before_path, state, navigation_scale
                )
                before_cue = self._overview_navigation_cue_metrics(before_mask)

                self.backend.send_keys(
                    record["domain"], self._require_recorded_domain_uuid(record), keys
                )
                deadline = time.monotonic() + 5
                while True:
                    after = self._capture_stable_ui(
                        record,
                        after_name,
                        navigation_output,
                        timeout_seconds=5,
                    )
                    after_path = Path(str(after["path"]))
                    captured_paths.add(after_path)
                    after_mask = self._overview_navigation_cue_mask(
                        after_path, state, navigation_scale
                    )
                    after_cue = self._overview_navigation_cue_metrics(after_mask)
                    if len(after_mask) != len(before_mask):
                        raise VMError(
                            FailureCategory.VISUAL_ASSERTION_FAILED,
                            "overview navigation cue dimensions changed",
                            {
                                "state": state,
                                "before_bytes": len(before_mask),
                                "after_bytes": len(after_mask),
                            },
                        )
                    changed_pixels = sum(
                        before_value != after_value
                        for before_value, after_value in zip(
                            before_mask, after_mask, strict=True
                        )
                    )
                    if changed_pixels >= minimum_changed_pixels:
                        acknowledged = True
                        return
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(0.1)

                if attempt + 1 < attempts:
                    # Reopen before retrying so a delayed first input cannot
                    # become an unintended double navigation. Preserve the
                    # review topology here: the full stop path restores every
                    # workspace to HEADLESS-UI and removes HEADLESS-AUX, while
                    # this retry only needs fresh production layer surfaces.
                    self._close_overview_layers(record)
                    self._open_overview_layers(record, state, output)
        finally:
            if acknowledged:
                for path in captured_paths:
                    path.unlink(missing_ok=True)
                self._guest(record).exec(
                    [
                        "rm",
                        "-f",
                        str(REMOTE_ARTIFACTS / "screenshots" / f"{before_name}.png"),
                        str(REMOTE_ARTIFACTS / "screenshots" / f"{after_name}.png"),
                    ],
                    timeout=10,
                    check=False,
                )
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "overview navigation did not produce its approved selection cue",
            {
                "state": state,
                "output": navigation_output,
                "scale": navigation_scale,
                "attempts": attempts,
                "cue": (
                    "cyan-window-edge"
                    if state == "selected-window"
                    else "violet-workspace-inset"
                ),
                "minimum_changed_pixels": minimum_changed_pixels,
                "changed_pixels": changed_pixels,
                "before_cue": before_cue,
                "after_cue": after_cue,
                "screenshots": sorted(str(path) for path in captured_paths),
            },
        )

    @staticmethod
    def _overview_navigation_cue_mask(
        image: Path,
        state: str,
        scale: float,
    ) -> bytes:
        color = "#62d8ff" if state == "selected-window" else "#9a5cff"
        width, height = (
            int(value) for value in physical_mode(scale).split("@", 1)[0].split("x")
        )
        y = min(height - 1, round(52 * scale))
        return subprocess.run(
            [
                "magick",
                str(image),
                "-crop",
                f"{width}x{height - y}+0+{y}",
                "+repage",
                "-alpha",
                "off",
                "-fill",
                "black",
                "+opaque",
                color,
                "-fill",
                "white",
                "-opaque",
                color,
                "-depth",
                "8",
                "gray:-",
            ],
            check=True,
            capture_output=True,
        ).stdout

    @staticmethod
    def _overview_navigation_cue_metrics(mask: bytes) -> dict[str, object]:
        return {
            "sha256": sha256(mask).hexdigest(),
            "selected_pixels": sum(value != 0 for value in mask),
        }

    def _start_overview_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
        scale: float,
        output: str,
        restart_service: bool,
    ) -> None:
        allowed_states = {
            "all-workspaces",
            "selected-window",
            "selected-workspace",
            "multi-monitor",
            "no-windows",
            "reduced-motion",
            "reduced-transparency",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid overview review state",
            )
        mode = physical_mode(scale)
        monitors = [
            {
                "name": output,
                "mode": mode,
                "position": "0x0",
                "scale": f"{scale:g}",
            }
        ]
        if state == "multi-monitor":
            auxiliary_scale = overview_auxiliary_scale(scale)
            monitors.append(
                {
                    "name": "HEADLESS-AUX",
                    "mode": physical_mode(auxiliary_scale),
                    "position": "1280x0",
                    "scale": f"{auxiliary_scale:g}",
                }
            )
        if restart_service:
            self._stop_overview_service(record)
            self._configure_virtual_displays(
                record,
                {"disable_unlisted": True, "monitors": monitors},
            )
            self._restart_overview_service(record, locale)
        guest = self._guest(record)
        found: dict[str, dict[str, Any]] = {}
        titles = [
            "app.tsx",
            "Documentation — Enoshima workstation integration reference",
            "Remote Desktop",
            "Meeting Notes",
            "성능 기록",
        ]
        if state != "no-windows":
            log_root = REMOTE_ARTIFACTS / "ui-review"
            commands: list[str] = []
            for index, title in enumerate(titles, start=1):
                commands.append(
                    f"nohup env LANG={locale} LC_ALL={locale} ghostty "
                    "--cursor-opacity=0 "
                    "--confirm-close-surface=false "
                    f"--title={shlex.quote(title)} -e sh -lc "
                    f"{shlex.quote('exec sleep infinity')} "
                    f">{log_root}/overview-{index}.log 2>&1 </dev/null &"
                )
            self._run_checked(
                record,
                f"start-overview-clients-{state}",
                self._hypr_command(" ".join(commands)),
                FailureCategory.VISUAL_ASSERTION_FAILED,
                timeout_seconds=30,
            )
            deadline = time.monotonic() + 30
            last_clients: list[dict[str, Any]] = []
            while time.monotonic() < deadline:
                result = guest.exec_retryable(
                    self._hypr_command("hyprctl -j clients"),
                    timeout=10,
                    check=False,
                )
                if result.returncode == 0:
                    last_clients = json.loads(result.stdout)
                    found = {
                        str(client.get("title", "")): client
                        for client in last_clients
                        if str(client.get("title", "")) in titles
                    }
                    if len(found) == len(titles):
                        break
                time.sleep(0.1)
            else:
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "overview review clients did not open",
                    {"found": sorted(found), "clients": last_clients},
                )
            for workspace, title in enumerate(titles, start=1):
                address = str(found[title]["address"])
                guest.exec(
                    self._hypr_command(
                        self._hypr_dispatch(
                            "hl.dsp.window.move({ workspace = "
                            f"{workspace}, follow = false, "
                            f'window = "address:{address}" }})'
                        )
                    ),
                    timeout=10,
                )
            if state == "multi-monitor":
                for workspace in (1, 2, 4):
                    guest.exec(
                        self._hypr_command(
                            self._hypr_dispatch(
                                "hl.dsp.workspace.move({ workspace = "
                                f'{workspace}, monitor = "HEADLESS-AUX" }})'
                            )
                        ),
                        timeout=10,
                    )
                workspaces = guest.exec_retryable(
                    self._hypr_command("hyprctl -j workspaces"),
                    timeout=15,
                )
                workspace_outputs = {
                    int(workspace.get("id", -1)): str(workspace.get("monitor", ""))
                    for workspace in json.loads(workspaces.stdout)
                    if isinstance(workspace, dict)
                }
                expected_outputs = {
                    1: "HEADLESS-AUX",
                    2: "HEADLESS-AUX",
                    3: output,
                    4: "HEADLESS-AUX",
                    5: output,
                }
                if any(
                    workspace_outputs.get(workspace) != expected
                    for workspace, expected in expected_outputs.items()
                ):
                    raise VMError(
                        FailureCategory.VISUAL_ASSERTION_FAILED,
                        "overview workspaces did not reach the intended outputs",
                        {
                            "expected": expected_outputs,
                            "actual": workspace_outputs,
                        },
                    )
                # Exercise keyboard navigation on the mixed-DPI output that
                # the cue assertion captures. Keeping the active workspace on
                # HEADLESS-UI would leave keyboard ownership on the primary
                # overview while requiring a selection change on HEADLESS-AUX.
                active_workspace = 1
            else:
                active_workspace = 1
            active_title = titles[active_workspace - 1]
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch(
                        f"hl.dsp.focus({{ workspace = {active_workspace} }})"
                    )
                ),
                timeout=10,
            )
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch(
                        'hl.dsp.focus({ window = "address:'
                        + str(found[active_title]["address"])
                        + '" })'
                    )
                ),
                timeout=10,
            )
        else:
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch("hl.dsp.focus({ workspace = 1 })")
                ),
                timeout=10,
            )
        self._open_overview_layers(record, state, output)
        self._acknowledge_overview_navigation(record, state, scale, output)

    @staticmethod
    def _ui_review_cleanup_targets(clients: list[object]) -> list[dict[str, Any]]:
        targets: list[dict[str, Any]] = []
        for value in clients:
            if not isinstance(value, dict):
                continue
            workspace = value.get("workspace")
            workspace_name = (
                str(workspace.get("name", "")) if isinstance(workspace, dict) else ""
            )
            # xembed-sni-proxy owns a tiny XWayland client on this reserved
            # workspace so legacy tray icons can be surfaced by the shell.
            # It is desktop infrastructure, not an application left behind
            # by a review scenario, and closing it would damage the session
            # that the remaining real-compositor cases must inspect.
            if workspace_name == "special:tray":
                continue
            targets.append(value)
        return targets

    def _close_ui_review_clients(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        result = guest.exec_retryable(
            self._hypr_command("hyprctl -j clients"), timeout=15, check=False
        )
        if result.returncode != 0:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "cannot enumerate desktop clients before UI review",
            )
        clients = json.loads(result.stdout)
        targets = self._ui_review_cleanup_targets(clients)
        for client in targets:
            address = str(client.get("address", ""))
            if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
                continue
            guest.exec(
                self._hypr_command(
                    "desktop-window-action close --address "
                    f"{address} --origin compositor"
                ),
                timeout=15,
                check=False,
            )
        deadline = time.monotonic() + 15
        remaining: list[object] = targets
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                remaining = self._ui_review_cleanup_targets(json.loads(result.stdout))
                if not remaining:
                    return
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "desktop clients remained after graceful UI-review cleanup",
            {"clients": remaining},
        )

    def _reset_ui_review_surface(self, record: dict[str, Any]) -> None:
        """Remove every prior review surface and late session-start client.

        Desktop autostart applications can become mapped after the initial
        review cleanup.  Resetting at every surface boundary prevents those
        clients from tiling a greeter or obscuring a shell capture while still
        preserving the reserved XEmbed tray infrastructure.
        """
        self._stop_command_palette_review(record)
        self._stop_overview_review(record)
        self._stop_auth_review(record)
        self._stop_notification_review(record)
        self._stop_titlebar_review(record)
        self._stop_desktop_shell_review(record)
        self._close_ui_review_clients(record)

    @staticmethod
    def _ui_review_identical_state_groups(
        captures: list[dict[str, object]],
    ) -> list[dict[str, object]]:
        groups: dict[tuple[str, str, float], dict[str, set[str]]] = {}
        for capture in captures:
            key = (
                str(capture.get("surface_id", "")),
                str(capture.get("locale", "")),
                float(capture.get("scale", 0)),
            )
            group = groups.setdefault(key, {"states": set(), "hashes": set()})
            group["states"].add(str(capture.get("state", "")))
            group["hashes"].add(
                str(capture.get("semantic_sha256") or capture.get("image_sha256", ""))
            )
        return [
            {
                "surface": surface,
                "locale": locale,
                "scale": scale,
                "states": sorted(group["states"]),
            }
            for (surface, locale, scale), group in sorted(groups.items())
            if len(group["states"]) > 1 and len(group["hashes"]) == 1
        ]

    @staticmethod
    def _ui_review_semantic_pixels(
        image: Path,
        surface: str,
        scale: float,
    ) -> bytes:
        width, height = (
            int(value) for value in physical_mode(scale).split("@", 1)[0].split("x")
        )
        if surface == "command-palette":
            crop_width = min(width, round(790 * scale))
            palette_height = min(height, round(500 * scale))
            search_height = min(palette_height - 1, round(68 * scale))
            x = max(0, (width - crop_width) // 2)
            y = max(0, (height - palette_height) // 2) + search_height
            crop_height = palette_height - search_height
        elif surface == "overview":
            x = 0
            y = min(height - 1, round(52 * scale))
            crop_width = width
            crop_height = height - y
        else:
            x = 0
            y = 0
            crop_width = width
            crop_height = height
        return subprocess.run(
            [
                "magick",
                str(image),
                "-crop",
                f"{crop_width}x{crop_height}+{x}+{y}",
                "+repage",
                "-colorspace",
                "Gray",
                "-resize",
                "25%",
                "-depth",
                "8",
                "gray:-",
            ],
            check=True,
            capture_output=True,
        ).stdout

    @classmethod
    def _ui_review_semantic_metrics(
        cls,
        image: Path,
        surface: str,
        scale: float,
    ) -> dict[str, object]:
        pixels = cls._ui_review_semantic_pixels(image, surface, scale)
        if not pixels:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "UI review semantic region is empty",
                {"image": str(image), "surface": surface, "scale": scale},
            )
        mean = sum(pixels) / len(pixels)
        normalized_stddev = (
            sum((value - mean) ** 2 for value in pixels) / len(pixels)
        ) ** 0.5 / 255
        return {
            "sha256": sha256(pixels).hexdigest(),
            "unique_gray_values": len(set(pixels)),
            "normalized_standard_deviation": round(normalized_stddev, 8),
        }

    @classmethod
    def _ui_review_semantic_sha256(
        cls,
        image: Path,
        surface: str,
        scale: float,
    ) -> str:
        return str(cls._ui_review_semantic_metrics(image, surface, scale)["sha256"])

    @staticmethod
    def _ui_review_identical_required_pairs(
        captures: list[dict[str, object]],
    ) -> list[dict[str, object]]:
        required_pairs = {
            "command-palette": (
                ("default", "search"),
                ("search", "empty-results"),
                ("search", "long-title"),
                ("clipboard-history", "emoji-picker"),
            ),
            "overview": (
                ("all-workspaces", "selected-window"),
                ("all-workspaces", "selected-workspace"),
                ("selected-window", "selected-workspace"),
                ("all-workspaces", "multi-monitor"),
                ("all-workspaces", "no-windows"),
            ),
        }
        indexed_captures = {
            (
                str(capture.get("surface_id", "")),
                str(capture.get("locale", "")),
                float(capture.get("scale", 0)),
                str(capture.get("state", "")),
            ): capture
            for capture in captures
        }
        failures: list[dict[str, object]] = []
        environments = sorted(
            {
                (surface, locale, scale)
                for surface, locale, scale, _state in indexed_captures
                if surface in required_pairs
            }
        )
        for surface, locale, scale in environments:
            for first, second in required_pairs[surface]:
                first_capture = indexed_captures.get((surface, locale, scale, first))
                second_capture = indexed_captures.get((surface, locale, scale, second))
                if first_capture is None or second_capture is None:
                    continue

                def semantic_hash(capture: dict[str, object]) -> str:
                    if surface == "overview" and {
                        first,
                        second,
                    } == {"all-workspaces", "multi-monitor"}:
                        outputs = capture.get("semantic_outputs")
                        if isinstance(outputs, dict):
                            primary = outputs.get("HEADLESS-UI")
                            if isinstance(primary, str):
                                return primary
                    return str(
                        capture.get("semantic_sha256")
                        or capture.get("image_sha256", "")
                    )

                first_hash = semantic_hash(first_capture)
                second_hash = semantic_hash(second_capture)
                if first_hash and first_hash == second_hash:
                    failures.append(
                        {
                            "surface": surface,
                            "locale": locale,
                            "scale": scale,
                            "states": [first, second],
                        }
                    )
        return failures

    def _start_desktop_shell_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        if state not in {
            "default",
            "active-window",
            "inactive-window",
            "internal-display",
            "external-display",
            "accessible",
        }:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid desktop shell review state"
            )
        self._stop_desktop_shell_review(record)
        guest = self._guest(record)
        log_root = REMOTE_ARTIFACTS / "ui-review"
        launch = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            'wayland=$WAYLAND_DISPLAY; test -n "$wayland"; '
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland ghostty --title='Enoshima Workspace' "
            '-e sh -lc \'printf "ENOSHIMA // WORKSPACE\\n\\nVM visual review\\n"; '
            f"exec sleep infinity' >{log_root}/desktop-ghostty.log 2>&1 "
            f"</dev/null & echo $! >{REMOTE_ROOT}/ui-fixture/desktop-ghostty.pid; "
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland thunar --window /home/kentakang "
            f">{log_root}/desktop-thunar.log 2>&1 </dev/null & "
            f"echo $! >{REMOTE_ROOT}/ui-fixture/desktop-thunar.pid"
        )
        self._run_checked(
            record,
            f"start-desktop-shell-review-{state}",
            self._hypr_command(launch),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        expected = {
            "ghostty": re.compile(r"ghostty", re.IGNORECASE),
            "thunar": re.compile(r"thunar", re.IGNORECASE),
        }
        found: dict[str, dict[str, Any]] = {}
        deadline = time.monotonic() + 30
        last_clients: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            result = guest.exec_retryable(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                last_clients = json.loads(result.stdout)
                for key, matcher in expected.items():
                    for client in last_clients:
                        identity = " ".join(
                            str(client.get(field, ""))
                            for field in ("class", "initialClass", "title")
                        )
                        if matcher.search(identity):
                            found[key] = client
                            break
                if len(found) == len(expected):
                    break
            time.sleep(0.1)
        else:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "desktop shell review applications did not open",
                {"found": sorted(found), "clients": last_clients},
            )
        for client in found.values():
            address = str(client["address"])
            guest.exec(
                self._hypr_command(
                    self._hypr_dispatch(
                        "hl.dsp.window.move({ workspace = 1, follow = false, "
                        f'window = "address:{address}" }})'
                    )
                ),
                timeout=10,
            )
        guest.exec(
            self._hypr_command(self._hypr_dispatch("hl.dsp.focus({ workspace = 1 })")),
            timeout=10,
        )
        focus_key = "thunar" if state == "inactive-window" else "ghostty"
        guest.exec(
            self._hypr_command(
                self._hypr_dispatch(
                    'hl.dsp.focus({ window = "address:'
                    + str(found[focus_key]["address"])
                    + '" })'
                )
            ),
            timeout=10,
        )

    def _restore_external_ui_review_services(
        self,
        record: dict[str, Any],
        surfaces: set[str],
    ) -> None:
        services = []
        if "command-palette" in surfaces:
            services.append("vicinae.service")
        if "overview" in surfaces:
            services.append("hyprshell.service")
        if not services:
            return
        units = " ".join(services)
        self._guest(record).exec(
            self._hypr_command(
                f"systemctl --user reset-failed {units} || true; "
                f"systemctl --user restart {units}"
            ),
            timeout=45,
        )

    def _cleanup_ui_review(
        self,
        record: dict[str, Any],
        surfaces: set[str],
        *,
        best_effort: bool,
    ) -> list[str]:
        notification_cleanup = (
            self._restore_notification_review
            if "notification-center" in surfaces
            else self._stop_notification_review
        )
        actions = [
            (
                "release pointer",
                lambda: self.backend.pointer_button(
                    record["domain"],
                    self._require_recorded_domain_uuid(record),
                    "left",
                    False,
                ),
            ),
            ("stop auth", lambda: self._stop_auth_review(record)),
            ("restore notifications", lambda: notification_cleanup(record)),
            ("stop command palette", lambda: self._stop_command_palette_review(record)),
            (
                "stop overview",
                lambda: self._stop_overview_review(
                    record,
                    best_effort=best_effort,
                ),
            ),
            ("stop titlebar", lambda: self._stop_titlebar_review(record)),
            ("stop desktop shell", lambda: self._stop_desktop_shell_review(record)),
            ("close clients", lambda: self._close_ui_review_clients(record)),
            (
                "restore external services",
                lambda: self._restore_external_ui_review_services(record, surfaces),
            ),
        ]
        errors: list[str] = []
        for label, action in actions:
            try:
                action()
            except Exception as error:
                errors.append(f"{label}: {error}")
        return errors

    def _run_ui_review(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        requested = values.get("surfaces")
        cleanup_surfaces = (
            {str(value) for value in requested}
            if isinstance(requested, list)
            else set()
        )
        failure: BaseException | None = None
        try:
            self._run_ui_review_body(record, config)
        except BaseException as error:
            failure = error
            raise
        finally:
            cleanup_errors = self._cleanup_ui_review(
                record,
                cleanup_surfaces,
                best_effort=failure is not None,
            )
            if cleanup_errors:
                record.setdefault("observations", {})["ui_review_cleanup_errors"] = (
                    cleanup_errors
                )
                self._write_record(record)
                if failure is None:
                    raise VMError(
                        FailureCategory.VISUAL_ASSERTION_FAILED,
                        "UI review cleanup did not restore the guest session",
                        {"errors": cleanup_errors},
                    )

    def _run_ui_review_body(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        requested = values.get("surfaces")
        if not isinstance(requested, list) or not requested:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "run_ui_review requires a non-empty surface list",
            )
        supported = {
            "auth",
            "command-palette",
            "desktop-shell",
            "launcher",
            "notification-center",
            "overview",
            "power-menu",
            "osd",
            "display-mode",
            "cyberdock-window-state",
            "snap-assist",
            "system-titlebar",
        }
        surfaces = {str(value) for value in requested}
        unsupported = surfaces - supported
        if unsupported:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "UI review surface lacks a real compositor adapter",
                {"surfaces": sorted(unsupported)},
            )
        matrix_mode = str(values.get("matrix_mode", "full"))
        requested_locales = values.get("locales")
        if requested_locales is not None and (
            not isinstance(requested_locales, list)
            or not requested_locales
            or not all(isinstance(locale, str) for locale in requested_locales)
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "run_ui_review locales must be a non-empty string list",
            )
        requested_scales = values.get("scales")
        if requested_scales is not None and (
            not isinstance(requested_scales, list)
            or not requested_scales
            or not all(isinstance(scale, (int, float)) for scale in requested_scales)
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "run_ui_review scales must be a non-empty number list",
            )
        locale_filter = (
            {str(locale) for locale in requested_locales}
            if requested_locales is not None
            else None
        )
        scale_filter = (
            {float(scale) for scale in requested_scales}
            if requested_scales is not None
            else None
        )
        matrix = select_ui_review_cases(
            load_ui_review_matrix(self.paths.repository),
            surfaces=surfaces,
            matrix_mode=matrix_mode,
            locales=locale_filter,
            scales=scale_filter,
        )
        if not matrix:
            raise VMError(FailureCategory.HARNESS_ERROR, "UI review matrix is empty")
        identities = load_ui_review_identities(self.paths.repository, surfaces)
        artifact_root = Path(record["artifact_dir"]) / "ui-review"
        artifact_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._close_ui_review_clients(record)
        if "notification-center" in surfaces:
            self._prepare_notification_review(record)
        output = "HEADLESS-UI"
        captures: list[dict[str, object]] = []
        overflow_failures: list[dict[str, object]] = []
        current_environment: tuple[str, float] | None = None
        command_palette_locale: str | None = None
        overview_environment: tuple[str, float] | None = None
        overview_previous_state: str | None = None
        for case in matrix:
            fixture_ack: dict[str, object] | None = None
            environment = (case.locale, case.scale)
            if environment != current_environment:
                if "overview" in surfaces:
                    self._stop_overview_service(record)
                mode = physical_mode(case.scale)
                self._configure_virtual_displays(
                    record,
                    {
                        "disable_unlisted": True,
                        "monitors": [
                            {
                                "name": output,
                                "mode": mode,
                                "position": "0x0",
                                "scale": f"{case.scale:g}",
                            }
                        ],
                    },
                )
                sequence = self._write_ui_fixture_state(
                    record, "desktop-shell", "default", output
                )
                self._restart_ui_review_shell(record, case.locale)
                self._wait_for_ui_fixture_ready(record, sequence)
                current_environment = environment
            self._reset_ui_review_surface(record)
            if "notification-center" not in surfaces:
                self._run_checked(
                    record,
                    "clear-ui-review-notifications",
                    self._hypr_command("swaync-client -cp -sw; swaync-client -C -sw"),
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    timeout_seconds=15,
                )
            # Hyprland client cleanup cannot dismiss Quickshell layer-shell
            # surfaces.  Reset the production shell model at every boundary
            # and wait for its exact sequence ACK before opening the next
            # surface so a launcher or power panel can never obscure a
            # greeter, SwayNC, or native titlebar capture.
            reset_sequence = self._write_ui_fixture_state(
                record, "desktop-shell", "default", output
            )
            self._wait_for_ui_fixture_ready(record, reset_sequence)
            titlebar_menu_state = case.surface == "system-titlebar" and case.state in {
                "keyboard-focus",
                "system-menu",
                "action-running",
                "action-error",
            }
            if titlebar_menu_state:
                self._wait_for_ui_review_layer(
                    record,
                    output,
                    "enoshima-window-menu",
                    present=False,
                )
            if case.surface == "auth":
                self._start_auth_review(record, case.locale, case.state)
            elif case.surface == "command-palette":
                restart_service = case.locale != command_palette_locale
                self._start_command_palette_review(
                    record,
                    case.locale,
                    case.state,
                    output,
                    restart_service,
                )
                command_palette_locale = case.locale
            elif case.surface == "notification-center":
                self._start_notification_review(record, case.locale, case.state)
            elif case.surface == "system-titlebar":
                client = self._start_titlebar_review(record, case.locale, case.state)
                sequence = self._write_ui_fixture_state(
                    record,
                    case.surface,
                    case.state,
                    output,
                    {"address": str(client["address"])},
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
                if titlebar_menu_state:
                    self._wait_for_ui_review_layer(
                        record,
                        output,
                        "enoshima-window-menu",
                        present=True,
                    )
            elif case.surface == "desktop-shell":
                self._start_desktop_shell_review(record, case.locale, case.state)
                sequence = self._write_ui_fixture_state(
                    record, case.surface, case.state, output
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
            elif case.surface == "overview":
                restart_service = (
                    environment != overview_environment
                    or case.state == "multi-monitor"
                    or overview_previous_state == "multi-monitor"
                )
                self._start_overview_review(
                    record,
                    case.locale,
                    case.state,
                    case.scale,
                    output,
                    restart_service,
                )
                overview_environment = environment
                overview_previous_state = case.state
            else:
                sequence = self._write_ui_fixture_state(
                    record, case.surface, case.state, output
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
            capture = self._capture_stable_ui(record, case.artifact_name, output)
            if case.surface == "system-titlebar":
                self.backend.pointer_button(
                    record["domain"],
                    self._require_recorded_domain_uuid(record),
                    "left",
                    False,
                )
            expected_width, expected_height = (
                int(value)
                for value in physical_mode(case.scale).split("@", 1)[0].split("x")
            )
            if (capture["width"], capture["height"]) != (
                expected_width,
                expected_height,
            ):
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "UI review capture has the wrong output dimensions",
                    {"case": case.key, "capture": capture},
                )
            auxiliary_outputs: list[dict[str, object]] = []
            if case.surface == "overview" and case.state == "multi-monitor":
                auxiliary_scale = overview_auxiliary_scale(case.scale)
                auxiliary_width, auxiliary_height = (
                    int(value)
                    for value in physical_mode(auxiliary_scale)
                    .split("@", 1)[0]
                    .split("x")
                )
                auxiliary = self._capture_stable_ui(
                    record,
                    f"{case.artifact_name}--headless-aux",
                    "HEADLESS-AUX",
                )
                if (auxiliary["width"], auxiliary["height"]) != (
                    auxiliary_width,
                    auxiliary_height,
                ):
                    raise VMError(
                        FailureCategory.VISUAL_ASSERTION_FAILED,
                        "auxiliary UI review capture has the wrong dimensions",
                        {"case": case.key, "capture": auxiliary},
                    )
                auxiliary_path = Path(str(auxiliary["path"]))
                auxiliary_semantic = self._ui_review_semantic_metrics(
                    auxiliary_path,
                    case.surface,
                    auxiliary_scale,
                )
                if (
                    int(auxiliary_semantic["unique_gray_values"])
                    < UI_SEMANTIC_MIN_UNIQUE_GRAY_VALUES
                    or float(auxiliary_semantic["normalized_standard_deviation"])
                    < UI_SEMANTIC_MIN_NORMALIZED_STDDEV
                ):
                    raise VMError(
                        FailureCategory.VISUAL_ASSERTION_FAILED,
                        "auxiliary overview lacks visible workspace content",
                        {
                            "case": case.key,
                            "expected_workspaces": [1, 2, 4],
                            "semantic_content": auxiliary_semantic,
                            "image": str(auxiliary_path),
                        },
                    )
                auxiliary_outputs.append(
                    {
                        "output": "HEADLESS-AUX",
                        "image": str(auxiliary_path),
                        "image_sha256": sha256(auxiliary_path.read_bytes()).hexdigest(),
                        "logical_size": [1280, 800],
                        "pixel_size": [auxiliary["width"], auxiliary["height"]],
                        "scale": auxiliary_scale,
                        "expected_workspaces": [1, 2, 4],
                        "semantic_content": auxiliary_semantic,
                        "stability_changed_pixel_ratio": auxiliary.get(
                            "stability_changed_pixel_ratio", 0.0
                        ),
                    }
                )
            image_path = Path(str(capture["path"]))
            semantic_outputs = {
                "HEADLESS-UI": self._ui_review_semantic_sha256(
                    image_path,
                    case.surface,
                    case.scale,
                )
            }
            for auxiliary in auxiliary_outputs:
                content = auxiliary["semantic_content"]
                if not isinstance(content, dict):
                    raise AssertionError("auxiliary semantic content is missing")
                semantic_outputs[str(auxiliary["output"])] = str(content["sha256"])
            if len(set(semantic_outputs.values())) != len(semantic_outputs):
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "multiple outputs rendered the same semantic UI region",
                    {"case": case.key, "semantic_outputs": semantic_outputs},
                )
            semantic_parts = [
                f"{output_name}:{output_hash}"
                for output_name, output_hash in semantic_outputs.items()
            ]
            semantic_sha256 = sha256("\0".join(semantic_parts).encode()).hexdigest()
            fixture_metadata = {
                "auth": {
                    "used": True,
                    "reason": "production greeter with deterministic visual auth state",
                },
                "notification-center": {
                    "used": False,
                    "reason": "production SwayNC and notification D-Bus state",
                },
                "command-palette": {
                    "used": case.state == "long-title",
                    "reason": (
                        "production Vicinae with one deterministic long-title "
                        "Script Command"
                        if case.state == "long-title"
                        else "production Vicinae over its packaged user service"
                    ),
                },
                "overview": {
                    "used": False,
                    "reason": (
                        "production Hyprshell over real Hyprland clients and "
                        "virtual outputs"
                    ),
                },
                "system-titlebar": {
                    "used": True,
                    "reason": (
                        "production native decoration on a real undecorated client; "
                        "deterministic menu result state where required"
                    ),
                },
            }.get(
                case.surface,
                {
                    "used": True,
                    "reason": "deterministic production-model state injection",
                },
            )
            sidecar = {
                "schema": 1,
                "surface_id": case.surface,
                "state": case.state,
                "locale": case.locale,
                "scale": case.scale,
                "output": output,
                "logical_size": [1280, 800],
                "pixel_size": [capture["width"], capture["height"]],
                "stability_changed_pixel_ratio": capture.get(
                    "stability_changed_pixel_ratio", 0.0
                ),
                "stability": {
                    "accepted_by": capture.get("stability_metric"),
                    "changed_pixel_ratio": capture.get(
                        "stability_changed_pixel_ratio", 0.0
                    ),
                    "normalized_rmse": capture.get("stability_normalized_rmse"),
                    "ssim_error": capture.get("stability_ssim_error"),
                },
                "image": str(image_path),
                "image_sha256": sha256(image_path.read_bytes()).hexdigest(),
                "semantic_sha256": semantic_sha256,
                "semantic_outputs": semantic_outputs,
                "auxiliary_outputs": auxiliary_outputs,
                "run_id": record["run_id"],
                "source_commit": record.get("source", {}).get("source_commit"),
                "worktree_hash": record.get("source", {}).get("worktree_hash"),
                **identities[case.surface],
                "text_overflow_count": (
                    fixture_ack.get("text_overflow_count")
                    if fixture_ack is not None
                    else None
                ),
                "fixture": fixture_metadata,
            }
            sidecar_path = artifact_root / f"{case.artifact_name}.json"
            sidecar_path.write_text(
                json.dumps(sidecar, indent=2) + "\n", encoding="utf-8"
            )
            captures.append(sidecar)
            if fixture_ack is not None and int(fixture_ack["text_overflow_count"]) > 0:
                overflow_failures.append(
                    {
                        "case": case.key,
                        "count": int(fixture_ack["text_overflow_count"]),
                        "image": str(image_path),
                    }
                )
        identical_state_failures = self._ui_review_identical_state_groups(captures)
        identical_pair_failures = self._ui_review_identical_required_pairs(captures)
        summary = {
            "schema": 1,
            "matrix_mode": matrix_mode,
            "expected": len(matrix),
            "actual": len(captures),
            "surfaces": sorted(surfaces),
            "locales": sorted({case.locale for case in matrix}),
            "scales": sorted({case.scale for case in matrix}),
            "text_overflow_failures": overflow_failures,
            "identical_state_failures": identical_state_failures,
            "identical_pair_failures": identical_pair_failures,
        }
        (artifact_root / "summary.json").write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8"
        )
        record.setdefault("observations", {})["ui_review"] = summary
        self._write_record(record)
        if overflow_failures:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "UI review found visible text outside its allocated bounds",
                {
                    "count": len(overflow_failures),
                    "failures": overflow_failures[:20],
                },
            )
        if identical_state_failures or identical_pair_failures:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "UI review rendered required states identically",
                {
                    "count": len(identical_state_failures)
                    + len(identical_pair_failures),
                    "failures": (identical_state_failures + identical_pair_failures)[
                        :20
                    ],
                },
            )

    def _run_electron_qualification(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        iterations = int(values.get("iterations", 20))
        if not 1 <= iterations <= 100:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "Electron qualification iterations must be between 1 and 100",
            )
        output = REMOTE_ARTIFACTS / "electron-qualification"
        fixture = REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "electron-window"
        driver = (
            REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "electron-qualification.py"
        )
        command = (
            f"install -d -m 0700 {output}; "
            f"python3 {driver} --fixture-root {fixture} --output {output} "
            f"--iterations {iterations}"
        )
        guest = self._guest(record)
        current = guest.exec(
            self._hypr_command(
                "hyprctl -j getoption plugin:enoshima_decoration:allowlist"
            ),
            timeout=20,
        )
        current_allowlist = str(json.loads(current.stdout).get("str", ""))
        try:
            self._run_checked(
                record,
                "electron-qualification",
                self._hypr_command(command),
                FailureCategory.DESKTOP_SESSION_FAILED,
                timeout_seconds=3600,
            )
        finally:
            guest.exec(
                self._hypr_command(
                    "hyprctl eval "
                    + shlex.quote(
                        self._decoration_allowlist_expression(current_allowlist)
                    )
                ),
                timeout=20,
                check=False,
            )
        summary = self._guest(record).exec(
            ["cat", str(output / "electron-summary.json")],
            timeout=15,
        )
        document = json.loads(summary.stdout)
        expected_actions = 2 * 3 * iterations * 10
        fallback_probes = document.get("nativeFallbackProbes")
        if (
            document.get("failures") != 0
            or document.get("combinations") != 6
            or document.get("actions") != expected_actions
            or document.get("decorationOwner") != "enoshima-system"
            or document.get("clientNativeMinimizeExposed") is not False
            or not isinstance(fallback_probes, list)
            or len(fallback_probes) != 2
            or {
                probe.get("backend")
                for probe in fallback_probes
                if isinstance(probe, dict)
            }
            != {"wayland", "x11"}
            or any(
                probe.get("backend") not in {"wayland", "x11"}
                or probe.get("processAlive") is not True
                or probe.get("workspaceUnchanged") is not True
                or probe.get("enoshimaDecorationAbsent") is not True
                for probe in fallback_probes
                if isinstance(probe, dict)
            )
            or any(not isinstance(probe, dict) for probe in fallback_probes)
            or document.get("coredumps")
        ):
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "Electron qualification summary is incomplete",
                {"summary": document, "expected_actions": expected_actions},
            )
        record.setdefault("observations", {})["electron_qualification"] = document
        self._write_record(record)

    @mutation_guard
    def collect(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        artifact_dir = Path(record["artifact_dir"])
        collected = collect_fixed_artifacts(
            self._guest(record), artifact_dir, REMOTE_ARTIFACTS
        )
        record["artifacts_collected_at"] = utc_now()
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_collect_artifacts", run_id=run_id)
        return {"artifact_dir": str(artifact_dir), "collected": collected}

    def status(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        domain_uuid = self._recorded_domain_uuid(record)
        if record.get("synthetic"):
            record["domain_state"] = "not-created"
        elif domain_uuid is None:
            record["domain_state"] = "ownership-unverified"
        else:
            record["domain_state"] = self.backend.owned_state(
                record["domain"], domain_uuid
            )
        return record

    @mutation_guard
    def poweroff(self, run_id: str) -> dict[str, str]:
        record = self.load_record(run_id)
        self.backend.poweroff(
            record["domain"], self._require_recorded_domain_uuid(record)
        )
        self._audit("vm_poweroff", run_id=run_id)
        return {"run_id": run_id, "status": "poweroff-requested"}

    @mutation_guard
    def destroy(self, run_id: str) -> dict[str, object]:
        run_dir = self._run_dir(run_id)
        with run_record_lock(run_dir):
            record = self.load_record(run_id)
            if run_cleanup_complete(record):
                return {"run_id": run_id, "removed": [], "recoverable": False}
            invalidated = record.get("status") == "invalidated"
            if not record.get("synthetic"):
                self._require_recorded_libvirt_session(record)
                self.backend.destroy(
                    record["domain"], self._require_recorded_domain_uuid(record)
                )
            self._stop_watchdog(record)
            self._wait_watchdog_stopped(record)
            removed = self._remove_ephemeral(record)
            if not invalidated:
                record["status"] = (
                    "completed" if record.get("result") == "passed" else "destroyed"
                )
            record["destroyed_at"] = utc_now()
            record["updated_at"] = utc_now()
            record.pop("private_key", None)
            record.pop("recovery_key", None)
            record.pop("login_password", None)
            self._write_record_unlocked(record)
        self._audit("vm_destroy", run_id=run_id)
        return {"run_id": run_id, "removed": removed, "recoverable": False}

    def _remove_ephemeral(self, record: dict[str, Any]) -> list[str]:
        run_dir = self._run_dir(record["run_id"])
        removed: list[str] = []
        file_targets = {
            run_dir / "root.qcow2",
            run_dir / "boot.qcow2",
            run_dir / "seed.iso",
            run_dir / WATCHDOG_READY_NAME,
        }
        for key in ("overlay", "boot_disk", "seed"):
            if record.get(key):
                file_targets.add(Path(record[key]))
        for value in file_targets:
            target = confined_path(run_dir, value)
            if target.exists():
                target.unlink()
                removed.append(str(target))
        for name in ("ssh", "cloud-init", "secrets", "swtpm"):
            target = confined_path(run_dir, run_dir / name)
            if target.exists():
                shutil.rmtree(target)
                removed.append(str(target))
        return removed

    def list_runs(self) -> list[dict[str, object]]:
        if not self.runs_root.exists():
            return []
        records = []
        for path in self.runs_root.glob("run-*/run.json"):
            try:
                records.append(self.load_record(path.parent.name))
            except (VMError, ValueError, json.JSONDecodeError):
                continue
        records.sort(
            key=lambda record: (
                str(record.get("updated_at") or record.get("created_at") or ""),
                str(record.get("run_id") or ""),
            ),
            reverse=True,
        )
        return records

    @mutation_guard
    def clean(self) -> dict[str, object]:
        cleaned: list[dict[str, object]] = []
        preserved: list[dict[str, str]] = []
        if not self.runs_root.exists():
            records: list[tuple[dict[str, object], str | None]] = []
        else:
            records = []
            for path in sorted(self.runs_root.glob("run-*/run.json")):
                try:
                    raw = json.loads(path.read_text(encoding="utf-8"))
                    if raw.get("run_id") != path.parent.name:
                        raise ValueError("run ID does not match its record path")
                    require_domain(str(raw.get("domain", "")))
                except (OSError, ValueError, json.JSONDecodeError) as error:
                    preserved.append(
                        {
                            "run_id": path.parent.name,
                            "reason": f"invalid-run-record: {error}",
                        }
                    )
                    continue
                recorded_session = raw.get("libvirt_session")
                expected_session = (
                    None if raw.get("synthetic") else self.backend.session_identity()
                )
                session_reason: str | None = None
                if not raw.get("synthetic") and recorded_session is None:
                    session_reason = "missing-libvirt-session"
                elif not raw.get("synthetic") and recorded_session != expected_session:
                    session_reason = "mismatched-libvirt-session"
                records.append((raw, session_reason))

        for record, session_reason in records:
            if run_cleanup_complete(record):
                continue
            if session_reason is not None:
                preserved.append(
                    {"run_id": str(record["run_id"]), "reason": session_reason}
                )
                continue
            if (
                not record.get("synthetic")
                and self._recorded_domain_uuid(record) is None
            ):
                preserved.append(
                    {
                        "run_id": str(record["run_id"]),
                        "reason": "missing-domain-uuid",
                    }
                )
                continue
            cleaned.append(self.destroy(str(record["run_id"])))
        return {
            "cleaned": cleaned,
            "preserved": preserved,
            "preserved_reports": True,
        }

    def _execute_step(
        self,
        record: dict[str, Any],
        suite: Suite,
        action: str,
        config: Any,
    ) -> None:
        if action == "wait_for_ssh":
            self._guest(record).wait_ssh()
        elif action == "wait_for_cloud_init":
            self._guest(record).wait_cloud_init()
        elif action == "wait_for_guest_agent":
            self.backend.wait_guest_agent(
                record["domain"], self._require_recorded_domain_uuid(record)
            )
        elif action == "upload_worktree":
            self.upload_worktree(record["run_id"])
        elif action == "seed_codex_electron_cache":
            self._seed_codex_electron_cache(record)
        elif action == "seed_pacman_cache":
            self._seed_pacman_cache(record)
        elif action == "run_validate":
            self._run_validate(record)
        elif action == "run_bootstrap":
            self._run_bootstrap(record, config)
        elif action == "run_postflight":
            self._run_postflight(record, config)
        elif action == "seed_sysstat_schema_migration":
            self._seed_sysstat_schema_migration(record)
        elif action == "assert_sysstat_schema_migration":
            self._assert_sysstat_schema_migration(record)
        elif action == "assert_idempotent":
            self._assert_idempotent(record)
        elif action == "assert_expected_skips":
            self._assert_expected_skips(record)
        elif action == "reboot":
            self.reboot(record["run_id"])
        elif action == "reboot_via_desktop_power":
            self._reboot_via_desktop_power(record, config)
        elif action == "configure_virtual_displays":
            self._configure_virtual_displays(record, config)
        elif action == "wait_for_client":
            self._wait_for_client(record, config)
        elif action == "assert_desktop_state":
            self._assert_desktop_state(record, config)
        elif action == "wait_for_layer":
            self._wait_for_layer(record, config)
        elif action == "prepare_login":
            self._prepare_login(record)
        elif action == "login_greetd":
            self._login_greetd(record)
        elif action == "assert_graphical_health":
            self._assert_graphical_health(record, config)
        elif action == "send_key":
            if not isinstance(config, dict) or not isinstance(config.get("keys"), list):
                raise VMError(FailureCategory.HARNESS_ERROR, "send_key requires keys")
            keys = [str(key) for key in config["keys"]]
            self.backend.send_keys(
                record["domain"], self._require_recorded_domain_uuid(record), keys
            )
        elif action == "send_pointer":
            if not isinstance(config, dict):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "send_pointer requires a mapping",
                )
            if "x" in config or "y" in config:
                if not isinstance(config.get("x"), int) or not isinstance(
                    config.get("y"), int
                ):
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "send_pointer requires integer x and y coordinates",
                    )
                self.backend.pointer_move_absolute(
                    record["domain"],
                    self._require_recorded_domain_uuid(record),
                    int(config["x"]),
                    int(config["y"]),
                )
            if "button" in config:
                self.backend.pointer_button(
                    record["domain"],
                    self._require_recorded_domain_uuid(record),
                    str(config["button"]),
                    bool(config.get("down", False)),
                )
        elif action == "query_desktop":
            desktop = self.query_desktop(record["run_id"])
            path = Path(record["artifact_dir"]) / "hyprctl" / "desktop.json"
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(json.dumps(desktop, indent=2) + "\n", encoding="utf-8")
        elif action == "screenshot":
            values = config if isinstance(config, dict) else {}
            output = values.get("output")
            self.screenshot(
                record["run_id"],
                str(values.get("name", "desktop")),
                str(output) if output is not None else None,
            )
        elif action == "run_ui_review":
            self._run_ui_review(record, config)
        elif action == "run_electron_qualification":
            self._run_electron_qualification(record, config)
        elif action == "collect_artifacts":
            self.collect(record["run_id"])
        elif action == "prepare_boot_disk":
            prepare_boot_disk(self, record)
        elif action == "boot_with_recovery":
            boot_with_recovery(self, record)
        elif action == "create_runtime_inventory":
            create_runtime_inventory(self, record)
        elif action == "assert_secure_boot":
            assert_secure_boot(self, record)
        elif action == "enroll_tpm":
            enroll_tpm(self, record)
        elif action == "test_recovery_path":
            test_recovery_path(self, record)
        elif action == "test_unsigned_rejection":
            test_unsigned_rejection(self, record)
        elif action == "collect_boot_security":
            collect_boot_security(self, record)
        else:
            raise VMError(
                FailureCategory.HARNESS_ERROR, f"unknown suite step: {action}"
            )

    @mutation_guard
    def run_suite(
        self,
        suite_name: str,
        *,
        keep_on_failure: bool = False,
        verification_mode: str = "release",
        surfaces: tuple[str, ...] = (),
        locales: tuple[str, ...] = (),
        scales: tuple[float, ...] = (),
        planned_source_commit: str | None = None,
        planned_worktree_digest: str | None = None,
        planned_source_tree_digest: str | None = None,
        planned_retry_digest: str | None = None,
        return_on_failure: bool = False,
    ) -> dict[str, Any]:
        canonical_suite = load_suite(suite_name, self.paths)
        mode = load_verification_mode(verification_mode, self.paths)
        suite = mode.apply(
            canonical_suite,
            surfaces=surfaces,
            locales=locales,
            scales=scales,
        )
        if mode.authoritative and (
            not planned_source_commit
            or not planned_worktree_digest
            or not planned_source_tree_digest
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "authoritative VM execution requires a frozen source identity",
            )
        record = self.create(
            suite_name,
            verification_mode=verification_mode,
            planned_source_commit=planned_source_commit,
            planned_worktree_digest=planned_worktree_digest,
            planned_source_tree_digest=planned_source_tree_digest,
            planned_retry_digest=planned_retry_digest,
        )
        try:
            for index, raw_step in enumerate(suite.steps, start=1):
                if isinstance(raw_step, str):
                    action, config = raw_step, None
                else:
                    action, config = next(iter(raw_step.items()))
                record = self.load_record(record["run_id"])
                record["current_step"] = action
                record["current_step_index"] = index
                record["updated_at"] = utc_now()
                self._write_record(record)
                step_started = time.monotonic()
                try:
                    self._execute_step(record, suite, action, config)
                except Exception:
                    record = self.load_record(record["run_id"])
                    record.setdefault("steps", []).append(
                        {
                            "index": index,
                            "action": action,
                            "status": "failed",
                            "duration_seconds": round(
                                time.monotonic() - step_started, 3
                            ),
                        }
                    )
                    self._write_record(record)
                    raise
                record = self.load_record(record["run_id"])
                record.setdefault("steps", []).append(
                    {
                        "index": index,
                        "action": action,
                        "status": "passed",
                        "duration_seconds": round(time.monotonic() - step_started, 3),
                    }
                )
                self._write_record(record)
            record = self.load_record(record["run_id"])
            record["result"] = "passed"
            record["status"] = "passed"
            record["category"] = None
            record["next_verification"] = (
                "release plan" if verification_mode == "checkpoint" else None
            )
            record["updated_at"] = utc_now()
            self._write_record(record)
            self._write_junit(record)
            self.destroy(record["run_id"])
            return self.load_record(record["run_id"])
        except Exception as error:
            record = self.load_record(record["run_id"])
            record["result"] = "failed"
            record["status"] = "failed"
            category = (
                error.category
                if isinstance(error, VMError)
                else FailureCategory.HARNESS_ERROR
            )
            record["category"] = str(category)
            record["error"] = str(error)
            record.update(
                failure_fields(
                    suite=suite_name,
                    step=str(record.get("current_step") or "") or None,
                    error=error,
                )
            )
            record["next_verification"] = (
                "change the relevant product or fixture source, then rerun the "
                f"{verification_mode} {suite_name} suite"
            )
            if isinstance(error, VMError) and error.details:
                record["details"] = error.details
            record["updated_at"] = utc_now()
            self._write_record(record)
            self._write_junit(record)
            try:
                self.collect(record["run_id"])
            except Exception as collection_error:
                record["collection_error"] = str(collection_error)
                self._write_record(record)
            if not keep_on_failure:
                self.destroy(record["run_id"])
            if return_on_failure:
                return self.load_record(record["run_id"])
            raise

    @mutation_guard
    def run_suite_result(
        self,
        suite_name: str,
        *,
        keep_on_failure: bool = False,
        verification_mode: str = "checkpoint",
        base_ref: str = "origin/main",
    ) -> dict[str, object]:
        self._assert_loaded_harness_current()
        if verification_mode == "release":
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "release evidence is available only from the canonical release plan",
            )
        load_suite(suite_name, self.paths)
        selection = select_verification(
            base_ref=base_ref,
            mode=verification_mode,
            paths=self.paths,
        )
        focused = run_focused_checks(selection, self.paths)
        assert_selection_unchanged(selection, self.paths)
        result = self._run_suite_with_retry_budget(
            suite_name,
            selection,
            keep_on_failure=keep_on_failure,
        )
        attempts = result.get("attempts")
        candidate = (
            attempts[-1]
            if isinstance(attempts, list) and attempts
            else result.get("failure")
        )
        response = dict(candidate) if isinstance(candidate, dict) else {}
        response.update(
            {
                "schema": 1,
                "suite": suite_name,
                "mode": verification_mode,
                "result": result.get("result"),
                "attemptCount": len(attempts) if isinstance(attempts, list) else 0,
                "focusedChecks": {
                    "result": focused.get("result"),
                    "artifactRoot": focused.get("artifactRoot"),
                    "count": len(focused.get("checks", [])),
                },
            }
        )
        if result.get("result") == "blocked":
            response["category"] = str(FailureCategory.VM_BLOCKED)
        return response

    def verification_plan(
        self,
        base_ref: str = "origin/main",
        mode: str = "checkpoint",
    ) -> dict[str, object]:
        return select_verification(
            base_ref=base_ref,
            mode=mode,
            paths=self.paths,
        ).to_dict()

    def check_affected(
        self,
        base_ref: str = "origin/main",
        mode: str = "checkpoint",
    ) -> dict[str, object]:
        selection = select_verification(
            base_ref=base_ref,
            mode=mode,
            paths=self.paths,
        )
        result = run_focused_checks(selection, self.paths)
        assert_selection_unchanged(selection, self.paths)
        return result

    def _prior_unchanged_failures(
        self,
        *,
        suite: str,
        retry_digest: str,
        source_tree_digest: str,
        verification_mode: str,
    ) -> list[dict[str, object]]:
        requested_mode = load_verification_mode(verification_mode, self.paths)

        def retry_identity_matches(record: dict[str, object]) -> bool:
            if record.get("current_step") == "run_validate":
                return record.get("planned_source_tree_digest") == source_tree_digest
            return record.get("planned_retry_digest") == retry_digest

        records = [
            record
            for record in self.list_runs()
            if record.get("suite") == suite
            and retry_identity_matches(record)
            and record.get("result") == "failed"
            and record.get("failure_fingerprint")
            and not record.get("source_invalidated")
            and (
                not requested_mode.authoritative
                or record.get("verification_mode") != "dev"
            )
        ]
        records.sort(key=lambda record: str(record.get("updated_at", "")), reverse=True)
        return records

    def _synthetic_failure_record(
        self,
        *,
        suite: str,
        mode: str,
        error: BaseException,
        source_commit: str | None = None,
        worktree_digest: str | None = None,
        retry_digest: str | None = None,
        source_tree_digest: str | None = None,
    ) -> dict[str, Any]:
        category = (
            error.category
            if isinstance(error, VMError)
            else FailureCategory.HARNESS_ERROR
        )
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        run_dir = self._run_dir(run_id)
        artifact_dir = run_dir / "artifacts"
        record: dict[str, Any] = {
            "schema": 1,
            "run_id": run_id,
            "domain": f"{DOMAIN_PREFIX}{run_id}",
            "suite": suite,
            "verification_mode": mode,
            "result": "failed",
            "status": "failed",
            "synthetic": True,
            "authoritative": False,
            "fresh_overlay": False,
            "fresh_overlay_required": load_verification_mode(
                mode, self.paths
            ).fresh_overlay_required,
            "planned_source_commit": source_commit,
            "planned_worktree_digest": worktree_digest,
            "planned_source_tree_digest": source_tree_digest,
            "planned_retry_digest": retry_digest,
            "current_step": "vm_create",
            "category": str(category),
            "error": str(error),
            "artifact_dir": str(artifact_dir),
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "next_verification": (
                "restore VM infrastructure or change the relevant fixture source"
            ),
        }
        if isinstance(error, VMError) and error.details:
            record["details"] = error.details
        record.update(failure_fields(suite=suite, step="vm_create", error=error))
        raw_root = artifact_dir / "runner"
        raw_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        raw_path = raw_root / "synthetic-error.json"
        raw_path.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "suite": suite,
                    "mode": mode,
                    "category": str(category),
                    "message": str(error),
                    "details": error.details if isinstance(error, VMError) else None,
                    "traceback": "".join(traceback.format_exception(error)),
                },
                indent=2,
                default=str,
            )
            + "\n",
            encoding="utf-8",
        )
        raw_path.chmod(0o600)
        record["synthetic_error_artifact"] = str(raw_path)
        self._write_record(record)
        self._audit("vm_synthetic_failure", run_id=run_id, result="failed")
        return record

    def _blocked_suite_result(
        self,
        *,
        suite: str,
        mode: str,
        message: str,
        previous: dict[str, object] | None = None,
    ) -> dict[str, object]:
        blocked: dict[str, object] = {
            "schema": 1,
            "suite": suite,
            "mode": mode,
            "result": "blocked",
            "category": str(FailureCategory.VM_BLOCKED),
            "errorExcerpt": message,
            "nextVerification": (
                "change the relevant source or restore VM infrastructure"
            ),
        }
        if previous:
            blocked["runId"] = previous.get("run_id")
            blocked["run_id"] = previous.get("run_id")
            blocked["failureOrigin"] = previous.get("failure_origin")
            blocked["failureFingerprint"] = previous.get("failure_fingerprint")
            blocked["artifactRoot"] = previous.get("artifact_dir")
        return blocked

    def _invalidate_attempt_record(
        self,
        record: dict[str, Any],
        error: BaseException,
    ) -> dict[str, Any]:
        run_id = record.get("run_id")
        if isinstance(run_id, str):
            try:
                record = self.load_record(run_id)
            except VMError:
                record = dict(record)
        record["invalidated_attempt"] = {
            "result": record.get("result"),
            "category": record.get("category"),
            "failure_origin": record.get("failure_origin"),
            "failure_fingerprint": record.get("failure_fingerprint"),
        }
        record["source_invalidated"] = True
        record["authoritative"] = False
        record["result"] = "failed"
        record["status"] = "invalidated"
        record["current_step"] = "source_freeze"
        record["category"] = str(
            error.category
            if isinstance(error, VMError)
            else FailureCategory.HARNESS_ERROR
        )
        record["error"] = str(error)
        record["next_verification"] = (
            "freeze the worktree, create a new verification plan, and rerun"
        )
        record.update(
            failure_fields(
                suite=str(record.get("suite")), step="source_freeze", error=error
            )
        )
        record["updated_at"] = utc_now()
        steps = record.setdefault("steps", [])
        if isinstance(steps, list) and not any(
            isinstance(step, dict) and step.get("action") == "source_freeze"
            for step in steps
        ):
            steps.append(
                {
                    "index": len(steps) + 1,
                    "action": "source_freeze",
                    "status": "failed",
                    "duration_seconds": 0,
                }
            )
        artifact_dir = record.get("artifact_dir")
        if isinstance(artifact_dir, str):
            raw_root = Path(artifact_dir) / "runner"
            raw_root.mkdir(mode=0o700, parents=True, exist_ok=True)
            raw_path = raw_root / "source-freeze-error.json"
            raw_path.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "message": str(error),
                        "details": (
                            error.details if isinstance(error, VMError) else None
                        ),
                    },
                    indent=2,
                    default=str,
                )
                + "\n",
                encoding="utf-8",
            )
            raw_path.chmod(0o600)
            record["source_freeze_artifact"] = str(raw_path)
        if isinstance(run_id, str):
            self._write_record(record)
            self._write_junit(record)
        return record

    def _run_suite_with_retry_budget(
        self,
        suite: str,
        selection: VerificationSelection,
        *,
        keep_on_failure: bool = False,
    ) -> dict[str, object]:
        retry_digest = selection.suite_retry_digests[suite]
        prior = self._prior_unchanged_failures(
            suite=suite,
            retry_digest=retry_digest,
            source_tree_digest=selection.source_tree_digest,
            verification_mode=selection.mode,
        )
        prior_product = next(
            (
                record
                for record in prior
                if record.get("failure_origin")
                in {str(FailureOrigin.PRODUCT), str(FailureOrigin.TEST_FIXTURE)}
            ),
            None,
        )
        if prior_product:
            return {
                "suite": suite,
                "result": "blocked",
                "attempts": [],
                "failure": self._blocked_suite_result(
                    suite=suite,
                    mode=selection.mode,
                    message=(
                        "unchanged product or test-fixture source already produced "
                        "an actionable failure"
                    ),
                    previous=prior_product,
                ),
            }

        prior_nonretryable_infra = next(
            (
                record
                for record in prior
                if record.get("failure_origin") == str(FailureOrigin.INFRA)
                and not retryable_infrastructure_failure(record)
            ),
            None,
        )
        if prior_nonretryable_infra:
            return {
                "suite": suite,
                "result": "blocked",
                "attempts": [],
                "failure": self._blocked_suite_result(
                    suite=suite,
                    mode=selection.mode,
                    message=(
                        "unchanged infrastructure integrity failure is not "
                        "eligible for automatic retry"
                    ),
                    previous=prior_nonretryable_infra,
                ),
            }

        infra_counts = Counter(
            str(record["failure_fingerprint"])
            for record in prior
            if record.get("failure_origin") == str(FailureOrigin.INFRA)
        )
        capacity_fingerprint = failure_fingerprint(
            suite=suite,
            step="vm_create",
            category=FailureCategory.HOST_INFRA_ERROR,
            message=_ACTIVE_DOMAIN_CAPACITY_ERROR,
        )
        capacity_recovered = False
        if infra_counts.get(capacity_fingerprint, 0) >= 2:
            try:
                capacity_recovered = (
                    len(self.backend.active_managed_domains()) < MAX_ACTIVE_DOMAINS
                )
            except Exception:
                # A failed capacity probe cannot prove that the contention is gone.
                capacity_recovered = False
        exhausted_fingerprint = next(
            (
                fingerprint
                for fingerprint, count in infra_counts.items()
                if count >= 2
                and not (capacity_recovered and fingerprint == capacity_fingerprint)
            ),
            None,
        )
        if exhausted_fingerprint:
            previous = next(
                record
                for record in prior
                if record.get("failure_fingerprint") == exhausted_fingerprint
            )
            return {
                "suite": suite,
                "result": "blocked",
                "attempts": [],
                "failure": self._blocked_suite_result(
                    suite=suite,
                    mode=selection.mode,
                    message=(
                        "the same infrastructure fingerprint already occurred "
                        "twice without a relevant source change"
                    ),
                    previous=previous,
                ),
            }

        attempts: list[dict[str, object]] = []
        for attempt_index in range(2):
            try:
                assert_selection_unchanged(selection, self.paths)
            except Exception as error:
                record = self._synthetic_failure_record(
                    suite=suite,
                    mode=selection.mode,
                    error=error,
                    source_commit=selection.source_commit,
                    worktree_digest=selection.worktree_digest,
                    retry_digest=retry_digest,
                    source_tree_digest=selection.source_tree_digest,
                )
                record = self._invalidate_attempt_record(record, error)
                summary = summarize_run_record(record)
                attempts.append(summary)
                return {
                    "suite": suite,
                    "result": "blocked",
                    "attempts": attempts,
                    "failure": self._blocked_suite_result(
                        suite=suite,
                        mode=selection.mode,
                        message="the worktree changed after verification selection",
                        previous=record,
                    ),
                }
            existing_run_ids = {
                str(candidate.get("run_id")) for candidate in self.list_runs()
            }
            try:
                record = self.run_suite(
                    suite,
                    keep_on_failure=keep_on_failure,
                    verification_mode=selection.mode,
                    surfaces=(
                        selection.surfaces
                        if suite == "ui-review" and selection.mode != "release"
                        else ()
                    ),
                    locales=(
                        selection.locales
                        if suite == "ui-review" and selection.mode != "release"
                        else ()
                    ),
                    scales=(
                        selection.scales
                        if suite == "ui-review" and selection.mode != "release"
                        else ()
                    ),
                    planned_source_commit=selection.source_commit,
                    planned_worktree_digest=selection.worktree_digest,
                    planned_source_tree_digest=selection.source_tree_digest,
                    planned_retry_digest=retry_digest,
                    return_on_failure=True,
                )
            except Exception as error:
                candidates = [
                    candidate
                    for candidate in self._prior_unchanged_failures(
                        suite=suite,
                        retry_digest=retry_digest,
                        source_tree_digest=selection.source_tree_digest,
                        verification_mode=selection.mode,
                    )
                    if str(candidate.get("run_id")) not in existing_run_ids
                ]
                record = (
                    candidates[0]
                    if candidates
                    else self._synthetic_failure_record(
                        suite=suite,
                        mode=selection.mode,
                        error=error,
                        source_commit=selection.source_commit,
                        worktree_digest=selection.worktree_digest,
                        retry_digest=retry_digest,
                        source_tree_digest=selection.source_tree_digest,
                    )
                )
            if record.get("category") == str(FailureCategory.SOURCE_INVALIDATED):
                invalidation = VMError(
                    FailureCategory.SOURCE_INVALIDATED,
                    str(record.get("error") or "uploaded source did not match plan"),
                    (
                        record.get("details")
                        if isinstance(record.get("details"), dict)
                        else None
                    ),
                )
                record = self._invalidate_attempt_record(record, invalidation)
                summary = summarize_run_record(record)
                attempts.append(summary)
                return {
                    "suite": suite,
                    "result": "blocked",
                    "attempts": attempts,
                    "failure": self._blocked_suite_result(
                        suite=suite,
                        mode=selection.mode,
                        message="the uploaded source did not match the frozen plan",
                        previous=record,
                    ),
                }
            try:
                assert_selection_unchanged(selection, self.paths)
            except Exception as error:
                record = self._invalidate_attempt_record(record, error)
                summary = summarize_run_record(record)
                attempts.append(summary)
                return {
                    "suite": suite,
                    "result": "blocked",
                    "attempts": attempts,
                    "failure": self._blocked_suite_result(
                        suite=suite,
                        mode=selection.mode,
                        message="the worktree changed during suite execution",
                        previous=record,
                    ),
                }
            summary = summarize_run_record(record)
            attempts.append(summary)
            if record.get("result") == "passed":
                return {"suite": suite, "result": "passed", "attempts": attempts}

            origin = record.get("failure_origin")
            fingerprint = record.get("failure_fingerprint")
            if origin != str(FailureOrigin.INFRA):
                return {
                    "suite": suite,
                    "result": "failed",
                    "attempts": attempts,
                }
            if not retryable_infrastructure_failure(record):
                return {
                    "suite": suite,
                    "result": "failed",
                    "attempts": attempts,
                }
            same_failures = [
                failure
                for failure in self._prior_unchanged_failures(
                    suite=suite,
                    retry_digest=retry_digest,
                    source_tree_digest=selection.source_tree_digest,
                    verification_mode=selection.mode,
                )
                if failure.get("failure_fingerprint") == fingerprint
            ]
            local_same_failures = sum(
                1
                for attempt in attempts
                if attempt.get("failureFingerprint") == fingerprint
            )
            if max(len(same_failures), local_same_failures) >= 2:
                return {
                    "suite": suite,
                    "result": "blocked",
                    "attempts": attempts,
                    "failure": self._blocked_suite_result(
                        suite=suite,
                        mode=selection.mode,
                        message=(
                            "the same infrastructure fingerprint occurred twice "
                            "without a relevant source change"
                        ),
                        previous=record,
                    ),
                }
            if keep_on_failure and attempt_index == 0:
                run_id = record.get("run_id")
                if isinstance(run_id, str):
                    # Keep only the final diagnostic attempt. Releasing the
                    # intermediate domain preserves the one-domain boundary
                    # and permits the fresh infrastructure retry.
                    self.destroy(run_id)
            if attempt_index == 1:
                break
        return {"suite": suite, "result": "failed", "attempts": attempts}

    def _write_operation_report(
        self,
        *,
        operation: str,
        selection: VerificationSelection,
        suites: tuple[str, ...],
        results: list[dict[str, object]],
        focused_checks: dict[str, object] | None = None,
        operation_id: str | None = None,
        complete: bool = True,
        operation_error: BaseException | None = None,
    ) -> dict[str, object]:
        operation_id = operation_id or f"{operation}-{uuid.uuid4().hex[:12]}"
        root = self.paths.state / "plans" / operation_id
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        path = root / "plan.json"
        if focused_checks is None and operation_error is not None:
            failed_checks: list[object] = []
            if (
                isinstance(operation_error, VMError)
                and isinstance(operation_error.details, dict)
                and isinstance(operation_error.details.get("checks"), list)
            ):
                failed_checks = operation_error.details["checks"]
            artifact_root: str | None = None
            if failed_checks and isinstance(failed_checks[0], dict):
                stdout_artifact = failed_checks[0].get("stdoutArtifact")
                if isinstance(stdout_artifact, str):
                    artifact_root = str(Path(stdout_artifact).parent)
            focused_checks = {
                "result": "failed",
                "checks": failed_checks,
                "artifactRoot": artifact_root,
            }
        created_at = utc_now()
        if path.is_file():
            try:
                previous = json.loads(path.read_text(encoding="utf-8"))
                created_at = str(previous.get("createdAt") or created_at)
            except (OSError, json.JSONDecodeError):
                pass
        verdict = "running"
        if operation_error is not None:
            verdict = "failed"
        elif not complete:
            verdict = "running"
        elif any(result.get("result") == "blocked" for result in results):
            verdict = "blocked"
        elif any(result.get("result") == "failed" for result in results):
            verdict = "failed"
        else:
            verdict = "passed"
        report = {
            "schema": 1,
            "operationId": operation_id,
            "operation": operation,
            "result": verdict,
            "authoritative": selection.authoritative and complete,
            "createdAt": created_at,
            "updatedAt": utc_now(),
            "selection": selection.to_dict(),
            "suites": list(suites),
            "suiteResults": results,
            "focusedChecks": focused_checks,
            "artifactRoot": str(root),
        }
        if operation_error is not None:
            report["operationError"] = {
                "category": str(
                    operation_error.category
                    if isinstance(operation_error, VMError)
                    else FailureCategory.HARNESS_ERROR
                ),
                "message": str(operation_error),
            }
        temporary = root / "plan.json.new"
        temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(temporary, path)

        compact_results: list[dict[str, object]] = []
        first_failure: dict[str, object] | None = None
        for result in results:
            attempts = result.get("attempts")
            last_attempt = (
                attempts[-1]
                if isinstance(attempts, list) and attempts
                else result.get("failure")
            )
            compact = {
                "suite": result.get("suite"),
                "result": result.get("result"),
                "attemptCount": len(attempts) if isinstance(attempts, list) else 0,
            }
            if isinstance(last_attempt, dict):
                for key in (
                    "runId",
                    "failedStep",
                    "category",
                    "failureOrigin",
                    "failureFingerprint",
                    "artifactRoot",
                ):
                    if last_attempt.get(key) is not None:
                        compact[key] = last_attempt[key]
                if first_failure is None and result.get("result") != "passed":
                    first_failure = last_attempt
            compact_results.append(compact)
        response: dict[str, object] = {
            "schema": 1,
            "operationId": operation_id,
            "operation": operation,
            "mode": selection.mode,
            "result": verdict,
            "sourceCommit": selection.source_commit,
            "worktreeDigest": selection.worktree_digest,
            "authoritative": selection.authoritative and complete,
            "suites": compact_results,
            "physicalGates": list(selection.physical_gates),
            "artifactRoot": str(root),
        }
        if focused_checks is not None:
            response["focusedChecks"] = {
                "result": focused_checks.get("result"),
                "artifactRoot": focused_checks.get("artifactRoot"),
                "count": len(focused_checks.get("checks", [])),
            }
        if first_failure:
            response["firstFailure"] = first_failure
        if len(json.dumps(response, sort_keys=True).encode()) > 32 * 1024:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "bounded VM operation summary exceeded 32 KiB",
            )
        return response

    @mutation_guard
    def run_affected(
        self,
        base_ref: str = "origin/main",
        mode: str = "checkpoint",
    ) -> dict[str, object]:
        self._assert_loaded_harness_current()
        if mode == "release":
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "release mode requires the canonical release plan",
            )
        selection = select_verification(
            base_ref=base_ref,
            mode=mode,
            paths=self.paths,
        )
        operation_id = f"affected-{uuid.uuid4().hex[:12]}"
        results: list[dict[str, object]] = []
        focused: dict[str, object] | None = None
        self._write_operation_report(
            operation="affected",
            selection=selection,
            suites=selection.suites,
            results=results,
            operation_id=operation_id,
            complete=False,
        )
        try:
            focused = run_focused_checks(selection, self.paths)
            self._write_operation_report(
                operation="affected",
                selection=selection,
                suites=selection.suites,
                results=results,
                focused_checks=focused,
                operation_id=operation_id,
                complete=False,
            )
            assert_selection_unchanged(selection, self.paths)
            mode_definition = load_verification_mode(mode, self.paths)
            for suite in selection.suites:
                result = self._run_suite_with_retry_budget(suite, selection)
                results.append(result)
                self._write_operation_report(
                    operation="affected",
                    selection=selection,
                    suites=selection.suites,
                    results=results,
                    focused_checks=focused,
                    operation_id=operation_id,
                    complete=False,
                )
                if result.get("result") != "passed" and mode_definition.fail_fast:
                    break
        except BaseException as error:
            self._write_operation_report(
                operation="affected",
                selection=selection,
                suites=selection.suites,
                results=results,
                focused_checks=focused,
                operation_id=operation_id,
                complete=False,
                operation_error=error,
            )
            raise
        return self._write_operation_report(
            operation="affected",
            selection=selection,
            suites=selection.suites,
            results=results,
            focused_checks=focused,
            operation_id=operation_id,
        )

    @mutation_guard
    def run_plan(
        self,
        plan_name: str = "release",
        *,
        base_ref: str = "origin/main",
    ) -> dict[str, object]:
        self._assert_loaded_harness_current()
        plan = load_verification_plan(plan_name, self.paths)
        selection = select_verification(
            base_ref=base_ref,
            mode=plan.mode,
            paths=self.paths,
        )
        if plan.mode == "release":
            checks = [
                command
                for command in selection.focused_checks
                if command != "make vm-unit"
            ]
            if "scripts/check-ui-visual-evidence" not in checks:
                checks.append("scripts/check-ui-visual-evidence")
            if "make validate" not in checks:
                checks.append("make validate")
            selection = replace(selection, focused_checks=tuple(checks))
        operation_id = f"{plan.name}-{uuid.uuid4().hex[:12]}"
        results: list[dict[str, object]] = []
        focused: dict[str, object] | None = None
        self._write_operation_report(
            operation=plan.name,
            selection=selection,
            suites=plan.suites,
            results=results,
            operation_id=operation_id,
            complete=False,
        )
        try:
            focused = run_focused_checks(selection, self.paths)
            self._write_operation_report(
                operation=plan.name,
                selection=selection,
                suites=plan.suites,
                results=results,
                focused_checks=focused,
                operation_id=operation_id,
                complete=False,
            )
            assert_selection_unchanged(selection, self.paths)
            mode_definition = load_verification_mode(plan.mode, self.paths)
            for suite in plan.suites:
                result = self._run_suite_with_retry_budget(suite, selection)
                results.append(result)
                self._write_operation_report(
                    operation=plan.name,
                    selection=selection,
                    suites=plan.suites,
                    results=results,
                    focused_checks=focused,
                    operation_id=operation_id,
                    complete=False,
                )
                if result.get("result") == "blocked" or (
                    result.get("result") != "passed" and mode_definition.fail_fast
                ):
                    break
        except BaseException as error:
            self._write_operation_report(
                operation=plan.name,
                selection=selection,
                suites=plan.suites,
                results=results,
                focused_checks=focused,
                operation_id=operation_id,
                complete=False,
                operation_error=error,
            )
            raise
        return self._write_operation_report(
            operation=plan.name,
            selection=selection,
            suites=plan.suites,
            results=results,
            focused_checks=focused,
            operation_id=operation_id,
        )
