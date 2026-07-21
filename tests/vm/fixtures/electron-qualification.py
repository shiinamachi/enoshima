#!/usr/bin/env python3
"""Exercise Electron client and Enoshima caption actions in a real Hyprland VM."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any


def run(*argv: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, check=check, capture_output=True, text=True)


def clients() -> list[dict[str, Any]]:
    value = json.loads(run("hyprctl", "-j", "clients").stdout)
    if not isinstance(value, list):
        raise RuntimeError("hyprctl clients did not return a list")
    return value


def wait_for(
    predicate: Callable[[], Any], description: str, timeout: float = 8.0
) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.04)
    raise RuntimeError(f"timed out waiting for {description}; last={last!r}")


def find_fixture(pid: int, *, generation: int | None = None) -> dict[str, Any] | None:
    marker = f"generation-{generation}" if generation is not None else ""
    for client in clients():
        if int(client.get("pid", -1)) != pid:
            continue
        if marker and marker not in str(client.get("title", "")):
            continue
        if int(client.get("pid", -1)) == pid:
            return client
    return None


def find_address(address: str) -> dict[str, Any] | None:
    return next(
        (client for client in clients() if client.get("address") == address), None
    )


def is_minimized(client: dict[str, Any] | None) -> bool:
    return bool(
        client
        and str(client.get("workspace", {}).get("name", "")) == "special:minimized"
    )


def is_maximized(client: dict[str, Any] | None) -> bool:
    return bool(
        client
        and (
            int(client.get("fullscreen", 0)) != 0
            or int(client.get("fullscreenClient", 0)) != 0
        )
    )


def has_enoshima_decoration(address: str) -> bool:
    completed = run("hyprctl", "decorations", f"address:{address}", check=False)
    return completed.returncode == 0 and "EnoshimaDecoration" in completed.stdout


def decoration_allowlist() -> str:
    completed = run(
        "hyprctl",
        "-j",
        "getoption",
        "plugin:enoshima_decoration:allowlist",
    )
    return str(json.loads(completed.stdout).get("str", ""))


def set_decoration_allowlist(value: str) -> None:
    if value and not re.fullmatch(
        r"[A-Za-z0-9._,*?-]+(?:,[A-Za-z0-9._,*?-]+)*", value
    ):
        raise RuntimeError("unsafe Electron qualification allowlist")
    expression = (
        'hl.config({ plugin = { enoshima_decoration = { allowlist = "'
        + value
        + '" } } })'
    )
    run("hyprctl", "eval", expression)


def dispatch_action(action: str, address: str, origin: str = "dock") -> None:
    completed = run(
        "desktop-window-action",
        action,
        "--address",
        address,
        "--origin",
        origin,
        "--json",
        check=False,
    )
    if completed.returncode:
        raise RuntimeError(
            f"desktop-window-action {action} failed: {completed.stderr.strip()}"
        )


def normalize_mode(address: str, mode: str) -> dict[str, Any]:
    client = wait_for(lambda: find_address(address), f"window {address}")
    if is_minimized(client):
        dispatch_action("restore", address)
        client = wait_for(
            lambda: (
                (value := find_address(address)) and not is_minimized(value) and value
            ),
            "restored fixture",
        )
    if is_maximized(client):
        dispatch_action("maximize", address, "keyboard")
        client = wait_for(
            lambda: (
                (value := find_address(address)) and not is_maximized(value) and value
            ),
            "unmaximized fixture",
        )
    should_float = mode == "floating"
    if bool(client.get("floating")) != should_float:
        action = "set" if should_float else "unset"
        run(
            "hyprctl",
            "dispatch",
            'hl.dsp.window.float({ action = "'
            + action
            + '", window = "address:'
            + address
            + '" })',
        )
        client = wait_for(
            lambda: (
                (value := find_address(address))
                and bool(value.get("floating")) == should_float
                and value
            ),
            f"{mode} fixture",
        )
    if mode == "maximized":
        dispatch_action("maximize", address, "keyboard")
        client = wait_for(
            lambda: (value := find_address(address)) and is_maximized(value) and value,
            "maximized fixture",
        )
    return client


class Fixture:
    def __init__(self, root: Path, output: Path, backend: str, decoration: str):
        self.root = root
        self.output = output
        self.backend = backend
        self.decoration = decoration
        self.token = uuid.uuid4().hex
        self.sequence = 0
        self.control = output / f"control-{self.token}.json"
        self.ack = output / f"ack-{self.token}.json"
        self.log = output / f"electron-{backend}-{decoration}.log"
        self.control.write_text('{"schema":1,"sequence":0}\n', encoding="utf-8")
        self.control.chmod(0o600)
        environment = os.environ.copy()
        environment.update(
            {
                "ENOSHIMA_ELECTRON_CONTROL": str(self.control),
                "ENOSHIMA_ELECTRON_ACK": str(self.ack),
                "ENOSHIMA_ELECTRON_TOKEN": self.token,
                "ENOSHIMA_ELECTRON_DECORATION": decoration,
                "ENOSHIMA_ELECTRON_SOFTWARE_RENDERING": (
                    "1" if backend == "x11" else "0"
                ),
            }
        )
        command = ["/usr/bin/electron39", str(root)]
        if backend == "wayland":
            command.extend(
                [
                    "--ozone-platform=wayland",
                    "--enable-features=UseOzonePlatform",
                    "--disable-features=WaylandWindowDecorations",
                ]
            )
        else:
            command.extend(
                [
                    "--ozone-platform=x11",
                    "--disable-features=WaylandWindowDecorations",
                ]
            )
        self.log_stream = self.log.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=self.log_stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            wait_for(lambda: self.ack.is_file(), "Electron fixture ACK", 20)
            self.client = wait_for(
                lambda: find_fixture(self.process.pid), "Electron fixture window", 30
            )
            address = str(self.client["address"])
            verify_decoration(self, address)
            if self.process.poll() is not None:
                raise RuntimeError("Electron fixture exited during startup")
        except Exception:
            self.close()
            raise

    def command(self, action: str) -> dict[str, Any]:
        self.sequence += 1
        temporary = self.control.with_suffix(".new")
        temporary.write_text(
            json.dumps({"schema": 1, "sequence": self.sequence, "action": action})
            + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        temporary.replace(self.control)

        def acknowledged() -> dict[str, Any] | None:
            try:
                document = json.loads(self.ack.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return None
            return document if document.get("sequence") == self.sequence else None

        document = wait_for(acknowledged, f"Electron ACK for {action}")
        if document.get("ok") is False:
            raise RuntimeError(f"Electron action failed: {document}")
        if self.process.poll() is not None:
            raise RuntimeError(f"Electron process exited after {action}")
        return document

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self.sequence += 1
                temporary = self.control.with_suffix(".new")
                temporary.write_text(
                    json.dumps(
                        {
                            "schema": 1,
                            "sequence": self.sequence,
                            "action": "shutdown",
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
                temporary.chmod(0o600)
                temporary.replace(self.control)

                def shutdown_acknowledged() -> bool:
                    try:
                        document = json.loads(self.ack.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError):
                        return False
                    return (
                        document.get("sequence") == self.sequence
                        and document.get("action") == "shutdown"
                    )

                wait_for(shutdown_acknowledged, "Electron graceful shutdown ACK", 4)
                self.process.wait(timeout=8)
            except (RuntimeError, subprocess.TimeoutExpired):
                if self.process.poll() is None:
                    os.killpg(self.process.pid, signal.SIGTERM)
                    try:
                        self.process.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.process.pid, signal.SIGKILL)
                        self.process.wait(timeout=3)
        self.log_stream.close()


def configure_environment() -> None:
    uid = os.getuid()
    runtime = Path(f"/run/user/{uid}")
    user_bin = Path.home() / ".local" / "bin"
    user_libexec = Path.home() / ".local" / "libexec"
    sockets = sorted(
        path.name for path in runtime.glob("wayland-*") if path.is_socket()
    )
    if not sockets:
        raise RuntimeError("Wayland session socket is unavailable")
    os.environ.update(
        {
            "XDG_RUNTIME_DIR": str(runtime),
            "WAYLAND_DISPLAY": sockets[0],
            "DISPLAY": os.environ.get("DISPLAY", ":0"),
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus",
            # The driver is launched through the suite's non-login Hyprland
            # command wrapper.  Keep the production chezmoi command locations
            # explicit instead of inheriting the SSH service manager PATH.
            "PATH": ":".join(
                (
                    str(user_bin),
                    str(user_libexec),
                    "/usr/local/bin",
                    "/usr/bin",
                )
            ),
        }
    )
    window_action = user_bin / "desktop-window-action"
    if not window_action.is_file() or not os.access(window_action, os.X_OK):
        raise RuntimeError(
            f"production window action helper is unavailable: {window_action}"
        )


def fixture_generation(client: dict[str, Any]) -> int:
    marker = str(client.get("title", "")).rsplit("generation-", 1)
    if len(marker) != 2 or not marker[1].isdigit():
        raise RuntimeError(f"Electron fixture lacks a generation marker: {client!r}")
    return int(marker[1])


def verify_decoration(fixture: Fixture, address: str) -> None:
    if fixture.decoration == "system":
        try:
            wait_for(
                lambda: has_enoshima_decoration(address),
                "Enoshima system titlebar",
            )
        except RuntimeError as error:
            client = find_address(address) or fixture.client
            raise RuntimeError(
                "Enoshima system titlebar did not attach to "
                f"class={client.get('class', '')!r} "
                f"initialClass={client.get('initialClass', '')!r}"
            ) from error
    elif has_enoshima_decoration(address):
        raise RuntimeError(
            "client-owned Electron chrome received duplicate system decoration"
        )


def wait_for_reopened_fixture(
    fixture: Fixture,
    closed_generation: int,
    description: str,
) -> str:
    wait_for(
        lambda: find_fixture(fixture.process.pid, generation=closed_generation) is None,
        f"{description} closed Electron generation",
    )
    fixture.client = wait_for(
        lambda: find_fixture(fixture.process.pid, generation=closed_generation + 1),
        f"{description} reopened Electron client",
    )
    address = str(fixture.client["address"])
    verify_decoration(fixture, address)
    return address


def exercise_iteration(
    fixture: Fixture,
    address: str,
    mode: str,
) -> tuple[str, int]:
    if fixture.decoration != "system":
        raise RuntimeError("managed action qualification requires system chrome")
    dispatch_action("minimize", address, "titlebar")
    wait_for(
        lambda: is_minimized(find_address(address)),
        f"{fixture.decoration} titlebar minimized window",
    )
    dispatch_action("restore", address, "titlebar")
    wait_for(
        lambda: (value := find_address(address)) and not is_minimized(value),
        f"{fixture.decoration} titlebar-minimize restore",
    )

    normalize_mode(address, mode)
    dispatch_action("minimize", address)
    wait_for(
        lambda: is_minimized(find_address(address)),
        "dock minimized window",
    )
    dispatch_action("restore", address)
    wait_for(
        lambda: (value := find_address(address)) and not is_minimized(value),
        "dock-minimize restore",
    )

    normalize_mode(address, "tiled")
    dispatch_action("maximize", address, "titlebar")
    wait_for(
        lambda: is_maximized(find_address(address)),
        "Enoshima maximized window",
    )
    dispatch_action("maximize", address, "titlebar")
    wait_for(
        lambda: (value := find_address(address)) and not is_maximized(value),
        "Enoshima restored window",
    )

    dispatch_action("maximize", address, "keyboard")
    wait_for(
        lambda: is_maximized(find_address(address)),
        "keyboard maximized window",
    )
    dispatch_action("maximize", address, "keyboard")
    wait_for(
        lambda: (value := find_address(address)) and not is_maximized(value),
        "keyboard restored window",
    )

    closed_generation = fixture_generation(fixture.client)
    fixture.command("arm-external-close")
    dispatch_action("close", address, "titlebar")
    address = wait_for_reopened_fixture(
        fixture, closed_generation, f"{fixture.decoration} titlebar"
    )

    closed_generation = fixture_generation(fixture.client)
    fixture.command("arm-external-close")
    dispatch_action("close", address, "dock")
    address = wait_for_reopened_fixture(fixture, closed_generation, "dock")
    if fixture.process.poll() is not None:
        raise RuntimeError("Electron process died during client close")
    return address, 10


def probe_native_minimize_fallback(
    fixture: Fixture,
) -> dict[str, Any]:
    """Prove why managed Electron launchers must not expose client minimize.

    Electron acknowledges BrowserWindow.minimize() on both Ozone backends but
    Hyprland receives no usable minimized state. This is a negative policy
    probe, not a supported user path: managed applications disable that frame
    and use the exact-address system chrome exercised below.
    """
    if fixture.decoration != "custom":
        raise RuntimeError("native fallback probe requires client-owned chrome")
    address = str(fixture.client["address"])
    before = normalize_mode(address, "tiled")
    acknowledgement = fixture.command("native-minimize")
    time.sleep(0.4)
    after = find_address(address)
    process_alive = fixture.process.poll() is None
    workspace_unchanged = bool(
        after
        and after.get("workspace") == before.get("workspace")
        and not is_minimized(after)
    )
    if not process_alive or not workspace_unchanged:
        raise RuntimeError(
            "Electron native minimize fallback behavior changed; reevaluate the "
            "managed decoration policy"
        )
    return {
        "backend": fixture.backend,
        "processAlive": process_alive,
        "workspaceUnchanged": workspace_unchanged,
        "electronReportedMinimized": bool(acknowledgement.get("minimized")),
        "enoshimaDecorationAbsent": not has_enoshima_decoration(address),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--iterations", type=int, default=20)
    args = parser.parse_args()
    if args.iterations < 1 or args.iterations > 100:
        raise SystemExit("iterations must be between 1 and 100")
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    configure_environment()
    started_at = int(time.time())
    results_path = args.output / "electron-results.jsonl"
    summary: dict[str, Any] = {
        "schema": 1,
        "iterations": args.iterations,
        "combinations": 0,
        "actions": 0,
        "failures": 0,
        "decorationOwner": "enoshima-system",
        "clientNativeMinimizeExposed": False,
        "nativeFallbackProbes": [],
    }
    original_allowlist = decoration_allowlist()
    allowlist_parts = [value for value in original_allowlist.split(",") if value]
    for value in (
        "enoshima-electron-qualification",
        "EnoshimaElectronFixture",
        "EnoshimaElectronFixtureSystem",
    ):
        if value not in allowlist_parts:
            allowlist_parts.append(value)
    system_allowlist = ",".join(allowlist_parts)
    try:
        for backend in ("wayland", "x11"):
            native_fixture = Fixture(args.fixture_root, args.output, backend, "custom")
            try:
                summary["nativeFallbackProbes"].append(
                    probe_native_minimize_fallback(native_fixture)
                )
            finally:
                native_fixture.close()

        set_decoration_allowlist(system_allowlist)
        with results_path.open("w", encoding="utf-8") as results:
            for backend in ("wayland", "x11"):
                decoration = "system"
                fixture = Fixture(args.fixture_root, args.output, backend, decoration)
                try:
                    summary["combinations"] += 3
                    for mode in ("tiled", "floating", "maximized"):
                        address = str(fixture.client["address"])
                        for iteration in range(1, args.iterations + 1):
                            initial = normalize_mode(address, mode)
                            old_address = address
                            record = {
                                "backend": backend,
                                "decoration": decoration,
                                "decorationOwner": "enoshima-system",
                                "mode": mode,
                                "iteration": iteration,
                                "pidBefore": fixture.process.pid,
                                "addressBefore": address,
                                "workspaceBefore": initial.get("workspace"),
                                "xwayland": bool(initial.get("xwayland")),
                                "rendering": (
                                    "electron-software"
                                    if backend == "x11"
                                    else "virtio-gpu"
                                ),
                            }
                            try:
                                address, actions = exercise_iteration(
                                    fixture, address, mode
                                )
                                summary["actions"] += actions
                                record.update(
                                    {
                                        "result": "pass",
                                        "addressAfter": address,
                                        "pidAfter": fixture.process.pid,
                                        "processAlive": True,
                                        "generationAfter": fixture_generation(
                                            fixture.client
                                        ),
                                        "addressReused": address == old_address,
                                    }
                                )
                            except Exception as error:
                                summary["failures"] += 1
                                record.update({"result": "fail", "error": str(error)})
                                results.write(json.dumps(record, sort_keys=True) + "\n")
                                results.flush()
                                raise
                            results.write(json.dumps(record, sort_keys=True) + "\n")
                            results.flush()
                finally:
                    fixture.close()
    finally:
        set_decoration_allowlist(original_allowlist)

    coredumps = run(
        "coredumpctl",
        "--since",
        f"@{started_at}",
        "--no-pager",
        "--no-legend",
        check=False,
    ).stdout.strip()
    summary["coredumps"] = coredumps
    if coredumps:
        summary["failures"] += 1
    (args.output / "electron-summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, sort_keys=True))
    return 0 if summary["failures"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
