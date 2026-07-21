from __future__ import annotations

from enoshima_vm.config import RuntimePaths
from enoshima_vm.ui_review import (
    load_ui_review_identities,
    load_ui_review_matrix,
    physical_mode,
)


def test_repository_ui_review_matrix_is_complete_and_dynamic() -> None:
    matrix = load_ui_review_matrix(RuntimePaths.discover().repository)

    assert len(matrix) == 432
    assert len({case.key for case in matrix}) == len(matrix)
    assert {case.locale for case in matrix} == {"en_US.UTF-8", "ko_KR.UTF-8"}
    assert {case.scale for case in matrix} == {1.0, 1.25, 2.0}
    assert {case.surface for case in matrix} == {
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
    assert all(case.artifact_name.replace("-", "").isalnum() for case in matrix)


def test_ui_review_modes_preserve_one_logical_canvas() -> None:
    assert physical_mode(1.0) == "1280x800@60"
    assert physical_mode(1.25) == "1600x1000@60"
    assert physical_mode(2.0) == "2560x1600@60"


def test_surface_identity_matches_the_current_registry() -> None:
    repository = RuntimePaths.discover().repository
    identity = load_ui_review_identities(repository, {"power-menu"})["power-menu"]
    assert len(identity["implementation_digest"]) == 64
    assert len(identity["concept_sha256"]) == 64
