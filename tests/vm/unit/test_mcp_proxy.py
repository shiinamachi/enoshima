from __future__ import annotations

import fcntl
import importlib.util
import json
import os
import py_compile
import select
import shutil
import signal
import subprocess
import sys
import textwrap
import threading
import time
import zipfile
from pathlib import Path

import anyio
import pytest
from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client


def write_fake_harness(
    root: Path,
    *,
    value: str,
    delay_seconds: float = 0,
    crash_selector: bool = False,
    crash_durable: bool = False,
    hang_selector: bool = False,
    durable_result: str = "passed",
) -> None:
    package = root / "enoshima_vm"
    package.mkdir(exist_ok=True)
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "service.py").write_text(
        "\n".join(
            [
                f"VALUE = {value!r}",
                f"DELAY_SECONDS = {delay_seconds!r}",
                f"CRASH_SELECTOR = {crash_selector!r}",
                f"CRASH_DURABLE = {crash_durable!r}",
                f"HANG_SELECTOR = {hang_selector!r}",
                f"DURABLE_RESULT = {durable_result!r}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (package / "config.py").write_text(
        """\
from types import SimpleNamespace


def load_suite(name):
    return SimpleNamespace(name=name, timeout_minutes=5)
""",
        encoding="utf-8",
    )
    (package / "verification.py").write_text(
        """\
from types import SimpleNamespace


def load_verification_plan(name):
    return SimpleNamespace(name=name, suites=("smoke", "converge"))
""",
        encoding="utf-8",
    )
    (package / "mcp_server.py").write_text(
        """\
import os
import signal
import time

from . import service


def operation_lock_identity():
    raw_fd = os.environ.get("ENOSHIMA_VM_OPERATION_LOCK_FD")
    if raw_fd is None:
        return {}
    stat = os.fstat(int(raw_fd))
    return {
        "operationLockFd": raw_fd,
        "operationLockDevice": stat.st_dev,
        "operationLockInode": stat.st_ino,
    }


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    if service.CRASH_SELECTOR:
        os.kill(os.getpid(), signal.SIGTERM)
    if service.HANG_SELECTOR:
        while True:
            time.sleep(60)
    return {
        "schema": 1,
        "base": base_ref,
        "mode": mode,
        "sourceCommit": "fake-commit",
        "worktreeDigest": service.VALUE,
        "sourceTreeDigest": service.VALUE,
        "suites": ["smoke"],
        "workerPid": os.getpid(),
    }


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    if service.CRASH_DURABLE:
        os.kill(os.getpid(), signal.SIGKILL)
    time.sleep(service.DELAY_SECONDS)
    return {
        "schema": 1,
        "result": service.DURABLE_RESULT,
        "base": base_ref,
        "mode": mode,
        "value": service.VALUE,
        "workerPid": os.getpid(),
        **operation_lock_identity(),
    }


def vm_run_plan(plan="release", base_ref="origin/main"):
    time.sleep(service.DELAY_SECONDS)
    return {
        "schema": 1,
        "result": "passed",
        "plan": plan,
        "value": service.VALUE,
    }


def vm_exec(run_id, argv, timeout_seconds=300):
    return {
        "schema": 1,
        "runId": run_id,
        "argv": argv,
        "timeoutSeconds": timeout_seconds,
        "value": service.VALUE,
        "xdgRuntimeDir": os.environ.get("XDG_RUNTIME_DIR"),
        "xdgCacheHome": os.environ.get("XDG_CACHE_HOME"),
        "xdgConfigHome": os.environ.get("XDG_CONFIG_HOME"),
        **operation_lock_identity(),
    }
""",
        encoding="utf-8",
    )


def proxy_parameters(tmp_path: Path) -> StdioServerParameters:
    repository = Path(__file__).resolve().parents[3]
    source = repository / "tests" / "vm" / "scripts" / "mcp_proxy.py"
    proxy = tmp_path / "mcp_proxy.py"
    shutil.copy2(source, proxy)
    shutil.copy2(
        repository
        / "tests"
        / "vm"
        / "src"
        / "enoshima_vm"
        / "process_bootstrap.py",
        tmp_path / "process_bootstrap.py",
    )
    proxy_source = proxy.read_text(encoding="utf-8")
    proxy_source = proxy_source.replace(
        "_TEST_GLOBAL_MUTATION_LOCK_PATH: Path | None = None",
        "_TEST_GLOBAL_MUTATION_LOCK_PATH: Path | None = "
        "Path(__file__).with_name('active.lock')",
    )
    proxy.write_text(proxy_source, encoding="utf-8")
    test_lock = proxy.with_name("active.lock")
    test_lock.touch(mode=0o600)
    test_lock.chmod(0o600)
    environment = dict(os.environ)
    environment.update(
        {
            "ENOSHIMA_VM_STATE_ROOT": str(tmp_path / "state"),
            "PYTHONPATH": str(tmp_path),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return StdioServerParameters(
        command=sys.executable,
        args=[str(proxy)],
        cwd=tmp_path,
        env=environment,
    )


def set_proxy_fresh_worker_timeout(
    parameters: StdioServerParameters,
    seconds: int,
) -> None:
    assert parameters.env is not None
    parameters.env["ENOSHIMA_VM_FRESH_WORKER_TIMEOUT_SECONDS"] = str(seconds)


def process_start_ticks(pid: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        suffix = raw[raw.rindex(")") + 2 :].split()
        if suffix[0] == "Z":
            return None
        return int(suffix[19])
    except (OSError, ValueError, IndexError):
        return None


def wait_for_process_identity(path: Path, timeout: float = 10) -> tuple[int, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            fields = path.read_text(encoding="utf-8").split()
            pid = int(fields[0])
            recorded_ticks = int(fields[1]) if len(fields) > 1 else None
        except (OSError, ValueError, IndexError):
            time.sleep(0.02)
            continue
        if recorded_ticks is not None:
            return pid, recorded_ticks
        ticks = process_start_ticks(pid)
        if ticks is not None:
            return pid, ticks
        time.sleep(0.02)
    raise AssertionError(f"process identity was not recorded in {path}")


def process_identity_alive(identity: tuple[int, int]) -> bool:
    pid, start_ticks = identity
    return process_start_ticks(pid) == start_ticks


def wait_for_process_exit(identity: tuple[int, int], timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while process_identity_alive(identity) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not process_identity_alive(identity)


def kill_process_identity(identity: tuple[int, int] | None) -> None:
    if identity is None or not process_identity_alive(identity):
        return
    try:
        os.kill(identity[0], signal.SIGKILL)
    except ProcessLookupError:
        pass


def write_anyio_import_trap(
    root: Path,
    *,
    importer_pid_path: Path,
    descendant_pid_path: Path | None = None,
) -> Path:
    descendant_source = "pass\n"
    if descendant_pid_path is not None:
        descendant_source = f"""\
        subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import os,pathlib,signal,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "raw=pathlib.Path('/proc/self/stat').read_text(); "
                "ticks=int(raw[raw.rindex(')')+2:].split()[19]); "
                "pathlib.Path({str(descendant_pid_path)!r}).write_text("
                "f'{{os.getpid()}} {{ticks}}'); "
                "time.sleep(60)",
            ],
            start_new_session=True,
        )
        deadline = time.monotonic() + 5
        while not pathlib.Path({str(descendant_pid_path)!r}).is_file():
            if time.monotonic() >= deadline:
                raise RuntimeError("import descendant did not start")
            time.sleep(0.01)
"""
    indented_descendant = textwrap.indent(
        textwrap.dedent(descendant_source).rstrip(), "            "
    )
    sitecustomize = root / "sitecustomize.py"
    sitecustomize.write_text(
        f"""\
import importlib.abc
import importlib.util
import os
import pathlib
import signal
import sys
import subprocess
import time


if "--worker" in sys.argv or "--payload-worker" in sys.argv:
    class BlockingAnyioLoader(importlib.abc.Loader):
        def create_module(self, spec):
            return None

        def exec_module(self, module):
            raw = pathlib.Path("/proc/self/stat").read_text()
            ticks = int(raw[raw.rindex(")") + 2:].split()[19])
            pathlib.Path({str(importer_pid_path)!r}).write_text(
                f"{{os.getpid()}} {{ticks}}"
            )
{indented_descendant.rstrip()}
            while True:
                time.sleep(60)


    class BlockingAnyioFinder(importlib.abc.MetaPathFinder):
        def find_spec(self, fullname, path, target=None):
            if fullname == "anyio":
                return importlib.util.spec_from_loader(fullname, BlockingAnyioLoader())
            return None


    sys.meta_path.insert(0, BlockingAnyioFinder())
""",
        encoding="utf-8",
    )
    return sitecustomize


def make_fake_harness_import_anyio(root: Path) -> None:
    source = root / "enoshima_vm" / "mcp_server.py"
    source.write_text(
        "import anyio\n" + source.read_text(encoding="utf-8"), encoding="utf-8"
    )


def seed_operation(
    parameters: StdioServerParameters,
    *,
    operation_id: str,
    status: str,
    envelope: dict[str, object] | None = None,
) -> Path:
    assert parameters.env is not None
    operation_root = (
        Path(parameters.env["ENOSHIMA_VM_STATE_ROOT"]) / "mcp-operations" / operation_id
    )
    operation_root.mkdir(mode=0o700, parents=True)
    record: dict[str, object] = {
        "schema": 1,
        "operationId": operation_id,
        "tool": "vm_run_affected",
        "status": status,
        "queuedAt": "2026-01-01T00:00:00+00:00",
        "updatedAt": "2026-01-01T00:00:01+00:00",
        "operationRoot": str(operation_root),
    }
    if status in {"passed", "failed", "blocked", "completed", "orphaned"}:
        record["completedAt"] = "2026-01-01T00:00:01+00:00"
        record["resultPath"] = str(operation_root / "result.json")
    (operation_root / "operation.json").write_text(json.dumps(record), encoding="utf-8")
    (operation_root / "lease.lock").touch(mode=0o600)
    if envelope is not None:
        (operation_root / "result.json").write_text(
            json.dumps(envelope), encoding="utf-8"
        )
    return operation_root


def proxy_global_lock_path(parameters: StdioServerParameters) -> Path:
    return Path(parameters.args[0]).with_name("active.lock")


def structured(result) -> dict[str, object]:
    assert result.isError is False
    assert isinstance(result.structuredContent, dict)
    return result.structuredContent


def test_same_transport_uses_fresh_harness_source(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="first-source")
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                first = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                write_fake_harness(tmp_path, value="second-source-is-new")
                second = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )

        assert first["sourceTreeDigest"] == "first-source"
        assert second["sourceTreeDigest"] == "second-source-is-new"
        assert first["workerPid"] != second["workerPid"]

    anyio.run(exercise)


def test_operation_observers_use_fresh_proxy_source(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="fresh-operation-observers")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-abc123abc123"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="failed",
        envelope={
            "ok": True,
            "result": {"result": "failed", "value": "fresh-operation-observers"},
        },
    )
    proxy = Path(parameters.args[0])
    current_source = proxy.read_text(encoding="utf-8")
    stale_source = current_source.replace(
        '        if state == "orphaned":\n',
        '        if state in {"failed", "orphaned"}:\n',
        1,
    )
    assert stale_source != current_source
    proxy.write_text(stale_source, encoding="utf-8")

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                # Keep this stdio server alive but restore the fixed source.
                # Every observer must execute the restored file in a new worker.
                proxy.write_text(current_source, encoding="utf-8")

                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                listed = structured(
                    await session.call_tool("vm_list_operations", {"limit": 10})
                )
                waited = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 0},
                    )
                )

        assert status["status"] == "failed"
        matching = [
            item
            for item in listed["operations"]
            if item["operationId"] == operation_id
        ]
        assert len(matching) == 1
        assert matching[0]["status"] == "failed"
        assert waited["result"] == "failed"
        assert waited["value"] == "fresh-operation-observers"

    anyio.run(exercise)


def test_built_wheel_contains_runnable_proxy_entrypoint(tmp_path: Path) -> None:
    repository = Path(__file__).resolve().parents[3]
    project = repository / "tests" / "vm"
    wheel_root = tmp_path / "wheel"
    subprocess.run(
        [
            "uv",
            "build",
            "--wheel",
            "--project",
            str(project),
            "--out-dir",
            str(wheel_root),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    wheel = next(wheel_root.glob("*.whl"))
    installed = tmp_path / "installed"
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(installed)
    entrypoint = installed / "enoshima_vm" / "proxy_entrypoint.py"
    packaged_proxy = installed / "enoshima_vm" / "mcp_proxy.py"
    packaged_bootstrap = installed / "enoshima_vm" / "process_bootstrap.py"
    assert entrypoint.is_file()
    assert packaged_proxy.is_file()
    assert packaged_bootstrap.is_file()

    environment = dict(os.environ)
    environment.update(
        {
            "PYTHONPATH": str(installed),
            "ENOSHIMA_VM_STATE_ROOT": str(tmp_path / "state"),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    process = subprocess.Popen(
        [sys.executable, "-m", "enoshima_vm.proxy_entrypoint"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    initialize = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "wheel-smoke", "version": "1"},
        },
    }
    output, error = process.communicate(
        json.dumps(initialize).encode() + b"\n", timeout=10
    )
    assert process.returncode == 0, error.decode(errors="replace")
    document = json.loads(output.splitlines()[0])
    assert document["id"] == 1
    assert document["result"]["serverInfo"]["name"] == "enoshima-vm"


def test_fresh_worker_ignores_same_size_same_timestamp_bytecode(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="first1")
    source = tmp_path / "enoshima_vm" / "service.py"
    source_size = source.stat().st_size
    frozen_time = int(source.stat().st_mtime) - 10
    os.utime(source, (frozen_time, frozen_time))
    py_compile.compile(str(source), doraise=True)
    cache = Path(importlib.util.cache_from_source(str(source)))
    assert cache.is_file()

    write_fake_harness(tmp_path, value="second")
    assert source.stat().st_size == source_size
    os.utime(source, (frozen_time, frozen_time))
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                current = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
        assert current["sourceTreeDigest"] == "second"

    anyio.run(exercise)


def test_worker_crash_does_not_close_proxy_transport(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="crashing", crash_selector=True)
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                crashed = await session.call_tool(
                    "verification_plan",
                    {"base_ref": "HEAD", "mode": "checkpoint"},
                )
                assert crashed.isError is True

                write_fake_harness(tmp_path, value="recovered")
                recovered = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )

        assert recovered["sourceTreeDigest"] == "recovered"

    anyio.run(exercise)


def test_fresh_result_does_not_wait_for_daemon_inheriting_stdout(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="fresh-daemon-stdout")
    daemon_pid_path = tmp_path / "fresh-stdout-daemon.pid"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import pathlib
import time


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    if os.fork() == 0:
        if os.fork() > 0:
            os._exit(0)
        pathlib.Path({str(daemon_pid_path)!r}).write_text(str(os.getpid()))
        time.sleep(60)
        os._exit(0)
    deadline = time.monotonic() + 5
    while not pathlib.Path({str(daemon_pid_path)!r}).exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("stdout daemon did not start")
        time.sleep(0.01)
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "fresh-daemon-stdout",
        "sourceTreeDigest": "fresh-daemon-stdout",
        "suites": ["smoke"],
    }}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    set_proxy_fresh_worker_timeout(parameters, 5)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                with anyio.fail_after(3):
                    result = structured(
                        await session.call_tool(
                            "verification_plan",
                            {"base_ref": "HEAD", "mode": "checkpoint"},
                        )
                    )
                assert result["sourceTreeDigest"] == "fresh-daemon-stdout"

    try:
        anyio.run(exercise)
        daemon_pid = int(daemon_pid_path.read_text(encoding="utf-8"))
        assert not Path(f"/proc/{daemon_pid}").exists()
    finally:
        if daemon_pid_path.exists():
            try:
                os.kill(
                    int(daemon_pid_path.read_text(encoding="utf-8")), signal.SIGKILL
                )
            except ProcessLookupError:
                pass


@pytest.mark.parametrize("inherited", [None, "", "/tmp/wrong-session"])
def test_proxy_restores_canonical_session_environment_when_caller_is_noncanonical(
    tmp_path: Path,
    inherited: str | None,
) -> None:
    write_fake_harness(tmp_path, value="session-environment")
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    if inherited is None:
        parameters.env.pop("XDG_RUNTIME_DIR", None)
        parameters.env.pop("XDG_CACHE_HOME", None)
        parameters.env.pop("XDG_CONFIG_HOME", None)
    else:
        parameters.env["XDG_RUNTIME_DIR"] = inherited
        parameters.env["XDG_CACHE_HOME"] = inherited
        parameters.env["XDG_CONFIG_HOME"] = inherited

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                result = structured(
                    await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                )
        assert result["xdgRuntimeDir"] == f"/run/user/{os.getuid()}"
        assert result["xdgCacheHome"] == str(Path.home() / ".cache")
        assert result["xdgConfigHome"] == str(Path.home() / ".config")
        lock_stat = proxy_global_lock_path(parameters).stat()
        assert result["operationLockDevice"] == lock_stat.st_dev
        assert result["operationLockInode"] == lock_stat.st_ino

    anyio.run(exercise)


def test_hung_fresh_worker_is_killed_without_closing_proxy_transport(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="hanging", hang_selector=True)
    parameters = proxy_parameters(tmp_path)
    # Leave enough room for a fresh interpreter and harness import on a busy
    # validation host while still bounding the intentional infinite loop.
    set_proxy_fresh_worker_timeout(parameters, 5)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                hung = await session.call_tool(
                    "verification_plan",
                    {"base_ref": "HEAD", "mode": "checkpoint"},
                )
                assert hung.isError is True
                assert any(
                    "process group was terminated" in block.text
                    for block in hung.content
                    if hasattr(block, "text")
                )

                write_fake_harness(tmp_path, value="recovered")
                recovered = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )

        assert recovered["sourceTreeDigest"] == "recovered"

    anyio.run(exercise)


@pytest.mark.parametrize("disconnect", ["stdio-eof", "cancel-notification"])
def test_transport_cancellation_cleans_mutating_fresh_tree_and_releases_lock(
    tmp_path: Path,
    disconnect: str,
) -> None:
    write_fake_harness(tmp_path, value="graceful-eof")
    payload_identity_path = tmp_path / "eof-payload.identity"
    descendant_identity_path = tmp_path / "eof-descendant.identity"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f'''\
import os
import pathlib
import signal
import subprocess
import sys
import time


def record_identity(path):
    raw = pathlib.Path("/proc/self/stat").read_text()
    ticks = int(raw[raw.rindex(")") + 2:].split()[19])
    pathlib.Path(path).write_text(f"{{os.getpid()}} {{ticks}}")


def vm_exec(run_id, argv, timeout_seconds=300):
    record_identity({str(payload_identity_path)!r})
    subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import os,pathlib,signal,time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "raw=pathlib.Path('/proc/self/stat').read_text(); "
            "ticks=int(raw[raw.rindex(')')+2:].split()[19]); "
            "pathlib.Path({str(descendant_identity_path)!r}).write_text("
            "f'{{os.getpid()}} {{ticks}}'); "
            "time.sleep(60)",
        ],
        start_new_session=True,
    )
    deadline = time.monotonic() + 5
    while not pathlib.Path({str(descendant_identity_path)!r}).exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("detached descendant did not start")
        time.sleep(0.01)
    while True:
        time.sleep(60)
''',
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    set_proxy_fresh_worker_timeout(parameters, 60)
    assert parameters.env is not None
    proxy = subprocess.Popen(
        [parameters.command, *parameters.args],
        cwd=parameters.cwd,
        env=parameters.env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    payload_identity: tuple[int, int] | None = None
    descendant_identity: tuple[int, int] | None = None
    lock_fd: int | None = None

    def send(document: dict[str, object]) -> None:
        assert proxy.stdin is not None
        proxy.stdin.write(json.dumps(document).encode() + b"\n")
        proxy.stdin.flush()

    def receive(timeout: float = 10) -> dict[str, object]:
        assert proxy.stdout is not None
        ready, _, _ = select.select([proxy.stdout], [], [], timeout)
        assert ready, "proxy did not answer the initialize request"
        line = proxy.stdout.readline()
        assert line
        document = json.loads(line)
        assert isinstance(document, dict)
        return document

    try:
        send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "eof-regression", "version": "1"},
                },
            }
        )
        assert receive()["id"] == 1
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {
                    "name": "vm_exec",
                    "arguments": {
                        "run_id": "run-eof0000000",
                        "argv": ["sleep", "60"],
                        "timeout_seconds": 60,
                    },
                },
            }
        )
        payload_identity = wait_for_process_identity(payload_identity_path)
        descendant_identity = wait_for_process_identity(descendant_identity_path)

        lock_fd = os.open(proxy_global_lock_path(parameters), os.O_RDWR)
        with pytest.raises(BlockingIOError):
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        if disconnect == "stdio-eof":
            assert proxy.stdin is not None
            proxy.stdin.close()
            proxy.wait(timeout=10)
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/cancelled",
                    "params": {"requestId": 2, "reason": "regression test"},
                }
            )
            cancelled = receive()
            assert cancelled["id"] == 2
        wait_for_process_exit(payload_identity)
        wait_for_process_exit(descendant_identity)
        lock_deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= lock_deadline:
                    raise
                time.sleep(0.02)
        assert not process_identity_alive(payload_identity)
        assert not process_identity_alive(descendant_identity)
        fcntl.flock(lock_fd, fcntl.LOCK_UN)

        write_fake_harness(tmp_path, value="replacement-transport")

        if disconnect == "stdio-eof":

            async def recover() -> None:
                async with stdio_client(parameters) as streams:
                    async with ClientSession(*streams) as session:
                        await session.initialize()
                        result = structured(
                            await session.call_tool(
                                "verification_plan",
                                {"base_ref": "HEAD", "mode": "checkpoint"},
                            )
                        )
                        assert result["sourceTreeDigest"] == "replacement-transport"

            anyio.run(recover)
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "verification_plan",
                        "arguments": {"base_ref": "HEAD", "mode": "checkpoint"},
                    },
                }
            )
            recovered = receive()
            assert recovered["id"] == 3
            assert "error" not in recovered
            assert (
                recovered["result"]["structuredContent"]["sourceTreeDigest"]
                == "replacement-transport"
            )
            assert proxy.stdin is not None
            proxy.stdin.close()
            proxy.wait(timeout=10)
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        if proxy.poll() is None:
            proxy.kill()
            proxy.wait(timeout=5)
        kill_process_identity(descendant_identity)
        kill_process_identity(payload_identity)


def test_fresh_deadline_starts_before_anyio_import_and_cleans_setsid_descendant(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="pre-import-hang")
    make_fake_harness_import_anyio(tmp_path)
    importer_pid_path = tmp_path / "importer.pid"
    descendant_pid_path = tmp_path / "import-descendant.pid"
    sitecustomize = write_anyio_import_trap(
        tmp_path,
        importer_pid_path=importer_pid_path,
        descendant_pid_path=descendant_pid_path,
    )
    parameters = proxy_parameters(tmp_path)
    set_proxy_fresh_worker_timeout(parameters, 2)
    importer_identity: tuple[int, int] | None = None
    descendant_identity: tuple[int, int] | None = None

    async def exercise() -> None:
        nonlocal importer_identity, descendant_identity
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                timed_out = await session.call_tool(
                    "verification_plan",
                    {"base_ref": "HEAD", "mode": "checkpoint"},
                )
                assert timed_out.isError is True
                assert any(
                    "process group was terminated" in block.text
                    for block in timed_out.content
                    if hasattr(block, "text")
                )
                importer_identity = wait_for_process_identity(importer_pid_path)
                descendant_identity = wait_for_process_identity(descendant_pid_path)
                wait_for_process_exit(importer_identity)
                wait_for_process_exit(descendant_identity)

                sitecustomize.unlink()
                recovered = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                assert recovered["sourceTreeDigest"] == "pre-import-hang"

    try:
        anyio.run(exercise)
    finally:
        kill_process_identity(descendant_identity)
        kill_process_identity(importer_identity)


def test_supervisor_sigkill_terminates_payload_blocked_before_anyio_import(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="pre-import-parent-death")
    make_fake_harness_import_anyio(tmp_path)
    importer_pid_path = tmp_path / "pre-import-payload.pid"
    write_anyio_import_trap(
        tmp_path,
        importer_pid_path=importer_pid_path,
    )
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    proxy = Path(parameters.args[0])
    supervisor = subprocess.Popen(
        [
            sys.executable,
            str(proxy),
            "--worker",
            "verification_plan",
            "--deadline-seconds",
            "30",
            "--expected-parent-pid",
            str(os.getpid()),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=parameters.env,
    )
    payload_identity: tuple[int, int] | None = None
    try:
        assert supervisor.stdin is not None
        supervisor.stdin.write(
            json.dumps({"base_ref": "HEAD", "mode": "checkpoint"}).encode()
        )
        supervisor.stdin.close()
        payload_identity = wait_for_process_identity(importer_pid_path)
        assert payload_identity[0] != supervisor.pid

        os.kill(supervisor.pid, signal.SIGKILL)
        supervisor.wait(timeout=5)
        wait_for_process_exit(payload_identity)
    finally:
        if supervisor.poll() is None:
            os.kill(supervisor.pid, signal.SIGKILL)
            supervisor.wait(timeout=5)
        kill_process_identity(payload_identity)


def test_durable_guardian_bootstrap_retains_parent_death_signal(
    tmp_path: Path,
) -> None:
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    child_identity_path = tmp_path / "durable-guardian-bootstrap.identity"
    target = tmp_path / "bootstrap-target.py"
    target.write_text(
        f"""\
import os
import pathlib
import time

raw = pathlib.Path('/proc/self/stat').read_text()
ticks = int(raw[raw.rindex(')') + 2:].split()[19])
pathlib.Path({str(child_identity_path)!r}).write_text(f'{{os.getpid()}} {{ticks}}')
while True:
    time.sleep(60)
""",
        encoding="utf-8",
    )
    launcher = tmp_path / "durable-guardian-launcher.py"
    bootstrap = tmp_path / "process_bootstrap.py"
    operation_dir = tmp_path / "operation-bootstrap"
    operation_dir.mkdir()
    launcher.write_text(
        f"""\
import os
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
subprocess.Popen(
    [
        sys.executable,
        '-I',
        '-S',
        {str(bootstrap)!r},
        '--expected-parent-pid',
        str(os.getpid()),
        {str(target)!r},
        '--guardian-worker',
        'vm_run_affected',
        '--operation-dir',
        {str(operation_dir)!r},
    ],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
while True:
    time.sleep(60)
""",
        encoding="utf-8",
    )
    environment = dict(parameters.env)
    environment["PYTHONPATH"] = ""
    parent = subprocess.Popen(
        [sys.executable, str(launcher)],
        start_new_session=True,
        env=environment,
    )
    child_identity: tuple[int, int] | None = None
    try:
        child_identity = wait_for_process_identity(child_identity_path)
        os.kill(parent.pid, signal.SIGKILL)
        parent.wait(timeout=5)
        wait_for_process_exit(child_identity)
    finally:
        if parent.poll() is None:
            os.kill(parent.pid, signal.SIGKILL)
            parent.wait(timeout=5)
        kill_process_identity(child_identity)


def test_timeout_kills_fresh_worker_descendants(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="hanging", hang_selector=True)
    package = tmp_path / "enoshima_vm"
    descendant_pid_path = tmp_path / "descendant.pid"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import pathlib
import subprocess
import sys
import time


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import os, pathlib, signal, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path({str(descendant_pid_path)!r}).write_text(str(os.getpid())); "
            "time.sleep(60)",
        ]
    )
    deadline = time.monotonic() + 2
    while not os.path.exists({str(descendant_pid_path)!r}):
        if time.monotonic() >= deadline:
            raise RuntimeError("descendant did not start")
        time.sleep(0.01)
    while True:
        time.sleep(60)


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    raise AssertionError("not used")


def vm_exec(run_id, argv, timeout_seconds=300):
    raise AssertionError("not used")
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    set_proxy_fresh_worker_timeout(parameters, 5)

    try:

        async def exercise() -> None:
            async with stdio_client(parameters) as streams:
                async with ClientSession(*streams) as session:
                    await session.initialize()
                    timed_out = await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                    assert timed_out.isError is True

        anyio.run(exercise)
        descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2
        while Path(f"/proc/{descendant_pid}").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not Path(f"/proc/{descendant_pid}").exists()
    finally:
        if descendant_pid_path.exists():
            descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
            try:
                os.kill(descendant_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_durable_worker_survives_transport_restart_and_serializes(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="durable", delay_seconds=1.5)
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                competing = await session.call_tool(
                    "vm_run_affected",
                    {"base_ref": "HEAD", "mode": "checkpoint"},
                )
                assert competing.isError is True
                mutating = await session.call_tool(
                    "vm_exec",
                    {
                        "run_id": "run-fake000000",
                        "argv": ["true"],
                        "timeout_seconds": 5,
                    },
                )
                assert mutating.isError is True
                selector = structured(
                    await session.call_tool(
                        "verification_plan",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                assert selector["sourceTreeDigest"] == "durable"

        partial = tmp_path / "state" / "mcp-operations" / "operation-deadbeef0000"
        partial.mkdir(mode=0o700)
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                listed = structured(
                    await session.call_tool("vm_list_operations", {"limit": 10})
                )
                completed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 5},
                    )
                )
                # The detached process has written its final result, but it may
                # still hold the serial lock for a few milliseconds while its
                # cleanup path exits. Wait for the lock handoff instead of
                # making this transport-restart proof timing-dependent.
                deadline = anyio.current_time() + 5
                while True:
                    mutating_result = await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                    if mutating_result.isError is False:
                        mutating = structured(mutating_result)
                        break
                    if anyio.current_time() >= deadline:
                        raise AssertionError(
                            "durable worker did not release its mutating lock"
                        )
                    await anyio.sleep(0.05)

        summaries = {
            str(summary["operationId"]): summary for summary in listed["operations"]
        }
        assert operation_id in summaries
        assert summaries["operation-deadbeef0000"]["status"] == "orphaned"
        assert completed["result"] == "passed"
        assert completed["value"] == "durable"
        assert mutating["value"] == "durable"

    anyio.run(exercise)


def test_durable_failed_result_commits_terminal_ledger(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="durable-failure", durable_result="failed")
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])

        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                completed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 5},
                    )
                )
                assert completed["result"] == "failed"
                assert completed["value"] == "durable-failure"

        operation_root = (
            tmp_path / "state" / "mcp-operations" / operation_id
        )
        record = json.loads(
            (operation_root / "operation.json").read_text(encoding="utf-8")
        )
        envelope = json.loads(
            (operation_root / "result.json").read_text(encoding="utf-8")
        )
        assert record["status"] == "failed"
        assert record["result"] == "failed"
        assert envelope["ok"] is True
        assert envelope["result"]["result"] == "failed"
        assert not (operation_root / "result.pending.json").exists()

    anyio.run(exercise)


def test_durable_worker_survives_transport_owner_sigkill(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="sigkill-recovery", delay_seconds=1.5)
    parameters = proxy_parameters(tmp_path)
    proxy_pid_path = tmp_path / "transport-owner.identity"
    wrapper = tmp_path / "transport-owner.py"
    proxy = Path(parameters.args[0])
    wrapper.write_text(
        f"""\
import os
import pathlib

raw = pathlib.Path('/proc/self/stat').read_text()
ticks = int(raw[raw.rindex(')') + 2:].split()[19])
pathlib.Path({str(proxy_pid_path)!r}).write_text(f'{{os.getpid()}} {{ticks}}')
os.execv({sys.executable!r}, [{sys.executable!r}, {str(proxy)!r}])
""",
        encoding="utf-8",
    )
    killed_parameters = StdioServerParameters(
        command=sys.executable,
        args=[str(wrapper)],
        cwd=parameters.cwd,
        env=parameters.env,
    )

    async def exercise() -> None:
        operation_id = ""
        async with stdio_client(killed_parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                operation_root = (
                    tmp_path / "state" / "mcp-operations" / operation_id
                )
                process = json.loads(
                    (operation_root / "process.json").read_text(encoding="utf-8")
                )
                assert isinstance(process["readyAt"], str)
                assert process_start_ticks(int(process["workerPid"])) == int(
                    process["workerStartTicks"]
                )
                assert process_start_ticks(int(process["guardianPid"])) == int(
                    process["guardianStartTicks"]
                )
                transport = wait_for_process_identity(proxy_pid_path)
                os.kill(transport[0], signal.SIGKILL)
                await anyio.sleep(0.05)

        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                recovered = structured(
                    await session.call_tool("vm_list_operations", {"limit": 10})
                )
                assert operation_id in {
                    str(item["operationId"]) for item in recovered["operations"]
                }
                completed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 5},
                    )
                )
                assert completed["result"] == "passed"
                assert completed["value"] == "sigkill-recovery"

    anyio.run(exercise)


def test_start_waits_for_disconnect_safe_durable_readiness(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="readiness-ack")
    parameters = proxy_parameters(tmp_path)
    release_path = tmp_path / "release-durable-supervisor"
    proxy = Path(parameters.args[0])
    source = proxy.read_text(encoding="utf-8")
    needle = """\
    interrupted: dict[str, int] = {}
    cleanup_active = False
"""
    replacement = f"""\
    interrupted: dict[str, int] = {{}}
    cleanup_active = False
    if operation_dir is not None:
        release_path = Path({str(release_path)!r})
        while not release_path.exists():
            time.sleep(0.02)
"""
    assert needle in source
    proxy.write_text(source.replace(needle, replacement, 1), encoding="utf-8")

    async def exercise() -> None:
        started: dict[str, object] = {}

        async def start_operation(session: ClientSession) -> None:
            started.update(
                structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
            )

        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                async with anyio.create_task_group() as task_group:
                    task_group.start_soon(start_operation, session)
                    operation_root = tmp_path / "state" / "mcp-operations"
                    deadline = anyio.current_time() + 10
                    while not list(operation_root.glob("operation-*/operation.json")):
                        if anyio.current_time() >= deadline:
                            raise AssertionError("durable operation was not queued")
                        await anyio.sleep(0.02)

                    # The former fixed two-second wait returned an operation ID
                    # here even though the detached supervisor had not yet
                    # created its guardian or readiness record.
                    await anyio.sleep(2.25)
                    assert started == {}
                    release_path.touch()
                    with anyio.fail_after(10):
                        while not started:
                            await anyio.sleep(0.02)

        operation_id = str(started["operationId"])
        process_path = (
            tmp_path
            / "state"
            / "mcp-operations"
            / operation_id
            / "process.json"
        )
        process = json.loads(process_path.read_text(encoding="utf-8"))
        assert isinstance(process["readyAt"], str)
        assert "guardianPid" in process

    anyio.run(exercise)


def test_queued_operation_with_live_lock_is_not_reported_orphaned(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="handoff")
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    state_root = Path(parameters.env["ENOSHIMA_VM_STATE_ROOT"])
    operation_id = "operation-123456789abc"
    operation_root = state_root / "mcp-operations" / operation_id
    operation_root.mkdir(mode=0o700, parents=True)
    (operation_root / "operation.json").write_text(
        json.dumps(
            {
                "schema": 1,
                "operationId": operation_id,
                "tool": "vm_run_affected",
                "status": "queued",
                "queuedAt": "2026-01-01T00:00:00+00:00",
                "operationRoot": str(operation_root),
            }
        ),
        encoding="utf-8",
    )
    (state_root / "mcp-operations" / "active.json").write_text(
        json.dumps({"operationId": operation_id}), encoding="utf-8"
    )
    lock_path = operation_root / "lease.lock"
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                summary = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert summary["status"] == "running"
                assert summary["recordedStatus"] == "queued"

    try:
        anyio.run(exercise)
    finally:
        os.close(lock_fd)


def test_wait_does_not_unwrap_torn_success_for_unlocked_running_operation(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="torn-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-111111111111"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="running",
        envelope={"ok": True, "result": {"result": "passed", "value": "torn"}},
    )

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 0},
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["recordedStatus"] == "running"
                assert observed.get("result") != "passed"
                assert observed.get("value") != "torn"

    anyio.run(exercise)


def test_wait_fails_closed_for_terminal_operation_without_result(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="missing-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-333333333333"
    seed_operation(parameters, operation_id=operation_id, status="passed")

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 0},
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["recordedStatus"] == "passed"
                assert observed["resultIntegrity"] == "missing"
                assert observed.get("result") != "passed"

    anyio.run(exercise)


@pytest.mark.parametrize(
    ("status", "envelope"),
    [
        ("failed", {"ok": True, "result": {"result": "passed"}}),
        ("passed", {"ok": False, "error": {"message": "contradiction"}}),
        ("passed", {"ok": True, "result": {"result": "failed"}}),
    ],
)
def test_terminal_operation_rejects_contradictory_result_envelopes(
    tmp_path: Path,
    status: str,
    envelope: dict[str, object],
) -> None:
    write_fake_harness(tmp_path, value="contradictory-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-555555555555"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status=status,
        envelope=envelope,
    )

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["recordedStatus"] == status
                assert observed["resultIntegrity"] == "invalid"

    anyio.run(exercise)


def test_terminal_operation_rejects_oversized_result_envelope(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="oversized-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-666666666666"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={"ok": True, "result": {"result": "passed", "data": "x" * 140_000}},
    )

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["resultIntegrity"] == "invalid"

    anyio.run(exercise)


def test_terminal_operation_rejects_record_result_mismatching_envelope(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="record-result-contradiction")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-777777777777"
    operation_root = seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={"ok": True, "result": {"result": "passed"}},
    )
    record_path = operation_root / "operation.json"
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record["result"] = "failed"
    record_path.write_text(json.dumps(record), encoding="utf-8")

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["recordedStatus"] == "passed"
                assert observed["resultIntegrity"] == "invalid"

    anyio.run(exercise)


def test_wait_revalidates_result_envelope_after_status_snapshot(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="wait-revalidation")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-888888888888"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={"ok": True, "result": {"result": "passed"}},
    )
    proxy = Path(parameters.args[0])
    script = f"""
import importlib.util

spec = importlib.util.spec_from_file_location('proxy_wait_revalidation', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
envelopes = iter((
    {{'ok': True, 'result': {{'result': 'passed'}}}},
    {{'ok': True, 'result': {{'result': 'failed'}}}},
))
module._load_envelope = lambda _path: next(envelopes)
try:
    module._wait_operation({operation_id!r}, 0)
except RuntimeError as error:
    assert 'contradicts its terminal status' in str(error)
else:
    raise AssertionError('wait accepted a contradictory second envelope read')
"""
    subprocess.run(
        [sys.executable, "-c", script],
        check=True,
        capture_output=True,
        text=True,
        env=parameters.env,
    )


def test_stderr_tail_is_bounded_to_eighty_lines(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="bounded-stderr")
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    proxy = Path(parameters.args[0])
    diagnostic = tmp_path / "diagnostic.log"
    diagnostic.write_text(
        "\n".join(f"line-{index}" for index in range(200)) + "\n",
        encoding="utf-8",
    )
    script = f"""
import importlib.util
spec = importlib.util.spec_from_file_location('proxy_module', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module._tail_text(__import__('pathlib').Path({str(diagnostic)!r})))
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        check=True,
        capture_output=True,
        text=True,
        env=parameters.env,
    )
    lines = completed.stdout.splitlines()
    assert len(lines) == 80
    assert lines[0] == "line-120"
    assert lines[-1] == "line-199"


def test_operation_status_and_list_are_bounded_to_32_kib(tmp_path: Path) -> None:
    write_fake_harness(tmp_path, value="bounded-summary")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-444444444444"
    operation_root = seed_operation(
        parameters,
        operation_id=operation_id,
        status="running",
    )
    record = json.loads((operation_root / "operation.json").read_text())
    record["cleanupSurvivors"] = [
        {"pid": index, "diagnostic": "x" * 4096} for index in range(100)
    ]
    record["cleanupDiagnostic"] = "d" * (64 * 1024)
    (operation_root / "operation.json").write_text(
        json.dumps(record), encoding="utf-8"
    )
    for index in range(60):
        seed_operation(
            parameters,
            operation_id=f"operation-{index:012x}",
            status="passed",
            envelope={"ok": True, "result": {"result": "passed"}},
        )

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                listed = structured(
                    await session.call_tool("vm_list_operations", {"limit": 50})
                )
                assert len(json.dumps(status, sort_keys=True).encode()) <= 32 * 1024
                assert len(json.dumps(listed, sort_keys=True).encode()) <= 32 * 1024
                assert status["cleanupSurvivorCount"] == 100
                assert status["truncated"] is True
                assert listed["truncated"] is True

    anyio.run(exercise)


def test_unrelated_global_lock_does_not_mark_terminal_operation_finalizing(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="unrelated-lock")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-222222222222"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={"ok": True, "result": {"result": "passed"}},
    )
    assert parameters.env is not None
    root = Path(parameters.env["ENOSHIMA_VM_STATE_ROOT"]) / "mcp-operations"
    (root / "active.json").write_text(
        json.dumps({"operationId": operation_id}), encoding="utf-8"
    )
    lock_path = proxy_global_lock_path(parameters)
    lock_path.parent.mkdir(mode=0o700, exist_ok=True)
    active_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(active_fd, fcntl.LOCK_EX)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert status["status"] == "passed"
                assert status["recordedStatus"] == "passed"

    try:
        anyio.run(exercise)
    finally:
        os.close(active_fd)


def test_alternate_state_roots_share_the_canonical_mutation_lock(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="canonical-lock")
    release_path = tmp_path / "release-mutation"
    entered_path = tmp_path / "entered-mutation"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import pathlib
import time


def vm_exec(run_id, argv, timeout_seconds=300):
    pathlib.Path({str(entered_path)!r}).write_text("entered")
    deadline = time.monotonic() + 10
    while not pathlib.Path({str(release_path)!r}).exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("mutation release timed out")
        time.sleep(0.02)
    return {{"result": "passed", "runId": run_id}}
""",
        encoding="utf-8",
    )
    first = proxy_parameters(tmp_path)
    second = proxy_parameters(tmp_path)
    assert first.env is not None and second.env is not None
    first.env["ENOSHIMA_VM_STATE_ROOT"] = str(tmp_path / "first-state")
    second.env["ENOSHIMA_VM_STATE_ROOT"] = str(tmp_path / "second-state")

    async def exercise() -> None:
        async with stdio_client(first) as first_streams:
            async with ClientSession(*first_streams) as first_session:
                await first_session.initialize()
                async with anyio.create_task_group() as task_group:
                    first_result: dict[str, object] = {}

                    async def run_first() -> None:
                        first_result["value"] = await first_session.call_tool(
                            "vm_exec",
                            {
                                "run_id": "run-fake000000",
                                "argv": ["true"],
                                "timeout_seconds": 5,
                            },
                        )

                    task_group.start_soon(run_first)
                    deadline = anyio.current_time() + 5
                    while not entered_path.exists():
                        if anyio.current_time() >= deadline:
                            raise AssertionError("first mutation did not start")
                        await anyio.sleep(0.02)

                    async with stdio_client(second) as second_streams:
                        async with ClientSession(*second_streams) as second_session:
                            await second_session.initialize()
                            blocked = await second_session.call_tool(
                                "vm_exec",
                                {
                                    "run_id": "run-fake000000",
                                    "argv": ["true"],
                                    "timeout_seconds": 5,
                                },
                            )
                            assert blocked.isError is True
                    release_path.touch()
                completed = first_result["value"]
                assert getattr(completed, "isError") is False

    anyio.run(exercise)


def test_wait_returns_committed_terminal_result_without_a_retry(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="direct-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-333333333333"
    seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={
            "ok": True,
            "result": {"result": "passed", "value": "direct-result"},
        },
    )

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                final = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 0},
                    )
                )
                assert final == {"result": "passed", "value": "direct-result"}

    anyio.run(exercise)


def test_terminal_result_visibility_lag_does_not_manufacture_orphan(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="delayed-result")
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-343434343434"
    operation_root = seed_operation(
        parameters,
        operation_id=operation_id,
        status="failed",
    )
    result_path = operation_root / "result.json"

    def publish_result() -> None:
        time.sleep(0.02)
        result_path.write_text(
            json.dumps({"ok": True, "result": {"result": "failed"}}),
            encoding="utf-8",
        )

    publisher = threading.Thread(target=publish_result)
    publisher.start()

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                observed = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert observed["status"] == "failed"
                assert observed["recordedStatus"] == "failed"

    try:
        anyio.run(exercise)
    finally:
        publisher.join(timeout=2)
        assert not publisher.is_alive()


def test_unlocked_stale_running_record_is_reread_before_orphaning(
    tmp_path: Path,
) -> None:
    parameters = proxy_parameters(tmp_path)
    operation_id = "operation-444444444444"
    operation_root = seed_operation(
        parameters,
        operation_id=operation_id,
        status="passed",
        envelope={
            "ok": True,
            "result": {"result": "passed", "value": "committed"},
        },
    )
    proxy = Path(parameters.args[0])
    script = f"""
import importlib.util
import json
import pathlib

spec = importlib.util.spec_from_file_location('proxy_module', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_read = module._read_json
record_path = pathlib.Path({str(operation_root / 'operation.json')!r})
first = True
def stale_once(path):
    global first
    if first and pathlib.Path(path) == record_path:
        first = False
        value = real_read(path)
        value['status'] = 'running'
        value.pop('completedAt', None)
        value.pop('resultPath', None)
        return value
    return real_read(path)
module._read_json = stale_once
print(json.dumps(module._wait_operation({operation_id!r}, 0), sort_keys=True))
"""
    completed = subprocess.run(
        [sys.executable, "-c", script],
        cwd=tmp_path,
        env=parameters.env,
        timeout=5,
        check=True,
        capture_output=True,
        text=True,
    )

    assert json.loads(completed.stdout) == {
        "result": "passed",
        "value": "committed",
    }


def test_release_deadline_uses_canonical_plan_suites_not_selector_suites(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="release-budget")
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_plan", {"plan": "release", "base_ref": "HEAD"}
                    )
                )
                completed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {
                            "operation_id": str(started["operationId"]),
                            "timeout_seconds": 5,
                        },
                    )
                )
                status = structured(
                    await session.call_tool(
                        "vm_operation_status",
                        {"operation_id": str(started["operationId"])},
                    )
                )
                assert completed["result"] == "passed"
                # The selector advertises only smoke, while the fake canonical
                # release plan contains smoke and converge (5 minutes each).
                assert status["deadlineSeconds"] == 19_200

    anyio.run(exercise)


def test_durable_payload_exports_the_canonical_operation_lock_fd(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="lock-fd")
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                result = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {
                            "operation_id": str(started["operationId"]),
                            "timeout_seconds": 5,
                        },
                    )
                )
                assert result["result"] == "passed"
                lock_stat = proxy_global_lock_path(parameters).stat()
                assert result["operationLockDevice"] == lock_stat.st_dev
                assert result["operationLockInode"] == lock_stat.st_ino

    anyio.run(exercise)


def test_hard_crashed_durable_worker_becomes_orphaned_and_unlocks(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="crashed", crash_durable=True)
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                failed_id = str(started["operationId"])
                orphaned = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": failed_id, "timeout_seconds": 5},
                    )
                )
                assert orphaned["status"] == "orphaned"

                write_fake_harness(tmp_path, value="recovered")
                recovered = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                completed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {
                            "operation_id": str(recovered["operationId"]),
                            "timeout_seconds": 5,
                        },
                    )
                )
                assert completed["result"] == "passed"
                assert completed["value"] == "recovered"

    anyio.run(exercise)


def test_parent_monitor_retries_cleanup_until_no_survivors(tmp_path: Path) -> None:
    parameters = proxy_parameters(tmp_path)
    proxy = Path(parameters.args[0])
    script = f"""
import importlib.util
import os
import pathlib

spec = importlib.util.spec_from_file_location('proxy_module', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
calls = pathlib.Path({str(tmp_path / "cleanup-calls")!r})
def cleanup():
    count = int(calls.read_text()) + 1 if calls.exists() else 1
    calls.write_text(str(count))
    return [{{'pid': 999}}] if count < 3 else []
module._monitor_expected_parent(os.getppid() + 1, cleanup)
"""
    process = subprocess.run(
        [sys.executable, "-c", script],
        cwd=tmp_path,
        env=parameters.env,
        timeout=5,
        check=False,
    )

    assert process.returncode == 128 + signal.SIGTERM
    assert (tmp_path / "cleanup-calls").read_text() == "3"


def test_guardian_parent_mismatch_never_spawns_payload(tmp_path: Path) -> None:
    parameters = proxy_parameters(tmp_path)
    proxy = Path(parameters.args[0])
    marker = tmp_path / "payload-spawned"
    script = f"""
import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location('proxy_module', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module._set_parent_death_signal = lambda _pid: False
class ForbiddenPopen:
    def __init__(self, *_args, **_kwargs):
        pathlib.Path({str(marker)!r}).write_text('spawned')
        raise AssertionError('payload must not be spawned')
module.subprocess.Popen = ForbiddenPopen
raise SystemExit(module._guardian_main(
    'verification_plan', operation_dir=None, lock_fd=None, lease_fd=None,
    expected_parent_pid=1,
))
"""
    process = subprocess.run(
        [sys.executable, "-c", script],
        cwd=tmp_path,
        env=parameters.env,
        timeout=5,
        check=False,
    )

    assert process.returncode == 128 + signal.SIGTERM
    assert not marker.exists()


def test_cleanup_signal_error_is_diagnostic_until_retry_succeeds(
    tmp_path: Path,
) -> None:
    parameters = proxy_parameters(tmp_path)
    proxy = Path(parameters.args[0])
    daemon_identity_path = tmp_path / "cleanup-daemon.identity"
    script = f"""
import importlib.util
import os
import pathlib
import signal
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location('proxy_module', {str(proxy)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
daemon = subprocess.Popen([
    sys.executable, '-c',
    "import os,pathlib,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "raw=pathlib.Path('/proc/self/stat').read_text(); "
    "ticks=int(raw[raw.rindex(')')+2:].split()[19]); "
    "target=pathlib.Path({str(daemon_identity_path)!r}); "
    "target.write_text(f'{{os.getpid()}} {{ticks}}'); "
    "time.sleep(60)",
], start_new_session=True)
deadline = time.monotonic() + 5
while not pathlib.Path({str(daemon_identity_path)!r}).exists():
    if time.monotonic() >= deadline:
        raise RuntimeError('daemon identity was not recorded')
    time.sleep(0.01)
real_signal = module._signal_process_identity
module._signal_process_identity = (
    lambda _pid, _start_ticks, _signum: 'injected pidfd failure'
)
first = module._terminate_descendants(os.getpid())
if not first:
    raise RuntimeError('cleanup unexpectedly completed after signal failure')
if not any('signalError' in survivor for survivor in first):
    raise RuntimeError(f'missing signal diagnostic: {{first!r}}')
module._signal_process_identity = real_signal
while module._cleanup_descendants_fail_closed(os.getpid()):
    time.sleep(0.05)
"""
    process = subprocess.run(
        [sys.executable, "-c", script],
        cwd=tmp_path,
        env=parameters.env,
        timeout=15,
        check=False,
        capture_output=True,
        text=True,
    )

    assert process.returncode == 0, process.stderr
    identity = wait_for_process_identity(daemon_identity_path)
    assert not process_identity_alive(identity)


def test_proxy_sigkill_keeps_mutation_locked_until_worker_group_is_dead(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="parent-death")
    descendant_pid_path = tmp_path / "mutation-descendant.pid"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import subprocess
import sys
import signal
import time


def vm_exec(run_id, argv, timeout_seconds=300):
    subprocess.Popen([
        sys.executable,
        "-c",
        "import os,pathlib,signal,time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path({str(descendant_pid_path)!r}).write_text(str(os.getpid())); "
        "time.sleep(60)",
    ])
    while True:
        time.sleep(60)
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    proxy = Path(parameters.args[0])
    lock_path = proxy_global_lock_path(parameters)
    helper_path = tmp_path / "proxy-parent.py"
    supervisor_pid_path = tmp_path / "supervisor.pid"
    helper_path.write_text(
        """\
import fcntl
import json
import os
import pathlib
import subprocess
import sys

proxy, lock_path, supervisor_pid_path = sys.argv[1:]
pathlib.Path(lock_path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
worker = subprocess.Popen(
    [sys.executable, proxy, "--worker", "vm_exec", "--deadline-seconds", "30",
     "--lock-fd", str(lock_fd), "--expected-parent-pid", str(os.getpid())],
    stdin=subprocess.PIPE,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    pass_fds=(lock_fd,),
    start_new_session=True,
)
pathlib.Path(supervisor_pid_path).write_text(str(worker.pid))
worker.stdin.write(json.dumps({"run_id": "run-fake000000", "argv": ["true"]}).encode())
worker.stdin.close()
worker.wait()
""",
        encoding="utf-8",
    )
    helper = subprocess.Popen(
        [
            sys.executable,
            str(helper_path),
            str(proxy),
            str(lock_path),
            str(supervisor_pid_path),
        ],
        env=parameters.env,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 10
        while not descendant_pid_path.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert descendant_pid_path.is_file()
        descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
        supervisor_pid = int(supervisor_pid_path.read_text(encoding="utf-8"))

        os.kill(helper.pid, signal.SIGKILL)
        helper.wait(timeout=5)

        probe_fd = os.open(lock_path, os.O_RDWR)
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    fcntl.flock(probe_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    assert Path(f"/proc/{supervisor_pid}").exists()
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.02)
            assert not Path(f"/proc/{descendant_pid}").exists()
        finally:
            os.close(probe_fd)
    finally:
        if helper.poll() is None:
            os.kill(helper.pid, signal.SIGKILL)
            helper.wait(timeout=5)
        if descendant_pid_path.exists():
            try:
                os.kill(
                    int(descendant_pid_path.read_text(encoding="utf-8")),
                    signal.SIGKILL,
                )
            except ProcessLookupError:
                pass


def test_durable_supervisor_sigkill_keeps_lock_until_payload_group_is_dead(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="supervisor-death")
    descendant_pid_path = tmp_path / "durable-supervisor-descendant.pid"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import pathlib
import signal
import subprocess
import sys
import time


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "supervisor-death",
        "sourceTreeDigest": "supervisor-death",
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    child = os.fork()
    if child == 0:
        os.setsid()
        grandchild = os.fork()
        if grandchild > 0:
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path({str(descendant_pid_path)!r}).write_text(str(os.getpid()))
        time.sleep(60)
        os._exit(0)
    os.waitpid(child, 0)
    while True:
        time.sleep(60)


def vm_exec(run_id, argv, timeout_seconds=300):
    return {{"result": "passed", "runId": run_id}}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                operation_root = tmp_path / "state" / "mcp-operations" / operation_id
                process_record = operation_root / "process.json"
                deadline = anyio.current_time() + 10
                while (
                    not descendant_pid_path.is_file()
                    or not process_record.is_file()
                    or '"guardianPid"' not in process_record.read_text()
                ):
                    if anyio.current_time() >= deadline:
                        raise AssertionError("durable payload did not start")
                    await anyio.sleep(0.02)

                import json

                worker_pid = int(
                    json.loads(process_record.read_text(encoding="utf-8"))["workerPid"]
                )
                guardian_pid = int(
                    json.loads(process_record.read_text(encoding="utf-8"))[
                        "guardianPid"
                    ]
                )
                descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
                descendant_stat = Path(f"/proc/{descendant_pid}/stat").read_text()
                assert (
                    int(
                        descendant_stat[
                            descendant_stat.rindex(")") + 2 :
                        ].split()[1]
                    )
                    == guardian_pid
                )
                os.kill(worker_pid, signal.SIGKILL)

                # The payload deliberately spends its TERM grace killing an
                # ignoring descendant. It must retain active.lock throughout.
                await anyio.sleep(0.1)
                assert Path(f"/proc/{descendant_pid}").exists()
                blocked = await session.call_tool(
                    "vm_exec",
                    {
                        "run_id": "run-fake000000",
                        "argv": ["true"],
                        "timeout_seconds": 5,
                    },
                )
                assert blocked.isError is True

                deadline = anyio.current_time() + 10
                while True:
                    mutation = await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                    if mutation.isError is False:
                        break
                    if anyio.current_time() >= deadline:
                        raise AssertionError("durable payload did not release its lock")
                    await anyio.sleep(0.05)
                assert not Path(f"/proc/{descendant_pid}").exists()
                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert status["status"] == "orphaned"

    try:
        anyio.run(exercise)
    finally:
        if descendant_pid_path.exists():
            try:
                os.kill(
                    int(descendant_pid_path.read_text(encoding="utf-8")),
                    signal.SIGKILL,
                )
            except ProcessLookupError:
                pass


def test_durable_guardian_sigkill_keeps_lock_until_payload_group_is_dead(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="guardian-death")
    descendant_pid_path = tmp_path / "durable-guardian-descendant.identity"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import pathlib
import signal
import time


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "guardian-death",
        "sourceTreeDigest": "guardian-death",
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    child = os.fork()
    if child == 0:
        os.setsid()
        grandchild = os.fork()
        if grandchild > 0:
            os._exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raw = pathlib.Path("/proc/self/stat").read_text()
        ticks = int(raw[raw.rindex(")") + 2 :].split()[19])
        pathlib.Path({str(descendant_pid_path)!r}).write_text(
            f"{{os.getpid()}} {{ticks}}"
        )
        time.sleep(60)
        os._exit(0)
    os.waitpid(child, 0)
    while True:
        time.sleep(60)


def vm_exec(run_id, argv, timeout_seconds=300):
    return {{"result": "passed", "runId": run_id}}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                operation_root = tmp_path / "state" / "mcp-operations" / operation_id
                process_record = operation_root / "process.json"
                deadline = anyio.current_time() + 10
                while (
                    not descendant_pid_path.is_file()
                    or not process_record.is_file()
                    or '"guardianPid"' not in process_record.read_text()
                ):
                    if anyio.current_time() >= deadline:
                        raise AssertionError("durable guardian did not start")
                    await anyio.sleep(0.02)

                process = json.loads(process_record.read_text(encoding="utf-8"))
                worker_pid = int(process["workerPid"])
                guardian_pid = int(process["guardianPid"])
                descendant = wait_for_process_identity(descendant_pid_path)
                os.kill(guardian_pid, signal.SIGKILL)

                await anyio.sleep(0.1)
                blocked = await session.call_tool(
                    "vm_exec",
                    {
                        "run_id": "run-fake000000",
                        "argv": ["true"],
                        "timeout_seconds": 5,
                    },
                )
                assert blocked.isError is True
                assert process_start_ticks(worker_pid) is not None

                deadline = anyio.current_time() + 10
                while True:
                    mutation = await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                    if mutation.isError is False:
                        break
                    if anyio.current_time() >= deadline:
                        raise AssertionError("supervisor did not release the lock")
                    await anyio.sleep(0.05)
                assert not process_identity_alive(descendant)
                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert status["status"] == "orphaned"

    try:
        anyio.run(exercise)
    finally:
        if descendant_pid_path.exists():
            kill_process_identity(wait_for_process_identity(descendant_pid_path))


def test_durable_deadline_kills_hung_operation_group_and_releases_lock(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="durable-deadline")
    descendant_pid_path = tmp_path / "durable-descendant.pid"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import subprocess
import sys
import time


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "durable-deadline",
        "sourceTreeDigest": "durable-deadline",
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    subprocess.Popen([
        sys.executable,
        "-c",
        "import os,pathlib,signal,time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path({str(descendant_pid_path)!r}).write_text(str(os.getpid())); "
        "time.sleep(60)",
    ], start_new_session=True)
    while True:
        time.sleep(60)


def vm_exec(run_id, argv, timeout_seconds=300):
    return {{"result": "passed", "runId": run_id}}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    parameters.env["ENOSHIMA_VM_DURABLE_WORKER_TIMEOUT_SECONDS"] = "3"

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                final = await session.call_tool(
                    "vm_wait_operation",
                    {"operation_id": operation_id, "timeout_seconds": 10},
                )
                assert final.isError is True
                status = structured(
                    await session.call_tool(
                        "vm_operation_status", {"operation_id": operation_id}
                    )
                )
                assert status["status"] == "failed"
                assert status["deadlineSeconds"] == 3
                deadline = anyio.current_time() + 5
                while True:
                    mutation_result = await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                    if mutation_result.isError is False:
                        mutation = structured(mutation_result)
                        break
                    if anyio.current_time() >= deadline:
                        raise AssertionError("durable deadline did not release lock")
                    await anyio.sleep(0.02)
                assert mutation["result"] == "passed"

    anyio.run(exercise)
    descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
    assert not Path(f"/proc/{descendant_pid}").exists()


def test_durable_absolute_deadline_covers_sitecustomize_before_worker_import(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="durable-pre-import-deadline")
    worker_identity_path = tmp_path / "durable-pre-import.identity"
    (tmp_path / "sitecustomize.py").write_text(
        f"""\
import os
import pathlib
import signal
import sys
import time

if len(sys.argv) > 1 and sys.argv[1] == '--worker' and '--operation-dir' in sys.argv:
    raw = pathlib.Path('/proc/self/stat').read_text()
    ticks = int(raw[raw.rindex(')') + 2:].split()[19])
    pathlib.Path({str(worker_identity_path)!r}).write_text(
        f'{{os.getpid()}} {{ticks}}'
    )
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(60)
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)
    assert parameters.env is not None
    parameters.env["ENOSHIMA_VM_DURABLE_WORKER_TIMEOUT_SECONDS"] = "3"
    worker_identity: tuple[int, int] | None = None

    async def exercise() -> None:
        nonlocal worker_identity
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = await session.call_tool(
                    "vm_run_affected",
                    {"base_ref": "HEAD", "mode": "checkpoint"},
                )
                assert started.isError is True
                operations_root = tmp_path / "state" / "mcp-operations"
                operation_dirs = sorted(operations_root.glob("operation-*"))
                assert len(operation_dirs) == 1
                operation_id = operation_dirs[0].name
                worker_identity = wait_for_process_identity(worker_identity_path)
                observed = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 12},
                    )
                )
                assert observed["status"] == "orphaned"
                assert observed["recordedStatus"] == "queued"
                wait_for_process_exit(worker_identity)
                mutation = structured(
                    await session.call_tool(
                        "vm_exec",
                        {
                            "run_id": "run-fake000000",
                            "argv": ["true"],
                            "timeout_seconds": 5,
                        },
                    )
                )
                assert mutation["value"] == "durable-pre-import-deadline"

    try:
        anyio.run(exercise)
    finally:
        kill_process_identity(worker_identity)


def test_payload_cannot_publish_terminal_result_before_supervisor_cleanup(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="pending-only")
    descendant_pid_path = tmp_path / "pending-descendant.pid"
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import os
import subprocess
import sys


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "pending-only",
        "sourceTreeDigest": "pending-only",
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    subprocess.Popen([
        sys.executable,
        "-c",
        "import os,pathlib,signal,time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path({str(descendant_pid_path)!r}).write_text(str(os.getpid())); "
        "time.sleep(60)",
    ], start_new_session=True)
    deadline = __import__("time").monotonic() + 5
    while not __import__("pathlib").Path({str(descendant_pid_path)!r}).exists():
        if __import__("time").monotonic() >= deadline:
            raise RuntimeError("pending descendant did not start")
        __import__("time").sleep(0.01)
    return {{"result": "passed"}}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                operation_id = str(started["operationId"])
                operation_root = tmp_path / "state" / "mcp-operations" / operation_id
                deadline = anyio.current_time() + 5
                while not descendant_pid_path.exists():
                    if anyio.current_time() >= deadline:
                        raise AssertionError("pending descendant did not start")
                    await anyio.sleep(0.01)
                descendant_pid = int(descendant_pid_path.read_text(encoding="utf-8"))
                deadline = anyio.current_time() + 1
                while (
                    Path(f"/proc/{descendant_pid}").exists()
                    and anyio.current_time() < deadline
                ):
                    assert not (operation_root / "result.json").exists()
                    status = structured(
                        await session.call_tool(
                            "vm_operation_status", {"operation_id": operation_id}
                        )
                    )
                    assert status["status"] in {"running", "finalizing"}
                    await anyio.sleep(0.02)
                final = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {"operation_id": operation_id, "timeout_seconds": 5},
                    )
                )
                assert final["result"] == "passed"
                assert not Path(f"/proc/{descendant_pid}").exists()
                assert not (operation_root / "result.pending.json").exists()

    anyio.run(exercise)


def test_supervisor_reaps_adopted_daemon_during_payload_execution(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="adopted-reaper")
    daemon_pid_path = tmp_path / "adopted-daemon.pid"
    daemonizer = tmp_path / "daemonizer.py"
    daemonizer.write_text(
        f"""\
import os
import pathlib
import time

if os.fork() > 0:
    os._exit(0)
os.setsid()
if os.fork() > 0:
    os._exit(0)
pid_path = pathlib.Path({str(daemon_pid_path)!r})
pending_pid_path = pid_path.with_suffix(".pending")
pending_pid_path.write_text(str(os.getpid()))
pending_pid_path.replace(pid_path)
time.sleep(0.1)
os._exit(0)
""",
        encoding="utf-8",
    )
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import pathlib
import subprocess
import sys
import time

DAEMONIZER = pathlib.Path({str(daemonizer)!r})
DAEMON_PID = pathlib.Path({str(daemon_pid_path)!r})


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": "adopted-reaper",
        "sourceTreeDigest": "adopted-reaper",
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    subprocess.run([sys.executable, str(DAEMONIZER)], check=True)
    deadline = time.monotonic() + 5
    while not DAEMON_PID.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("daemon pid was not published")
        time.sleep(0.01)
    daemon_pid = int(DAEMON_PID.read_text())
    daemon_proc = pathlib.Path(f"/proc/{{daemon_pid}}")
    deadline = time.monotonic() + 3
    while daemon_proc.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    return {{
        "result": "passed",
        "adoptedDaemonPid": daemon_pid,
        "adoptedDaemonReaped": not daemon_proc.exists(),
    }}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                final = structured(
                    await session.call_tool(
                        "vm_wait_operation",
                        {
                            "operation_id": str(started["operationId"]),
                            "timeout_seconds": 10,
                        },
                    )
                )
                assert final["adoptedDaemonReaped"] is True
                assert not Path(f"/proc/{final['adoptedDaemonPid']}").exists()

    anyio.run(exercise)


def test_durable_result_distinguishes_planned_and_actual_identity(
    tmp_path: Path,
) -> None:
    write_fake_harness(tmp_path, value="unused")
    identity_path = tmp_path / "identity.txt"
    identity_path.write_text("planned", encoding="utf-8")
    package = tmp_path / "enoshima_vm"
    (package / "mcp_server.py").write_text(
        f"""\
import pathlib
import time

IDENTITY = pathlib.Path({str(identity_path)!r})


def verification_plan(base_ref="origin/main", mode="checkpoint"):
    identity = IDENTITY.read_text()
    return {{
        "sourceCommit": "fake-commit",
        "worktreeDigest": identity,
        "sourceTreeDigest": identity,
        "suites": ["smoke"],
    }}


def vm_run_affected(base_ref="origin/main", mode="checkpoint"):
    time.sleep(1)
    return {{"result": "passed"}}
""",
        encoding="utf-8",
    )
    parameters = proxy_parameters(tmp_path)

    async def exercise() -> None:
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                await session.initialize()
                started = structured(
                    await session.call_tool(
                        "vm_run_affected",
                        {"base_ref": "HEAD", "mode": "checkpoint"},
                    )
                )
                assert started["plannedWorktreeDigest"] == "planned"
                assert "actualWorktreeDigest" not in started
                identity_path.write_text("actual", encoding="utf-8")
                final = await session.call_tool(
                    "vm_wait_operation",
                    {
                        "operation_id": str(started["operationId"]),
                        "timeout_seconds": 5,
                    },
                )
                assert final.isError is True
                status = structured(
                    await session.call_tool(
                        "vm_operation_status",
                        {"operation_id": str(started["operationId"])},
                    )
                )
                assert status["status"] == "failed"
                assert status["plannedWorktreeDigest"] == "planned"
                assert status["actualWorktreeDigest"] == "actual"

    anyio.run(exercise)
