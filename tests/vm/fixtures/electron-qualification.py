#!/usr/bin/env python3
"""Exercise Electron client and Enoshima caption actions in a real Hyprland VM."""

from __future__ import annotations

import argparse
import json
import os
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
    completed = run(
        "hyprctl", "decorations", f"address:{address}", check=False
    )
    return completed.returncode == 0 and "EnoshimaDecoration" in completed.stdout


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
            lambda: (value := find_address(address))
            and not is_minimized(value)
            and value,
            "restored fixture",
        )
    if is_maximized(client):
        dispatch_action("maximize", address, "keyboard")
        client = wait_for(
            lambda: (value := find_address(address))
            and not is_maximized(value)
            and value,
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
            lambda: (value := find_address(address))
            and bool(value.get("floating")) == should_float
            and value,
            f"{mode} fixture",
        )
    if mode == "maximized":
        dispatch_action("maximize", address, "keyboard")
        client = wait_for(
            lambda: (value := find_address(address))
            and is_maximized(value)
            and value,
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
            wait_for(
                lambda: has_enoshima_decoration(str(self.client["address"])),
                "Enoshima system titlebar",
            )
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
    }
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
                            dispatch_action("minimize", address, "titlebar")
                            wait_for(
                                lambda: is_minimized(find_address(address)),
                                "titlebar minimized window",
                            )
                            dispatch_action("restore", address, "titlebar")
                            wait_for(
                                lambda: (value := find_address(address))
                                and not is_minimized(value),
                                "titlebar-minimize restore",
                            )
                            summary["actions"] += 2

                            normalize_mode(address, mode)
                            dispatch_action("minimize", address)
                            wait_for(
                                lambda: is_minimized(find_address(address)),
                                "dock minimized window",
                            )
                            dispatch_action("restore", address)
                            wait_for(
                                lambda: (value := find_address(address))
                                and not is_minimized(value),
                                "dock-minimize restore",
                            )
                            summary["actions"] += 2

                            normalize_mode(address, "tiled")
                            dispatch_action("maximize", address, "titlebar")
                            wait_for(
                                lambda: is_maximized(find_address(address)),
                                "Enoshima maximized window",
                            )
                            dispatch_action("maximize", address, "titlebar")
                            wait_for(
                                lambda: (value := find_address(address))
                                and not is_maximized(value),
                                "Enoshima restored window",
                            )
                            summary["actions"] += 2

                            dispatch_action("maximize", address, "keyboard")
                            wait_for(
                                lambda: is_maximized(find_address(address)),
                                "keyboard maximized window",
                            )
                            dispatch_action("maximize", address, "keyboard")
                            wait_for(
                                lambda: (value := find_address(address))
                                and not is_maximized(value),
                                "keyboard restored window",
                            )
                            summary["actions"] += 2

                            old_address = address
                            close_ack = fixture.command("arm-external-close")
                            closed_generation = int(close_ack["generation"])
                            dispatch_action("close", old_address, "titlebar")
                            wait_for(
                                lambda: find_fixture(
                                    fixture.process.pid,
                                    generation=closed_generation,
                                )
                                is None,
                                "titlebar closed Electron generation",
                            )
                            fixture.client = wait_for(
                                lambda: find_fixture(
                                    fixture.process.pid,
                                    generation=closed_generation + 1,
                                ),
                                "titlebar reopened Electron client",
                            )
                            address = str(fixture.client["address"])
                            wait_for(
                                lambda: has_enoshima_decoration(address),
                                "titlebar reopened Enoshima system chrome",
                            )
                            summary["actions"] += 1

                            old_address = address
                            close_ack = fixture.command("arm-external-close")
                            closed_generation = int(close_ack["generation"])
                            dispatch_action("close", old_address, "dock")
                            wait_for(
                                lambda: find_fixture(
                                    fixture.process.pid,
                                    generation=closed_generation,
                                )
                                is None,
                                "dock closed Electron generation",
                            )
                            fixture.client = wait_for(
                                lambda: find_fixture(
                                    fixture.process.pid,
                                    generation=closed_generation + 1,
                                ),
                                "dock reopened Electron client",
                            )
                            address = str(fixture.client["address"])
                            wait_for(
                                lambda: has_enoshima_decoration(address),
                                "dock reopened Enoshima system titlebar",
                            )
                            if fixture.process.poll() is not None:
                                raise RuntimeError(
                                    "Electron process died during client close"
                                )
                            summary["actions"] += 1
                            record.update(
                                {
                                    "result": "pass",
                                    "addressAfter": address,
                                    "pidAfter": fixture.process.pid,
                                    "processAlive": True,
                                    "generationAfter": closed_generation + 1,
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
