from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest


def load_driver() -> ModuleType:
    path = (
        Path(__file__).resolve().parents[1] / "fixtures" / "electron-qualification.py"
    )
    spec = importlib.util.spec_from_file_location("electron_qualification", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_reopened_electron_generation_may_reuse_hyprland_address(
    monkeypatch,
) -> None:
    driver = load_driver()
    reused_address = "0x1234"
    monkeypatch.setattr(
        driver,
        "clients",
        lambda: [
            {
                "pid": 4242,
                "address": reused_address,
                "title": "Enoshima Electron Fixture token generation-18",
            }
        ],
    )

    assert driver.find_fixture(4242, generation=17) is None
    reopened = driver.find_fixture(4242, generation=18)
    assert reopened is not None
    assert reopened["address"] == reused_address


def test_electron_generation_filter_rejects_another_process(monkeypatch) -> None:
    driver = load_driver()
    monkeypatch.setattr(
        driver,
        "clients",
        lambda: [
            {
                "pid": 9999,
                "address": "0x1234",
                "title": "Enoshima Electron Fixture token generation-3",
            }
        ],
    )

    assert driver.find_fixture(4242, generation=3) is None


def test_electron_qualification_proves_fallback_and_system_chrome() -> None:
    fixture = (
        Path(__file__).resolve().parents[1] / "fixtures" / "electron-window" / "main.js"
    ).read_text(encoding="utf-8")
    driver = (
        Path(__file__).resolve().parents[1] / "fixtures" / "electron-qualification.py"
    ).read_text(encoding="utf-8")

    assert "EnoshimaElectronFixtureCustom" in fixture
    assert "EnoshimaElectronFixtureSystem" in fixture
    assert "probe_native_minimize_fallback(native_fixture)" in driver
    assert 'fixture.command("native-minimize")' in driver
    assert "duplicate system decoration" in driver
    assert 'decoration = "system"' in driver
    assert '"clientNativeMinimizeExposed": False' in driver


def test_native_minimize_probe_records_the_managed_fallback(monkeypatch) -> None:
    driver = load_driver()
    workspace = {"id": 2, "name": "2"}
    fixture = SimpleNamespace(
        decoration="custom",
        backend="wayland",
        client={"address": "0x1234"},
        process=SimpleNamespace(poll=lambda: None),
        command=lambda action: {"action": action, "minimized": False},
    )
    monkeypatch.setattr(
        driver, "normalize_mode", lambda _address, _mode: {"workspace": workspace}
    )
    monkeypatch.setattr(
        driver,
        "find_address",
        lambda _address: {"workspace": workspace},
    )
    monkeypatch.setattr(driver, "has_enoshima_decoration", lambda _address: False)
    monkeypatch.setattr(driver.time, "sleep", lambda _seconds: None)

    result = driver.probe_native_minimize_fallback(fixture)

    assert result == {
        "backend": "wayland",
        "processAlive": True,
        "workspaceUnchanged": True,
        "electronReportedMinimized": False,
        "enoshimaDecorationAbsent": True,
    }

    monkeypatch.setattr(
        driver,
        "find_address",
        lambda _address: {"workspace": {"id": -99, "name": "special:minimized"}},
    )
    with pytest.raises(RuntimeError, match="reevaluate"):
        driver.probe_native_minimize_fallback(fixture)
