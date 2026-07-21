from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType


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


def test_electron_qualification_covers_native_and_system_chrome() -> None:
    fixture = (
        Path(__file__).resolve().parents[1] / "fixtures" / "electron-window" / "main.js"
    ).read_text(encoding="utf-8")
    driver = (
        Path(__file__).resolve().parents[1] / "fixtures" / "electron-qualification.py"
    ).read_text(encoding="utf-8")

    assert "EnoshimaElectronFixtureCustom" in fixture
    assert "EnoshimaElectronFixtureSystem" in fixture
    assert 'for decoration in ("custom", "system")' in driver
    assert 'fixture.command("native-minimize")' in driver
    assert 'fixture.command("native-maximize")' in driver
    assert 'fixture.command("native-unmaximize")' in driver
    assert 'fixture.command("native-close-reopen")' in driver
    assert "duplicate system decoration" in driver
