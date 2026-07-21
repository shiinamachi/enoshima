from __future__ import annotations

import json
import os
import re
import secrets
import shlex
import shutil
import struct
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
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
from .ui_review import (
    load_ui_review_identities,
    load_ui_review_matrix,
    physical_mode,
)

REMOTE_ROOT = PurePosixPath("/home/kentakang/enoshima-test")
REMOTE_SOURCE = REMOTE_ROOT / "source"
REMOTE_ARTIFACTS = REMOTE_ROOT / "artifacts"
REMOTE_LOGIN_PASSWORD = REMOTE_ROOT / "secrets" / "login-password"
REMOTE_LOGIN_CREDENTIAL = REMOTE_ROOT / "secrets" / "chpasswd-input"


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
            cloud = self.cloud_init.build(
                run_dir,
                run_id,
                "kentakang",
                definition.repository_snapshot,
            )
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

    def _write_junit(self, record: dict[str, Any]) -> Path:
        steps = record.get("steps", [])
        failures = sum(1 for step in steps if step.get("status") == "failed")
        elapsed = sum(float(step.get("duration_seconds", 0)) for step in steps)
        suite = ET.Element(
            "testsuite",
            {
                "name": f"enoshima-vm.{record['suite']}",
                "tests": str(len(steps)),
                "failures": str(failures),
                "errors": "0",
                "skipped": "0",
                "time": f"{elapsed:.3f}",
            },
        )
        for step in steps:
            case = ET.SubElement(
                suite,
                "testcase",
                {
                    "classname": f"enoshima_vm.{record['suite']}",
                    "name": str(step["action"]),
                    "time": f"{float(step.get('duration_seconds', 0)):.3f}",
                },
            )
            if step.get("status") == "failed":
                failure = ET.SubElement(
                    case,
                    "failure",
                    {
                        "type": str(record.get("category") or "HARNESS_ERROR"),
                        "message": str(record.get("error") or "suite step failed"),
                    },
                )
                failure.text = str(record.get("error") or "suite step failed")
        destination = Path(record["artifact_dir"]) / "junit.xml"
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        ET.ElementTree(suite).write(destination, encoding="utf-8", xml_declaration=True)
        return destination

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

    def _graphical_shell(self, command: str) -> list[str]:
        environment = (
            "uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
            "while IFS= read -r entry; do case $entry in "
            "PATH=*|WAYLAND_DISPLAY=*|DISPLAY=*|HYPRLAND_INSTANCE_SIGNATURE=*|"
            "XDG_CURRENT_DESKTOP=*|XDG_SESSION_DESKTOP=*|XDG_SESSION_TYPE=*) "
            'export "$entry" ;; esac; done < <(systemctl --user show-environment); '
        )
        return self._remote_shell(environment + command)

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
        argv = self._remote_shell(command)
        if record.get("observations", {}).get("greetd_login_at"):
            argv = self._graphical_shell(command)
        self._run_checked(
            record,
            f"postflight-{report}",
            argv,
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

    def _reboot_via_desktop_power(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        iterations = values.get("iterations", 1)
        if not isinstance(iterations, int) or not 1 <= iterations <= 10:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "desktop power reboot iterations must be between 1 and 10",
            )
        guest = self._guest(record)
        results: list[dict[str, str]] = []
        for iteration in range(1, iterations + 1):
            before = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"]
            ).stdout.strip()
            log_path = REMOTE_ARTIFACTS / f"desktop-power-reboot-{iteration}.jsonl"
            launch = (
                f"install -d -m 0700 {REMOTE_ARTIFACTS}; "
                f"nohup desktop-power reboot >{log_path} 2>&1 </dev/null &"
            )
            launched = guest.exec(
                self._graphical_shell(launch), timeout=30, check=False
            )
            if launched.returncode != 0:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "could not dispatch reboot through desktop-power",
                    {
                        "iteration": iteration,
                        "stderr": launched.stderr[-2000:],
                    },
                )
            guest.wait_ssh_cycle(600)
            self.backend.wait_guest_agent(record["domain"], 300)
            after = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"]
            ).stdout.strip()
            if not before or before == after:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "desktop-power did not change the guest boot ID",
                    {"iteration": iteration, "boot_id": before},
                )
            self._login_greetd(record)
            verify_command = self._remote_shell(
                "test ! -e ~/.local/state/enoshima/power/pending.json; "
                "jq -e --arg before "
                + shlex.quote(before)
                + " --arg after "
                + shlex.quote(after)
                + ' \'.status == "succeeded" and .action == "reboot" '
                "and .boot_id_before == $before and .boot_id_after == $after' "
                "~/.local/state/enoshima/power/last-result.json"
            )
            verify_deadline = time.monotonic() + 30
            while True:
                verification = guest.exec(verify_command, timeout=15, check=False)
                if verification.returncode == 0 or time.monotonic() >= verify_deadline:
                    break
                time.sleep(1)
            if verification.returncode != 0:
                raise VMError(
                    FailureCategory.REBOOT_FAILED,
                    "desktop-power checkpoint was not verified after login",
                    {
                        "iteration": iteration,
                        "stderr": verification.stderr[-2000:],
                    },
                )
            results.append(
                {
                    "before_boot_id": before,
                    "after_boot_id": after,
                }
            )
        record.setdefault("observations", {})["desktop_power_reboots"] = results
        self._write_record(record)

    @staticmethod
    def _hypr_command(command: str) -> list[str]:
        shell = (
            "uid=$(id -u); "
            "sig=$(find /run/user/$uid/hypr -mindepth 1 -maxdepth 1 -type d "
            "-printf '%f\\n' 2>/dev/null | head -n1); "
            'test -n "$sig"; export HYPRLAND_INSTANCE_SIGNATURE=$sig; '
            'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:'
            '/usr/local/bin:/usr/bin"; ' + command
        )
        return ["bash", "-lc", shell]

    def query_desktop(self, run_id: str) -> dict[str, object]:
        record = self.load_record(run_id)
        guest = self._guest(record)
        result: dict[str, object] = {}
        for name in (
            "monitors",
            "workspaces",
            "clients",
            "activewindow",
            "activeworkspace",
            "devices",
        ):
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

    def _configure_virtual_displays(self, record: dict[str, Any], config: Any) -> None:
        if not isinstance(config, dict) or not isinstance(config.get("monitors"), list):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "configure_virtual_displays requires a monitor list",
            )
        guest = self._guest(record)
        configured_names: set[str] = set()
        for monitor in config["monitors"]:
            if not isinstance(monitor, dict):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor")
            name = str(monitor.get("name", ""))
            mode = str(monitor.get("mode", ""))
            position = str(monitor.get("position", ""))
            scale = str(monitor.get("scale", ""))
            if not re.fullmatch(r"HEADLESS-[A-Z]+", name):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor name")
            configured_names.add(name)
            if not re.fullmatch(r"[0-9]{3,5}x[0-9]{3,5}@[0-9]{2,3}", mode):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor mode")
            if not re.fullmatch(r"-?[0-9]{1,5}x-?[0-9]{1,5}", position):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor position")
            if not re.fullmatch(r"[0-9](?:\.[0-9]+)?", scale):
                raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor scale")
            create = guest.exec(
                self._hypr_command(f"hyprctl output create headless {name}"),
                timeout=30,
                check=False,
            )
            if (
                create.returncode
                and "already" not in (create.stdout + create.stderr).lower()
            ):
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    f"cannot create virtual output: {name}",
                    {"stderr": create.stderr[-2000:]},
                )
            monitor_expression = self._monitor_eval_expression(
                name, mode, position, scale
            )
            self._run_checked(
                record,
                f"configure-{name.lower()}",
                self._hypr_command(f"hyprctl eval '{monitor_expression}'"),
                FailureCategory.DESKTOP_SESSION_FAILED,
                timeout_seconds=30,
            )
        if config.get("disable_unlisted"):
            monitors = guest.exec(self._hypr_command("hyprctl -j monitors"), timeout=30)
            for monitor in json.loads(monitors.stdout):
                output = str(monitor.get("name", ""))
                if output in configured_names:
                    continue
                if not re.fullmatch(r"[A-Za-z0-9._-]+", output):
                    raise VMError(
                        FailureCategory.DESKTOP_SESSION_FAILED,
                        "Hyprland reported an unsafe output name",
                        {"output": output},
                    )
                self._run_checked(
                    record,
                    f"disable-{output.lower()}",
                    self._hypr_command(
                        f"hyprctl eval '{self._monitor_disable_expression(output)}'"
                    ),
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    timeout_seconds=30,
                )

    @staticmethod
    def _monitor_eval_expression(
        name: str, mode: str, position: str, scale: str
    ) -> str:
        return (
            'hl.monitor({ output = "'
            + name
            + '", mode = "'
            + mode
            + '", position = "'
            + position
            + '", scale = '
            + scale
            + " })"
        )

    @staticmethod
    def _monitor_disable_expression(name: str) -> str:
        return f'hl.monitor({{ output = "{name}", disabled = true }})'

    @staticmethod
    def _decoration_allowlist_expression(allowlist: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9._,*?-]+(?:,[A-Za-z0-9._,*?-]+)*", allowlist):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "invalid decoration allowlist",
            )
        return (
            'hl.config({ plugin = { enoshima_decoration = { allowlist = "'
            + allowlist
            + '" } } })'
        )

    def _wait_for_client(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        pattern = str(values.get("class", ""))
        workspace = str(values.get("workspace", ""))
        if not pattern or not workspace:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "wait_for_client requires class and workspace",
            )
        try:
            matcher = re.compile(pattern, re.IGNORECASE)
        except re.error as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid client regex"
            ) from error
        guest = self._guest(record)
        deadline = time.monotonic() + int(values.get("timeout_seconds", 120))
        last: list[object] = []
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j clients"), timeout=15, check=False
            )
            if result.returncode == 0:
                last = json.loads(result.stdout)
                for client in last:
                    class_name = str(client.get("class", ""))
                    initial_class = str(client.get("initialClass", ""))
                    client_workspace = str(client.get("workspace", {}).get("name", ""))
                    if (
                        matcher.search(class_name) or matcher.search(initial_class)
                    ) and client_workspace == workspace:
                        return
            time.sleep(2)
        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            "expected client did not appear on its routed workspace",
            {"class": pattern, "workspace": workspace, "clients": last},
        )

    def _assert_desktop_state(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        expected_monitors = values.get("monitors", [])
        if not isinstance(expected_monitors, list):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid monitor assertions")
        desktop = self.query_desktop(record["run_id"])
        actual = {monitor["name"]: monitor for monitor in desktop["monitors"]}
        failures: list[str] = []
        if "monitor_count" in values and len(actual) != int(values["monitor_count"]):
            failures.append(
                f"monitor count={len(actual)}, expected {values['monitor_count']}"
            )
        for expected in expected_monitors:
            name = str(expected["name"])
            monitor = actual.get(name)
            if monitor is None:
                failures.append(f"missing monitor {name}")
                continue
            for key in ("width", "height", "x", "y"):
                if key in expected and int(monitor.get(key, -1)) != int(expected[key]):
                    failures.append(
                        f"{name}.{key}={monitor.get(key)!r}, expected {expected[key]!r}"
                    )
            if (
                "scale" in expected
                and abs(float(monitor.get("scale", 0)) - float(expected["scale"]))
                > 0.01
            ):
                failures.append(
                    f"{name}.scale={monitor.get('scale')!r}, "
                    f"expected {expected['scale']!r}"
                )
        active_workspace = str(desktop.get("activeworkspace", {}).get("name", ""))
        if values.get("active_workspace") and active_workspace != str(
            values["active_workspace"]
        ):
            failures.append(
                f"active workspace={active_workspace!r}, "
                f"expected {values['active_workspace']!r}"
            )
        devices = desktop.get("devices", {})
        if values.get("require_keyboard") and not devices.get("keyboards"):
            failures.append("no keyboard reported by Hyprland")
        if failures:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "desktop structural assertions failed",
                {"failures": failures, "desktop": desktop},
            )

    def _wait_for_layer(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        namespace = str(values.get("namespace", ""))
        if not re.fullmatch(r"[a-z0-9-]+", namespace):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid layer namespace")
        guest = self._guest(record)
        deadline = time.monotonic() + int(values.get("timeout_seconds", 60))
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j layers"), timeout=15, check=False
            )
            if result.returncode == 0:
                layers = json.loads(result.stdout)
                namespaces: list[str] = []

                def visit(value: object) -> None:
                    if isinstance(value, dict):
                        if isinstance(value.get("namespace"), str):
                            namespaces.append(value["namespace"])
                        for child in value.values():
                            visit(child)
                    elif isinstance(value, list):
                        for child in value:
                            visit(child)

                visit(layers)
                if namespace in namespaces:
                    return
            time.sleep(1)
        raise VMError(
            FailureCategory.DESKTOP_SESSION_FAILED,
            f"expected layer did not appear: {namespace}",
        )

    def _prepare_login(self, record: dict[str, Any]) -> None:
        secret_dir = self._run_dir(record["run_id"]) / "secrets"
        secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        password_path = secret_dir / "login-password"
        # gnome-keyring-daemon consumes every byte from stdin as the keyring
        # password.  Keep this file newline-free; chpasswd gets its own
        # line-oriented credential below.
        password_path.write_text(secrets.token_hex(16), encoding="utf-8")
        password_path.chmod(0o600)
        credential = secret_dir / "chpasswd-input"
        credential.write_text(
            f"kentakang:{password_path.read_text(encoding='utf-8').strip()}\n",
            encoding="utf-8",
        )
        credential.chmod(0o600)
        guest = self._guest(record)
        guest.upload_file(password_path, REMOTE_LOGIN_PASSWORD)
        guest.upload_file(credential, REMOTE_LOGIN_CREDENTIAL)
        try:
            self._run_checked(
                record,
                "prepare-greetd-login",
                self._remote_shell(f"sudo chpasswd < {REMOTE_LOGIN_CREDENTIAL}"),
                FailureCategory.LOGIN_SESSION_FAILED,
            )
            self._run_checked(
                record,
                "prepare-login-keyring",
                self._remote_shell(
                    "export HOME=/home/kentakang; "
                    "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
                    "export GNOME_KEYRING_CONTROL=$XDG_RUNTIME_DIR/keyring; "
                    f"gnome-keyring-daemon --unlock < {REMOTE_LOGIN_PASSWORD}"
                ),
                FailureCategory.LOGIN_SESSION_FAILED,
            )
        finally:
            credential.unlink(missing_ok=True)
            guest.exec(["unlink", str(REMOTE_LOGIN_PASSWORD)], check=False)
            guest.exec(["unlink", str(REMOTE_LOGIN_CREDENTIAL)], check=False)
        record["login_password"] = str(password_path)
        self._write_record(record)

    def _login_greetd(self, record: dict[str, Any]) -> None:
        password_path = confined_path(
            self._run_dir(record["run_id"]), Path(record.get("login_password", ""))
        )
        if not password_path.is_file():
            raise VMError(
                FailureCategory.LOGIN_SESSION_FAILED,
                "disposable greetd password is unavailable",
            )
        guest = self._guest(record)
        self._run_checked(
            record,
            "assert-greetd-active",
            ["systemctl", "is-active", "greetd.service"],
            FailureCategory.LOGIN_SESSION_FAILED,
        )
        time.sleep(10)
        self._capture_greetd_screenshot(record)
        # Enoshima Auth is intentionally password-first but still follows the
        # greetd protocol's two phases: create the managed-user session, then
        # answer the PAM password prompt. Typing before the first Enter only
        # reaches the focused Continue button and leaves the password empty.
        self.backend.send_keys(record["domain"], ["KEY_ENTER"])
        time.sleep(1)
        self.backend.type_text(
            record["domain"], password_path.read_text(encoding="utf-8").strip()
        )
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j monitors"), timeout=15, check=False
            )
            if result.returncode == 0:
                self._assert_login_keyring(record)
                record.setdefault("observations", {})["greetd_login_at"] = utc_now()
                self._write_record(record)
                return
            time.sleep(2)
        journal = guest.exec(
            ["sudo", "journalctl", "-u", "greetd.service", "-b", "--no-pager"],
            check=False,
        )
        raise VMError(
            FailureCategory.LOGIN_SESSION_FAILED,
            "greetd did not start the user Hyprland session",
            {"journal": journal.stdout[-8000:]},
        )

    def _assert_login_keyring(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus; "
            "timeout 12s bash -c 'printf vm-probe | secret-tool store "
            "--label=Enoshima-VM-Probe enoshima-vm probe >/dev/null; "
            "value=$(secret-tool lookup enoshima-vm probe); "
            'test "$value" = vm-probe; '
            "secret-tool clear enoshima-vm probe >/dev/null'"
        )
        result = guest.exec(self._remote_shell(shell), timeout=20, check=False)
        clients_result = guest.exec(
            self._hypr_command("hyprctl -j clients"), timeout=10, check=False
        )
        clients = (
            json.loads(clients_result.stdout) if clients_result.returncode == 0 else []
        )
        keyring_journal = guest.exec(
            self._remote_shell(
                "sudo journalctl -u greetd.service -b -o cat --no-pager | "
                "grep -F 'the password for the login keyring was invalid' || true"
            ),
            timeout=15,
            check=False,
        )
        prompts = [
            client
            for client in clients
            if "gcr-prompter" in str(client.get("class", "")).lower()
            or "unlock login keyring" in str(client.get("title", "")).lower()
        ]
        if result.returncode != 0 or prompts or keyring_journal.stdout.strip():
            raise VMError(
                FailureCategory.LOGIN_SESSION_FAILED,
                "greetd login did not unlock the GNOME login keyring",
                {
                    "secret_tool_exit_code": result.returncode,
                    "stderr": result.stderr[-2000:],
                    "prompts": prompts,
                    "journal": keyring_journal.stdout[-2000:],
                },
            )

    def _graphical_health_failures(self, record: dict[str, Any]) -> dict[str, str]:
        """Reject latent session failures that screenshots alone can hide."""
        guest = self._guest(record)
        checks = {
            "failed_system_units": [
                "systemctl",
                "--failed",
                "--no-legend",
                "--plain",
                "--state=failed",
            ],
            "failed_user_units": self._remote_shell(
                "uid=$(id -u); export XDG_RUNTIME_DIR=/run/user/$uid; "
                "export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus; "
                "systemctl --user --failed --no-legend --plain --state=failed"
            ),
            "coredumps": self._remote_shell(
                "command -v coredumpctl >/dev/null || exit 0; "
                "boot_started=$(uptime -s); "
                'coredumpctl --since "$boot_started" --no-pager --no-legend '
                "list 2>/dev/null || true"
            ),
            "fatal_graphical_logs": self._remote_shell(
                "journalctl -b --no-pager -o cat 2>/dev/null | "
                "grep -Eai "
                "'(Hyprland|quickshell|qs\\[|swaync|enoshima-greeter|greetd).*'"
                "'(segmentation fault|segfault|core dumped|coredump|fatal|'"
                "'TypeError|ReferenceError|Gtk-CRITICAL)' || true"
            ),
        }
        failures: dict[str, str] = {}
        for name, argv in checks.items():
            result = guest.exec(argv, timeout=30, check=False)
            output = "\n".join(
                part.strip() for part in (result.stdout, result.stderr) if part.strip()
            )
            if result.returncode != 0 or output:
                failures[name] = output[-8000:] or f"exit code {result.returncode}"
        return failures

    def _assert_graphical_health(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        settle_seconds = values.get("settle_seconds", 0)
        required_user_units = values.get("required_user_units", [])
        if (
            not isinstance(settle_seconds, int)
            or not 0 <= settle_seconds <= 600
            or not isinstance(required_user_units, list)
            or not all(
                isinstance(unit, str)
                and re.fullmatch(r"[A-Za-z0-9@_.:-]+\.service", unit)
                for unit in required_user_units
            )
        ):
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "assert_graphical_health has invalid configuration",
            )
        deadline = time.monotonic() + settle_seconds
        while True:
            failures = self._graphical_health_failures(record)
            if failures:
                raise VMError(
                    FailureCategory.DESKTOP_SESSION_FAILED,
                    "graphical session health assertions failed",
                    failures,
                )
            if time.monotonic() >= deadline:
                break
            time.sleep(min(10.0, max(0.0, deadline - time.monotonic())))

        inactive: list[str] = []
        for unit in required_user_units:
            result = self._guest(record).exec(
                self._graphical_shell(
                    f"systemctl --user is-active --quiet {shlex.quote(unit)}"
                ),
                timeout=15,
                check=False,
            )
            if result.returncode != 0:
                inactive.append(unit)
        if inactive:
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "required graphical autostart units are inactive",
                {"units": inactive},
            )

    def _capture_greetd_screenshot(self, record: dict[str, Any]) -> Path:
        """Capture the accelerated production greeter through Wayland."""
        remote = REMOTE_ARTIFACTS / "screenshots" / "greetd.png"
        guest = self._guest(record)
        guest.exec(["install", "-d", "-m", "0700", str(remote.parent)])
        shell = (
            "set -eu; "
            "uid=$(id -u greeter); runtime=/run/user/$uid; "
            'wayland=$(sudo find "$runtime" -maxdepth 1 -type s '
            "-name 'wayland-*' -printf '%f\\n' | LC_ALL=C sort | head -n1); "
            'test -n "$wayland"; '
            "capture_dir=$(mktemp -d /tmp/enoshima-greetd.XXXXXX); "
            'trap \'sudo unlink "$capture_dir/capture.png" 2>/dev/null || true; '
            'sudo rmdir "$capture_dir" 2>/dev/null || true\' EXIT; '
            'sudo chown greeter:greeter "$capture_dir"; '
            'sudo -u greeter env XDG_RUNTIME_DIR="$runtime" '
            'WAYLAND_DISPLAY="$wayland" '
            'grim "$capture_dir/capture.png"; '
            f"sudo install -o kentakang -g kentakang -m 0600 "
            f'"$capture_dir/capture.png" {remote}'
        )
        result = guest.exec(self._remote_shell(shell), timeout=60, check=False)
        if result.returncode:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "greetd compositor screenshot failed",
                {
                    "stdout": result.stdout[-3000:],
                    "stderr": result.stderr[-3000:],
                },
            )
        local = Path(record["artifact_dir"]) / "screenshots" / "greetd.png"
        guest.download(remote, local)
        self._validate_png(local)
        record.setdefault("observations", {})["greetd_screenshot"] = str(local)
        self._write_record(record)
        return local

    @staticmethod
    def _validate_png(path: Path) -> tuple[int, int]:
        header = path.read_bytes()[:24]
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "captured compositor evidence is not a PNG",
            )
        width, height = struct.unpack(">II", header[16:24])
        if width < 1280 or height < 720:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "captured compositor evidence is unexpectedly small",
                {"width": width, "height": height},
            )
        return width, height

    def screenshot(
        self,
        run_id: str,
        name: str = "desktop",
        output: str | None = None,
    ) -> dict[str, object]:
        if not re.fullmatch(r"[a-z0-9-]+", name):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid screenshot name")
        if output is not None and not re.fullmatch(r"[A-Za-z0-9._-]+", output):
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid screenshot output")
        record = self.load_record(run_id)
        remote = REMOTE_ARTIFACTS / "screenshots" / f"{name}.png"
        output_argument = f" -o {output}" if output else ""
        command = self._hypr_command(
            "wayland=$(find /run/user/$(id -u) -maxdepth 1 -type s "
            "-name 'wayland-*' -printf '%f\\n' | head -n1); "
            'test -n "$wayland"; export WAYLAND_DISPLAY=$wayland; '
            f"install -d -m 0700 {remote.parent}; grim{output_argument} {remote}"
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
        width, height = self._validate_png(local)
        self._audit("vm_screenshot", run_id=run_id)
        return {
            "path": str(local),
            "width": width,
            "height": height,
            "output": output,
        }

    def _write_ui_fixture_state(
        self,
        record: dict[str, Any],
        surface: str,
        state: str,
        output: str,
        extra: dict[str, object] | None = None,
    ) -> int:
        observations = record.setdefault("observations", {})
        sequence = int(observations.get("ui_fixture_sequence", 0)) + 1
        observations["ui_fixture_sequence"] = sequence
        fixture_dir = self._run_dir(record["run_id"]) / "ui-fixture"
        fixture_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        local = fixture_dir / "state.json"
        temporary = fixture_dir / "state.json.new"
        document: dict[str, object] = {
            "schema": 1,
            "surface": surface,
            "state": state,
            "output": output,
            "sequence": sequence,
        }
        if extra:
            document.update(extra)
        temporary.write_text(
            json.dumps(document, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        temporary.chmod(0o600)
        os.replace(temporary, local)
        guest = self._guest(record)
        remote_dir = REMOTE_ROOT / "ui-fixture"
        remote_new = remote_dir / "state.json.new"
        guest.exec(["install", "-d", "-m", "0700", str(remote_dir)])
        guest.upload_file(local, remote_new)
        guest.exec(["mv", "-f", str(remote_new), str(remote_dir / "state.json")])
        return sequence

    def _wait_for_ui_fixture_ready(
        self,
        record: dict[str, Any],
        sequence: int,
        *,
        timeout_seconds: float = 15,
    ) -> dict[str, object]:
        guest = self._guest(record)
        ready = REMOTE_ROOT / "ui-fixture" / "ready.json"
        deadline = time.monotonic() + timeout_seconds
        last_error = "ready file was not created"
        while time.monotonic() < deadline:
            result = guest.exec(["cat", str(ready)], timeout=5, check=False)
            if result.returncode == 0:
                try:
                    document = json.loads(result.stdout)
                    if (
                        document.get("schema") == 1
                        and int(document.get("sequence", 0)) == sequence
                    ):
                        overflow = document.get("text_overflow_count")
                        if not isinstance(overflow, int) or overflow < 0:
                            last_error = (
                                "fixture ACK lacks a valid text overflow count: "
                                f"{document!r}"
                            )
                        else:
                            missing_translations = document.get(
                                "missing_translation_count"
                            )
                            if (
                                not isinstance(missing_translations, int)
                                or missing_translations < 0
                            ):
                                last_error = (
                                    "fixture ACK lacks a valid missing translation "
                                    f"count: {document!r}"
                                )
                            elif missing_translations > 0:
                                raise VMError(
                                    FailureCategory.VISUAL_ASSERTION_FAILED,
                                    "production UI exposed untranslated catalog keys",
                                    {
                                        "sequence": sequence,
                                        "surface": document.get("surface"),
                                        "missing_translation_count": (
                                            missing_translations
                                        ),
                                    },
                                )
                            else:
                                return document
                    else:
                        last_error = f"stale fixture ACK: {document!r}"
                except (json.JSONDecodeError, TypeError, ValueError) as error:
                    last_error = f"invalid fixture ACK: {error}"
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "production UI did not acknowledge the requested review state",
            {"sequence": sequence, "reason": last_error},
        )

    def _capture_stable_ui(
        self,
        record: dict[str, Any],
        name: str,
        output: str,
        *,
        timeout_seconds: float = 8,
    ) -> dict[str, object]:
        deadline = time.monotonic() + timeout_seconds
        previous_hash = ""
        previous_path: Path | None = None
        last_capture: dict[str, object] | None = None
        while time.monotonic() < deadline:
            last_capture = self.screenshot(record["run_id"], name, output)
            image_path = Path(str(last_capture["path"]))
            current_hash = sha256(image_path.read_bytes()).hexdigest()
            if current_hash == previous_hash:
                last_capture["stability_changed_pixel_ratio"] = 0.0
                if previous_path is not None:
                    previous_path.unlink(missing_ok=True)
                return last_capture
            if previous_path is not None:
                comparison = subprocess.run(
                    [
                        "magick",
                        "compare",
                        "-metric",
                        "AE",
                        str(previous_path),
                        str(image_path),
                        "null:",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if comparison.returncode in {0, 1}:
                    try:
                        changed_pixels = float(comparison.stderr.strip())
                    except ValueError:
                        changed_pixels = -1
                    total_pixels = int(last_capture["width"]) * int(
                        last_capture["height"]
                    )
                    changed_ratio = changed_pixels / total_pixels
                    if 0 <= changed_ratio <= 0.0025:
                        last_capture["stability_changed_pixel_ratio"] = round(
                            changed_ratio, 8
                        )
                        previous_path.unlink(missing_ok=True)
                        return last_capture
            previous_hash = current_hash
            stable_probe = image_path.with_name(f".{image_path.name}.previous")
            shutil.copyfile(image_path, stable_probe)
            previous_path = stable_probe
            time.sleep(0.1)
        if previous_path is not None:
            previous_path.unlink(missing_ok=True)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "compositor output did not settle to two identical frames",
            {"name": name, "output": output, "last_capture": last_capture},
        )

    def _restart_ui_review_shell(
        self,
        record: dict[str, Any],
        locale: str,
    ) -> None:
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"}:
            raise VMError(FailureCategory.HARNESS_ERROR, "unsupported UI review locale")
        log_name = locale.replace(".", "-") + ".log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "wayland=$(find \"$runtime\" -maxdepth 1 -type s -name 'wayland-*' "
            "-printf '%f\\n' | LC_ALL=C sort | head -n1); test -n \"$wayland\"; "
            "pkill -TERM -x qs 2>/dev/null || true; "
            "for attempt in $(seq 1 50); do pgrep -x qs >/dev/null || break; "
            "sleep 0.1; done; ! pgrep -x qs >/dev/null; "
            f"install -d -m 0700 {REMOTE_ARTIFACTS}/ui-review; "
            f"nohup env LANG={locale} LC_ALL={locale} "
            "ENOSHIMA_VM_UI_TEST=1 "
            f"ENOSHIMA_UI_FIXTURE_DIR={REMOTE_ROOT}/ui-fixture "
            "PATH=/home/kentakang/.local/share/mise/shims:"
            "/home/kentakang/.local/bin:/usr/local/bin:/usr/bin "
            "XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$wayland "
            "HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE "
            "/usr/bin/qs -p /home/kentakang/.config/quickshell/cyberdock "
            f">{REMOTE_ARTIFACTS}/ui-review/{log_name} 2>&1 </dev/null &"
        )
        self._run_checked(
            record,
            "restart-ui-review-shell",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        self._wait_for_layer(
            record,
            {"namespace": "cyberdock", "timeout_seconds": 60},
        )

    def _stop_auth_review(self, record: dict[str, Any]) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / "auth.pid"
        shell = (
            f"if test -s {pid_path}; then "
            f"pid=$(cat {pid_path}); "
            "case $pid in (*[!0-9]*|'') exit 2;; esac; "
            "if test -e /proc/$pid/exe && "
            'test "$(readlink -f /proc/$pid/exe)" = /usr/bin/enoshima-greeter; '
            "then kill -TERM $pid; fi; "
            f"rm -f {pid_path}; fi"
        )
        self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    def _start_auth_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        allowed_states = {
            "password",
            "fingerprint-ready",
            "fingerprint-progress",
            "success",
            "failure",
            "caps-lock",
            "busy",
            "power-confirmation",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(FailureCategory.HARNESS_ERROR, "invalid Auth review state")
        self._stop_auth_review(record)
        pid_path = REMOTE_ROOT / "ui-fixture" / "auth.pid"
        log_path = REMOTE_ARTIFACTS / "ui-review" / "auth-review.log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "wayland=$(find \"$runtime\" -maxdepth 1 -type s -name 'wayland-*' "
            "-printf '%f\\n' | LC_ALL=C sort | head -n1); test -n \"$wayland\"; "
            f"nohup env LANG={locale} LC_ALL={locale} GDK_BACKEND=wayland "
            "ENOSHIMA_VM_UI_TEST=1 XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland /usr/bin/enoshima-greeter "
            f"--user kentakang --review-state {state} "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"start-auth-review-{state}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        deadline = time.monotonic() + 20
        last_clients: list[object] = []
        while time.monotonic() < deadline:
            result = self._guest(record).exec(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                last_clients = json.loads(result.stdout)
                if any(
                    str(client.get("title", "")) == "Enoshima Auth"
                    for client in last_clients
                ):
                    return
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "production Enoshima Greeter did not render its review state",
            {"state": state, "clients": last_clients},
        )

    def _stop_notification_review(self, record: dict[str, Any]) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / "swaync.pid"
        shell = (
            f"if test -s {pid_path}; then "
            f"pid=$(cat {pid_path}); "
            "case $pid in (*[!0-9]*|'') exit 2;; esac; "
            "if test -e /proc/$pid/exe && "
            'test "$(readlink -f /proc/$pid/exe)" = /usr/bin/swaync; '
            "then kill -TERM $pid; fi; "
            f"rm -f {pid_path}; fi"
        )
        self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    def _start_notification_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        allowed_states = {
            "default",
            "empty",
            "do-not-disturb",
            "notification",
            "critical",
            "action-error",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid notification review state"
            )
        self._stop_notification_review(record)
        pid_path = REMOTE_ROOT / "ui-fixture" / "swaync.pid"
        log_path = REMOTE_ARTIFACTS / "ui-review" / "swaync-review.log"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "export DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus; "
            "wayland=$(find \"$runtime\" -maxdepth 1 -type s -name 'wayland-*' "
            "-printf '%f\\n' | LC_ALL=C sort | head -n1); test -n \"$wayland\"; "
            "systemctl --user stop swaync.service; "
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus WAYLAND_DISPLAY=$wayland "
            "/home/kentakang/.local/bin/enoshima-swaync "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"start-notification-review-{state}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        guest = self._guest(record)
        ready_deadline = time.monotonic() + 20
        while time.monotonic() < ready_deadline:
            ready = guest.exec(
                self._hypr_command("swaync-client -D"), timeout=5, check=False
            )
            if ready.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "production SwayNC did not acquire its session bus",
                {"state": state},
            )

        guest.exec(
            self._hypr_command(
                "swaync-client -cp -sw; swaync-client -C -sw; swaync-client -df -sw"
            ),
            timeout=15,
        )
        korean = locale.startswith("ko")
        messages = {
            "default": (
                "Enoshima Desktop" if not korean else "Enoshima 데스크탑",
                (
                    "Your workspace is ready."
                    if not korean
                    else "작업 공간을 사용할 수 있습니다."
                ),
                "normal",
            ),
            "notification": (
                "Build finished" if not korean else "빌드 완료",
                (
                    "All checks passed successfully."
                    if not korean
                    else "모든 검증을 통과했습니다."
                ),
                "normal",
            ),
            "critical": (
                "Battery needs attention" if not korean else "배터리 확인 필요",
                (
                    "Connect power to continue safely."
                    if not korean
                    else "안전하게 계속하려면 전원을 연결하세요."
                ),
                "critical",
            ),
            "action-error": (
                (
                    "Action could not be completed"
                    if not korean
                    else "작업을 완료할 수 없음"
                ),
                (
                    "The requested action failed. Try again."
                    if not korean
                    else "요청한 작업이 실패했습니다. 다시 시도하세요."
                ),
                "critical",
            ),
        }
        if state == "do-not-disturb":
            guest.exec(self._hypr_command("swaync-client -dn -sw"), timeout=10)
        elif state not in {"empty"}:
            summary, body, urgency = messages[state]
            action_label = "다시 시도" if korean else "Retry"
            action = (
                f" --action=retry={shlex.quote(action_label)}"
                if state == "action-error"
                else ""
            )
            command = (
                "nohup notify-send --app-name=Enoshima "
                f"--urgency={urgency}{action} "
                f"{shlex.quote(summary)} {shlex.quote(body)} "
                ">/dev/null 2>&1 </dev/null &"
            )
            guest.exec(self._hypr_command(command), timeout=10)
            expected = 1
            count_deadline = time.monotonic() + 10
            while time.monotonic() < count_deadline:
                count = guest.exec(
                    self._hypr_command("swaync-client -c"), timeout=5, check=False
                )
                if count.returncode == 0 and int(count.stdout.strip() or 0) >= expected:
                    break
                time.sleep(0.1)
            else:
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "SwayNC did not render the requested notification",
                    {"state": state},
                )
        guest.exec(self._hypr_command("swaync-client -op -sw"), timeout=10)
        self._wait_for_layer(
            record,
            {"namespace": "swaync-control-center", "timeout_seconds": 20},
        )

    def _stop_titlebar_review(self, record: dict[str, Any]) -> None:
        for name in ("titlebar-primary.pid", "titlebar-secondary.pid"):
            pid_path = REMOTE_ROOT / "ui-fixture" / name
            shell = (
                f"if test -s {pid_path}; then "
                f"pid=$(cat {pid_path}); "
                "case $pid in (*[!0-9]*|'') exit 2;; esac; "
                "if test -e /proc/$pid/exe && "
                'test "$(readlink -f /proc/$pid/exe)" = '
                f"{REMOTE_ROOT}/ui-fixture/titlebar-window; "
                "then kill -TERM $pid; fi; "
                f"rm -f {pid_path}; fi"
            )
            self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)
        self.backend.pointer_button(record["domain"], "left", False)

    def _compile_titlebar_fixture(self, record: dict[str, Any]) -> None:
        binary = REMOTE_ROOT / "ui-fixture" / "titlebar-window"
        source = REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "titlebar-window.c"
        command = (
            f"test -x {binary} || cc -std=c17 -O2 -Wall -Wextra -Werror "
            f"$(pkg-config --cflags gtk4) {source} -o {binary} "
            "$(pkg-config --libs gtk4)"
        )
        self._run_checked(
            record,
            "compile-titlebar-fixture",
            self._remote_shell(command),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=120,
        )

    def _launch_titlebar_fixture(
        self,
        record: dict[str, Any],
        locale: str,
        pid_name: str,
    ) -> None:
        pid_path = REMOTE_ROOT / "ui-fixture" / pid_name
        log_path = REMOTE_ARTIFACTS / "ui-review" / f"{pid_name}.log"
        binary = REMOTE_ROOT / "ui-fixture" / "titlebar-window"
        shell = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "wayland=$(find \"$runtime\" -maxdepth 1 -type s -name 'wayland-*' "
            "-printf '%f\\n' | LC_ALL=C sort | head -n1); test -n \"$wayland\"; "
            f"nohup env LANG={locale} LC_ALL={locale} GDK_BACKEND=wayland "
            f"XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$wayland {binary} "
            f">{log_path} 2>&1 </dev/null & echo $! >{pid_path}"
        )
        self._run_checked(
            record,
            f"launch-{pid_name}",
            self._hypr_command(shell),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )

    def _titlebar_clients(self, record: dict[str, Any]) -> list[dict[str, Any]]:
        result = self._guest(record).exec(
            self._hypr_command("hyprctl -j clients"), timeout=10
        )
        return [
            client
            for client in json.loads(result.stdout)
            if str(client.get("class", "")) == "org.enoshima.TitlebarFixture"
            or str(client.get("initialClass", "")) == "org.enoshima.TitlebarFixture"
        ]

    def _wait_for_titlebar_clients(
        self,
        record: dict[str, Any],
        count: int,
    ) -> list[dict[str, Any]]:
        deadline = time.monotonic() + 20
        clients: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            clients = self._titlebar_clients(record)
            if len(clients) >= count:
                return clients
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "undecorated titlebar fixture did not become a Hyprland client",
            {"expected": count, "clients": clients},
        )

    def _start_titlebar_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> dict[str, Any]:
        allowed_states = {
            "active",
            "inactive",
            "keyboard-focus",
            "hover",
            "pressed",
            "maximized",
            "close-hover",
            "system-menu",
            "action-running",
            "action-error",
        }
        if locale not in {"en_US.UTF-8", "ko_KR.UTF-8"} or state not in allowed_states:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid system titlebar review state"
            )
        self._stop_titlebar_review(record)
        self._compile_titlebar_fixture(record)
        allowlist = "mpv,imv,org.pwmt.zathura,org.enoshima.TitlebarFixture"
        self._run_checked(
            record,
            "allow-titlebar-fixture",
            self._hypr_command(
                "hyprctl eval "
                + shlex.quote(self._decoration_allowlist_expression(allowlist))
            ),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=20,
        )
        self._launch_titlebar_fixture(record, locale, "titlebar-primary.pid")
        clients = self._wait_for_titlebar_clients(record, 1)
        primary = clients[-1]
        address = str(primary.get("address", ""))
        if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "titlebar fixture returned an invalid Hyprland address",
                {"client": primary},
            )
        guest = self._guest(record)
        guest.exec(
            self._hypr_command(f"hyprctl dispatch focuswindow address:{address}"),
            timeout=10,
        )
        if state == "inactive":
            self._launch_titlebar_fixture(record, locale, "titlebar-secondary.pid")
            clients = self._wait_for_titlebar_clients(record, 2)
            secondary = next(
                client for client in clients if client.get("address") != address
            )
            guest.exec(
                self._hypr_command(
                    "hyprctl dispatch focuswindow address:" + str(secondary["address"])
                ),
                timeout=10,
            )
        elif state == "maximized":
            guest.exec(
                self._hypr_command(
                    "desktop-window-action maximize --address "
                    f"{address} --origin vm-review --json"
                ),
                timeout=15,
            )
        if state in {"hover", "pressed", "close-hover"}:
            current = next(
                client
                for client in self._titlebar_clients(record)
                if client.get("address") == address
            )
            at = current.get("at", [0, 0])
            size = current.get("size", [900, 560])
            button_offset = 22 if state == "close-hover" else 72
            cursor_x = int(at[0]) + int(size[0]) - button_offset
            cursor_y = max(4, int(at[1]) - 18)
            guest.exec(
                self._hypr_command(
                    f"hyprctl dispatch movecursor {cursor_x} {cursor_y}"
                ),
                timeout=10,
            )
            if state == "pressed":
                self.backend.pointer_button(record["domain"], "left", True)
        return primary

    def _stop_desktop_shell_review(self, record: dict[str, Any]) -> None:
        for name, executable in (
            ("desktop-ghostty.pid", "/usr/bin/ghostty"),
            ("desktop-thunar.pid", "/usr/bin/thunar"),
        ):
            pid_path = REMOTE_ROOT / "ui-fixture" / name
            shell = (
                f"if test -s {pid_path}; then "
                f"pid=$(cat {pid_path}); "
                "case $pid in (*[!0-9]*|'') exit 2;; esac; "
                "if test -e /proc/$pid/exe && "
                f'test "$(readlink -f /proc/$pid/exe)" = {executable}; '
                "then kill -TERM $pid; fi; "
                f"rm -f {pid_path}; fi"
            )
            self._guest(record).exec(self._remote_shell(shell), timeout=15, check=False)

    @staticmethod
    def _ui_review_cleanup_targets(clients: list[object]) -> list[dict[str, Any]]:
        targets: list[dict[str, Any]] = []
        for value in clients:
            if not isinstance(value, dict):
                continue
            workspace = value.get("workspace")
            workspace_name = (
                str(workspace.get("name", "")) if isinstance(workspace, dict) else ""
            )
            # xembed-sni-proxy owns a tiny XWayland client on this reserved
            # workspace so legacy tray icons can be surfaced by the shell.
            # It is desktop infrastructure, not an application left behind
            # by a review scenario, and closing it would damage the session
            # that the remaining real-compositor cases must inspect.
            if workspace_name == "special:tray":
                continue
            targets.append(value)
        return targets

    def _close_ui_review_clients(self, record: dict[str, Any]) -> None:
        guest = self._guest(record)
        result = guest.exec(
            self._hypr_command("hyprctl -j clients"), timeout=15, check=False
        )
        if result.returncode != 0:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "cannot enumerate desktop clients before UI review",
            )
        clients = json.loads(result.stdout)
        targets = self._ui_review_cleanup_targets(clients)
        for client in targets:
            address = str(client.get("address", ""))
            if not re.fullmatch(r"0x[0-9a-fA-F]+", address):
                continue
            guest.exec(
                self._hypr_command(
                    "desktop-window-action close --address "
                    f"{address} --origin vm-review --json"
                ),
                timeout=15,
                check=False,
            )
        deadline = time.monotonic() + 15
        remaining: list[object] = targets
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                remaining = self._ui_review_cleanup_targets(json.loads(result.stdout))
                if not remaining:
                    return
            time.sleep(0.1)
        raise VMError(
            FailureCategory.VISUAL_ASSERTION_FAILED,
            "desktop clients remained after graceful UI-review cleanup",
            {"clients": remaining},
        )

    def _reset_ui_review_surface(self, record: dict[str, Any]) -> None:
        """Remove every prior review surface and late session-start client.

        Desktop autostart applications can become mapped after the initial
        review cleanup.  Resetting at every surface boundary prevents those
        clients from tiling a greeter or obscuring a shell capture while still
        preserving the reserved XEmbed tray infrastructure.
        """
        self._stop_auth_review(record)
        self._stop_notification_review(record)
        self._stop_titlebar_review(record)
        self._stop_desktop_shell_review(record)
        self._close_ui_review_clients(record)

    def _start_desktop_shell_review(
        self,
        record: dict[str, Any],
        locale: str,
        state: str,
    ) -> None:
        if state not in {
            "default",
            "active-window",
            "inactive-window",
            "internal-display",
            "external-display",
        }:
            raise VMError(
                FailureCategory.HARNESS_ERROR, "invalid desktop shell review state"
            )
        self._stop_desktop_shell_review(record)
        guest = self._guest(record)
        log_root = REMOTE_ARTIFACTS / "ui-review"
        launch = (
            "set -eu; uid=$(id -u); runtime=/run/user/$uid; "
            "export XDG_RUNTIME_DIR=$runtime; "
            "wayland=$(find \"$runtime\" -maxdepth 1 -type s -name 'wayland-*' "
            "-printf '%f\\n' | LC_ALL=C sort | head -n1); test -n \"$wayland\"; "
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland ghostty --title='Enoshima Workspace' "
            '-e sh -lc \'printf "ENOSHIMA // WORKSPACE\\n\\nVM visual review\\n"; '
            f"exec sleep infinity' >{log_root}/desktop-ghostty.log 2>&1 "
            f"</dev/null & echo $! >{REMOTE_ROOT}/ui-fixture/desktop-ghostty.pid; "
            f"nohup env LANG={locale} LC_ALL={locale} XDG_RUNTIME_DIR=$runtime "
            "WAYLAND_DISPLAY=$wayland thunar --window /home/kentakang "
            f">{log_root}/desktop-thunar.log 2>&1 </dev/null & "
            f"echo $! >{REMOTE_ROOT}/ui-fixture/desktop-thunar.pid"
        )
        self._run_checked(
            record,
            f"start-desktop-shell-review-{state}",
            self._hypr_command(launch),
            FailureCategory.VISUAL_ASSERTION_FAILED,
            timeout_seconds=30,
        )
        expected = {
            "ghostty": re.compile(r"ghostty", re.IGNORECASE),
            "thunar": re.compile(r"thunar", re.IGNORECASE),
        }
        found: dict[str, dict[str, Any]] = {}
        deadline = time.monotonic() + 30
        last_clients: list[dict[str, Any]] = []
        while time.monotonic() < deadline:
            result = guest.exec(
                self._hypr_command("hyprctl -j clients"), timeout=10, check=False
            )
            if result.returncode == 0:
                last_clients = json.loads(result.stdout)
                for key, matcher in expected.items():
                    for client in last_clients:
                        identity = " ".join(
                            str(client.get(field, ""))
                            for field in ("class", "initialClass", "title")
                        )
                        if matcher.search(identity):
                            found[key] = client
                            break
                if len(found) == len(expected):
                    break
            time.sleep(0.1)
        else:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "desktop shell review applications did not open",
                {"found": sorted(found), "clients": last_clients},
            )
        for client in found.values():
            address = str(client["address"])
            guest.exec(
                self._hypr_command(
                    f"hyprctl dispatch movetoworkspacesilent 1,address:{address}"
                ),
                timeout=10,
            )
        guest.exec(self._hypr_command("hyprctl dispatch workspace 1"), timeout=10)
        focus_key = "thunar" if state == "inactive-window" else "ghostty"
        guest.exec(
            self._hypr_command(
                "hyprctl dispatch focuswindow address:"
                + str(found[focus_key]["address"])
            ),
            timeout=10,
        )

    def _run_ui_review(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        requested = values.get("surfaces")
        if not isinstance(requested, list) or not requested:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "run_ui_review requires a non-empty surface list",
            )
        supported = {
            "auth",
            "desktop-shell",
            "launcher",
            "notification-center",
            "power-menu",
            "osd",
            "display-mode",
            "cyberdock-window-state",
            "snap-assist",
            "system-titlebar",
        }
        surfaces = {str(value) for value in requested}
        unsupported = surfaces - supported
        if unsupported:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "UI review surface lacks a real compositor adapter",
                {"surfaces": sorted(unsupported)},
            )
        matrix = [
            case
            for case in load_ui_review_matrix(self.paths.repository)
            if case.surface in surfaces
        ]
        matrix.sort(
            key=lambda case: (case.locale, case.scale, case.surface, case.state)
        )
        if not matrix:
            raise VMError(FailureCategory.HARNESS_ERROR, "UI review matrix is empty")
        identities = load_ui_review_identities(self.paths.repository, surfaces)
        artifact_root = Path(record["artifact_dir"]) / "ui-review"
        artifact_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._close_ui_review_clients(record)
        output = "HEADLESS-UI"
        captures: list[dict[str, object]] = []
        overflow_failures: list[dict[str, object]] = []
        current_environment: tuple[str, float] | None = None
        for case in matrix:
            fixture_ack: dict[str, object] | None = None
            environment = (case.locale, case.scale)
            if environment != current_environment:
                mode = physical_mode(case.scale)
                self._configure_virtual_displays(
                    record,
                    {
                        "disable_unlisted": True,
                        "monitors": [
                            {
                                "name": output,
                                "mode": mode,
                                "position": "0x0",
                                "scale": f"{case.scale:g}",
                            }
                        ],
                    },
                )
                sequence = self._write_ui_fixture_state(
                    record, "desktop-shell", "default", output
                )
                self._restart_ui_review_shell(record, case.locale)
                self._wait_for_ui_fixture_ready(record, sequence)
                current_environment = environment
            self._reset_ui_review_surface(record)
            if case.surface == "auth":
                self._start_auth_review(record, case.locale, case.state)
            elif case.surface == "notification-center":
                self._start_notification_review(record, case.locale, case.state)
            elif case.surface == "system-titlebar":
                client = self._start_titlebar_review(record, case.locale, case.state)
                sequence = self._write_ui_fixture_state(
                    record,
                    case.surface,
                    case.state,
                    output,
                    {"address": str(client["address"])},
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
            elif case.surface == "desktop-shell":
                self._start_desktop_shell_review(record, case.locale, case.state)
                sequence = self._write_ui_fixture_state(
                    record, case.surface, case.state, output
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
            else:
                sequence = self._write_ui_fixture_state(
                    record, case.surface, case.state, output
                )
                fixture_ack = self._wait_for_ui_fixture_ready(record, sequence)
            capture = self._capture_stable_ui(record, case.artifact_name, output)
            if case.surface == "system-titlebar":
                self.backend.pointer_button(record["domain"], "left", False)
            expected_width, expected_height = (
                int(value)
                for value in physical_mode(case.scale).split("@", 1)[0].split("x")
            )
            if (capture["width"], capture["height"]) != (
                expected_width,
                expected_height,
            ):
                raise VMError(
                    FailureCategory.VISUAL_ASSERTION_FAILED,
                    "UI review capture has the wrong output dimensions",
                    {"case": case.key, "capture": capture},
                )
            image_path = Path(str(capture["path"]))
            fixture_metadata = {
                "auth": {
                    "used": True,
                    "reason": "production greeter with deterministic visual auth state",
                },
                "notification-center": {
                    "used": False,
                    "reason": "production SwayNC and notification D-Bus state",
                },
                "system-titlebar": {
                    "used": True,
                    "reason": (
                        "production native decoration on a real undecorated client; "
                        "deterministic menu result state where required"
                    ),
                },
            }.get(
                case.surface,
                {
                    "used": True,
                    "reason": "deterministic production-model state injection",
                },
            )
            sidecar = {
                "schema": 1,
                "surface_id": case.surface,
                "state": case.state,
                "locale": case.locale,
                "scale": case.scale,
                "output": output,
                "logical_size": [1280, 800],
                "pixel_size": [capture["width"], capture["height"]],
                "stability_changed_pixel_ratio": capture.get(
                    "stability_changed_pixel_ratio", 0.0
                ),
                "image": str(image_path),
                "image_sha256": sha256(image_path.read_bytes()).hexdigest(),
                "run_id": record["run_id"],
                "source_commit": record.get("source", {}).get("source_commit"),
                "worktree_hash": record.get("source", {}).get("worktree_hash"),
                **identities[case.surface],
                "text_overflow_count": (
                    fixture_ack.get("text_overflow_count")
                    if fixture_ack is not None
                    else None
                ),
                "fixture": fixture_metadata,
            }
            sidecar_path = artifact_root / f"{case.artifact_name}.json"
            sidecar_path.write_text(
                json.dumps(sidecar, indent=2) + "\n", encoding="utf-8"
            )
            captures.append(sidecar)
            if fixture_ack is not None and int(fixture_ack["text_overflow_count"]) > 0:
                overflow_failures.append(
                    {
                        "case": case.key,
                        "count": int(fixture_ack["text_overflow_count"]),
                        "image": str(image_path),
                    }
                )
        summary = {
            "schema": 1,
            "expected": len(matrix),
            "actual": len(captures),
            "surfaces": sorted(surfaces),
            "locales": sorted({case.locale for case in matrix}),
            "scales": sorted({case.scale for case in matrix}),
            "text_overflow_failures": overflow_failures,
        }
        (artifact_root / "summary.json").write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8"
        )
        record.setdefault("observations", {})["ui_review"] = summary
        self._stop_auth_review(record)
        self._stop_notification_review(record)
        self._stop_titlebar_review(record)
        self._stop_desktop_shell_review(record)
        self._guest(record).exec(
            self._hypr_command("systemctl --user start swaync.service"),
            timeout=30,
            check=False,
        )
        self._write_record(record)
        if overflow_failures:
            raise VMError(
                FailureCategory.VISUAL_ASSERTION_FAILED,
                "UI review found visible text outside its allocated bounds",
                {
                    "count": len(overflow_failures),
                    "failures": overflow_failures[:20],
                },
            )

    def _run_electron_qualification(self, record: dict[str, Any], config: Any) -> None:
        values = config if isinstance(config, dict) else {}
        iterations = int(values.get("iterations", 20))
        if not 1 <= iterations <= 100:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "Electron qualification iterations must be between 1 and 100",
            )
        output = REMOTE_ARTIFACTS / "electron-qualification"
        fixture = REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "electron-window"
        driver = (
            REMOTE_SOURCE / "tests" / "vm" / "fixtures" / "electron-qualification.py"
        )
        command = (
            f"install -d -m 0700 {output}; "
            f"python3 {driver} --fixture-root {fixture} --output {output} "
            f"--iterations {iterations}"
        )
        guest = self._guest(record)
        current = guest.exec(
            self._hypr_command(
                "hyprctl -j getoption plugin:enoshima_decoration:allowlist"
            ),
            timeout=20,
        )
        current_allowlist = str(json.loads(current.stdout).get("str", ""))
        try:
            self._run_checked(
                record,
                "electron-qualification",
                self._hypr_command(command),
                FailureCategory.DESKTOP_SESSION_FAILED,
                timeout_seconds=3600,
            )
        finally:
            guest.exec(
                self._hypr_command(
                    "hyprctl eval "
                    + shlex.quote(
                        self._decoration_allowlist_expression(current_allowlist)
                    )
                ),
                timeout=20,
                check=False,
            )
        summary = self._guest(record).exec(
            ["cat", str(output / "electron-summary.json")],
            timeout=15,
        )
        document = json.loads(summary.stdout)
        expected_actions = 2 * 3 * iterations * 10
        fallback_probes = document.get("nativeFallbackProbes")
        if (
            document.get("failures") != 0
            or document.get("combinations") != 6
            or document.get("actions") != expected_actions
            or document.get("decorationOwner") != "enoshima-system"
            or document.get("clientNativeMinimizeExposed") is not False
            or not isinstance(fallback_probes, list)
            or len(fallback_probes) != 2
            or {
                probe.get("backend")
                for probe in fallback_probes
                if isinstance(probe, dict)
            }
            != {"wayland", "x11"}
            or any(
                probe.get("backend") not in {"wayland", "x11"}
                or probe.get("processAlive") is not True
                or probe.get("workspaceUnchanged") is not True
                or probe.get("enoshimaDecorationAbsent") is not True
                for probe in fallback_probes
                if isinstance(probe, dict)
            )
            or any(not isinstance(probe, dict) for probe in fallback_probes)
            or document.get("coredumps")
        ):
            raise VMError(
                FailureCategory.DESKTOP_SESSION_FAILED,
                "Electron qualification summary is incomplete",
                {"summary": document, "expected_actions": expected_actions},
            )
        record.setdefault("observations", {})["electron_qualification"] = document
        self._write_record(record)

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
        record.pop("login_password", None)
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
        elif action == "reboot_via_desktop_power":
            self._reboot_via_desktop_power(record, config)
        elif action == "configure_virtual_displays":
            self._configure_virtual_displays(record, config)
        elif action == "wait_for_client":
            self._wait_for_client(record, config)
        elif action == "assert_desktop_state":
            self._assert_desktop_state(record, config)
        elif action == "wait_for_layer":
            self._wait_for_layer(record, config)
        elif action == "prepare_login":
            self._prepare_login(record)
        elif action == "login_greetd":
            self._login_greetd(record)
        elif action == "assert_graphical_health":
            self._assert_graphical_health(record, config)
        elif action == "send_key":
            if not isinstance(config, dict) or not isinstance(config.get("keys"), list):
                raise VMError(FailureCategory.HARNESS_ERROR, "send_key requires keys")
            keys = [str(key) for key in config["keys"]]
            self.backend.send_keys(record["domain"], keys)
        elif action == "send_pointer":
            if not isinstance(config, dict):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    "send_pointer requires a mapping",
                )
            if "x" in config or "y" in config:
                if not isinstance(config.get("x"), int) or not isinstance(
                    config.get("y"), int
                ):
                    raise VMError(
                        FailureCategory.HARNESS_ERROR,
                        "send_pointer requires integer x and y coordinates",
                    )
                self.backend.pointer_move_absolute(
                    record["domain"], int(config["x"]), int(config["y"])
                )
            if "button" in config:
                self.backend.pointer_button(
                    record["domain"],
                    str(config["button"]),
                    bool(config.get("down", False)),
                )
        elif action == "query_desktop":
            desktop = self.query_desktop(record["run_id"])
            path = Path(record["artifact_dir"]) / "hyprctl" / "desktop.json"
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(json.dumps(desktop, indent=2) + "\n", encoding="utf-8")
        elif action == "screenshot":
            values = config if isinstance(config, dict) else {}
            output = values.get("output")
            self.screenshot(
                record["run_id"],
                str(values.get("name", "desktop")),
                str(output) if output is not None else None,
            )
        elif action == "run_ui_review":
            self._run_ui_review(record, config)
        elif action == "run_electron_qualification":
            self._run_electron_qualification(record, config)
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
                step_started = time.monotonic()
                try:
                    self._execute_step(record, suite, action, config)
                except Exception:
                    record = self.load_record(record["run_id"])
                    record.setdefault("steps", []).append(
                        {
                            "index": index,
                            "action": action,
                            "status": "failed",
                            "duration_seconds": round(
                                time.monotonic() - step_started, 3
                            ),
                        }
                    )
                    self._write_record(record)
                    raise
                record = self.load_record(record["run_id"])
                record.setdefault("steps", []).append(
                    {
                        "index": index,
                        "action": action,
                        "status": "passed",
                        "duration_seconds": round(time.monotonic() - step_started, 3),
                    }
                )
                self._write_record(record)
            record = self.load_record(record["run_id"])
            record["result"] = "passed"
            record["status"] = "passed"
            record["category"] = None
            record["updated_at"] = utc_now()
            self._write_record(record)
            self._write_junit(record)
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
            self._write_junit(record)
            try:
                self.collect(record["run_id"])
            except Exception as collection_error:
                record["collection_error"] = str(collection_error)
                self._write_record(record)
            if not keep_on_failure:
                self.destroy(record["run_id"])
            raise
