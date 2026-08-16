from __future__ import annotations

import hashlib
import os
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import pytest

import enoshima_vm.impact as impact_module
from enoshima_vm.config import RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.impact import (
    CANONICAL_SUITE_ORDER,
    collect_changed_paths,
    load_verification_map,
    run_focused_checks,
    select_verification,
    worktree_digest,
)


def _git(repository: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _write(repository: Path, relative: str, value: str) -> None:
    path = repository / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def test_collect_changed_paths_covers_every_git_change_area(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    _git(repository, "init", "--initial-branch=main")
    _git(repository, "config", "user.name", "Enoshima Test")
    _git(repository, "config", "user.email", "enoshima@example.invalid")

    for name in (
        "committed.txt",
        "staged.txt",
        "unstaged.txt",
        "rename-source.txt",
        "deleted.txt",
    ):
        _write(repository, name, "base\n")
    _git(repository, "add", ".")
    _git(repository, "commit", "-m", "base")
    base = _git(repository, "rev-parse", "HEAD")

    _write(repository, "committed.txt", "committed after base\n")
    _git(repository, "add", "committed.txt")
    _git(repository, "commit", "-m", "committed change")

    _write(repository, "staged.txt", "staged change\n")
    _git(repository, "add", "staged.txt")
    _write(repository, "unstaged.txt", "unstaged change\n")
    _write(repository, "untracked.txt", "untracked change\n")
    _git(repository, "mv", "rename-source.txt", "rename-destination.txt")
    _git(repository, "rm", "deleted.txt")

    assert collect_changed_paths(repository, base) == (
        "committed.txt",
        "deleted.txt",
        "rename-destination.txt",
        "rename-source.txt",
        "staged.txt",
        "unstaged.txt",
        "untracked.txt",
    )


def test_worktree_digest_includes_executable_mode(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    _git(repository, "init", "--initial-branch=main")
    _git(repository, "config", "user.name", "Enoshima Test")
    _git(repository, "config", "user.email", "enoshima@example.invalid")
    _write(repository, "scripts/helper", "#!/bin/sh\n")
    _git(repository, "add", ".")
    _git(repository, "commit", "-m", "base")

    before = worktree_digest(repository, ("scripts/helper",))[1]
    (repository / "scripts/helper").chmod(0o755)
    after = worktree_digest(repository, ("scripts/helper",))[1]

    assert before != after


def test_single_star_does_not_cross_path_segments() -> None:
    nested = select_verification(
        changed_paths=("tests/vm/scripts/fixture.sh",),
    )
    root = select_verification(changed_paths=("tests/fixture.sh",))

    assert nested.focused_checks == ("make vm-unit",)
    assert root.focused_checks == ("make validate",)


def test_validate_dedupe_contract_matches_the_canonical_entrypoint() -> None:
    repository = RuntimePaths.discover().repository
    source = (repository / "scripts" / "validate.sh").read_text(encoding="utf-8")

    assert '"$repo_root/scripts/check-ui-concept-coverage"' in source
    assert "tests/test-login-manager.sh" in source
    assert "tests/test-ui-evidence-gate.sh" in source
    assert "uv run --locked --project tests/vm pytest" in source
    assert "uv run --locked --project tests/vm ruff check" in source


def test_selector_reverse_maps_ui_implementation_to_surface() -> None:
    selection = select_verification(
        mode="checkpoint",
        changed_paths=("home/dot_config/quickshell/cyberdock/CyberLauncher.qml",),
    )

    assert selection.surfaces == ("launcher",)
    assert selection.suites == ("desktop", "ui-review")
    assert selection.focused_checks == ("make validate",)
    assert any(
        "scripts/check-ui-concept-coverage" in reason
        for reason in selection.reasons["make validate"]
    )
    assert selection.locales == ("en_US.UTF-8", "ko_KR.UTF-8")
    assert selection.scales == (1.0, 1.25, 2.0)


def test_ui_mapping_preserves_non_ui_suite_rules() -> None:
    selection = select_verification(
        changed_paths=("packages/local/enoshima-greeter/enoshima-greeter.c",),
    )

    assert selection.surfaces == ("auth",)
    assert selection.suites == ("converge", "login", "ui-review")


def test_display_driver_preserves_physical_hardware_gates() -> None:
    selection = select_verification(
        changed_paths=("home/dot_local/bin/executable_workspace-output-route",),
    )

    assert selection.suites == ("desktop",)
    assert selection.physical_gates == (
        "internal-oled-edid-refresh-rate",
        "external-display-dock",
    )


@pytest.mark.parametrize(
    ("changed_path", "gate"),
    [
        (
            "home/dot_config/hypr/hyprland.lua",
            "desktop-capture-recording",
        ),
        (
            "home/dot_config/xdg-desktop-portal/hyprland-portals.conf",
            "desktop-capture-recording",
        ),
        (
            "home/dot_config/quickshell/cyberdock/shell.qml",
            "accessibility-screen-reader",
        ),
        (
            "home/dot_config/vicinae/settings.json",
            "command-palette-staged-rollout",
        ),
        (
            "home/dot_config/hyprshell/config.ron",
            "overview-keyboard-mixed-dpi",
        ),
        (
            "ansible/roles/system/tasks/observability.yml",
            "performance-observability-history-overhead",
        ),
    ],
)
def test_desktop_essentials_preserve_new_physical_gates(
    changed_path: str,
    gate: str,
) -> None:
    assert gate in select_verification(changed_paths=(changed_path,)).physical_gates


@pytest.mark.parametrize(
    ("changed_path", "expected_gates"),
    [
        (
            "packages/native.txt",
            (
                "desktop-capture-recording",
                "performance-observability-history-overhead",
            ),
        ),
        (
            "docs/DESKTOP-EXPANSION-OPERATIONS.md",
            (
                "desktop-capture-recording",
                "command-palette-staged-rollout",
                "overview-keyboard-mixed-dpi",
            ),
        ),
        (
            "ansible/roles/desktop_expansion/tasks/main.yml",
            ("command-palette-staged-rollout",),
        ),
        (
            "bootstrap.sh",
            (
                "command-palette-staged-rollout",
                "overview-keyboard-mixed-dpi",
            ),
        ),
        (
            "home/dot_config/mimeapps.list",
            ("command-palette-staged-rollout",),
        ),
        (
            "scripts/install-local-packages.sh",
            (
                "command-palette-staged-rollout",
                "overview-keyboard-mixed-dpi",
            ),
        ),
        (
            "packages/local/hyprshell-bin/overview-direct-input.patch",
            ("overview-keyboard-mixed-dpi",),
        ),
        (
            "scripts/check-hyprshell-provenance",
            ("overview-keyboard-mixed-dpi",),
        ),
        (
            "ansible/roles/system/tasks/main.yml",
            ("performance-observability-history-overhead",),
        ),
        (
            "ansible/roles/system/handlers/main.yml",
            ("performance-observability-history-overhead",),
        ),
    ],
)
def test_desktop_essential_production_paths_preserve_physical_gates(
    changed_path: str,
    expected_gates: tuple[str, ...],
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert set(expected_gates) <= set(selection.physical_gates)


@pytest.mark.parametrize(
    "changed_path",
    [
        "docs/concepts/command-palette.yaml",
        "docs/assets/concepts/command-palette/command-palette-v1.png",
        "docs/evidence/auth/review.json",
    ],
)
def test_ui_contract_artifacts_require_ui_review(changed_path: str) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert selection.suites == ("ui-review",)
    assert selection.focused_checks == (
        "scripts/check-ui-concept-coverage",
        "tests/test-ui-evidence-gate.sh",
        "make vm-unit",
    )
    assert selection.smallest_real_suite_required is True
    assert selection.vm_omitted_reason is None


def test_codex_mcp_configuration_is_verification_workflow() -> None:
    selection = select_verification(changed_paths=(".codex/config.toml",))

    assert selection.focused_checks == ("make vm-unit",)
    assert selection.suites == ("smoke",)
    assert selection.smallest_real_suite_required is True


def test_vm_unit_tests_select_smoke_without_resetting_runtime_failures() -> None:
    selection = select_verification(
        changed_paths=("tests/vm/unit/test_orchestration.py",)
    )
    mapping = load_verification_map()
    rule = next(rule for rule in mapping.rules if rule.identifier == "vm-harness-tests")

    assert selection.focused_checks == ("make vm-unit",)
    assert selection.suites == ("smoke",)
    assert rule.retry_suites == ()


def test_suite_retry_digest_is_a_full_dependency_snapshot_not_a_diff() -> None:
    smoke_only = select_verification(
        changed_paths=("tests/vm/src/enoshima_vm/service.py",),
    )
    with_metadata = select_verification(
        changed_paths=(
            "README.md",
            "tests/vm/src/enoshima_vm/service.py",
        ),
    )
    with_another_runtime_diff = select_verification(
        changed_paths=(
            "ansible/roles/system/files/enoshima-rebuild-uki",
            "tests/vm/src/enoshima_vm/service.py",
        ),
    )

    assert smoke_only.worktree_digest != with_metadata.worktree_digest
    assert (
        smoke_only.suite_retry_digests["smoke"]
        == with_metadata.suite_retry_digests["smoke"]
    )
    assert (
        smoke_only.suite_retry_digests == with_another_runtime_diff.suite_retry_digests
    )
    empty_digest = hashlib.sha256().hexdigest()
    assert all(
        digest != empty_digest for digest in smoke_only.suite_retry_digests.values()
    )


def test_repository_test_diff_does_not_unfreeze_later_desktop_failure() -> None:
    desktop = "home/dot_config/quickshell/cyberdock/CyberLauncher.qml"
    ui_only = select_verification(changed_paths=(desktop,))
    with_host_test = select_verification(changed_paths=(desktop, "tests/test-vm-ci.sh"))

    assert (
        ui_only.suite_retry_digests["desktop"]
        == with_host_test.suite_retry_digests["desktop"]
    )


@pytest.mark.parametrize(
    "changed_path",
    [
        "tests/vm/src/enoshima_vm/service.py",
        "bootstrap.sh",
        "scripts/validate.sh",
    ],
)
def test_shared_runner_inputs_change_every_suite_retry_digest(
    changed_path: str,
) -> None:
    selection = select_verification(changed_paths=(changed_path,))
    empty_digest = hashlib.sha256().hexdigest()

    assert all(
        selection.suite_retry_digests[suite] != empty_digest
        for suite in CANONICAL_SUITE_ORDER
    )


@pytest.mark.parametrize(
    ("changed_path", "suite", "gate"),
    [
        (
            "ansible/roles/system/templates/crypttab.initramfs.j2",
            "boot-security",
            "tpm-unlock-recovery",
        ),
        (
            "ansible/roles/system/templates/logind-lid.conf.j2",
            "reboot",
            "suspend-resume",
        ),
        (
            "ansible/roles/system/tasks/network.yml",
            "converge",
            "wwan-connectivity-shutdown",
        ),
        (
            "packages/local/enoshima-greeter/enoshima-greeter.c",
            "login",
            "fingerprint-enrollment-authentication",
        ),
        (
            "ansible/roles/system/tasks/authentication.yml",
            "login",
            "fingerprint-enrollment-authentication",
        ),
        (
            "home/dot_config/quickshell/cyberdock/CyberLauncher.qml",
            "ui-review",
            "internal-external-display-review",
        ),
        (
            "home/dot_config/enoshima/defaults/display.json",
            "desktop",
            "external-display-dock",
        ),
        (
            "home/dot_config/hypr/hypridle.conf",
            "reboot",
            "post-resume-thermal",
        ),
    ],
)
def test_selector_preserves_special_suite_and_t5_contracts(
    changed_path: str, suite: str, gate: str
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert suite in selection.suites
    assert gate in selection.physical_gates


@pytest.mark.parametrize(
    "changed_path",
    [
        "ansible/inventory/group_vars/all.yml",
        "ansible/inventory/host_vars/tpx1c13.yml",
    ],
)
def test_physical_inventory_selects_every_owned_lane_and_gate(
    changed_path: str,
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert selection.suites == (
        "converge",
        "reboot",
        "desktop",
        "login",
        "ui-review",
        "boot-security",
    )
    assert selection.physical_gates == (
        "accessibility-screen-reader",
        "suspend-resume",
        "sleep-battery-drain",
        "post-resume-thermal",
        "internal-oled-edid-refresh-rate",
        "external-display-dock",
        "internal-external-display-review",
        "desktop-capture-recording",
        "command-palette-staged-rollout",
        "overview-keyboard-mixed-dpi",
        "performance-observability-history-overhead",
        "fingerprint-enrollment-authentication",
        "secure-boot-enrollment",
        "tpm-unlock-recovery",
        "wwan-connectivity-shutdown",
    )


def test_kernel_cmdline_preserves_boot_and_resume_contracts() -> None:
    selection = select_verification(
        changed_paths=("ansible/roles/system/templates/kernel-cmdline.j2",)
    )

    assert "reboot" in selection.suites
    assert "boot-security" in selection.suites
    assert "suspend-resume" in selection.physical_gates
    assert "tpm-unlock-recovery" in selection.physical_gates


def test_modemmanager_timeout_preserves_wwan_gate() -> None:
    selection = select_verification(
        changed_paths=(
            "ansible/roles/system/templates/modemmanager-stop-timeout.conf.j2",
        )
    )

    assert "converge" in selection.suites
    assert "wwan-connectivity-shutdown" in selection.physical_gates


@pytest.mark.parametrize(
    "changed_path",
    [
        "ansible/roles/system/handlers/main.yml",
        "ansible/roles/system/tasks/main.yml",
        "packages/native.txt",
    ],
)
def test_cross_cutting_policy_preserves_behavioral_and_hardware_contracts(
    changed_path: str,
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert selection.suites == (
        "converge",
        "reboot",
        "desktop",
        "login",
        "boot-security",
    )
    assert "suspend-resume" in selection.physical_gates
    assert "fingerprint-enrollment-authentication" in selection.physical_gates
    assert "tpm-unlock-recovery" in selection.physical_gates
    assert "wwan-connectivity-shutdown" in selection.physical_gates


@pytest.mark.parametrize(
    "changed_path",
    [
        "ansible/roles/system/templates/sddm-hidpi.conf.j2",
        "ansible/roles/system/tasks/desktop.yml",
        "ansible/roles/desktop_expansion/tasks/sddm.yml",
        "ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml",
    ],
)
def test_sddm_fallback_preserves_login_visual_and_hardware_contracts(
    changed_path: str,
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert "login" in selection.suites
    assert "ui-review" in selection.suites
    assert "internal-external-display-review" in selection.physical_gates
    assert "external-display-dock" in selection.physical_gates
    assert "fingerprint-enrollment-authentication" in selection.physical_gates
    assert {
        "desktop-capture-recording",
        "command-palette-staged-rollout",
        "overview-keyboard-mixed-dpi",
        "performance-observability-history-overhead",
    }.isdisjoint(selection.physical_gates)


@pytest.mark.parametrize(
    "changed_path", [".codex/agents/enoshima-triage.toml", ".gitignore"]
)
def test_codex_and_ignore_policy_changes_receive_focused_verification(
    changed_path: str,
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert selection.focused_checks == ("make vm-unit",)
    assert selection.suites == ("smoke",)


@pytest.mark.parametrize(
    ("changed_path", "reason_fragment"),
    [
        ("docs/notes/verification-speed.md", "non-runtime metadata"),
        (
            "tests/vm/unit/__pycache__/test_impact.cpython-313.pyc",
            "generated file",
        ),
    ],
)
def test_selector_omits_documentation_and_generated_files(
    changed_path: str, reason_fragment: str
) -> None:
    selection = select_verification(changed_paths=(changed_path,))

    assert selection.suites == ()
    assert selection.vm_omitted_reason is not None
    assert any(reason_fragment in reason for reason in selection.reasons["vm-omitted"])


def test_selector_fails_closed_for_unmapped_runtime_path() -> None:
    with pytest.raises(VMError) as raised:
        select_verification(changed_paths=("scripts/new-runtime-helper",))

    assert raised.value.category is FailureCategory.UNMAPPED_RUNTIME_PATH
    assert raised.value.message == "UNMAPPED_RUNTIME_PATH"
    assert raised.value.details == {
        "paths": ["scripts/new-runtime-helper"],
        "map": str(
            RuntimePaths.discover().repository / "tests" / "verification-map.yaml"
        ),
    }


def test_every_tracked_runtime_path_is_mapped() -> None:
    repository = RuntimePaths.discover().repository
    tracked_paths = tuple(
        subprocess.run(
            ["git", "-C", str(repository), "ls-files"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
    )

    selection = select_verification(changed_paths=tracked_paths)

    assert selection.suites == CANONICAL_SUITE_ORDER


def test_selector_returns_suites_in_canonical_order() -> None:
    selection = select_verification(
        changed_paths=(
            "tests/vm/boot/fixture.py",
            "packages/local/enoshima-greeter/src/fixture.py",
            "home/dot_local/bin/executable_desktop-power",
            "home/dot_config/quickshell/cyberdock/CyberLauncher.qml",
            "scripts/postflight.sh",
        )
    )

    assert selection.suites == CANONICAL_SUITE_ORDER


@pytest.mark.parametrize(
    ("changed_paths", "expected_locales", "expected_scales"),
    [
        (
            ("home/dot_config/enoshima/i18n/ko-KR.json",),
            ("en_US.UTF-8", "ko_KR.UTF-8"),
            (1.0,),
        ),
        (
            ("home/dot_config/quickshell/cyberdock/CyberLauncher.qml",),
            ("en_US.UTF-8",),
            (1.0, 1.25, 2.0),
        ),
    ],
)
def test_dev_ui_scope_expands_only_changed_locale_or_layout_dimensions(
    changed_paths: tuple[str, ...],
    expected_locales: tuple[str, ...],
    expected_scales: tuple[float, ...],
) -> None:
    selection = select_verification(mode="dev", changed_paths=changed_paths)

    assert selection.locales == expected_locales
    assert selection.scales == expected_scales
    assert selection.authoritative is False
    assert selection.fresh_overlay_required is False


def test_focused_checks_store_raw_output_in_artifacts(tmp_path: Path) -> None:
    discovered = RuntimePaths.discover()
    paths = RuntimePaths(
        discovered.repository,
        discovered.project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    selection = replace(
        select_verification(changed_paths=("README.md",)),
        focused_checks=("sh -c 'printf focused-stdout; printf focused-stderr >&2'",),
    )

    result = run_focused_checks(selection, paths)

    check = result["checks"][0]
    assert Path(check["stdoutArtifact"]).read_text() == "focused-stdout"
    assert Path(check["stderrArtifact"]).read_text() == "focused-stderr"


def test_focused_checks_do_not_export_the_payload_lock_descriptor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    discovered = RuntimePaths.discover()
    paths = RuntimePaths(
        discovered.repository,
        discovered.project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    selection = replace(
        select_verification(changed_paths=("README.md",)),
        focused_checks=("sh -c 'test -z \"${ENOSHIMA_VM_OPERATION_LOCK_FD-}\"'",),
    )
    monkeypatch.setenv("ENOSHIMA_VM_OPERATION_LOCK_FD", "123")

    result = run_focused_checks(selection, paths)

    assert result["result"] == "passed"
    assert result["checks"][0]["exitCode"] == 0


def test_focused_check_idle_deadline_kills_descendants_and_keeps_artifacts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    discovered = RuntimePaths.discover()
    paths = RuntimePaths(
        discovered.repository,
        discovered.project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    child_pid_path = tmp_path / "focused-child.pid"
    script = (
        "import pathlib,subprocess,sys,time; "
        "print('focused-started', flush=True); "
        "child=subprocess.Popen([sys.executable,'-c',"
        "'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN);'"
        "'time.sleep(30)']); "
        f"pathlib.Path({str(child_pid_path)!r}).write_text(str(child.pid)); "
        "time.sleep(30)"
    )
    command = f"{shlex.quote(sys.executable)} -c {shlex.quote(script)}"
    selection = replace(
        select_verification(changed_paths=("README.md",)),
        focused_checks=(command,),
    )
    monkeypatch.setattr(impact_module, "FOCUSED_CHECK_TIMEOUT_SECONDS", 2)
    monkeypatch.setattr(impact_module, "FOCUSED_CHECK_IDLE_TIMEOUT_SECONDS", 0.3)

    with pytest.raises(VMError) as raised:
        run_focused_checks(selection, paths)

    checks = raised.value.details["checks"]
    assert checks[0]["timeoutKind"] == "idle"
    assert Path(checks[0]["stdoutArtifact"]).read_text() == "focused-started\n"
    child_pid = int(child_pid_path.read_text(encoding="utf-8"))
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        stat_path = Path(f"/proc/{child_pid}/stat")
        if not stat_path.is_file() or stat_path.read_text().split()[2] == "Z":
            break
        time.sleep(0.01)
    else:
        os.kill(child_pid, signal.SIGKILL)
        pytest.fail("focused-check deadline left its descendant alive")
