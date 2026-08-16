from __future__ import annotations

import hashlib
import itertools
from dataclasses import dataclass
from pathlib import Path

import yaml

from .errors import FailureCategory, VMError


@dataclass(frozen=True, slots=True)
class UiReviewCase:
    surface: str
    state: str
    locale: str
    scale: float

    @property
    def key(self) -> str:
        safe_locale = self.locale.replace(".", "-")
        return f"{self.surface}--{self.state}--{safe_locale}--{self.scale:g}x"

    @property
    def artifact_name(self) -> str:
        return self.key.lower().replace("_", "-").replace(".", "-")


def load_ui_review_matrix(repository: Path) -> tuple[UiReviewCase, ...]:
    manifest_path = repository / "docs" / "ui-surfaces.yaml"
    try:
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "cannot load the UI surface registry",
            {"path": str(manifest_path), "error": str(error)},
        ) from error
    if not isinstance(manifest, dict) or manifest.get("schema") != 2:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "UI review requires the schema 2 surface registry",
        )
    surfaces = manifest.get("surfaces")
    if not isinstance(surfaces, dict) or not surfaces:
        raise VMError(FailureCategory.HARNESS_ERROR, "UI surface registry is empty")

    cases: list[UiReviewCase] = []
    for surface, entry in surfaces.items():
        evidence = entry.get("evidence") if isinstance(entry, dict) else None
        if not isinstance(evidence, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI surface lacks an evidence contract: {surface}",
            )
        states = evidence.get("required_states")
        locales = evidence.get("required_locales")
        scales = evidence.get("required_scales")
        if not all(
            isinstance(value, list) and value for value in (states, locales, scales)
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI surface has an incomplete evidence matrix: {surface}",
            )
        for state, locale, scale in itertools.product(states, locales, scales):
            cases.append(
                UiReviewCase(
                    surface=str(surface),
                    state=str(state),
                    locale=str(locale),
                    scale=float(scale),
                )
            )

    keys = [case.key for case in cases]
    if len(keys) != len(set(keys)):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "UI surface registry produces duplicate capture keys",
        )
    return tuple(cases)


def select_ui_review_cases(
    matrix: tuple[UiReviewCase, ...],
    *,
    surfaces: set[str],
    matrix_mode: str,
    locales: set[str] | None = None,
    scales: set[float] | None = None,
) -> tuple[UiReviewCase, ...]:
    if matrix_mode not in {"representative", "affected-full", "full"}:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "run_ui_review has an invalid matrix mode",
            {"matrix_mode": matrix_mode},
        )
    selected = [
        case
        for case in matrix
        if case.surface in surfaces
        and (locales is None or case.locale in locales)
        and (scales is None or case.scale in scales)
    ]
    if matrix_mode == "representative":
        selected_locales = locales or {"en_US.UTF-8"}
        selected_scales = scales or {1.0}
        representatives: list[UiReviewCase] = []
        for surface in sorted(surfaces):
            for locale in sorted(selected_locales):
                for scale in sorted(selected_scales):
                    candidates = [
                        case
                        for case in selected
                        if case.surface == surface
                        and case.locale == locale
                        and case.scale == scale
                    ]
                    if not candidates:
                        raise VMError(
                            FailureCategory.HARNESS_ERROR,
                            (
                                "representative UI review scope is absent from "
                                "the registry"
                            ),
                            {
                                "surface": surface,
                                "locale": locale,
                                "scale": scale,
                            },
                        )
                    representatives.append(
                        min(
                            candidates,
                            key=lambda case: (case.state != "default", case.state),
                        )
                    )
        selected = representatives
    selected.sort(key=lambda case: (case.locale, case.scale, case.surface, case.state))
    return tuple(selected)


def load_ui_review_identities(
    repository: Path, surfaces: set[str]
) -> dict[str, dict[str, str]]:
    manifest = yaml.safe_load(
        (repository / "docs" / "ui-surfaces.yaml").read_text(encoding="utf-8")
    )
    entries = manifest.get("surfaces", {}) if isinstance(manifest, dict) else {}
    identities: dict[str, dict[str, str]] = {}
    for surface in surfaces:
        entry = entries.get(surface)
        if not isinstance(entry, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI review surface is not registered: {surface}",
            )
        digest = hashlib.sha256()
        for value in sorted(entry.get("implementation", [])):
            path = repository / str(value)
            if not path.is_file() or path.is_symlink():
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"UI implementation is unavailable: {value}",
                )
            digest.update(str(value).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        concept = entry.get("concept", {})
        concept_path = repository / str(concept.get("asset", ""))
        concept_spec_path = repository / str(concept.get("spec", ""))
        if not concept_path.is_file() or concept_path.is_symlink():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI concept asset is unavailable: {surface}",
            )
        concept_hash = hashlib.sha256(concept_path.read_bytes()).hexdigest()
        if concept_hash != concept.get("sha256"):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI concept hash is stale: {surface}",
            )
        if not concept_spec_path.is_file() or concept_spec_path.is_symlink():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI concept spec is unavailable: {surface}",
            )
        identities[surface] = {
            "implementation_digest": digest.hexdigest(),
            "concept_sha256": concept_hash,
            "concept_spec_sha256": hashlib.sha256(
                concept_spec_path.read_bytes()
            ).hexdigest(),
        }
    return identities


def physical_mode(scale: float, logical_size: tuple[int, int] = (1280, 800)) -> str:
    if scale <= 0:
        raise ValueError("scale must be positive")
    width = round(logical_size[0] * scale)
    height = round(logical_size[1] * scale)
    if (
        abs(width / scale - logical_size[0]) > 0.01
        or abs(height / scale - logical_size[1]) > 0.01
    ):
        raise ValueError("scale cannot produce an integral physical mode")
    return f"{width}x{height}@60"


def overview_auxiliary_scale(primary_scale: float) -> float:
    """Choose a supported, deliberately different scale for the second output."""
    supported = (1.0, 1.25, 2.0)
    if not any(abs(primary_scale - value) < 0.001 for value in supported):
        raise ValueError("overview scale must be part of the review matrix")
    return 2.0 if abs(primary_scale - 1.25) < 0.001 else 1.25
