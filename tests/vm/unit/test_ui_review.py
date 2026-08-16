from __future__ import annotations

import re

import pytest

from enoshima_vm.config import RuntimePaths
from enoshima_vm.ui_review import (
    load_ui_review_identities,
    load_ui_review_matrix,
    overview_auxiliary_scale,
    physical_mode,
    select_ui_review_cases,
)


def test_repository_ui_review_matrix_is_complete_and_dynamic() -> None:
    matrix = load_ui_review_matrix(RuntimePaths.discover().repository)

    assert len(matrix) == 516
    assert len({case.key for case in matrix}) == len(matrix)
    assert {case.locale for case in matrix} == {"en_US.UTF-8", "ko_KR.UTF-8"}
    assert {case.scale for case in matrix} == {1.0, 1.25, 2.0}
    assert {case.surface for case in matrix} == {
        "auth",
        "command-palette",
        "cyberdock-window-state",
        "desktop-shell",
        "display-mode",
        "launcher",
        "notification-center",
        "overview",
        "osd",
        "power-menu",
        "snap-assist",
        "system-titlebar",
    }
    assert "desktop-capture-recording" not in {case.surface for case in matrix}
    assert all(case.artifact_name.replace("-", "").isalnum() for case in matrix)


def test_ui_review_modes_preserve_one_logical_canvas() -> None:
    assert physical_mode(1.0) == "1280x800@60"
    assert physical_mode(1.25) == "1600x1000@60"
    assert physical_mode(2.0) == "2560x1600@60"


def test_overview_auxiliary_scale_is_always_mixed_dpi() -> None:
    assert overview_auxiliary_scale(1.0) == 1.25
    assert overview_auxiliary_scale(1.25) == 2.0
    assert overview_auxiliary_scale(2.0) == 1.25

    with pytest.raises(ValueError, match="review matrix"):
        overview_auxiliary_scale(1.5)


def test_ui_review_mode_selects_representative_or_affected_full_matrix() -> None:
    matrix = load_ui_review_matrix(RuntimePaths.discover().repository)
    representative = select_ui_review_cases(
        matrix,
        surfaces={"power-menu"},
        matrix_mode="representative",
        locales={"en_US.UTF-8"},
        scales={1.0},
    )
    affected_full = select_ui_review_cases(
        matrix,
        surfaces={"power-menu"},
        matrix_mode="affected-full",
    )
    full = select_ui_review_cases(
        matrix,
        surfaces={case.surface for case in matrix},
        matrix_mode="full",
    )

    assert len(representative) == 1
    assert representative[0].state == "default"
    assert len(affected_full) == 6 * 2 * 3
    assert len(full) == 516


def test_command_palette_representative_covers_async_emoji_rendering() -> None:
    matrix = load_ui_review_matrix(RuntimePaths.discover().repository)

    representative = select_ui_review_cases(
        matrix,
        surfaces={"command-palette"},
        matrix_mode="representative",
        locales={"en_US.UTF-8"},
        scales={1.0},
    )

    assert len(representative) == 1
    assert representative[0].state == "emoji-picker"


def test_surface_identity_matches_the_current_registry() -> None:
    repository = RuntimePaths.discover().repository
    identity = load_ui_review_identities(repository, {"power-menu"})["power-menu"]
    assert len(identity["implementation_digest"]) == 64
    assert len(identity["concept_sha256"]) == 64
    assert len(identity["concept_spec_sha256"]) == 64


def test_display_confirmation_fixture_has_a_stable_countdown_frame() -> None:
    repository = RuntimePaths.discover().repository
    shell = (repository / "home/dot_config/quickshell/cyberdock/shell.qml").read_text(
        encoding="utf-8"
    )

    assert '"deadline": 0,' in shell
    assert '"seconds_remaining": state === "confirmation" ? 12 : 0' in shell


def test_snap_fixture_covers_every_production_layout() -> None:
    repository = RuntimePaths.discover().repository
    shell = (repository / "home/dot_config/quickshell/cyberdock/shell.qml").read_text(
        encoding="utf-8"
    )
    broker = (
        repository / "home/dot_local/libexec/executable_enoshima-windowd"
    ).read_text(encoding="utf-8")

    fixture_layouts = set(re.findall(r'"layoutId": "([^"]+)"', shell))
    production_layouts = set(re.findall(r'"id": "([^"]+)",', broker))

    assert fixture_layouts == production_layouts
