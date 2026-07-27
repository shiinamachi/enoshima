from __future__ import annotations

import io
import json
import subprocess
import tarfile
import xml.etree.ElementTree as ET
import zipfile
from hashlib import sha256
from pathlib import Path

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import VMError
from enoshima_vm.process import CommandResult
from enoshima_vm.service import (
    VMService,
    _write_recovery_key,
    normalized_image_metric,
)


class ScreenshotGuest:
    def __init__(self) -> None:
        self.commands: list[tuple[str, ...]] = []

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        return CommandResult(tuple(argv), 0, "", "")

    def exec_retryable(self, argv, **kwargs):
        return self.exec(argv, **kwargs)

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


class CacheSeedGuest(ScreenshotGuest):
    def __init__(self) -> None:
        super().__init__()
        self.uploads: list[tuple[Path, str, int]] = []

    def upload_file(
        self,
        local: Path,
        remote,
        *,
        mode: int = 0o600,
        timeout: float = 120,
    ) -> None:
        del timeout
        self.uploads.append((local, str(remote), mode))

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        archive = self.uploads[-1][0]
        digest = sha256(archive.read_bytes()).hexdigest()
        return CommandResult(tuple(argv), 0, f"{digest}  {argv[-1]}\n", "")


class PacmanCacheGuest(ScreenshotGuest):
    def __init__(self, packages: dict[str, bytes]) -> None:
        super().__init__()
        self.packages = packages
        self.uploads: list[tuple[Path, str, int]] = []

    def upload_file(
        self,
        local: Path,
        remote,
        *,
        mode: int = 0o600,
        timeout: float = 120,
    ) -> None:
        del timeout
        self.uploads.append((local, str(remote), mode))

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        if tuple(argv[:2]) == ("sudo", "find"):
            output = "".join(
                f"{name}\t{len(payload)}\n"
                for name, payload in sorted(self.packages.items())
            )
            return CommandResult(tuple(argv), 0, output, "")
        return CommandResult(tuple(argv), 0, "", "")

    def download(self, _remote, local: Path, *, timeout: float = 300) -> None:
        del timeout
        local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tarfile.open(local, mode="w") as bundle:
            for name, payload in sorted(self.packages.items()):
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                bundle.addfile(info, io.BytesIO(payload))


class PowerClientGuest(ScreenshotGuest):
    def __init__(self) -> None:
        super().__init__()
        self.responses = [
            "[]\n",
            (
                '[{"address":"0xabc","class":"com.mitchellh.ghostty",'
                '"title":"Enoshima Power Fixture","pid":42}]\n'
            ),
        ]

    def exec(self, argv, **_kwargs):
        self.commands.append(tuple(argv))
        return CommandResult(tuple(argv), 0, self.responses.pop(0), "")


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
    assert capture["stability_metric"] == "changed-pixel-ratio"
    assert comparisons[0][1:4] == ("compare", "-metric", "AE")
    assert not image.with_name(".busy.png.previous").exists()


def test_stable_ui_retries_after_a_slow_transitional_frame(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "transition.png"
    frames = [b"before-layer-map", b"after-layer-map", b"after-layer-map"]
    captures = 0
    monotonic_values = iter([0.0, 0.0, 30.0, 31.0])

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(frames[captures])
        captures += 1
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {"AE": "1000000", "RMSE": "0.2 (0.2)", "SSIM": "0.2"}
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)
    monkeypatch.setattr(
        "enoshima_vm.service.time.monotonic", lambda: next(monotonic_values)
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"},
        "transition",
        "HEADLESS-UI",
        timeout_seconds=20,
    )

    assert captures == 3
    assert capture["stability_changed_pixel_ratio"] == 0.0
    assert capture["stability_metric"] == "pixel-hash"


def test_stable_ui_does_not_report_a_negative_ratio_for_invalid_ae(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "invalid-ae.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {
            "AE": "not-a-number",
            "RMSE": "64 (0.000976577)",
            "SSIM": "0.0666445",
        }
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "invalid-ae", "HEADLESS-UI"
    )

    assert capture["stability_changed_pixel_ratio"] == 1.0
    assert capture["stability_metric"] == "normalized-rmse"


def test_normalized_image_metric_prefers_parenthesized_value() -> None:
    assert normalized_image_metric("64 (0.000976577)") == 0.000976577
    assert normalized_image_metric("0.9995") == 0.9995


def test_codex_electron_cache_seed_is_explicit_and_checksum_verified(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = CacheSeedGuest()
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    archive = cache / "electron-v42.3.0-linux-x64.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("electron", "fixture")
    node_archive = tmp_path / "node-v22.22.2-linux-x64.tar.xz"
    with tarfile.open(node_archive, mode="w:xz") as bundle:
        info = tarfile.TarInfo("node-v22.22.2-linux-x64/README.md")
        payload = b"fixture"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{sha256(node_archive.read_bytes()).hexdigest()}  {node_archive.name}\n",
        encoding="utf-8",
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"koly" + (b"\0" * 508))
    digest_lock = tmp_path / "packages" / "codex-desktop-dmg-sha256.txt"
    digest_lock.write_text(
        sha256(dmg.read_bytes()).hexdigest() + "\n", encoding="utf-8"
    )

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(node_archive))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)
    record = {"run_id": "run-012345abcdef"}

    service._seed_codex_electron_cache(record)

    assert guest.uploads == [
        (
            archive,
            "/home/kentakang/.cache/codex-desktop/electron/"
            "electron-v42.3.0-linux-x64.zip",
            0o600,
        ),
        (
            node_archive,
            "/home/kentakang/.cache/codex-desktop/node-runtime/"
            "node-v22.22.2-linux-x64.tar.xz",
            0o600,
        ),
        (
            dmg,
            "/home/kentakang/.cache/codex-desktop/Codex.dmg",
            0o600,
        ),
    ]
    seeded = record["observations"]["codex_electron_cache"]
    assert seeded["status"] == "seeded"
    assert seeded["archives"][0]["sha256"] == sha256(archive.read_bytes()).hexdigest()
    assert seeded["node_runtime"]["status"] == "seeded"
    assert seeded["node_runtime"]["sha256"] == sha256(
        node_archive.read_bytes()
    ).hexdigest()
    assert seeded["dmg"]["status"] == "seeded"
    assert seeded["dmg"]["sha256"] == sha256(dmg.read_bytes()).hexdigest()


def test_codex_node_runtime_seed_rejects_a_stale_valid_archive(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_archive = tmp_path / "node-v22.22.2-linux-x64.tar.xz"
    with tarfile.open(node_archive, mode="w:xz") as bundle:
        info = tarfile.TarInfo("node-v22.22.2-linux-x64/README.md")
        payload = b"fixture"
        info.size = len(payload)
        bundle.addfile(info, io.BytesIO(payload))
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{'0' * 64}  {node_archive.name}\n", encoding="utf-8"
    )

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(node_archive))
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(tmp_path / "missing.dmg"))

    with pytest.raises(VMError, match="does not match its digest lock"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_codex_dmg_cache_seed_rejects_a_stale_valid_cache(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{'0' * 64}  node-v22.22.2-linux-x64.tar.xz\n", encoding="utf-8"
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"koly" + (b"\0" * 508))
    digest_lock = tmp_path / "packages" / "codex-desktop-dmg-sha256.txt"
    digest_lock.write_text(("0" * 64) + "\n", encoding="utf-8")

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv(
        "ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(tmp_path / "missing-node.tar.xz")
    )
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))

    with pytest.raises(VMError, match="does not match the repository digest lock"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_codex_dmg_cache_seed_rejects_an_invalid_udif_trailer(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    cache = tmp_path / "electron-cache"
    cache.mkdir()
    node_lock = tmp_path / "packages" / "codex-desktop-node-runtime.sha256"
    node_lock.parent.mkdir()
    node_lock.write_text(
        f"{'0' * 64}  node-v22.22.2-linux-x64.tar.xz\n", encoding="utf-8"
    )
    dmg = tmp_path / "Codex.dmg"
    dmg.write_bytes(b"invalid" + (b"\0" * 505))

    monkeypatch.setenv("ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR", str(cache))
    monkeypatch.setenv(
        "ENOSHIMA_VM_CODEX_NODE_ARCHIVE", str(tmp_path / "missing-node.tar.xz")
    )
    monkeypatch.setenv("ENOSHIMA_VM_CODEX_DMG", str(dmg))

    with pytest.raises(VMError, match="no UDIF trailer"):
        service._seed_codex_electron_cache({"run_id": "run-012345abcdef"})


def test_pacman_cache_round_trip_is_snapshot_scoped_and_bounded(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    record = {
        "run_id": "run-012345abcdef",
        "base_image": str(
            tmp_path / "arch-cloud-reproducible-f419d4e29aebfc01.qcow2"
        ),
    }
    guest = PacmanCacheGuest(
        {
            "alpha-1.0-1-x86_64.pkg.tar.zst": b"alpha-package",
            "alpha-1.0-1-x86_64.pkg.tar.zst.sig": b"alpha-signature",
            "beta-2.0-1-any.pkg.tar.zst": b"beta-package",
        }
    )
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr(service, "_write_record", lambda _record: None)
    monkeypatch.setattr(service, "_audit", lambda *_args, **_kwargs: None)
    service._run_dir(record["run_id"]).mkdir(mode=0o700, parents=True)

    service._collect_pacman_cache(record)

    cache_root, package_root, archive, manifest = service._pacman_cache_paths(record)
    assert cache_root.is_relative_to(paths.cache)
    assert sorted(path.name for path in package_root.iterdir()) == [
        "alpha-1.0-1-x86_64.pkg.tar.zst",
        "alpha-1.0-1-x86_64.pkg.tar.zst.sig",
        "beta-2.0-1-any.pkg.tar.zst",
    ]
    assert archive.is_file()
    metadata = json.loads(manifest.read_text(encoding="utf-8"))
    assert metadata["package_count"] == 3
    assert metadata["package_bytes"] == len(
        b"alpha-packagealpha-signaturebeta-package"
    )
    assert record["observations"]["pacman_cache_collect"]["status"] == "updated"

    seed_guest = CacheSeedGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: seed_guest)
    service._seed_pacman_cache(record)

    assert seed_guest.uploads == [
        (
            archive,
            "/home/kentakang/enoshima-test/cache/pacman-seed.tar",
            0o600,
        )
    ]
    assert record["observations"]["pacman_cache_seed"]["status"] == "seeded"
    assert any(
        command[:3] == ("sudo", "tar", "--extract")
        for command in seed_guest.commands
    )


def test_every_bootstrap_suite_seeds_the_optional_electron_cache() -> None:
    suites = RuntimePaths.discover().project / "suites"
    for path in suites.glob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        if "run_bootstrap" not in text:
            continue
        assert "- seed_codex_electron_cache" in text
        assert text.rindex("- upload_worktree") < text.index("- run_bootstrap")
        assert text.index("- seed_codex_electron_cache") < text.index(
            "- run_bootstrap"
        )
        assert "- seed_pacman_cache" in text
        assert text.index("- seed_pacman_cache") < text.index("- run_bootstrap")


def test_stable_ui_accepts_perceptually_identical_renderer_noise(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "noisy.png"
    captures = 0

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        metric = argv[argv.index("-metric") + 1]
        outputs = {
            "AE": "1000000",
            "RMSE": "64 (0.000976577)",
            "SSIM": "0.0666445",
        }
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr=outputs[metric])

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)

    capture = service._capture_stable_ui(
        {"run_id": "run-012345abcdef"}, "noisy", "HEADLESS-UI"
    )

    assert captures == 2
    assert capture["stability_changed_pixel_ratio"] == 1.0
    assert capture["stability_normalized_rmse"] == 0.00097658
    assert capture["stability_ssim_error"] == 0.0666445
    assert capture["stability_metric"] == "normalized-rmse"
    assert not image.with_name(".noisy.png.previous").exists()


def test_unstable_ui_retains_the_best_frame_pair_and_difference(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    image = tmp_path / "artifacts" / "screenshots" / "unstable.png"
    captures = 0
    monotonic_values = iter([0.0, 1.0])

    def screenshot(_run_id, _name, _output):
        nonlocal captures
        captures += 1
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        image.write_bytes(f"frame-{captures}".encode())
        return {"path": str(image), "width": 1000, "height": 1000}

    def compare(argv, **_kwargs):
        if "-metric" in argv:
            metric = argv[argv.index("-metric") + 1]
            outputs = {"AE": "1000000", "RMSE": "0.2 (0.2)", "SSIM": "0.2"}
            return subprocess.CompletedProcess(
                argv, 1, stdout="", stderr=outputs[metric]
            )
        Path(argv[-1]).write_bytes(b"difference")
        return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

    monkeypatch.setattr(service, "screenshot", screenshot)
    monkeypatch.setattr("enoshima_vm.service.subprocess.run", compare)
    monkeypatch.setattr(
        "enoshima_vm.service.time.monotonic", lambda: next(monotonic_values)
    )
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    with pytest.raises(VMError, match="perceptually stable") as failure:
        service._capture_stable_ui(
            {"run_id": "run-012345abcdef"},
            "unstable",
            "HEADLESS-UI",
            timeout_seconds=0.5,
        )

    assert captures == 3
    assert failure.value.details is not None
    assert failure.value.details["best_stability"] == {
        "changed_pixel_ratio": 1.0,
        "normalized_rmse": 0.2,
        "ssim_error": 0.2,
    }
    for key in (
        "diagnostic_previous",
        "diagnostic_current",
        "diagnostic_difference",
    ):
        assert Path(str(failure.value.details[key])).is_file()
    assert not image.with_name(".unstable.png.previous").exists()


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
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
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
    assert "hl.dsp.exec_cmd" in method
    assert "self._hypr_command(launch)" in method
    assert "self._graphical_shell(launch)" not in method
    assert "self._start_power_client_fixture(record)" in method
    fixture = source[
        source.index("def _start_power_client_fixture") : source.index(
            "def _reboot_via_desktop_power"
        )
    ]
    assert "Enoshima Power Fixture" in fixture
    assert "ghostty" in fixture
    assert "desktop-power did not change the guest boot ID" in method
    assert "desktop-power checkpoint was not verified after login" in method


def test_idempotency_diff_excludes_non_filesystem_script_entries() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    method = source[
        source.index("def _assert_idempotent") : source.index(
            "def _assert_expected_skips"
        )
    ]

    assert '"diff",\n                "--exclude",\n                "scripts"' in method


def test_power_reboot_waits_for_a_real_application_client(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = PowerClientGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)
    monkeypatch.setattr("enoshima_vm.service.time.sleep", lambda _seconds: None)

    clients = service._wait_for_power_clients(
        {"run_id": "run-012345abcdef"}, timeout_seconds=1
    )

    assert clients == [
        {
            "address": "0xabc",
            "class": "com.mitchellh.ghostty",
            "title": "Enoshima Power Fixture",
            "pid": 42,
        }
    ]
    command = " ".join(guest.commands[0])
    assert "xembed-sni-proxy" in command
    assert "special:tray" in command
    assert "Enoshima Power Fixture" in command


def test_power_reboot_starts_a_closeable_wayland_fixture(
    tmp_path, monkeypatch
) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    service = VMService(paths)
    guest = ScreenshotGuest()
    monkeypatch.setattr(service, "_guest", lambda _record: guest)

    service._start_power_client_fixture({"run_id": "run-012345abcdef"})

    command = " ".join(guest.commands[-1])
    assert "hl.dsp.exec_cmd" in command
    assert "ghostty" in command
    assert "--confirm-close-surface=false" in command
    assert "Enoshima Power Fixture" in command
    assert "sleep infinity" in command


def test_disposable_login_password_is_newline_free_for_gnome_keyring() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
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


def test_disposable_luks_recovery_key_is_newline_free(tmp_path: Path) -> None:
    recovery_key = tmp_path / "luks-recovery.key"

    _write_recovery_key(recovery_key)

    value = recovery_key.read_bytes()
    assert len(value) == 64
    assert set(value) <= set(b"0123456789abcdef")
    assert recovery_key.stat().st_mode & 0o777 == 0o600


def test_deterministic_login_suites_suppress_managed_application_autostarts() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_login") : source.index("def _login_greetd")
    ]

    assert 'suite in {"ui-review", "reboot"}' in prepare
    assert "def _suppress_managed_application_autostarts" in prepare
    assert "for entry in discord slack kakaotalk" in prepare
    assert "Hidden=true" in prepare


def test_postflight_imports_the_live_graphical_environment_after_login() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
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
    assert "coredumpctl --since" in method
    assert '"$boot_started"' in method or '\\"$boot_started\\"' in method
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
    assert "len(fallback_probes) != 2" in source


def test_ui_review_closes_existing_clients_with_exact_addresses() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    cleanup = source.index("def _close_ui_review_clients")
    review = source.index("def _run_ui_review", cleanup)
    body = source[cleanup:review]
    assert "desktop-window-action close --address" in body
    assert "--origin compositor" in body
    assert "--origin vm-review" not in body
    assert "--active" not in body


def test_titlebar_review_uses_the_supported_maximize_action_contract() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    titlebar = source[
        source.index("def _start_titlebar_review") : source.index(
            "def _stop_desktop_shell_review"
        )
    ]

    assert "desktop-window-action maximize --address" in titlebar
    assert "--origin compositor" in titlebar
    assert "--origin vm-review" not in titlebar
    assert "maximize-titlebar-fixture" in titlebar


def test_titlebar_review_waits_for_the_production_menu_layer_transition() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]

    reset = review.index("present=False")
    fixture = review.index('elif case.surface == "system-titlebar"')
    ready = review.index("fixture_ack = self._wait_for_ui_fixture_ready", fixture)
    mapped = review.index("present=True", ready)
    capture = review.index("capture = self._capture_stable_ui", mapped)

    assert reset < fixture < ready < mapped < capture


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


def test_notification_review_owns_the_dbus_daemon_without_systemd_races() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    prepare = source[
        source.index("def _prepare_notification_review") : source.index(
            "def _restore_notification_review"
        )
    ]
    start = source[
        source.index("def _start_notification_review") : source.index(
            "def _stop_titlebar_review"
        )
    ]
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]

    assert "systemctl --user stop swaync.service" in prepare
    assert "systemctl --user mask --runtime --force swaync.service" in prepare
    assert "systemctl --user stop swaync.service" not in start
    assert "org.freedesktop.Notifications" in start
    assert 'test "$owner" = "$pid"' in start
    assert 'if "notification-center" in surfaces:' in review
    assert "self._prepare_notification_review(record)" in review
    assert "self._restore_notification_review(record)" in review


def test_ui_review_resets_quickshell_layers_at_every_surface_boundary() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
    ).read_text(encoding="utf-8")
    review = source[
        source.index("def _run_ui_review") : source.index(
            "def _run_electron_qualification"
        )
    ]
    reset = review.index("self._reset_ui_review_surface(record)")
    branch = review.index('if case.surface == "auth"')
    fixture_reset = review.index(
        'record, "desktop-shell", "default", output', reset
    )

    assert reset < fixture_reset < branch
    assert "self._wait_for_ui_fixture_ready(record, reset_sequence)" in review


def test_ui_review_rejects_identical_required_states() -> None:
    captures = [
        {
            "surface_id": "notification-center",
            "state": state,
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "image_sha256": "same-image",
        }
        for state in ("empty", "notification", "critical")
    ]
    captures.append(
        {
            "surface_id": "notification-center",
            "state": "empty",
            "locale": "ko_KR.UTF-8",
            "scale": 1.0,
            "image_sha256": "only-one-state",
        }
    )

    failures = VMService._ui_review_identical_state_groups(captures)

    assert failures == [
        {
            "surface": "notification-center",
            "locale": "en_US.UTF-8",
            "scale": 1.0,
            "states": ["critical", "empty", "notification"],
        }
    ]


def test_ui_review_resets_clients_at_every_surface_boundary() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
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

    result = service.screenshot("run-012345abcdef", "launcher-en", "HEADLESS-INTERNAL")

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
        "hl.config({ plugin = { enoshima_decoration = { allowlist = "
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

    ack = service._wait_for_ui_fixture_ready({"run_id": "run-012345abcdef"}, 42)

    assert guest.commands[-1][-1].endswith("/ui-fixture/ready.json")
    assert ack["text_overflow_count"] == 0
    assert ack["missing_translation_count"] == 0


def test_ui_fixture_rejects_untranslated_catalog_keys(tmp_path, monkeypatch) -> None:
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
        service._wait_for_ui_fixture_ready({"run_id": "run-012345abcdef"}, 42)


def test_ui_review_rejects_measured_text_overflow() -> None:
    source = (
        RuntimePaths.discover().project / "src" / "enoshima_vm" / "service.py"
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
    assert result["stability_metric"] == "pixel-hash"
