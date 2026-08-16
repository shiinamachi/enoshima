from __future__ import annotations

import ctypes
import os
import runpy
import signal
import sys
from pathlib import Path

PR_SET_PDEATHSIG = 1


def _configure_parent_death_signal(signum: int) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_PDEATHSIG, signum, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def _set_parent_death_signal(expected_parent_pid: int) -> bool:
    _configure_parent_death_signal(signal.SIGTERM)
    return os.getppid() == expected_parent_pid


def _enable_environment() -> None:
    # The launcher uses ``-I -S`` so neither PYTHONPATH nor sitecustomize can
    # execute before parent-death signaling is armed. Enabling the reviewed
    # virtual-environment site directory happens only after that boundary.
    explicit_paths = [
        path for path in os.environ.get("PYTHONPATH", "").split(os.pathsep) if path
    ]
    sys.path[:0] = explicit_paths

    import site

    site.main()


def _configure_bytecode() -> None:
    # ``-I`` ignores PYTHON* during interpreter startup. Apply the unique
    # worker cache root after the safety boundary so timestamp/size-valid pyc
    # from a previous mutable harness revision can never be reused.
    cache_prefix = os.environ.get("PYTHONPYCACHEPREFIX")
    if cache_prefix:
        sys.pycache_prefix = cache_prefix
    sys.dont_write_bytecode = True


def main() -> None:
    if len(sys.argv) < 4 or sys.argv[1] != "--expected-parent-pid":
        raise SystemExit(
            "usage: process_bootstrap --expected-parent-pid PID TARGET [ARGS ...]"
        )
    expected_parent_pid = int(sys.argv[2])
    if expected_parent_pid <= 1:
        raise SystemExit("process bootstrap requires a valid parent pid")

    # SIG_IGN survives exec. Reset it before arming PDEATHSIG so a launcher
    # cannot accidentally make the pre-import bootstrap survive its parent.
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    if not _set_parent_death_signal(expected_parent_pid):
        raise SystemExit(128 + signal.SIGTERM)

    target = Path(sys.argv[3]).resolve()
    sys.argv = [str(target), *sys.argv[4:]]
    _enable_environment()
    _configure_bytecode()
    if (
        len(sys.argv) > 1
        and sys.argv[1] == "--worker"
        and "--operation-dir" in sys.argv
    ):
        # Durable workers intentionally outlive the MCP transport that started
        # them. Disarm only this outer supervisor: guardian and payload
        # bootstraps retain PDEATHSIG so a supervisor crash cannot orphan a
        # pre-import descendant or its inherited mutation locks.
        _configure_parent_death_signal(0)
    runpy.run_path(str(target), run_name="__main__")


if __name__ == "__main__":
    main()
