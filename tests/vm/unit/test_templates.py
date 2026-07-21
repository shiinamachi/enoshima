from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from enoshima_vm.config import RuntimePaths, load_suite


def test_domain_templates_render_as_xml_without_host_mounts(tmp_path: Path) -> None:
    paths = RuntimePaths.discover()
    environment = Environment(
        loader=FileSystemLoader(paths.project / "templates"),
        autoescape=True,
        undefined=StrictUndefined,
    )
    context = {
        "domain": "enoshima-test-run-012345abcdef",
        "memory_mib": 8192,
        "vcpus": 4,
        "overlay": tmp_path / "root.qcow2",
        "boot_disk": tmp_path / "boot.qcow2",
        "seed": tmp_path / "seed.iso",
        "ssh_host_port": 22022,
        "run_dir": tmp_path,
    }
    for name in (
        "domain-fast.xml.j2",
        "domain-desktop.xml.j2",
        "domain-secure-boot.xml.j2",
    ):
        rendered = environment.get_template(name).render(**context)
        root = ET.fromstring(rendered)
        assert root.findtext("name") == context["domain"]
        assert root.findall(".//filesystem") == []
        if root.findall(".//devices//boot"):
            assert root.findall(".//os/boot") == []
        assert "hostfwd=tcp:127.0.0.1:22022-:22" in rendered
        assert "user,id=enoshima-net,ipv6=off," in rendered
        assert "virtio-net-pci,netdev=enoshima-net,addr=0x8" in rendered
        assert "/dev/" not in rendered.replace("/dev/urandom", "")
        if name == "domain-desktop.xml.j2":
            assert '<controller type="usb" model="qemu-xhci"/>' in rendered
            assert '<input type="tablet" bus="usb"/>' in rendered


def test_reproducible_cloud_init_pins_the_complete_archive_snapshot() -> None:
    paths = RuntimePaths.discover()
    environment = Environment(
        loader=FileSystemLoader(paths.project / "templates"),
        autoescape=False,
        undefined=StrictUndefined,
    )
    template = environment.get_template("user-data.j2")
    common = {
        "run_id": "run-012345abcdef",
        "user": "kentakang",
        "public_key": "ssh-ed25519 fixture",
    }
    reproducible = template.render(
        **common,
        repository_snapshot="2026/07/15",
    )
    latest = template.render(**common, repository_snapshot=None)
    archive = "archive.archlinux.org/repos/2026/07/15/$repo/os/$arch"
    assert archive in reproducible
    assert "archive.archlinux.org" not in latest
    assert "enoshima-cloud-bootstrap" in reproducible
    assert "for attempt in 1 2 3 4 5 6 7 8" in reproducible
    assert "ParallelDownloads = 1" in reproducible
    assert 'pacman -Syu --needed --noconfirm "${packages[@]}"' in reproducible
    for package in (
        "ansible",
        "base-devel",
        "chezmoi",
        "git",
        "gtk4",
        "hyprland",
        "imagemagick",
        "lua",
        "python",
        "python-gobject",
        "ripgrep",
        "yq",
    ):
        assert package in reproducible
    assert "en_US.UTF-8 UTF-8" in reproducible
    assert "ko_KR.UTF-8 UTF-8" in reproducible
    assert "LANG=en_US.UTF-8" in reproducible
    assert "command -v \"$command\"" in reproducible
    assert "touch /var/lib/enoshima-cloud-ready" in reproducible


def test_cloud_init_network_matches_the_qemu_user_network_interface() -> None:
    paths = RuntimePaths.discover()
    environment = Environment(
        loader=FileSystemLoader(paths.project / "templates"),
        autoescape=False,
        undefined=StrictUndefined,
    )
    rendered = environment.get_template("network-config.j2").render()
    assert "  eth0:" in rendered
    assert "dhcp4: true" in rendered


def test_desktop_suite_uses_a_real_greetd_seat() -> None:
    suite = load_suite("desktop")
    actions = {
        step if isinstance(step, str) else next(iter(step)) for step in suite.steps
    }
    assert "prepare_login" in actions
    assert "login_greetd" in actions
    assert "start_desktop" not in actions
    display_step = next(
        step["configure_virtual_displays"]
        for step in suite.steps
        if isinstance(step, dict) and "configure_virtual_displays" in step
    )
    assert all(
        isinstance(monitor["position"], str)
        for monitor in display_step["monitors"]
    )


def test_ui_review_suite_uses_the_production_login_and_matrix_runner() -> None:
    suite = load_suite("ui-review")
    actions = {
        step if isinstance(step, str) else next(iter(step)) for step in suite.steps
    }
    assert "prepare_login" in actions
    assert "login_greetd" in actions
    assert "run_ui_review" in actions
    matrix_step = next(
        step["run_ui_review"]
        for step in suite.steps
        if isinstance(step, dict) and "run_ui_review" in step
    )
    assert set(matrix_step["surfaces"]) == {
        "auth",
        "cyberdock-window-state",
        "desktop-shell",
        "display-mode",
        "launcher",
        "notification-center",
        "osd",
        "power-menu",
        "snap-assist",
        "system-titlebar",
    }


def test_titlebar_fixture_is_an_undecorated_wayland_client() -> None:
    source = (
        RuntimePaths.discover().repository
        / "tests"
        / "vm"
        / "fixtures"
        / "titlebar-window.c"
    ).read_text(encoding="utf-8")
    assert '"org.enoshima.TitlebarFixture"' in source
    assert "gtk_window_set_decorated(GTK_WINDOW(window), FALSE)" in source


def test_electron_fixture_preserves_the_process_across_client_close() -> None:
    root = Path(__file__).resolve().parents[3]
    main = (
        root / "tests" / "vm" / "fixtures" / "electron-window" / "main.js"
    ).read_text(encoding="utf-8")
    driver = (
        root / "tests" / "vm" / "fixtures" / "electron-qualification.py"
    ).read_text(encoding="utf-8")

    assert 'case "native-minimize"' in main
    assert 'case "native-close-reopen"' in main
    assert 'case "arm-external-close"' in main
    assert 'action === "shutdown"' in main
    assert "windowGeneration += 1" in main
    assert 'generation: windowGeneration' in main
    assert 'app.on("window-all-closed"' in main
    assert "process.kill" not in main
    assert 'for backend in ("wayland", "x11")' in driver
    assert 'decoration = "system"' in driver
    assert '"--disable-features=WaylandWindowDecorations"' in driver
    assert '"ENOSHIMA_ELECTRON_SOFTWARE_RENDERING"' in driver
    assert "app.disableHardwareAcceleration()" in main
    assert '"EnoshimaDecoration" in completed.stdout' in driver
    assert 'for mode in ("tiled", "floating", "maximized")' in driver
    assert 'str(user_bin)' in driver
    assert 'production window action helper is unavailable' in driver
    assert 'generation=closed_generation + 1' in driver
    assert '"Electron graceful shutdown ACK"' in driver
    assert "excluded=old_address" not in driver
