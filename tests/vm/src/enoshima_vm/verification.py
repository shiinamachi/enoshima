from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, replace
from typing import Any

from .config import RuntimePaths, Suite, _load_yaml, load_suite
from .errors import FailureCategory, VMError

VALID_MODES = ("dev", "checkpoint", "release")
RELEASE_SUITE_ORDER = (
    "smoke",
    "converge",
    "reboot",
    "desktop",
    "login",
    "ui-review",
    "boot-security",
)


@dataclass(frozen=True, slots=True)
class VerificationMode:
    name: str
    authoritative: bool
    fresh_overlay_required: bool
    fail_fast: bool
    overrides: dict[str, dict[str, Any]]

    def apply(
        self,
        suite: Suite,
        *,
        surfaces: tuple[str, ...] = (),
        locales: tuple[str, ...] = (),
        scales: tuple[float, ...] = (),
    ) -> Suite:
        steps: list[str | dict[str, Any]] = []
        for raw_step in suite.steps:
            if isinstance(raw_step, str):
                action = raw_step
                original: Any = None
            else:
                action, original = next(iter(raw_step.items()))
            override = self.overrides.get(action)
            inject_ui_scope = action == "run_ui_review" and bool(surfaces)
            if override is None and not inject_ui_scope:
                steps.append(deepcopy(raw_step))
                continue
            if original is None:
                config: dict[str, Any] = {}
            elif isinstance(original, dict):
                config = deepcopy(original)
            else:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"mode override requires mapping step config: {action}",
                )
            if override:
                config.update(deepcopy(override))
            if inject_ui_scope:
                config["surfaces"] = list(surfaces)
                if locales:
                    config["locales"] = list(locales)
                if scales:
                    config["scales"] = list(scales)
            steps.append({action: config})
        return replace(suite, steps=tuple(steps))


@dataclass(frozen=True, slots=True)
class VerificationPlanDefinition:
    name: str
    mode: str
    suites: tuple[str, ...]
    unique: bool


def load_verification_modes(
    paths: RuntimePaths | None = None,
) -> dict[str, VerificationMode]:
    paths = paths or RuntimePaths.discover()
    path = paths.project / "verification-modes.yaml"
    data = _load_yaml(path)
    if data.get("schema") != 1 or not isinstance(data.get("modes"), dict):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid verification mode document: {path}",
        )
    modes: dict[str, VerificationMode] = {}
    for name, raw in data["modes"].items():
        if name not in VALID_MODES or not isinstance(raw, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid verification mode: {name}",
            )
        overrides = raw.get("overrides", {})
        if not isinstance(overrides, dict) or any(
            not isinstance(action, str) or not isinstance(values, dict)
            for action, values in overrides.items()
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid verification mode overrides: {name}",
            )
        modes[name] = VerificationMode(
            name=name,
            authoritative=bool(raw.get("authoritative", False)),
            fresh_overlay_required=bool(raw.get("fresh_overlay", False)),
            fail_fast=bool(raw.get("fail_fast", True)),
            overrides=deepcopy(overrides),
        )
    if tuple(modes) != VALID_MODES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "verification modes must be declared in dev/checkpoint/release order",
        )
    if modes["dev"].authoritative or modes["dev"].fresh_overlay_required:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "dev mode must remain non-authoritative and permit diagnostic reuse",
        )
    for name in ("checkpoint", "release"):
        if not modes[name].authoritative or not modes[name].fresh_overlay_required:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"{name} mode requires authoritative fresh overlays",
            )
    return modes


def load_verification_mode(
    name: str, paths: RuntimePaths | None = None
) -> VerificationMode:
    try:
        return load_verification_modes(paths)[name]
    except KeyError as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"unknown verification mode: {name}",
        ) from error


def load_verification_plan(
    name: str, paths: RuntimePaths | None = None
) -> VerificationPlanDefinition:
    paths = paths or RuntimePaths.discover()
    if name != "release":
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"unknown verification plan: {name}",
        )
    path = paths.project / "plans" / f"{name}.yaml"
    data = _load_yaml(path)
    suites = data.get("suites")
    if (
        data.get("schema") != 1
        or data.get("name") != name
        or data.get("mode") != "release"
        or not isinstance(suites, list)
        or not suites
        or not all(isinstance(suite, str) for suite in suites)
    ):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid verification plan: {path}",
        )
    unique = bool(data.get("unique", False))
    if not unique or len(suites) != len(set(suites)):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"verification plan must contain unique suites: {path}",
        )
    if name == "release" and tuple(suites) != RELEASE_SUITE_ORDER:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "release verification plan must use the canonical suite order",
            {"expected": list(RELEASE_SUITE_ORDER), "actual": suites},
        )
    for suite in suites:
        load_suite(suite, paths)
    return VerificationPlanDefinition(name, str(data["mode"]), tuple(suites), unique)
