from __future__ import annotations

from typing import Any

import pytest

import enoshima_vm.verification as verification
from enoshima_vm.config import Suite, load_suite
from enoshima_vm.errors import VMError
from enoshima_vm.impact import CANONICAL_SUITE_ORDER
from enoshima_vm.verification import (
    load_verification_mode,
    load_verification_plan,
)


def _step_config(suite: Suite, action: str) -> dict[str, Any]:
    for step in suite.steps:
        if isinstance(step, dict) and action in step:
            value = step[action]
            assert isinstance(value, dict)
            return value
    raise AssertionError(f"suite does not contain step: {action}")


@pytest.mark.parametrize(
    ("mode_name", "electron_iterations", "reboot_iterations", "matrix_mode"),
    [
        ("dev", 1, 1, "representative"),
        ("checkpoint", 3, 3, "affected-full"),
        ("release", 20, 10, "full"),
    ],
)
def test_mode_applies_iteration_budgets_and_ui_matrix(
    mode_name: str,
    electron_iterations: int,
    reboot_iterations: int,
    matrix_mode: str,
) -> None:
    mode = load_verification_mode(mode_name)
    desktop = mode.apply(load_suite("desktop"))
    reboot = mode.apply(load_suite("reboot"))
    ui_review = mode.apply(
        load_suite("ui-review"),
        surfaces=("launcher",),
        locales=("en_US.UTF-8", "ko_KR.UTF-8"),
        scales=(1.0, 2.0),
    )

    assert _step_config(desktop, "run_electron_qualification")["iterations"] == (
        electron_iterations
    )
    assert _step_config(reboot, "reboot_via_desktop_power")["iterations"] == (
        reboot_iterations
    )
    ui_config = _step_config(ui_review, "run_ui_review")
    assert ui_config["matrix_mode"] == matrix_mode
    assert ui_config["surfaces"] == ["launcher"]
    assert ui_config["locales"] == ["en_US.UTF-8", "ko_KR.UTF-8"]
    assert ui_config["scales"] == [1.0, 2.0]


def test_release_plan_is_unique_and_in_canonical_order() -> None:
    plan = load_verification_plan("release")

    assert plan.mode == "release"
    assert plan.unique is True
    assert plan.suites == CANONICAL_SUITE_ORDER
    assert len(plan.suites) == len(set(plan.suites))


@pytest.mark.parametrize(
    "override",
    [
        {"mode": "checkpoint"},
        {"unique": False},
        {"suites": list(reversed(CANONICAL_SUITE_ORDER))},
    ],
)
def test_release_plan_rejects_noncanonical_contract(
    monkeypatch, override: dict[str, object]
) -> None:
    document: dict[str, object] = {
        "schema": 1,
        "name": "release",
        "mode": "release",
        "suites": list(CANONICAL_SUITE_ORDER),
        "unique": True,
    }
    document.update(override)
    monkeypatch.setattr(verification, "_load_yaml", lambda _path: document)

    with pytest.raises(VMError):
        load_verification_plan("release")
