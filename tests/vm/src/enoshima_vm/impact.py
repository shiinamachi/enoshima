from __future__ import annotations

import fnmatch
import hashlib
import os
import re
import shlex
import stat
import subprocess
import uuid
from dataclasses import dataclass
from functools import cache
from pathlib import Path, PurePosixPath
from typing import Any

from .config import RuntimePaths, _load_yaml, load_suite
from .errors import FailureCategory, VMError
from .source import source_identity
from .verification import VALID_MODES, load_verification_mode

CANONICAL_SUITE_ORDER = (
    "smoke",
    "converge",
    "reboot",
    "desktop",
    "login",
    "ui-review",
    "boot-security",
)
BASE_REF_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@{}^~+-]*$")
SPECIAL_METADATA_NAMES = {"AGENTS.md", "README.md", "LICENSE"}


@dataclass(frozen=True, slots=True)
class VerificationRule:
    identifier: str
    paths: tuple[str, ...]
    focused_checks: tuple[str, ...]
    checkpoint_suites: tuple[str, ...]
    retry_suites: tuple[str, ...]
    physical_gates: tuple[str, ...]
    smallest_real_suite_required: bool


@dataclass(frozen=True, slots=True)
class VerificationMap:
    generated_paths: tuple[str, ...]
    metadata_paths: tuple[str, ...]
    runtime_paths: tuple[str, ...]
    rules: tuple[VerificationRule, ...]


@dataclass(frozen=True, slots=True)
class VerificationSelection:
    mode: str
    base: str
    source_commit: str
    worktree_digest: str
    source_tree_digest: str
    suite_retry_digests: dict[str, str]
    changed_paths: tuple[str, ...]
    focused_checks: tuple[str, ...]
    surfaces: tuple[str, ...]
    suites: tuple[str, ...]
    physical_gates: tuple[str, ...]
    locales: tuple[str, ...]
    scales: tuple[float, ...]
    reasons: dict[str, tuple[str, ...]]
    authoritative: bool
    fresh_overlay_required: bool
    smallest_real_suite_required: bool
    vm_omitted_reason: str | None

    def to_dict(self) -> dict[str, object]:
        result: dict[str, object] = {
            "schema": 1,
            "mode": self.mode,
            "base": self.base,
            "sourceCommit": self.source_commit,
            "worktreeDigest": self.worktree_digest,
            "sourceTreeDigest": self.source_tree_digest,
            "suiteRetryDigests": {
                suite: self.suite_retry_digests[suite]
                for suite in self.suites
                if suite in self.suite_retry_digests
            },
            "changedPaths": list(self.changed_paths),
            "focusedChecks": list(self.focused_checks),
            "surfaces": list(self.surfaces),
            "suites": list(self.suites),
            "physicalGates": list(self.physical_gates),
            "uiLocales": list(self.locales),
            "uiScales": list(self.scales),
            "authoritative": self.authoritative,
            "freshOverlayRequired": self.fresh_overlay_required,
            "smallestRealSuiteRequired": self.smallest_real_suite_required,
            "reasons": {
                key: list(values) for key, values in sorted(self.reasons.items())
            },
        }
        if self.vm_omitted_reason:
            result["vmOmittedReason"] = self.vm_omitted_reason
        return result


def _matches(path: str, pattern: str) -> bool:
    path_parts = PurePosixPath(path).parts
    pattern_parts = PurePosixPath(pattern).parts

    @cache
    def match(path_index: int, pattern_index: int) -> bool:
        if pattern_index == len(pattern_parts):
            return path_index == len(path_parts)
        segment = pattern_parts[pattern_index]
        if segment == "**":
            return match(path_index, pattern_index + 1) or (
                path_index < len(path_parts) and match(path_index + 1, pattern_index)
            )
        return (
            path_index < len(path_parts)
            and fnmatch.fnmatchcase(path_parts[path_index], segment)
            and match(path_index + 1, pattern_index + 1)
        )

    return match(0, 0)


def _string_tuple(raw: Any, *, field: str, path: Path) -> tuple[str, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, list) or not all(
        isinstance(value, str) and value for value in raw
    ):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid {field} in verification map: {path}",
        )
    return tuple(raw)


def load_verification_map(paths: RuntimePaths | None = None) -> VerificationMap:
    paths = paths or RuntimePaths.discover()
    path = paths.repository / "tests" / "verification-map.yaml"
    data = _load_yaml(path)
    raw_rules = data.get("rules")
    if data.get("schema") != 1 or not isinstance(raw_rules, list):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid verification map: {path}",
        )
    rules: list[VerificationRule] = []
    identifiers: set[str] = set()
    for raw in raw_rules:
        if not isinstance(raw, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"verification rule must be a mapping: {path}",
            )
        identifier = raw.get("id")
        if (
            not isinstance(identifier, str)
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identifier)
            or identifier in identifiers
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid or duplicate verification rule id: {identifier!r}",
            )
        identifiers.add(identifier)
        suites = _string_tuple(
            raw.get("checkpoint_suites"), field="checkpoint_suites", path=path
        )
        retry_suites = _string_tuple(
            raw.get("retry_suites"), field="retry_suites", path=path
        )
        retry_suites_declared = "retry_suites" in raw
        for suite in (*suites, *retry_suites):
            if suite not in CANONICAL_SUITE_ORDER:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"verification rule references a non-canonical suite: {suite}",
                )
            load_suite(suite, paths)
        rules.append(
            VerificationRule(
                identifier=identifier,
                paths=_string_tuple(raw.get("paths"), field="paths", path=path),
                focused_checks=_string_tuple(
                    raw.get("focused_checks"), field="focused_checks", path=path
                ),
                checkpoint_suites=suites,
                retry_suites=retry_suites if retry_suites_declared else suites,
                physical_gates=_string_tuple(
                    raw.get("physical_gates"), field="physical_gates", path=path
                ),
                smallest_real_suite_required=bool(
                    raw.get("smallest_real_suite_required", False)
                ),
            )
        )
    return VerificationMap(
        generated_paths=_string_tuple(
            data.get("generated_paths"), field="generated_paths", path=path
        ),
        metadata_paths=_string_tuple(
            data.get("metadata_paths"), field="metadata_paths", path=path
        ),
        runtime_paths=_string_tuple(
            data.get("runtime_paths"), field="runtime_paths", path=path
        ),
        rules=tuple(rules),
    )


def _git(repository: Path, *args: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        check=False,
        capture_output=True,
        text=not binary,
    )
    if result.returncode:
        stderr = (os.fsdecode(result.stderr) if binary else str(result.stderr)).strip()
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"git command failed: git {' '.join(args)}",
            {"stderr": stderr[-4000:]},
        )
    return result.stdout


def _validate_base_ref(base_ref: str) -> None:
    if not BASE_REF_PATTERN.fullmatch(base_ref):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid verification base ref: {base_ref!r}",
        )


def _validate_changed_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    pure = PurePosixPath(normalized)
    if not normalized or pure.is_absolute() or ".." in pure.parts:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"git returned an unsafe changed path: {path!r}",
        )
    return pure.as_posix()


def _parse_name_status(payload: bytes) -> set[str]:
    fields = payload.rstrip(b"\0").split(b"\0") if payload else []
    paths: set[str] = set()
    index = 0
    while index < len(fields):
        status = os.fsdecode(fields[index])
        index += 1
        count = 2 if status[:1] in {"R", "C"} else 1
        if index + count > len(fields):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "git produced incomplete name-status output",
            )
        for raw_path in fields[index : index + count]:
            paths.add(_validate_changed_path(os.fsdecode(raw_path)))
        index += count
    return paths


def collect_changed_paths(repository: Path, base_ref: str) -> tuple[str, ...]:
    _validate_base_ref(base_ref)
    _git(repository, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    paths = _parse_name_status(
        _git(
            repository,
            "diff",
            "--name-status",
            "-z",
            "--find-renames",
            f"{base_ref}...HEAD",
            "--",
            binary=True,
        )
    )
    paths.update(
        _parse_name_status(
            _git(
                repository,
                "diff",
                "--cached",
                "--name-status",
                "-z",
                "--find-renames",
                "--",
                binary=True,
            )
        )
    )
    paths.update(
        _parse_name_status(
            _git(
                repository,
                "diff",
                "--name-status",
                "-z",
                "--find-renames",
                "--",
                binary=True,
            )
        )
    )
    untracked = _git(
        repository,
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        binary=True,
    )
    if untracked:
        for raw_path in untracked.rstrip(b"\0").split(b"\0"):
            paths.add(_validate_changed_path(os.fsdecode(raw_path)))
    return tuple(sorted(paths))


def worktree_digest(
    repository: Path,
    changed_paths: tuple[str, ...],
    *,
    excluded_patterns: tuple[str, ...] = (),
    include_source_commit: bool = True,
) -> tuple[str, str]:
    source_commit = str(_git(repository, "rev-parse", "HEAD")).strip()
    digest = hashlib.sha256()
    if include_source_commit:
        digest.update(f"commit\0{source_commit}\0".encode())
    for relative in changed_paths:
        if any(_matches(relative, pattern) for pattern in excluded_patterns):
            continue
        digest.update(relative.encode("utf-8", errors="surrogateescape") + b"\0")
        path = repository / relative
        try:
            file_mode = path.lstat().st_mode
        except FileNotFoundError:
            file_mode = None
        if file_mode is not None:
            digest.update(
                (
                    f"mode\0{stat.S_IFMT(file_mode):o}\0{stat.S_IMODE(file_mode):o}\0"
                ).encode()
            )
        if path.is_symlink():
            digest.update(b"symlink\0" + os.readlink(path).encode() + b"\0")
        elif path.is_file():
            digest.update(b"file\0")
            with path.open("rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
        elif path.exists():
            digest.update(b"other\0")
        else:
            digest.update(b"deleted\0")
    return source_commit, digest.hexdigest()


def _load_ui_registry(
    paths: RuntimePaths,
) -> tuple[dict[str, tuple[str, ...]], dict[str, dict[str, tuple[Any, ...]]]]:
    path = paths.repository / "docs" / "ui-surfaces.yaml"
    data = _load_yaml(path)
    raw_surfaces = data.get("surfaces")
    if not isinstance(raw_surfaces, dict):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"invalid UI surface registry: {path}",
        )
    implementation: dict[str, list[str]] = {}
    requirements: dict[str, dict[str, tuple[Any, ...]]] = {}
    for surface, raw in raw_surfaces.items():
        if not isinstance(surface, str) or not isinstance(raw, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"invalid UI surface entry: {surface!r}",
            )
        inputs = _string_tuple(
            raw.get("implementation"), field="implementation", path=path
        )
        evidence = raw.get("evidence")
        if not isinstance(evidence, dict):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI surface lacks evidence contract: {surface}",
            )
        locales = _string_tuple(
            evidence.get("required_locales"), field="required_locales", path=path
        )
        raw_scales = evidence.get("required_scales")
        if not isinstance(raw_scales, list) or not all(
            isinstance(scale, (int, float)) for scale in raw_scales
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"UI surface has invalid scales: {surface}",
            )
        for input_path in inputs:
            implementation.setdefault(input_path, []).append(surface)
        requirements[surface] = {
            "locales": locales,
            "scales": tuple(float(scale) for scale in raw_scales),
        }
    return (
        {path: tuple(sorted(values)) for path, values in implementation.items()},
        requirements,
    )


def _append_unique(values: list[str], value: str) -> None:
    if value not in values:
        values.append(value)


def select_verification(
    *,
    base_ref: str = "origin/main",
    mode: str = "checkpoint",
    paths: RuntimePaths | None = None,
    changed_paths: tuple[str, ...] | None = None,
) -> VerificationSelection:
    paths = paths or RuntimePaths.discover()
    if mode not in VALID_MODES:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"unknown verification mode: {mode}",
        )
    mapping = load_verification_map(paths)
    mode_definition = load_verification_mode(mode, paths)
    selected_paths = (
        tuple(sorted({_validate_changed_path(path) for path in changed_paths}))
        if changed_paths is not None
        else collect_changed_paths(paths.repository, base_ref)
    )
    source_commit, digest = worktree_digest(
        paths.repository,
        selected_paths,
        excluded_patterns=mapping.generated_paths,
    )
    payload_identity = source_identity(paths.repository)
    if payload_identity.commit != source_commit:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "source commit changed while creating the verification plan",
            {
                "worktreeCommit": source_commit,
                "payloadCommit": payload_identity.commit,
            },
        )
    ui_inputs, ui_requirements = _load_ui_registry(paths)
    checks: list[str] = []
    surfaces: list[str] = []
    suite_set: set[str] = set()
    physical_gates: list[str] = []
    reasons: dict[str, list[str]] = {}
    unmapped: list[str] = []
    omitted: list[str] = []
    ui_changed_paths: list[str] = []
    suite_paths: dict[str, set[str]] = {suite: set() for suite in CANONICAL_SUITE_ORDER}
    smallest_real_suite_required = False

    def reason(target: str, value: str) -> None:
        reasons.setdefault(target, [])
        if value not in reasons[target]:
            reasons[target].append(value)

    for changed in selected_paths:
        if any(_matches(changed, pattern) for pattern in mapping.generated_paths):
            omitted.append(changed)
            reason("vm-omitted", f"generated file: {changed}")
            continue
        if PurePosixPath(changed).name in SPECIAL_METADATA_NAMES:
            omitted.append(changed)
            reason("vm-omitted", f"instruction or documentation file: {changed}")
            continue
        matched_surfaces = ui_inputs.get(changed, ())
        if matched_surfaces:
            ui_changed_paths.append(changed)
            _append_unique(checks, "scripts/check-ui-concept-coverage")
            _append_unique(physical_gates, "internal-external-display-review")
            reason(
                "internal-external-display-review",
                f"registered visible implementation changed: {changed}",
            )
            for surface in matched_surfaces:
                _append_unique(surfaces, surface)
                reason(surface, f"registered implementation changed: {changed}")
                if surface == "auth":
                    _append_unique(
                        physical_gates, "fingerprint-enrollment-authentication"
                    )
                    reason(
                        "fingerprint-enrollment-authentication",
                        f"auth surface implementation changed: {changed}",
                    )
                    suite_set.add("login")
                    reason("login", f"auth surface implementation changed: {changed}")
                else:
                    suite_set.add("desktop")
                    reason(
                        "desktop",
                        f"{surface} surface implementation changed: {changed}",
                    )
                suite_set.add("ui-review")
                reason("ui-review", f"{surface} surface implementation changed")

        # UI registration adds visual evidence, but it must not suppress the
        # convergence, restart, security, or physical-gate rules for the same
        # implementation path.
        matched_rule = bool(matched_surfaces)
        for rule in mapping.rules:
            if not any(_matches(changed, pattern) for pattern in rule.paths):
                continue
            matched_rule = True
            smallest_real_suite_required |= rule.smallest_real_suite_required
            for check in rule.focused_checks:
                _append_unique(checks, check)
                reason(check, f"rule {rule.identifier}: {changed}")
            for suite in rule.checkpoint_suites:
                suite_set.add(suite)
                reason(suite, f"rule {rule.identifier}: {changed}")
            for gate in rule.physical_gates:
                _append_unique(physical_gates, gate)
                reason(gate, f"rule {rule.identifier}: {changed}")
        if matched_rule:
            continue
        if any(_matches(changed, pattern) for pattern in mapping.metadata_paths):
            omitted.append(changed)
            reason("vm-omitted", f"non-runtime metadata: {changed}")
            continue
        if any(_matches(changed, pattern) for pattern in mapping.runtime_paths):
            unmapped.append(changed)
        else:
            omitted.append(changed)
            reason("vm-omitted", f"outside managed runtime: {changed}")

    if unmapped:
        raise VMError(
            FailureCategory.UNMAPPED_RUNTIME_PATH,
            "UNMAPPED_RUNTIME_PATH",
            {
                "paths": sorted(unmapped),
                "map": str(paths.repository / "tests" / "verification-map.yaml"),
            },
        )

    # Retry identity follows the complete current dependency state, not only
    # this invocation's diff. A clean tree therefore keeps meaningful suite
    # digests when its comparison base advances instead of collapsing every
    # lane to SHA-256(empty).
    for dependency in payload_identity.files:
        if any(_matches(dependency, pattern) for pattern in mapping.generated_paths):
            continue
        matched_surfaces = ui_inputs.get(dependency, ())
        if matched_surfaces:
            suite_paths["ui-review"].add(dependency)
            for surface in matched_surfaces:
                suite_paths["login" if surface == "auth" else "desktop"].add(dependency)
        for rule in mapping.rules:
            if any(_matches(dependency, pattern) for pattern in rule.paths):
                for suite in rule.retry_suites:
                    suite_paths[suite].add(dependency)

    suite_retry_digests: dict[str, str] = {}
    for suite in CANONICAL_SUITE_ORDER:
        _, retry_digest = worktree_digest(
            paths.repository,
            tuple(sorted(suite_paths[suite])),
            excluded_patterns=mapping.generated_paths,
            include_source_commit=False,
        )
        suite_retry_digests[suite] = retry_digest

    ordered_surfaces = tuple(sorted(surfaces))
    locales: tuple[str, ...] = ()
    scales: tuple[float, ...] = ()
    if ordered_surfaces:
        all_locales = tuple(
            sorted(
                {
                    str(locale)
                    for surface in ordered_surfaces
                    for locale in ui_requirements[surface]["locales"]
                }
            )
        )
        all_scales = tuple(
            sorted(
                {
                    float(scale)
                    for surface in ordered_surfaces
                    for scale in ui_requirements[surface]["scales"]
                }
            )
        )
        if mode == "dev":
            translation_changed = any("/i18n/" in path for path in ui_changed_paths)
            layout_changed = any(
                PurePosixPath(path).suffix.lower()
                in {".c", ".cc", ".cpp", ".css", ".h", ".hpp", ".j2", ".qml"}
                or "layout" in PurePosixPath(path).name.lower()
                for path in ui_changed_paths
                if "/i18n/" not in path
            )
            locales = all_locales if translation_changed else ("en_US.UTF-8",)
            scales = all_scales if layout_changed else (1.0,)
        else:
            locales = all_locales
            scales = all_scales

    suites = tuple(suite for suite in CANONICAL_SUITE_ORDER if suite in suite_set)
    if "make validate" in checks and "make vm-unit" in checks:
        checks.remove("make vm-unit")
        reasons.pop("make vm-unit", None)
        reason("make validate", "make validate includes the VM runner unit suite")
    vm_omitted_reason: str | None = None
    if not suites:
        if not selected_paths:
            vm_omitted_reason = "no changed paths"
        elif omitted:
            vm_omitted_reason = (
                "only documentation, metadata, generated, or T0-only paths changed"
            )
        else:
            vm_omitted_reason = "no VM suite selected"
    return VerificationSelection(
        mode=mode,
        base=base_ref,
        source_commit=source_commit,
        worktree_digest=digest,
        source_tree_digest=payload_identity.tree_hash,
        suite_retry_digests=suite_retry_digests,
        changed_paths=selected_paths,
        focused_checks=tuple(checks),
        surfaces=ordered_surfaces,
        suites=suites,
        physical_gates=tuple(physical_gates),
        locales=locales,
        scales=scales,
        reasons={key: tuple(values) for key, values in reasons.items()},
        authoritative=mode_definition.authoritative,
        fresh_overlay_required=mode_definition.fresh_overlay_required,
        smallest_real_suite_required=smallest_real_suite_required,
        vm_omitted_reason=vm_omitted_reason,
    )


def assert_selection_unchanged(
    selection: VerificationSelection, paths: RuntimePaths | None = None
) -> None:
    paths = paths or RuntimePaths.discover()
    mapping = load_verification_map(paths)
    current_paths = collect_changed_paths(paths.repository, selection.base)
    source_commit, digest = worktree_digest(
        paths.repository,
        current_paths,
        excluded_patterns=mapping.generated_paths,
    )
    payload_identity = source_identity(paths.repository)
    if (
        current_paths != selection.changed_paths
        or source_commit != selection.source_commit
        or digest != selection.worktree_digest
        or payload_identity.commit != selection.source_commit
        or payload_identity.tree_hash != selection.source_tree_digest
    ):
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            "worktree changed after verification plan creation",
            {
                "expectedPaths": list(selection.changed_paths),
                "actualPaths": list(current_paths),
                "expectedCommit": selection.source_commit,
                "actualCommit": source_commit,
                "expectedDigest": selection.worktree_digest,
                "actualDigest": digest,
                "expectedSourceTreeDigest": selection.source_tree_digest,
                "actualSourceTreeDigest": payload_identity.tree_hash,
            },
        )


def run_focused_checks(
    selection: VerificationSelection,
    paths: RuntimePaths | None = None,
) -> dict[str, object]:
    paths = paths or RuntimePaths.discover()
    outcomes: list[dict[str, object]] = []
    artifact_root: Path | None = None
    if selection.focused_checks:
        artifact_root = paths.state / "checks" / f"check-{uuid.uuid4().hex[:12]}"
        artifact_root.mkdir(mode=0o700, parents=True, exist_ok=False)
    for index, command in enumerate(selection.focused_checks, start=1):
        argv = shlex.split(command)
        if not argv:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "verification map contains an empty focused check",
            )
        assert artifact_root is not None
        stdout_path = artifact_root / f"{index:02d}-stdout.log"
        stderr_path = artifact_root / f"{index:02d}-stderr.log"
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            started = subprocess.run(
                argv,
                cwd=paths.repository,
                check=False,
                stdout=stdout,
                stderr=stderr,
            )
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        outcome = {
            "command": command,
            "exitCode": started.returncode,
            "stdoutArtifact": str(stdout_path),
            "stderrArtifact": str(stderr_path),
        }
        outcomes.append(outcome)
        if started.returncode:
            raise VMError(
                FailureCategory.VALIDATION_FAILED,
                f"affected focused check failed: {command}",
                {"checks": outcomes},
            )
    return {
        "result": "passed",
        "mode": selection.mode,
        "checks": outcomes,
        "worktreeDigest": selection.worktree_digest,
        "artifactRoot": str(artifact_root) if artifact_root else None,
    }
