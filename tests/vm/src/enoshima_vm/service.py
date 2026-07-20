from __future__ import annotations

import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import uuid
from collections.abc import Sequence
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path, PurePosixPath
from typing import Any

from .artifacts import collect_fixed_artifacts
from .boot_security import (
    assert_secure_boot,
    boot_with_recovery,
    collect_boot_security,
    create_runtime_inventory,
    enroll_tpm,
    prepare_boot_disk,
    test_recovery_path,
    test_unsigned_rejection,
)
from .cloud_init import CloudInitBuilder
from .config import (
    DOMAIN_PREFIX,
    RuntimePaths,
    Suite,
    load_images,
    load_suite,
)
from .errors import FailureCategory, VMError
from .guest import Guest, parse_json_result, source_identity_json
from .image import ImageCache
from .libvirt_backend import LibvirtBackend
from .security import (
    append_audit,
    argv_digest,
    confined_path,
    redact_argv,
    require_domain,
    require_run_id,
)

REMOTE_ROOT = PurePosixPath("/home/kentakang/enoshima-test")
REMOTE_SOURCE = REMOTE_ROOT / "source"
REMOTE_ARTIFACTS = REMOTE_ROOT / "artifacts"


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class VMService:
    def __init__(
        self,
        paths: RuntimePaths | None = None,
        *,
        libvirt_uri: str | None = None,
    ) -> None:
        self.paths = paths or RuntimePaths.discover()
        self.uri = libvirt_uri or os.environ.get(
            "ENOSHIMA_VM_LIBVIRT_URI", "qemu:///session"
        )
        self.backend = LibvirtBackend(self.paths, self.uri)
        self.images = ImageCache(self.paths)
        self.cloud_init = CloudInitBuilder(self.paths)
        self.runs_root = self.paths.state / "runs"
        self.audit_path = self.paths.state / "audit.jsonl"

    def _audit(
        self,
        tool: str,
        *,
        run_id: str | None = None,
        argv: Sequence[str] | None = None,
        result: str = "ok",
        duration_ms: int | None = None,
    ) -> None:
        event: dict[str, object] = {
            "timestamp": utc_now(),
            "actor": "codex",
            "tool": tool,
            "result": result,
        }
        if run_id:
            event["run_id"] = run_id
        if argv:
            event["argv"] = redact_argv(argv)
            event["argv_sha256"] = argv_digest(argv)
        if duration_ms is not None:
            event["duration_ms"] = duration_ms
        append_audit(self.audit_path, event)

    def _run_dir(self, run_id: str) -> Path:
        require_run_id(run_id)
        return confined_path(self.runs_root, self.runs_root / run_id)

    def _record_path(self, run_id: str) -> Path:
        return self._run_dir(run_id) / "run.json"

    def _write_record(self, record: dict[str, Any]) -> None:
        path = self._record_path(record["run_id"])
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = path.with_suffix(".json.new")
        temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(temporary, path)

    def load_record(self, run_id: str) -> dict[str, Any]:
        path = self._record_path(run_id)
        if not path.is_file():
            raise VMError(FailureCategory.HARNESS_ERROR, f"unknown run: {run_id}")
        record = json.loads(path.read_text(encoding="utf-8"))
        if record.get("run_id") != run_id:
            raise VMError(FailureCategory.HARNESS_ERROR, f"corrupt run record: {path}")
        require_domain(record["domain"])
        return record

    def _guest(self, record: dict[str, Any]) -> Guest:
        private_key = confined_path(
            self._run_dir(record["run_id"]), Path(record["private_key"])
        )
        if not private_key.is_file():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "disposable SSH key is unavailable; the run has already been destroyed",
            )
        return Guest(int(record["ssh_host_port"]), private_key)

    def preflight(self, suite_name: str) -> dict[str, object]:
        suite = load_suite(suite_name, self.paths)
        checks = self.backend.preflight(suite)
        images = load_images(self.paths)
        if suite.base_image not in images:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"suite references unknown image: {suite.base_image}",
            )
        checks["image"] = suite.base_image
        checks["state_root"] = str(self.paths.state)
        checks["cache_root"] = str(self.paths.cache)
        return checks

    def create(
        self, suite_name: str, *, source_ref: str = "working-tree"
    ) -> dict[str, Any]:
        if source_ref != "working-tree":
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "only the current working tree may be supplied to a VM run",
            )
        suite = load_suite(suite_name, self.paths)
        self.preflight(suite_name)
        definitions = load_images(self.paths)
        definition = definitions[suite.base_image]
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        run_dir = self._run_dir(run_id)
        run_dir.mkdir(mode=0o700, parents=True)
        record: dict[str, Any] = {
            "schema": 1,
            "run_id": run_id,
            "domain": f"{DOMAIN_PREFIX}{run_id}",
            "suite": suite.name,
            "status": "creating",
            "category": None,
            "created_at": utc_now(),
            "updated_at": utc_now(),
            "libvirt_uri": self.uri,
            "artifact_dir": str(run_dir / "artifacts"),
            "source_ref": source_ref,
        }
        if suite.name == "boot-security":
            secret_dir = run_dir / "secrets"
            secret_dir.mkdir(mode=0o700)
            recovery_key = secret_dir / "luks-recovery.key"
            recovery_key.write_text(secrets.token_hex(32) + "\n", encoding="utf-8")
            recovery_key.chmod(0o600)
            record["recovery_key"] = str(recovery_key)
        self._write_record(record)
        try:
            base_image = self.images.ensure(definition)
            cloud = self.cloud_init.build(run_dir, run_id, "kentakang")
            spec = self.backend.prepare_domain(
                run_dir, run_id, suite, base_image, cloud.seed
            )
            record.update(
                {
                    "domain": spec.domain,
                    "base_image": str(base_image),
                    "overlay": str(spec.overlay),
                    "seed": str(spec.seed),
                    "private_key": str(cloud.private_key),
                    "ssh_host_port": spec.ssh_host_port,
                    "domain_xml": str(spec.xml),
                }
            )
            if spec.boot_disk:
                record["boot_disk"] = str(spec.boot_disk)
            self.backend.define_and_start(spec)
            record["status"] = "running"
            record["updated_at"] = utc_now()
            watchdog = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "enoshima_vm.watchdog",
                    run_id,
                    str(suite.timeout_minutes * 60),
                    self.uri,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            record["watchdog_pid"] = watchdog.pid
            record["maximum_duration_minutes"] = suite.timeout_minutes
            self._write_record(record)
            self._audit("vm_create", run_id=run_id)
            return record
        except Exception as error:
            record["status"] = "failed"
            record["category"] = (
                error.category
                if isinstance(error, VMError)
                else (FailureCategory.HARNESS_ERROR)
            )
            record["error"] = str(error)
            record["updated_at"] = utc_now()
            self._write_record(record)
            self.backend.destroy(record["domain"])
            self._remove_ephemeral(record)
            self._audit("vm_create", run_id=run_id, result="failed")
            raise

    def wait(self, run_id: str, timeout_seconds: int = 1200) -> dict[str, Any]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        guest.wait_ssh(min(timeout_seconds, 600))
        guest.wait_cloud_init(timeout_seconds)
        self.backend.wait_guest_agent(record["domain"], min(timeout_seconds, 300))
        record["status"] = "ready"
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_wait", run_id=run_id)
        return record

    def upload_worktree(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        identity = self._guest(record).upload_worktree(
            self.paths.repository, REMOTE_SOURCE
        )
        source = source_identity_json(identity)
        record["source"] = source
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_upload_worktree", run_id=run_id)
        return source

    def exec(
        self,
        run_id: str,
        argv: Sequence[str],
        *,
        timeout_seconds: int = 300,
    ) -> dict[str, object]:
        if not argv:
            raise VMError(FailureCategory.HARNESS_ERROR, "argv must not be empty")
        record = self.load_record(run_id)
        start = time.monotonic()
        result = self._guest(record).exec(
            list(argv), timeout=timeout_seconds, check=False
        )
        duration_ms = int((time.monotonic() - start) * 1000)
        self._audit(
            "vm_exec",
            run_id=run_id,
            argv=list(argv),
            result="ok" if result.returncode == 0 else "failed",
            duration_ms=duration_ms,
        )
        return {
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "duration_ms": duration_ms,
        }

    def _write_step_log(
        self,
        record: dict[str, Any],
        name: str,
        result: dict[str, object],
    ) -> Path:
        path = Path(record["artifact_dir"]) / "runner" / f"{name}.log"
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        stderr = (
            "\n--- stderr ---\n" + str(result["stderr"]) if result["stderr"] else ""
        )
        path.write_text(str(result["stdout"]) + stderr, encoding="utf-8")
        return path

    def _run_checked(
        self,
        record: dict[str, Any],
        name: str,
        argv: Sequence[str],
        category: FailureCategory,
        *,
        timeout_seconds: int = 7200,
    ) -> dict[str, object]:
        result = self.exec(record["run_id"], argv, timeout_seconds=timeout_seconds)
        log = self._write_step_log(record, name, result)
        if result["exit_code"]:
            raise VMError(
                category,
                f"suite step failed: {name}",
                {
                    "exit_code": result["exit_code"],
                    "log": str(log),
                    "stderr_tail": str(result["stderr"])[-4000:],
                },
            )
        return result

    def _remote_shell(self, command: str) -> list[str]:
        return ["bash", "-lc", command]

    def _run_validate(self, record: dict[str, Any]) -> None:
        self._run_checked(
            record,
            "validate",
            self._remote_shell(f"cd {REMOTE_SOURCE} && make validate"),
            FailureCategory.VALIDATION_FAILED,
        )

    def _run_bootstrap(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        report = str(values.get("report", "current"))
        if not re.fullmatch(r"[a-z0-9-]+", report):
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid bootstrap report name"
            )
        suite = load_suite(record["suite"], self.paths)
        remote_report = REMOTE_ARTIFACTS / f"bootstrap-{report}"
        inventory = f"{REMOTE_SOURCE}/ansible/inventory/hosts.yml"
        if values.get("inventory") == "runtime":
            inventory = str(record.get("observations", {}).get("runtime_inventory", ""))
            if not inventory:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "runtime inventory has not been generated",
                )
        apply_boot_artifacts = (
            " --apply-boot-artifacts" if values.get("apply_boot_artifacts") else ""
        )
        command = (
            f"cd {REMOTE_SOURCE} && ./bootstrap.sh --profile {suite.profile} "
            f"--inventory {inventory} "
            f"--conflict-policy backup --report-dir {remote_report} "
            f"--report-format json{apply_boot_artifacts}"
        )
        self._run_checked(
            record,
            f"bootstrap-{report}",
            self._remote_shell(command),
            FailureCategory.BOOTSTRAP_FAILED,
            timeout_seconds=4 * 60 * 60,
        )
        packages = (
            self._guest(record)
            .exec(self._remote_shell("pacman -Qq | LC_ALL=C sort"), timeout=120)
            .stdout
        )
        package_hash = sha256(packages.encode()).hexdigest()
        observations = record.setdefault("observations", {})
        observations[f"package_hash_{report}"] = package_hash
        self._write_record(record)

    def _run_postflight(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        report = str(values.get("report", "current"))
        if not re.fullmatch(r"[a-z0-9-]+", report):
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid postflight report name"
            )
        suite = load_suite(record["suite"], self.paths)
        destination = REMOTE_ARTIFACTS / f"postflight-{report}.json"
        inventory = f"{REMOTE_SOURCE}/ansible/inventory/hosts.yml"
        if values.get("inventory") == "runtime":
            inventory = str(record.get("observations", {}).get("runtime_inventory", ""))
            if not inventory:
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "runtime inventory has not been generated",
                )
        command = (
            f"cd {REMOTE_SOURCE} && scripts/postflight.sh --profile {suite.profile} "
            f"--inventory {inventory} "
            f"--format json --output {destination}"
        )
        self._run_checked(
            record,
            f"postflight-{report}",
            self._remote_shell(command),
            FailureCategory.POSTFLIGHT_FAILED,
        )
        record.setdefault("observations", {})["last_postflight"] = str(destination)
        self._write_record(record)

    def _assert_idempotent(self, record: dict[str, Any]) -> None:
        observations = record.get("observations", {})
        if observations.get("package_hash_first") != observations.get(
            "package_hash_second"
        ):
            raise VMError(
                FailureCategory.IDEMPOTENCY_FAILED,
                "installed package set changed during the second bootstrap",
            )
        report_path = REMOTE_ARTIFACTS / "bootstrap-second" / "bootstrap.json"
        report = parse_json_result(
            self._guest(record).exec(["cat", str(report_path)]),
            "second bootstrap report",
        )
        assert isinstance(report, dict)
        changes: list[dict[str, object]] = []
        for step in report.get("steps", []):
            label = str(step.get("label", ""))
            if (
                "Ansible desired state" not in label
                and "desktop expansion" not in label
            ):
                continue
            log_path = step.get("log")
            if not log_path:
                continue
            body = self._guest(record).exec(["cat", str(log_path)]).stdout
            counts = [int(value) for value in re.findall(r"changed=(\d+)", body)]
            if not counts:
                changes.append({"step": label, "reason": "missing Ansible recap"})
            elif any(counts):
                changes.append({"step": label, "changed": counts})

        diff = self._guest(record).exec(
            [
                "chezmoi",
                "--config",
                "/dev/null",
                "--config-format",
                "toml",
                "--source",
                str(REMOTE_SOURCE),
                "--persistent-state",
                "/home/kentakang/.enoshima/chezmoi-state.boltdb",
                "diff",
            ],
            timeout=180,
            check=False,
        )
        if diff.returncode or diff.stdout.strip():
            changes.append(
                {
                    "step": "chezmoi diff",
                    "exit_code": diff.returncode,
                    "output": diff.stdout[-4000:],
                }
            )
        if changes:
            raise VMError(
                FailureCategory.IDEMPOTENCY_FAILED,
                "the second bootstrap was not idempotent",
                {"unexpected_changes": changes},
            )

    def _assert_expected_skips(self, record: dict[str, Any]) -> None:
        suite = load_suite(record["suite"], self.paths)
        path = record.get("observations", {}).get("last_postflight")
        if not path:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "no postflight report is available for skip validation",
            )
        report = parse_json_result(
            self._guest(record).exec(["cat", str(path)]), "postflight report"
        )
        assert isinstance(report, dict)
        actual = {
            check["id"]
            for check in report.get("checks", [])
            if check.get("status") == "skip"
        }
        unexpected = sorted(actual - suite.allowed_skips)
        if suite.fail_on_unexpected_skip and unexpected:
            raise VMError(
                FailureCategory.POSTFLIGHT_FAILED,
                "postflight contains unexpected skipped checks",
                {
                    "unexpected_skips": unexpected,
                    "allowed": sorted(suite.allowed_skips),
                },
            )

    def reboot(self, run_id: str, timeout_seconds: int = 600) -> dict[str, object]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        before = guest.exec(["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
        self.backend.reboot(record["domain"])
        guest.wait_ssh_cycle(timeout_seconds)
        self.backend.wait_guest_agent(record["domain"], min(timeout_seconds, 300))
        after = guest.exec(["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
        if not before or before == after:
            raise VMError(
                FailureCategory.REBOOT_FAILED,
                "guest boot ID did not change after reboot",
            )
        self._audit("vm_reboot", run_id=run_id)
        return {"before_boot_id": before, "after_boot_id": after}

    def _start_desktop(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        command = [
            "systemd-run",
            "--user",
            "--unit=enoshima-vm-desktop",
            "--collect",
            "--setenv=WLR_RENDERER_ALLOW_SOFTWARE=1",
            "dbus-run-session",
            "start-hyprland",
        ]
        result = guest.exec(command, timeout=60, check=False)
        if result.returncode:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "cannot launch the VM Hyprland session",
                {"stderr": result.stderr[-4000:]},
            )
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j monitors"), timeout=15, check=False
            )
            if result.returncode == 0:
                return
            time.sleep(2)
        journal = guest.exec(
            ["journalctl", "--user", "-u", "enoshima-vm-desktop", "--no-pager"],
            check=False,
        )
        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            "Hyprland IPC did not become ready",
            {"journal": journal.stdout[-8000:]},
        )

    @staticmethod
    def _hypr_command(command: str) -> list[str]:
        shell = (
            "uid=$(id -u); "
            "sig=$(find /run/user/$uid/hypr -mindepth 1 -maxdepth 1 -type d "
            "-printf '%f\\n' 2>/dev/null | head -n1); "
            'test -n "$sig"; export HYPRLAND_INSTANCE_SIGNATURE=$sig; ' + command
        )
        return ["bash", "-lc", shell]

    def query_desktop(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        result: dict[str, object] = {}
        for name in ("monitors", "workspaces", "clients", "activewindow", "devices"):
            command = self._hypr_command(f"hyprctl -j {name}")
            value = guest.exec(command, timeout=30, check=False)
            if value.returncode:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    f"hyprctl query failed: {name}",
                    {"stderr": value.stderr[-2000:]},
                )
            result[name] = json.loads(value.stdout)
        self._audit("vm_query_desktop", run_id=run_id)
        return result

    def screenshot(self, run_id: str, name: str = "desktop") -> dict[str, str]:
        if not re.fullmatch(r"[a-z0-9-]+", name):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid screenshot name")
        record = self.load_record(run_id)
        remote = REMOTE_ARTIFACTS / "screenshots" / f"{name}.png"
        command = self._hypr_command(
            "wayland=$(find /run/user/$(id -u) -maxdepth 1 -type s "
            "-name 'wayland-*' -printf '%f\\n' | head -n1); "
            'test -n "$wayland"; export WAYLAND_DISPLAY=$wayland; '
            f"install -d -m 0700 {remote.parent}; grim {remote}"
        )
        result = self._guest(record).exec(command, timeout=60, check=False)
        if result.returncode:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "guest screenshot failed",
                {"stderr": result.stderr[-3000:]},
            )
        local = Path(record["artifact_dir"]) / "screenshots" / f"{name}.png"
        self._guest(record).download(remote, local)
        self._audit("vm_screenshot", run_id=run_id)
        return {"path": str(local)}

    def collect(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        artifact_dir = Path(record["artifact_dir"])
        collected = collect_fixed_artifacts(
            self._guest(record), artifact_dir, REMOTE_ARTIFACTS
        )
        record["artifacts_collected_at"] = utc_now()
        record["updated_at"] = utc_now()
        self._write_record(record)
        self._audit("vm_collect_artifacts", run_id=run_id)
        return {"artifact_dir": str(artifact_dir), "collected": collected}

    def status(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        record["domain_state"] = self.backend.state(record["domain"])
        return record

    def poweroff(self, run_id: str) -> dict[str, str]:
        record = self.load_record(run_id)
        self.backend.poweroff(record["domain"])
        self._audit("vm_poweroff", run_id=run_id)
        return {"run_id": run_id, "status": "poweroff-requested"}

    def destroy(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        self.backend.destroy(record["domain"])
        removed = self._remove_ephemeral(record)
        record["status"] = (
            "completed" if record.get("result") == "passed" else "destroyed"
        )
        record["destroyed_at"] = utc_now()
        record["updated_at"] = utc_now()
        record.pop("private_key", None)
        record.pop("recovery_key", None)
        self._write_record(record)
        self._audit("vm_destroy", run_id=run_id)
        return {"run_id": run_id, "removed": removed, "recoverable": False}

    def _remove_ephemeral(self, record: dict[str, Any]) -> list[str]:
        run_dir = self._run_dir(record["run_id"])
        removed: list[str] = []
        file_targets = {
            run_dir / "root.qcow2",
            run_dir / "boot.qcow2",
            run_dir / "seed.iso",
        }
        for key in ("overlay", "boot_disk", "seed"):
            if record.get(key):
                file_targets.add(Path(record[key]))
        for value in file_targets:
            target = confined_path(run_dir, value)
            if target.exists():
                target.unlink()
                removed.append(str(target))
        for name in ("ssh", "cloud-init", "secrets", "swtpm"):
            target = confined_path(run_dir, run_dir / name)
            if target.exists():
                shutil.rmtree(target)
                removed.append(str(target))
        return removed

    def list_runs(self) -> list[dict[str, object]]:
        if not self.runs_root.exists():
            return []
        records = []
        for path in sorted(self.runs_root.glob("run-*/run.json"), reverse=True):
            try:
                records.append(self.load_record(path.parent.name))
            except (VMError, ValueError, json.JSONDecodeError):
                continue
        return records

    def clean(self) -> dict[str, object]:
        cleaned = []
        for record in self.list_runs():
            has_key = bool(record.get("private_key"))
            has_domain = self.backend.state(record["domain"]) != "undefined"
            if has_key or has_domain:
                cleaned.append(self.destroy(record["run_id"]))
        return {"cleaned": cleaned, "preserved_reports": True}

    def _execute_step(
        self,
        record: dict[str, Any],
        suite: Suite,
        action: str,
        config: Any,
    ) -> None:
        if action == "wait_for_ssh":
            self._guest(record).wait_ssh()
        elif action == "wait_for_cloud_init":
            self._guest(record).wait_cloud_init()
        elif action == "wait_for_guest_agent":
            self.backend.wait_guest_agent(record["domain"])
        elif action == "upload_worktree":
            self.upload_worktree(record["run_id"])
        elif action == "run_validate":
            self._run_validate(record)
        elif action == "run_bootstrap":
            self._run_bootstrap(record, config)
        elif action == "run_postflight":
            self._run_postflight(record, config)
        elif action == "assert_idempotent":
            self._assert_idempotent(record)
        elif action == "assert_expected_skips":
            self._assert_expected_skips(record)
        elif action == "reboot":
            self.reboot(record["run_id"])
        elif action == "start_desktop":
            self._start_desktop(record)
        elif action == "send_key":
            if not isinstance(config, dict) or not isinstance(config.get("keys"), list):
                raise VMError(FailureCategory.HARNESS_ERROR, "send_key requires keys")
            keys = [str(key) for key in config["keys"]]
            self.backend.send_keys(record["domain"], keys)
        elif action == "query_desktop":
            desktop = self.query_desktop(record["run_id"])
            path = Path(record["artifact_dir"]) / "hyprctl" / "desktop.json"
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(json.dumps(desktop, indent=2) + "\n", encoding="utf-8")
        elif action == "screenshot":
            values = config if isinstance(config, dict) else {}
            self.screenshot(record["run_id"], str(values.get("name", "desktop")))
        elif action == "collect_artifacts":
            self.collect(record["run_id"])
        elif action == "prepare_boot_disk":
            prepare_boot_disk(self, record)
        elif action == "boot_with_recovery":
            boot_with_recovery(self, record)
        elif action == "create_runtime_inventory":
            create_runtime_inventory(self, record)
        elif action == "assert_secure_boot":
            assert_secure_boot(self, record)
        elif action == "enroll_tpm":
            enroll_tpm(self, record)
        elif action == "test_recovery_path":
            test_recovery_path(self, record)
        elif action == "test_unsigned_rejection":
            test_unsigned_rejection(self, record)
        elif action == "collect_boot_security":
            collect_boot_security(self, record)
        else:
            raise VMError(
                FailureCategory.HARNESS_ERROR, f"unknown suite step: {action}"
            )

    def run_suite(
        self,
        suite_name: str,
        *,
        keep_on_failure: bool = False,
    ) -> dict[str, Any]:
        suite = load_suite(suite_name, self.paths)
        record = self.create(suite_name)
        try:
            for index, raw_step in enumerate(suite.steps, start=1):
                if isinstance(raw_step, str):
                    action, config = raw_step, None
                else:
                    action, config = next(iter(raw_step.items()))
                record = self.load_record(record["run_id"])
                record["current_step"] = action
                record["current_step_index"] = index
                record["updated_at"] = utc_now()
                self._write_record(record)
                self._execute_step(record, suite, action, config)
            record = self.load_record(record["run_id"])
            record["result"] = "passed"
            record["status"] = "passed"
            record["category"] = None
            record["updated_at"] = utc_now()
            self._write_record(record)
            self.destroy(record["run_id"])
            return self.load_record(record["run_id"])
        except Exception as error:
            record = self.load_record(record["run_id"])
            record["result"] = "failed"
            record["status"] = "failed"
            category = (
                error.category
                if isinstance(error, VMError)
                else FailureCategory.HARNESS_ERROR
            )
            record["category"] = str(category)
            record["error"] = str(error)
            if isinstance(error, VMError) and error.details:
                record["details"] = error.details
            record["updated_at"] = utc_now()
            self._write_record(record)
            try:
                self.collect(record["run_id"])
            except Exception as collection_error:
                record["collection_error"] = str(collection_error)
                self._write_record(record)
            if not keep_on_failure:
                self.destroy(record["run_id"])
            raise
