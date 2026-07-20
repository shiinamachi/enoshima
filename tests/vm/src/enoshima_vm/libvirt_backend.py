from __future__ import annotations

import shutil
import socket
import time
from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from .config import DOMAIN_PREFIX, MAX_ACTIVE_DOMAINS, RuntimePaths, Suite
from .errors import FailureCategory, VMError
from .process import CommandResult, run
from .security import require_domain


@dataclass(frozen=True, slots=True)
class DomainSpec:
    run_id: str
    domain: str
    overlay: Path
    seed: Path
    ssh_host_port: int
    xml: Path


def allocate_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


class LibvirtBackend:
    def __init__(self, paths: RuntimePaths, uri: str = "qemu:///session") -> None:
        self.paths = paths
        self.uri = uri
        self.environment = Environment(
            loader=FileSystemLoader(paths.project / "templates"),
            autoescape=True,
            undefined=StrictUndefined,
            keep_trailing_newline=True,
        )

    def virsh(
        self,
        args: list[str | Path],
        *,
        timeout: float = 60,
        check: bool = True,
    ) -> CommandResult:
        return run(
            ["virsh", "--connect", self.uri, *args],
            timeout=timeout,
            check=check,
        )

    def active_managed_domains(self) -> list[str]:
        output = self.virsh(["list", "--state-running", "--name"]).stdout
        return [name for name in output.splitlines() if name.startswith(DOMAIN_PREFIX)]

    def preflight(self, suite: Suite) -> dict[str, object]:
        required = ["virsh", "qemu-img", "ssh", "scp", "ssh-keygen", "tar", "gpgv"]
        missing = [command for command in required if not shutil.which(command)]
        if not shutil.which("cloud-localds") and not shutil.which("xorriso"):
            missing.append("cloud-localds|xorriso")
        kvm = Path("/dev/kvm")
        checks = {
            "commands": {command: shutil.which(command) for command in required},
            "kvm_readable": kvm.exists() and os_access(kvm),
            "libvirt_uri": self.uri,
            "resources": {
                "vcpus": suite.resources.vcpus,
                "memory_mib": suite.resources.memory_mib,
                "disk_gib": suite.resources.disk_gib,
            },
        }
        if missing:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "VM host dependencies are missing",
                {"missing": missing, "checks": checks},
            )
        if not checks["kvm_readable"]:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "/dev/kvm is not readable and writable",
                checks,
            )
        try:
            self.virsh(["uri"], timeout=15)
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"libvirt connection is unavailable: {self.uri}",
                {"error": str(error), "checks": checks},
            ) from error
        return checks

    def prepare_domain(
        self,
        run_dir: Path,
        run_id: str,
        suite: Suite,
        base_image: Path,
        seed: Path,
    ) -> DomainSpec:
        active = self.active_managed_domains()
        if len(active) >= MAX_ACTIVE_DOMAINS:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "maximum active Enoshima VM count reached",
                {"active": active, "maximum": MAX_ACTIVE_DOMAINS},
            )
        domain = require_domain(f"{DOMAIN_PREFIX}{run_id}")
        overlay = run_dir / "root.qcow2"
        try:
            run(
                [
                    "qemu-img",
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    base_image,
                    overlay,
                ],
                timeout=60,
            )
            run(
                ["qemu-img", "resize", overlay, f"{suite.resources.disk_gib}G"],
                timeout=60,
            )
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "cannot create the disposable qcow2 overlay",
                {"error": str(error)},
            ) from error

        ssh_host_port = allocate_loopback_port()
        xml_path = run_dir / "domain.xml"
        template = self.environment.get_template(suite.domain_template)
        xml_path.write_text(
            template.render(
                domain=domain,
                memory_mib=suite.resources.memory_mib,
                vcpus=suite.resources.vcpus,
                overlay=overlay,
                seed=seed,
                ssh_host_port=ssh_host_port,
                run_dir=run_dir,
            ),
            encoding="utf-8",
        )
        xml_path.chmod(0o600)
        return DomainSpec(run_id, domain, overlay, seed, ssh_host_port, xml_path)

    def define_and_start(self, spec: DomainSpec) -> None:
        try:
            self.virsh(["define", spec.xml])
            self.virsh(["start", spec.domain], timeout=60)
        except Exception as error:
            raise VMError(
                FailureCategory.VM_BOOT_ERROR,
                f"cannot start domain {spec.domain}",
                {"error": str(error)},
            ) from error

    def state(self, domain: str) -> str:
        require_domain(domain)
        result = self.virsh(["domstate", domain], check=False)
        if result.returncode:
            return "undefined"
        return result.stdout.strip().lower()

    def wait_guest_agent(self, domain: str, timeout_seconds: int = 300) -> None:
        require_domain(domain)
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            result = self.virsh(
                ["qemu-agent-command", domain, '{"execute":"guest-ping"}'],
                timeout=10,
                check=False,
            )
            if result.returncode == 0:
                return
            time.sleep(2)
        raise VMError(
            FailureCategory.GUEST_AGENT_TIMEOUT,
            f"guest agent did not become ready for {domain}",
        )

    def reboot(self, domain: str) -> None:
        require_domain(domain)
        self.virsh(["reboot", domain, "--mode", "agent"], timeout=30)

    def poweroff(self, domain: str) -> None:
        require_domain(domain)
        self.virsh(["shutdown", domain, "--mode", "agent"], timeout=30, check=False)

    def send_keys(self, domain: str, keys: list[str]) -> None:
        require_domain(domain)
        self.virsh(["send-key", domain, *keys], timeout=30)

    def screenshot(self, domain: str, destination: Path) -> None:
        require_domain(domain)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.virsh(["screenshot", domain, destination], timeout=30)

    def destroy(self, domain: str) -> None:
        require_domain(domain)
        if self.state(domain) not in {"undefined", "shut off", "shutoff"}:
            self.virsh(["destroy", domain], timeout=30, check=False)
        self.virsh(["undefine", domain, "--nvram"], timeout=30, check=False)


def os_access(path: Path) -> bool:
    import os

    return os.access(path, os.R_OK | os.W_OK)
