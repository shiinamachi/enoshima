from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from enoshima_vm.config import MAX_ACTIVE_DOMAINS, RuntimePaths
from enoshima_vm.errors import FailureCategory, VMError
from enoshima_vm.impact import VerificationSelection
from enoshima_vm.results import failure_fingerprint
from enoshima_vm.service import VMService
from enoshima_vm.source import SourceIdentity
from enoshima_vm.verification import VerificationPlanDefinition


def selection(
    *,
    mode: str = "checkpoint",
    suites: tuple[str, ...] = ("smoke",),
) -> VerificationSelection:
    return VerificationSelection(
        mode=mode,
        base="origin/main",
        source_commit="a" * 40,
        worktree_digest="b" * 64,
        source_tree_digest="d" * 64,
        suite_retry_digests={suite: "c" * 64 for suite in suites},
        changed_paths=("tests/vm/src/enoshima_vm/service.py",),
        focused_checks=("make vm-unit",),
        surfaces=(),
        suites=suites,
        physical_gates=(),
        locales=(),
        scales=(),
        reasons={},
        authoritative=mode != "dev",
        fresh_overlay_required=mode != "dev",
        smallest_real_suite_required=True,
        vm_omitted_reason=None,
    )


def service_with_temporary_state(tmp_path: Path) -> VMService:
    discovered = RuntimePaths.discover()
    paths = RuntimePaths(
        discovered.repository,
        discovered.project,
        tmp_path / "cache",
        tmp_path / "state",
    )
    return VMService(paths)


def failed_record(origin: str, fingerprint: str, index: int) -> dict[str, object]:
    return {
        "run_id": f"run-{index:012x}",
        "suite": "smoke",
        "verification_mode": "checkpoint",
        "result": "failed",
        "authoritative": True,
        "fresh_overlay": True,
        "planned_source_commit": "a" * 40,
        "planned_worktree_digest": "b" * 64,
        "planned_source_tree_digest": "d" * 64,
        "planned_retry_digest": "c" * 64,
        "current_step": "run_validate",
        "steps": [
            {"action": "run_validate", "status": "failed", "duration_seconds": 1}
        ],
        "category": "SSH_TIMEOUT" if origin == "INFRA" else "VALIDATION_FAILED",
        "failure_origin": origin,
        "failure_fingerprint": fingerprint,
        "artifact_dir": f"/artifacts/{index}",
        "error": "fixture failure",
    }


def capacity_failure_record(index: int) -> dict[str, object]:
    message = "maximum active Enoshima VM count reached"
    record = failed_record(
        "INFRA",
        failure_fingerprint(
            suite="smoke",
            step="vm_create",
            category=FailureCategory.HOST_INFRA_ERROR,
            message=message,
        ),
        index,
    )
    record.update(
        {
            "current_step": "vm_create",
            "category": str(FailureCategory.HOST_INFRA_ERROR),
            "error": f"{FailureCategory.HOST_INFRA_ERROR}: {message}",
        }
    )
    return record


def persist_record(
    service: VMService,
    record: dict[str, object],
    tmp_path: Path,
) -> dict[str, Any]:
    persisted: dict[str, Any] = dict(record)
    run_id = str(persisted["run_id"])
    persisted.update(
        {
            "schema": 1,
            "domain": f"enoshima-test-{run_id}",
            "status": persisted.get("status", persisted.get("result", "failed")),
            "created_at": "2026-08-05T00:00:00+00:00",
            "updated_at": "2026-08-05T00:00:00+00:00",
            "artifact_dir": str(tmp_path / "state" / "runs" / run_id / "artifacts"),
            "synthetic": True,
        }
    )
    service._write_record(persisted)
    return persisted


def test_same_infra_fingerprint_runs_once_then_retries_and_blocks(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    history: list[dict[str, object]] = []
    fingerprint = "sha256:" + "c" * 64
    calls = 0

    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: list(history),
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        record = failed_record("INFRA", fingerprint, calls)
        history.append(record)
        return record

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert calls == 2
    assert result["result"] == "blocked"
    assert len(result["attempts"]) == 2
    assert result["failure"]["category"] == "VM_BLOCKED"


def test_keep_on_failure_releases_intermediate_retry_domain(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    history: list[dict[str, object]] = []
    destroyed: list[str] = []
    fingerprint = "sha256:" + "a" * 64
    calls = 0

    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: list(history),
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        record = failed_record("INFRA", fingerprint, calls)
        history.append(record)
        return record

    monkeypatch.setattr(service, "run_suite", run_suite)
    monkeypatch.setattr(
        service,
        "destroy",
        lambda run_id: destroyed.append(run_id) or {"run_id": run_id},
    )

    result = service._run_suite_with_retry_budget(
        "smoke", selection(), keep_on_failure=True
    )

    assert calls == 2
    assert destroyed == ["run-000000000001"]
    assert result["result"] == "blocked"


def test_product_failure_is_not_retried(tmp_path: Path, monkeypatch) -> None:
    service = service_with_temporary_state(tmp_path)
    calls = 0
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: [],
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return failed_record("PRODUCT", "sha256:" + "d" * 64, calls)

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert calls == 1
    assert result["result"] == "failed"


def test_vm_create_infra_exception_receives_one_fresh_retry(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    calls = 0
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: [],
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise VMError(FailureCategory.SSH_TIMEOUT, "preflight SSH failed")

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert calls == 2
    assert result["result"] == "blocked"
    assert result["failure"]["failureOrigin"] == "INFRA"


def test_direct_suite_result_returns_bounded_create_failure(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    monkeypatch.setattr(
        "enoshima_vm.service.run_focused_checks",
        lambda *_args, **_kwargs: {"result": "passed", "checks": []},
    )
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "run_suite",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            VMError(FailureCategory.IMAGE_ERROR, "checksum mismatch for image")
        ),
    )

    result = service.run_suite_result("smoke", verification_mode="checkpoint")

    assert result["result"] == "failed"
    assert result["category"] == "IMAGE_ERROR"
    assert result["failureOrigin"] == "INFRA"
    assert result["failedStep"] == "vm_create"


def test_unchanged_product_failure_blocks_before_vm_creation(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    prior = failed_record("PRODUCT", "sha256:" + "e" * 64, 1)
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: [prior],
    )
    monkeypatch.setattr(
        service,
        "run_suite",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("VM must not be created")
        ),
    )

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert result["result"] == "blocked"
    assert result["attempts"] == []


def test_exhausted_infra_history_blocks_before_vm_creation(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    fingerprint = "sha256:" + "f" * 64
    prior = [failed_record("INFRA", fingerprint, index) for index in (1, 2)]
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: prior,
    )
    monkeypatch.setattr(
        service.backend,
        "active_managed_domains",
        lambda: (_ for _ in ()).throw(
            AssertionError("unrelated fingerprints must not probe live capacity")
        ),
    )
    calls = 0

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise AssertionError("VM must not be created")

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert calls == 0
    assert result["result"] == "blocked"
    assert result["attempts"] == []


def test_exhausted_capacity_history_runs_when_capacity_has_cleared(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    prior = [capacity_failure_record(index) for index in (1, 2)]
    calls = 0
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: prior,
    )
    monkeypatch.setattr(service.backend, "active_managed_domains", lambda: [])

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        record = failed_record("PRODUCT", "sha256:" + "a" * 64, 3)
        record.update(
            {
                "result": "passed",
                "status": "completed",
                "category": None,
                "failure_origin": None,
                "failure_fingerprint": None,
            }
        )
        return record

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert calls == 1
    assert result["result"] == "passed"


def test_exhausted_capacity_history_stays_blocked_while_full(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    prior = [capacity_failure_record(index) for index in (1, 2)]
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: prior,
    )
    monkeypatch.setattr(
        service.backend,
        "active_managed_domains",
        lambda: [
            f"enoshima-test-run-{index:012x}" for index in range(MAX_ACTIVE_DOMAINS)
        ],
    )
    monkeypatch.setattr(
        service,
        "run_suite",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("VM must not be created")
        ),
    )

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert result["result"] == "blocked"
    assert result["attempts"] == []


def test_recovered_capacity_does_not_mask_other_exhausted_fingerprint(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    other_fingerprint = "sha256:" + "9" * 64
    prior = [
        capacity_failure_record(1),
        capacity_failure_record(2),
        failed_record("INFRA", other_fingerprint, 3),
        failed_record("INFRA", other_fingerprint, 4),
    ]
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: prior,
    )
    monkeypatch.setattr(service.backend, "active_managed_domains", lambda: [])
    monkeypatch.setattr(
        service,
        "run_suite",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("VM must not be created")
        ),
    )

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert result["result"] == "blocked"
    assert result["attempts"] == []
    assert result["failure"]["failureFingerprint"] == other_fingerprint


def test_synthetic_infra_failures_persist_across_operations(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    calls = 0
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        raise VMError(FailureCategory.HOST_INFRA_ERROR, "libvirt unavailable")

    monkeypatch.setattr(service, "run_suite", run_suite)

    first = service._run_suite_with_retry_budget("smoke", selection())
    second = service._run_suite_with_retry_budget("smoke", selection())

    assert first["result"] == "blocked"
    assert second["result"] == "blocked"
    assert calls == 2
    assert len(service.list_runs()) == 2
    assert all(record.get("synthetic") for record in service.list_runs())


def test_create_failure_before_overlay_has_raw_artifact_and_no_authority(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    monkeypatch.setattr(service, "preflight", lambda *_args, **_kwargs: {})
    monkeypatch.setattr(
        service.images,
        "ensure",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            VMError(FailureCategory.HOST_INFRA_ERROR, "image storage unavailable")
        ),
    )
    monkeypatch.setattr(service.backend, "destroy", lambda *_args: None)

    with pytest.raises(VMError, match="image storage unavailable"):
        service.create("smoke", verification_mode="checkpoint")

    record = service.list_runs()[0]
    assert record["domain_uuid"]
    assert record["fresh_overlay"] is False
    assert record["authoritative"] is False
    assert Path(str(record["create_error_artifact"])).is_file()


def test_preflight_failure_has_raw_artifact_and_retry_record(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    monkeypatch.setattr(
        service,
        "preflight",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            VMError(FailureCategory.HOST_INFRA_ERROR, "KVM is unavailable")
        ),
    )
    monkeypatch.setattr(service.backend, "destroy", lambda *_args: None)

    with pytest.raises(VMError, match="KVM is unavailable"):
        service.create("smoke", verification_mode="checkpoint")

    record = service.list_runs()[0]
    assert record["domain_uuid"]
    assert record["current_step"] == "vm_create"
    assert record["failure_origin"] == "INFRA"
    assert record["fresh_overlay"] is False
    assert record["authoritative"] is False
    assert Path(str(record["create_error_artifact"])).is_file()


def test_dev_failure_cannot_block_authoritative_verification(tmp_path: Path) -> None:
    service = service_with_temporary_state(tmp_path)
    dev_failure = failed_record("PRODUCT", "sha256:" + "6" * 64, 6)
    dev_failure["verification_mode"] = "dev"
    dev_failure["authoritative"] = False
    persist_record(service, dev_failure, tmp_path)

    assert (
        service._prior_unchanged_failures(
            suite="smoke",
            retry_digest="c" * 64,
            source_tree_digest="d" * 64,
            verification_mode="checkpoint",
        )
        == []
    )
    assert (
        len(
            service._prior_unchanged_failures(
                suite="smoke",
                retry_digest="c" * 64,
                source_tree_digest="d" * 64,
                verification_mode="dev",
            )
        )
        == 1
    )


def test_validate_failure_uses_step_scoped_source_identity(tmp_path: Path) -> None:
    service = service_with_temporary_state(tmp_path)
    validate_failure = failed_record("PRODUCT", "sha256:" + "8" * 64, 8)
    persist_record(service, validate_failure, tmp_path)

    assert (
        service._prior_unchanged_failures(
            suite="smoke",
            retry_digest="c" * 64,
            source_tree_digest="e" * 64,
            verification_mode="checkpoint",
        )
        == []
    )

    validate_failure["current_step"] = "run_electron_qualification"
    persist_record(service, validate_failure, tmp_path)
    later_failures = service._prior_unchanged_failures(
        suite="smoke",
        retry_digest="c" * 64,
        source_tree_digest="e" * 64,
        verification_mode="checkpoint",
    )
    assert len(later_failures) == 1


def test_upload_worktree_returns_bounded_identity_and_full_manifest(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    record = persist_record(
        service,
        failed_record("PRODUCT", "sha256:" + "7" * 64, 7),
        tmp_path,
    )
    identity = SourceIdentity(
        commit="a" * 40,
        dirty=True,
        tree_hash="b" * 64,
        files=tuple(f"file-{index}" for index in range(100)),
        untracked_files=tuple(
            f"untracked-{index}-" + "한" * 1000 for index in range(100)
        ),
    )

    class UploadGuest:
        def upload_worktree(self, *_args, **_kwargs):
            return identity

    monkeypatch.setattr(service, "_guest", lambda _record: UploadGuest())

    result = service.upload_worktree(str(record["run_id"]))

    assert len(json.dumps(result, sort_keys=True).encode()) <= 32 * 1024
    assert result["untracked_file_count"] == 100
    assert result["untracked_files_truncated"] is True
    manifest = Path(str(result["manifest_artifact"]))
    assert manifest.is_file()
    manifest_document = json.loads(manifest.read_text(encoding="utf-8"))
    assert len(manifest_document["untrackedFiles"]) == 100


def test_list_runs_is_newest_first(tmp_path: Path) -> None:
    service = service_with_temporary_state(tmp_path)
    older = persist_record(
        service,
        failed_record("PRODUCT", "sha256:" + "4" * 64, 4),
        tmp_path,
    )
    newer = persist_record(
        service,
        failed_record("PRODUCT", "sha256:" + "5" * 64, 5),
        tmp_path,
    )
    older["updated_at"] = "2026-08-05T00:00:00+00:00"
    newer["updated_at"] = "2026-08-06T00:00:00+00:00"
    service._write_record(older)
    service._write_record(newer)

    assert [record["run_id"] for record in service.list_runs()] == [
        newer["run_id"],
        older["run_id"],
    ]


def test_current_create_error_is_not_replaced_by_prior_failure(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    old = persist_record(
        service,
        failed_record("INFRA", "sha256:" + "1" * 64, 1),
        tmp_path,
    )
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "run_suite",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            VMError(FailureCategory.VALIDATION_FAILED, "new product failure")
        ),
    )

    result = service._run_suite_with_retry_budget("smoke", selection())

    assert result["result"] == "failed"
    assert result["attempts"][0]["failureOrigin"] == "PRODUCT"
    assert result["attempts"][0]["failureFingerprint"] != old["failure_fingerprint"]


def test_source_change_invalidates_persisted_authoritative_pass(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    passed = failed_record("PRODUCT", "sha256:" + "2" * 64, 3)
    passed.update(
        {
            "result": "passed",
            "status": "completed",
            "category": None,
            "failure_origin": None,
            "failure_fingerprint": None,
        }
    )
    persisted = persist_record(service, passed, tmp_path)
    checks = iter(
        [
            None,
            VMError(FailureCategory.HARNESS_ERROR, "worktree changed"),
        ]
    )

    def assert_frozen(*_args, **_kwargs):
        outcome = next(checks)
        if isinstance(outcome, BaseException):
            raise outcome

    monkeypatch.setattr("enoshima_vm.service.assert_selection_unchanged", assert_frozen)
    monkeypatch.setattr(service, "run_suite", lambda *_args, **_kwargs: persisted)

    result = service._run_suite_with_retry_budget("smoke", selection())
    invalidated = service.load_record(str(persisted["run_id"]))

    assert result["result"] == "blocked"
    assert invalidated["status"] == "invalidated"
    assert invalidated["result"] == "failed"
    assert invalidated["authoritative"] is False
    assert invalidated["source_invalidated"] is True
    junit = Path(str(invalidated["artifact_dir"])) / "junit.xml"
    junit_text = junit.read_text(encoding="utf-8")
    assert 'failures="0"' not in junit_text
    assert "source_freeze" in junit_text


def test_uploaded_source_mismatch_is_invalidated_and_never_retried(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    mismatch = failed_record("TEST_FIXTURE", "sha256:" + "9" * 64, 9)
    mismatch.update(
        {
            "category": "SOURCE_INVALIDATED",
            "error": "archive payload differs from plan",
            "details": {"expected": "sha256:a", "actual": "sha256:b"},
        }
    )
    persisted = persist_record(service, mismatch, tmp_path)
    calls = 0

    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_prior_unchanged_failures",
        lambda **_kwargs: [],
    )

    def run_suite(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return persisted

    monkeypatch.setattr(service, "run_suite", run_suite)

    result = service._run_suite_with_retry_budget("smoke", selection())
    invalidated = service.load_record(str(persisted["run_id"]))

    assert calls == 1
    assert result["result"] == "blocked"
    assert invalidated["source_invalidated"] is True
    assert invalidated["authoritative"] is False
    assert invalidated["category"] == "SOURCE_INVALIDATED"


def test_low_level_exec_and_desktop_query_keep_raw_artifacts_bounded(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    record = persist_record(
        service,
        failed_record("PRODUCT", "sha256:" + "3" * 64, 4),
        tmp_path,
    )
    run_id = str(record["run_id"])
    monkeypatch.setattr(
        service,
        "exec",
        lambda *_args, **_kwargs: {
            "exit_code": 1,
            "stdout": "\n".join("out" + "x" * 500 for _ in range(200)),
            "stderr": "\n".join("err" + "y" * 500 for _ in range(200)),
            "duration_ms": 100,
        },
    )

    exec_result = service.exec_bounded(run_id, ["false"])

    assert Path(str(exec_result["artifactPath"])).is_file()
    assert len(json.dumps(exec_result).encode()) <= 32 * 1024

    monkeypatch.setattr(
        service,
        "query_desktop",
        lambda *_args, **_kwargs: {
            "monitors": [],
            "workspaces": [],
            "clients": [{"title": "z" * 2000} for _ in range(100)],
            "devices": {},
            "activewindow": {"title": "active"},
            "activeworkspace": {"name": "1"},
        },
    )
    desktop_result = service.query_desktop_bounded(run_id)

    assert desktop_result["truncated"] is True
    assert Path(str(desktop_result["artifactPath"])).is_file()
    assert len(json.dumps(desktop_result).encode()) <= 32 * 1024


def test_release_plan_runs_each_suite_once_in_canonical_order(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    suites = (
        "smoke",
        "converge",
        "reboot",
        "desktop",
        "login",
        "ui-review",
        "boot-security",
    )
    plan = VerificationPlanDefinition("release", "release", suites, True)
    frozen = selection(mode="release", suites=suites)
    calls: list[str] = []

    monkeypatch.setattr(
        "enoshima_vm.service.load_verification_plan", lambda *_args: plan
    )
    monkeypatch.setattr(
        "enoshima_vm.service.select_verification", lambda **_kwargs: frozen
    )
    monkeypatch.setattr(
        "enoshima_vm.service.run_focused_checks",
        lambda *_args, **_kwargs: {
            "result": "passed",
            "checks": [],
            "artifactRoot": "/checks",
        },
    )
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )

    def run_suite(suite: str, _selection: VerificationSelection):
        calls.append(suite)
        return {"suite": suite, "result": "passed", "attempts": []}

    monkeypatch.setattr(service, "_run_suite_with_retry_budget", run_suite)

    result = service.run_plan("release")

    assert calls == list(suites)
    assert result["result"] == "passed"
    assert [entry["suite"] for entry in result["suites"]] == list(suites)
    assert (Path(result["artifactRoot"]) / "plan.json").is_file()


def test_release_plan_runs_focused_checks_before_vm_suites(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    frozen = selection(mode="release", suites=("smoke",))
    plan = VerificationPlanDefinition("release", "release", ("smoke",), True)
    events: list[str] = []

    monkeypatch.setattr(
        "enoshima_vm.service.load_verification_plan", lambda *_args: plan
    )
    monkeypatch.setattr(
        "enoshima_vm.service.select_verification", lambda **_kwargs: frozen
    )
    monkeypatch.setattr(
        "enoshima_vm.service.run_focused_checks",
        lambda *_args, **_kwargs: (
            events.append("focused")
            or {"result": "passed", "checks": [], "artifactRoot": "/checks"}
        ),
    )
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: events.append("freeze"),
    )
    monkeypatch.setattr(
        service,
        "_run_suite_with_retry_budget",
        lambda *_args, **_kwargs: (
            events.append("vm")
            or {"suite": "smoke", "result": "passed", "attempts": []}
        ),
    )

    service.run_plan("release")

    assert events == ["focused", "freeze", "vm"]


def test_release_plan_requires_canonical_visual_evidence(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    frozen = selection(mode="release", suites=("smoke",))
    plan = VerificationPlanDefinition("release", "release", ("smoke",), True)
    observed_checks: list[tuple[str, ...]] = []

    monkeypatch.setattr(
        "enoshima_vm.service.load_verification_plan", lambda *_args: plan
    )
    monkeypatch.setattr(
        "enoshima_vm.service.select_verification", lambda **_kwargs: frozen
    )
    monkeypatch.setattr(
        "enoshima_vm.service.run_focused_checks",
        lambda selected, *_args, **_kwargs: (
            observed_checks.append(selected.focused_checks)
            or {"result": "passed", "checks": [], "artifactRoot": "/checks"}
        ),
    )
    monkeypatch.setattr(
        "enoshima_vm.service.assert_selection_unchanged",
        lambda *_args, **_kwargs: None,
    )
    monkeypatch.setattr(
        service,
        "_run_suite_with_retry_budget",
        lambda suite, _selection: {"suite": suite, "result": "passed", "attempts": []},
    )

    service.run_plan("release")

    assert observed_checks == [
        ("scripts/check-ui-visual-evidence", "make validate")
    ]


def test_release_operation_is_persisted_before_focused_checks(
    tmp_path: Path, monkeypatch
) -> None:
    service = service_with_temporary_state(tmp_path)
    frozen = selection(mode="release", suites=("smoke",))
    plan = VerificationPlanDefinition("release", "release", ("smoke",), True)

    monkeypatch.setattr(
        "enoshima_vm.service.load_verification_plan", lambda *_args: plan
    )
    monkeypatch.setattr(
        "enoshima_vm.service.select_verification", lambda **_kwargs: frozen
    )

    def fail_focused(*_args, **_kwargs):
        plan_paths = list((service.paths.state / "plans").glob("*/plan.json"))
        assert len(plan_paths) == 1
        running = json.loads(plan_paths[0].read_text(encoding="utf-8"))
        assert running["result"] == "running"
        assert running["authoritative"] is False
        check_root = service.paths.state / "checks" / "check-fixture"
        check_root.mkdir(mode=0o700, parents=True)
        stdout = check_root / "01-stdout.log"
        stderr = check_root / "01-stderr.log"
        stdout.write_text("", encoding="utf-8")
        stderr.write_text("failure", encoding="utf-8")
        raise VMError(
            FailureCategory.VALIDATION_FAILED,
            "focused check failed",
            {
                "checks": [
                    {
                        "command": "make validate",
                        "exitCode": 1,
                        "stdoutArtifact": str(stdout),
                        "stderrArtifact": str(stderr),
                    }
                ]
            },
        )

    monkeypatch.setattr("enoshima_vm.service.run_focused_checks", fail_focused)

    with pytest.raises(VMError, match="focused check failed"):
        service.run_plan("release")

    plan_path = next((service.paths.state / "plans").glob("*/plan.json"))
    failed = json.loads(plan_path.read_text(encoding="utf-8"))
    assert failed["result"] == "failed"
    assert failed["authoritative"] is False
    assert failed["operationError"]["category"] == "VALIDATION_FAILED"
    assert failed["focusedChecks"]["result"] == "failed"


def test_affected_runner_rejects_release_mode(tmp_path: Path) -> None:
    service = service_with_temporary_state(tmp_path)

    with pytest.raises(VMError, match="canonical release plan"):
        service.run_affected(mode="release")
