from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

import enoshima_vm.process as process_module
from enoshima_vm.process import ProcessIdleTimeout, run


def test_silent_process_is_stopped_at_the_idle_budget() -> None:
    started = time.monotonic()
    with pytest.raises(ProcessIdleTimeout) as raised:
        run(
            [sys.executable, "-c", "import time; time.sleep(5)"],
            timeout=5,
            idle_timeout=0.3,
        )

    assert time.monotonic() - started < 2
    assert raised.value.idle_timeout == 0.3


def test_output_progress_resets_the_idle_budget() -> None:
    result = run(
        [
            sys.executable,
            "-c",
            (
                "import time; "
                "[(print(i, flush=True), time.sleep(0.1)) for i in range(5)]"
            ),
        ],
        timeout=2,
        idle_timeout=0.35,
    )

    assert result.returncode == 0
    assert result.stdout.splitlines() == ["0", "1", "2", "3", "4"]


def test_absolute_timeout_bounds_carriage_return_progress_on_stderr() -> None:
    with pytest.raises(subprocess.TimeoutExpired) as raised:
        run(
            [
                sys.executable,
                "-c",
                (
                    "import time; "
                    "import sys,time; "
                    "[(sys.stderr.write(f'\\r{i}'), sys.stderr.flush(), "
                    "time.sleep(0.05)) for i in range(100)]"
                ),
            ],
            timeout=0.4,
            idle_timeout=0.2,
        )

    assert not isinstance(raised.value, ProcessIdleTimeout)


def test_idle_timeout_kills_a_term_ignoring_descendant(tmp_path: Path) -> None:
    child_pid_file = tmp_path / "child.pid"
    script = (
        "import pathlib, signal, subprocess, sys, time; "
        "child = subprocess.Popen([sys.executable, '-c', "
        "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '"
        "'time.sleep(30)']); "
        f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid)); "
        "time.sleep(30)"
    )

    with pytest.raises(ProcessIdleTimeout):
        run(
            [sys.executable, "-c", script],
            timeout=5,
            idle_timeout=0.3,
        )

    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        stat = Path(f"/proc/{child_pid}/stat")
        if stat.is_file() and stat.read_text(encoding="utf-8").split()[2] == "Z":
            break
        time.sleep(0.01)
    else:
        pytest.fail("SIGTERM-ignoring descendant remained alive after group cleanup")


def test_absolute_timeout_without_idle_monitor_kills_process_group(
    tmp_path: Path,
) -> None:
    child_pid_file = tmp_path / "absolute-child.pid"
    script = (
        "import pathlib, subprocess, sys, time; "
        "child = subprocess.Popen([sys.executable, '-c', "
        "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '"
        "'time.sleep(30)']); "
        f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid)); "
        "time.sleep(30)"
    )

    with pytest.raises(subprocess.TimeoutExpired):
        run([sys.executable, "-c", script], timeout=0.4)

    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        stat = Path(f"/proc/{child_pid}/stat")
        if not stat.is_file() or stat.read_text(encoding="utf-8").split()[2] == "Z":
            break
        time.sleep(0.01)
    else:
        pytest.fail("absolute timeout left a command descendant alive")


def test_exception_unwind_kills_the_command_process_group(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    child_pid_file = tmp_path / "child.pid"
    leader_pid_file = tmp_path / "leader.pid"
    script = (
        "import os,pathlib,signal,subprocess,sys,time; "
        f"pathlib.Path({str(leader_pid_file)!r}).write_text(str(os.getpid())); "
        "child = subprocess.Popen([sys.executable, '-c', "
        "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '"
        "'time.sleep(30)']); "
        f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid)); "
        "time.sleep(30)"
    )
    real_sleep = time.sleep

    class SimulatedWorkerSignal(BaseException):
        pass

    def interrupt_after_child_started(_seconds: float) -> None:
        deadline = time.monotonic() + 2
        while not child_pid_file.is_file() and time.monotonic() < deadline:
            real_sleep(0.01)
        raise SimulatedWorkerSignal

    monkeypatch.setattr(process_module.time, "sleep", interrupt_after_child_started)
    with pytest.raises(SimulatedWorkerSignal):
        run(
            [sys.executable, "-c", script],
            timeout=30,
            idle_timeout=20,
        )

    for pid_file in (leader_pid_file, child_pid_file):
        pid = int(pid_file.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            stat = Path(f"/proc/{pid}/stat")
            if not stat.is_file() or stat.read_text(encoding="utf-8").split()[2] == "Z":
                break
            real_sleep(0.01)
        else:
            pytest.fail(f"process {pid} survived exception cleanup")
