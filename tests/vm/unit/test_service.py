from __future__ import annotations

import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import VMError
from enoshima_vm.process import CommandResult
from enoshima_vm.service import VMService


class ScreenshotGuest:
    def __init__(self) -> None:
        self.commands: list[tuple[str, ...]] = []

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        return CommandResult(tuple(argv), 0, "", "")

    def download(self, _remote, local: Path) -> None:
        local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        header = (
            b"\x89PNG\r\n\x1a\n"
            + b"\x00\x00\x00\rIHDR"
            + (1280).to_bytes(4, "big")
            + (800).to_bytes(4, "big")
        )
        local.write_bytes(header)


class ReadyGuest(ScreenshotGuest):
    def __init__(self, sequence: int, missing_translations: int = 0) -> None:
        super().__init__()
        self.sequence = sequence
        self.missing_translations = missing_translations

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        if tuple(argv[:1]) == ("cat",):
            return CommandResult(
                tuple(argv),
                0,
                (
                    f'{{"schema":1,"sequence":{self.sequence},'
                    '"text_overflow_count":0,'
                    f'"missing_translation_count":{self.missing_translations}}}\n'
                ),
                "",
            )
        return CommandResult(tuple(argv), 0, "", "")


def test_junit_report_preserves_step_failure_and_duration(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    destination = service._write_junit(
        {
            "suite": "fixture",
            "artifact_dir": str(tmp_path / "artifacts"),
            "category": "POSTFLIGHT_FAILED",
            "error": "postflight failed",
            "steps": [
                {
                    "action": "bootstrap",
                    "status": "passed",
                    "duration_seconds": 1.25,
                },
                {
                    "action": "postflight",
                    "status": "failed",
                    "duration_seconds": 0.75,
                },
            ],
        }
    )
    root = ET.parse(destination).getroot()
    assert root.attrib["tests"] == "2"
    assert root.attrib["failures"] == "1"
    assert root.attrib["time"] == "2.000"
    failed = root.findall("testcase")[1].find("failure")
    assert failed is not None
    assert failed.attrib["type"] == "POSTFLIGHT_FAILED"
    assert failed.text == "postflight failed"


def test_stable_ui_accepts_only_a_bounded_animated_region(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "busy.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    comparisons: list[tuple[str, ...]] = []

    def compare(argv, **_kwargs):
        comparisons.append(tuple(argv))
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="200")

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "busy", "HEADLESS-UI"
    )

    assert captures == 2
    assert capture["stability_changed_pixel_ratio"] == 0.0002
    assert comparisons[0][1:4] == ("compare", "-metric", "AE")
    assert not image.with_name(".busy.png.previous").exists()


def test_greetd_capture_uses_the_guest_wayland_output(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    record = {
        "run_id": "run-012345abcdef",
        "artifact_dir": str(tmp_path / "artifacts"),
    }

    captured = service._capture_greetd_screenshot(record)

    assert captured == tmp_path / "artifacts" / "screenshots" / "greetd.png"
    command = " ".join(guest.commands[-1])
    assert "sudo -u greeter" in command
    assert "XDG_RUNTIME_DIR" in command
    assert "WAYLAND_DISPLAY" in command
    assert "grim" in command
    assert "virsh" not in command
    assert record["observations"]["greetd_screenshot"] == str(captured)


def test_greetd_login_uses_the_two_phase_authentication_flow() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    capture = source.index("self._capture_greetd_screenshot(record)")
    create_session = source.index(
        'self.backend.send_keys(record["domain"], ["KEY_ENTER"])', capture
    )
    password = source.index("self.backend.type_text(", create_session)
    keyring = source.index("self._assert_login_keyring(record)", password)
    assert capture < create_session < password < keyring


def test_reboot_suite_uses_the_desktop_power_path_ten_times() -> None:
    project = RuntimePaths.discover().project
    suite = (project / "suites" / "reboot.yaml").read_text(encoding="utf-8")
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )
    assert "domain-desktop.xml.j2" in suite
    assert "- reboot_via_desktop_power:" in suite
    assert "iterations: 10" in suite
    method = source[source.index("def _reboot_via_desktop_power") :]
    assert "desktop-power reboot" in method
    assert "desktop-power did not change the guest boot ID" in method
    assert "desktop-power checkpoint was not verified after login" in method


def test_disposable_login_password_is_newline_free_for_gnome_keyring() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_login") : source.index("def _login_greetd")
    ]
    assert 'write_text(secrets.token_hex(16), encoding="utf-8")' in prepare
    keyring = source[
        source.index("def _assert_login_keyring") : source.index(
            "def _assert_graphical_health"
        )
    ]
    assert "the password for the login keyring was invalid" in keyring


def test_postflight_imports_the_live_graphical_environment_after_login() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    helper = source[source.index("def _graphical_shell") :]
    assert "systemctl --user show-environment" in helper
    assert "HYPRLAND_INSTANCE_SIGNATURE" in helper
    assert '"PATH=*|WAYLAND_DISPLAY=*' in helper
    postflight = source[source.index("def _run_postflight") :]
    assert 'get("greetd_login_at")' in postflight
    assert "self._graphical_shell(command)" in postflight


def test_hypr_commands_use_the_managed_user_path() -> None:
    command = VMService._hypr_command("desktop-window-action close --active")

    assert command[:2] == ["bash", "-lc"]
    assert "$HOME/.local/share/mise/shims:$HOME/.local/bin" in command[2]
    assert command[2].endswith("desktop-window-action close --active")


def test_graphical_suites_reject_latent_session_failures() -> None:
    project = RuntimePaths.discover().project
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )
    method = source[source.index("def _graphical_health_failures") :]
    assert "systemctl --user --failed" in method
    assert 'coredumpctl --since \\"$boot_started\\"' in method
    assert "TypeError|ReferenceError|Gtk-CRITICAL" in method
    assert "qs\\\\[" in method
    for suite in ("desktop", "login", "ui-review"):
        text = (project / "suites" / f"{suite}.yaml").read_text(encoding="utf-8")
        assert "- assert_graphical_health" in text
    desktop = (project / "suites" / "desktop.yaml").read_text(encoding="utf-8")
    assert "settle_seconds: 310" in desktop
    assert "app-slack@autostart.service" in desktop


def test_desktop_suite_runs_the_full_electron_action_matrix() -> None:
    project = RuntimePaths.discover().project
    desktop = (project / "suites" / "desktop.yaml").read_text(encoding="utf-8")
    source = (project / "src" / "enoshima_vm" / "service.py").read_text(
        encoding="utf-8"
    )

    assert "run_electron_qualification" in desktop
    assert "iterations: 20" in desktop
    assert "expected_actions = 2 * 3 * iterations * 10" in source
    assert 'document.get("decorationOwner") != "enoshima-system"' in source
    assert "clientNativeMinimizeExposed" in source


def test_ui_review_closes_existing_clients_with_exact_addresses() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    cleanup = source.index("def _close_ui_review_clients")
    review = source.index("def _run_ui_review", cleanup)
    body = source[cleanup:review]
    assert "desktop-window-action close --address" in body
    assert "--origin vm-review --json" in body
    assert "--active" not in body


def test_ui_review_cleanup_preserves_reserved_tray_clients() -> None:
    clients = [
        {
            "address": "0x1",
            "class": "xembed-sni-proxy",
            "workspace": {"id": -98, "name": "special:tray"},
        },
        {
            "address": "0x2",
            "class": "ghostty",
            "workspace": {"id": 1, "name": "1"},
        },
        {
            "address": "0x3",
            "class": "electron",
            "workspace": {"id": -99, "name": "special:minimized"},
        },
    ]

    targets = VMService._ui_review_cleanup_targets(clients)

    assert [client["address"] for client in targets] == ["0x2", "0x3"]


def test_ui_review_resets_clients_at_every_surface_boundary() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    reset = source[source.index("def _reset_ui_review_surface") :]
    review = source[source.index("def _run_ui_review") :]

    assert "self._stop_auth_review(record)" in reset
    assert "self._stop_notification_review(record)" in reset
    assert "self._stop_titlebar_review(record)" in reset
    assert "self._stop_desktop_shell_review(record)" in reset
    assert "self._close_ui_review_clients(record)" in reset
    assert "for case in matrix:" in review
    assert "self._reset_ui_review_surface(record)" in review


def test_screenshot_can_target_one_compositor_output(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(
        service,
        "load_record",
        lambda _run_id: {
            "run_id": "run-012345abcdef",
            "artifact_dir": str(tmp_path / "artifacts"),
        },
    )
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)

    result = service.screenshot(
        "run-012345abcdef", "launcher-en", "HEADLESS-INTERNAL"
    )

    command = " ".join(guest.commands[-1])
    assert "grim -o HEADLESS-INTERNAL" in command
    assert result["output"] == "HEADLESS-INTERNAL"


def test_virtual_monitor_uses_the_hyprland_lua_evaluator() -> None:
    expression = VMService._monitor_eval_expression(
        "HEADLESS-EXTERNAL", "2560x1440@60", "-2560x0", "1.25"
    )

    assert expression == (
        'hl.monitor({ output = "HEADLESS-EXTERNAL", '
        'mode = "2560x1440@60", position = "-2560x0", scale = 1.25 })'
    )
    assert VMService._monitor_disable_expression("Virtual-1") == (
        'hl.monitor({ output = "Virtual-1", disabled = true })'
    )


def test_titlebar_allowlist_uses_the_hyprland_lua_evaluator() -> None:
    expression = VMService._decoration_allowlist_expression(
        "mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture"
    )

    assert expression == (
        'hl.config({ plugin = { enoshima_decoration = { allowlist = '
        '"mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture" } } })'
    )

    with pytest.raises(VMError, match="invalid decoration allowlist"):
        VMService._decoration_allowlist_expression('mpv"; os.execute("id")')


def test_ui_fixture_waits_for_the_exact_qml_ack(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ReadyGuest(42)
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    ack = service._wait_for_ui_fixture_ready(
        {"run_id": "run-012345abcdef"}, 42
    )

    assert guest.commands[-1][-1].endswith("/ui-fixture/ready.json")
    assert ack["text_overflow_count"] == 0
    assert ack["missing_translation_count"] == 0


def test_ui_fixture_rejects_untranslated_catalog_keys(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    guest = ReadyGuest(42, missing_translations=3)
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    with pytest.raises(VMError, match="untranslated catalog keys"):
        service._wait_for_ui_fixture_ready(
            {"run_id": "run-012345abcdef"}, 42
        )


def test_ui_review_rejects_measured_text_overflow() -> None:
    source = (
        RuntimePaths.discover().project
        / "src"
        / "enoshima_vm"
        / "service.py"
    ).read_text(encoding="utf-8")
    review = source[source.index("def _run_ui_review") :]

    assert 'int(fixture_ack["text_overflow_count"]) > 0' in review
    assert "UI review found visible text outside its allocated bounds" in review


def test_ui_capture_requires_two_identical_frames(tmp_path, monkeypatch) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    image = tmp_path / "stable.png"
    image.write_bytes(b"same compositor frame")
    calls = 0

    def screenshot(_run_id, _name, output):
        nonlocal calls
        calls += 1
        return {"path": str(image), "width": 1280, "height": 800, "output": output}

    monkeypatch.setattr(service, "screenshot", screenshot)

    result = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "launcher", "HEADLESS-UI"
    )

    assert calls == 2
    assert result["output"] == "HEADLESS-UI"
