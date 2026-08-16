from __future__ import annotations

import json
import os
import pty
import pwd
import select
import shutil
import socket
import stat
import subprocess
import termios
import time
import tty
import uuid
from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from .config import DOMAIN_PREFIX, MAX_ACTIVE_DOMAINS, RuntimePaths, Suite
from .errors import FailureCategory, VMError
from .process import CommandResult, run
from .security import confined_path, require_domain


@dataclass(frozen=True, slots=True)
class DomainSpec:
    run_id: str
    domain: str
    domain_uuid: str
    overlay: Path
    seed: Path
    ssh_host_port: int
    xml: Path
    boot_disk: Path | None = None


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

    def session_identity(self) -> dict[str, object]:
        uid = os.getuid()
        home = Path(pwd.getpwuid(uid).pw_dir)
        runtime = Path(f"/run/user/{uid}")
        try:
            runtime_stat = runtime.stat()
        except OSError as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"canonical desktop runtime is unavailable: {runtime}",
                {"error": str(error)},
            ) from error
        if not runtime.is_dir() or runtime.is_symlink() or runtime_stat.st_uid != uid:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"canonical desktop runtime is unsafe: {runtime}",
            )
        if stat.S_IMODE(runtime_stat.st_mode) != 0o700:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"canonical desktop runtime has unsafe permissions: {runtime}",
            )
        return {
            "uri": self.uri,
            "uid": uid,
            "runtimeDir": str(runtime),
            "socketPath": str(runtime / "libvirt" / "virtqemud-sock"),
            "configHome": str(home / ".config"),
            "cacheHome": str(home / ".cache"),
        }

    def _session_environment(self) -> dict[str, str]:
        identity = self.session_identity()
        environment = dict(os.environ)
        environment.update(
            {
                "HOME": str(Path(str(identity["configHome"])).parent),
                "XDG_RUNTIME_DIR": str(identity["runtimeDir"]),
                "XDG_CONFIG_HOME": str(identity["configHome"]),
                "XDG_CACHE_HOME": str(identity["cacheHome"]),
            }
        )
        return environment

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
            env=self._session_environment(),
        )

    def active_managed_domains(self) -> list[str]:
        output = self.virsh(["list", "--state-running", "--name"]).stdout
        return [name for name in output.splitlines() if name.startswith(DOMAIN_PREFIX)]

    def preflight(self, suite: Suite) -> dict[str, object]:
        required = [
            "virsh",
            "qemu-img",
            "ssh",
            "scp",
            "ssh-keygen",
            "tar",
            "gpg",
            "gpgv",
        ]
        if suite.domain_template == "domain-secure-boot.xml.j2":
            required.append("swtpm")
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
                FailureCategory.HOST_INFRA_ERROR,
                "VM host dependencies are missing",
                {"missing": missing, "checks": checks},
            )
        if not checks["kvm_readable"]:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "/dev/kvm is not readable and writable",
                checks,
            )
        try:
            self.virsh(["uri"], timeout=15)
        except Exception as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"libvirt connection is unavailable: {self.uri}",
                {"error": str(error), "checks": checks},
            ) from error
        return checks

    def prepare_domain(
        self,
        run_dir: Path,
        run_id: str,
        domain_uuid: str,
        suite: Suite,
        base_image: Path,
        seed: Path,
    ) -> DomainSpec:
        active = self.active_managed_domains()
        if len(active) >= MAX_ACTIVE_DOMAINS:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "maximum active Enoshima VM count reached",
                {"active": active, "maximum": MAX_ACTIVE_DOMAINS},
            )
        domain = require_domain(f"{DOMAIN_PREFIX}{run_id}")
        domain_uuid = str(uuid.UUID(domain_uuid))
        overlay = run_dir / "root.qcow2"
        boot_disk: Path | None = None
        overlay_gib = (
            16
            if suite.domain_template == "domain-secure-boot.xml.j2"
            else suite.resources.disk_gib
        )
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
                ["qemu-img", "resize", overlay, f"{overlay_gib}G"],
                timeout=60,
            )
            if suite.domain_template == "domain-secure-boot.xml.j2":
                boot_disk = run_dir / "boot.qcow2"
                run(
                    [
                        "qemu-img",
                        "create",
                        "-f",
                        "qcow2",
                        boot_disk,
                        f"{suite.resources.disk_gib}G",
                    ],
                    timeout=60,
                )
        except Exception as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "cannot create the disposable qcow2 overlay",
                {"error": str(error)},
            ) from error

        ssh_host_port = allocate_loopback_port()
        xml_path = run_dir / "domain.xml"
        template = self.environment.get_template(suite.domain_template)
        xml_path.write_text(
            template.render(
                domain=domain,
                domain_uuid=domain_uuid,
                memory_mib=suite.resources.memory_mib,
                vcpus=suite.resources.vcpus,
                overlay=overlay,
                seed=seed,
                ssh_host_port=ssh_host_port,
                run_dir=run_dir,
                boot_disk=boot_disk,
            ),
            encoding="utf-8",
        )
        xml_path.chmod(0o600)
        return DomainSpec(
            run_id,
            domain,
            domain_uuid,
            overlay,
            seed,
            ssh_host_port,
            xml_path,
            boot_disk,
        )

    def define_and_start(self, spec: DomainSpec) -> None:
        try:
            self.virsh(["define", spec.xml])
            self.virsh(["start", spec.domain_uuid], timeout=60)
        except Exception as error:
            details: dict[str, object] = {"error": str(error)}
            if isinstance(error, subprocess.CalledProcessError):
                details.update(
                    {
                        "argv": list(error.cmd),
                        "returncode": error.returncode,
                        "stdout": error.stdout or "",
                        "stderr": error.stderr or "",
                    }
                )
            raise VMError(
                FailureCategory.VM_BOOT_ERROR,
                f"cannot start domain {spec.domain}",
                details,
            ) from error

    def state(self, domain: str) -> str:
        require_domain(domain)
        domains = {
            name
            for name in self.virsh(
                ["list", "--all", "--name"], timeout=30
            ).stdout.splitlines()
            if name
        }
        if domain not in domains:
            return "undefined"
        result = self.virsh(["domstate", domain], timeout=30, check=False)
        state = result.stdout.strip().lower()
        if result.returncode == 0 and state:
            return state
        remaining = {
            name
            for name in self.virsh(
                ["list", "--all", "--name"], timeout=30
            ).stdout.splitlines()
            if name
        }
        if domain not in remaining:
            return "undefined"
        raise VMError(
            FailureCategory.HOST_INFRA_ERROR,
            f"cannot query managed domain state: {domain}",
            {
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            },
        )

    def owned_state(self, domain: str, domain_uuid: str) -> str:
        require_domain(domain)
        expected_uuid = str(uuid.UUID(domain_uuid))
        owned_state = self._uuid_state(expected_uuid)
        resolved = self.virsh(["domuuid", domain], timeout=30, check=False)
        if resolved.returncode == 0:
            actual_uuid = resolved.stdout.strip().lower()
            if actual_uuid != expected_uuid:
                raise VMError(
                    FailureCategory.HOST_INFRA_ERROR,
                    "managed domain UUID does not match the recorded run owner; "
                    "preserving the domain and ephemeral storage",
                    {
                        "domain": domain,
                        "recordedUuid": expected_uuid,
                        "actualUuid": actual_uuid,
                    },
                )
            if owned_state == "undefined":
                raise VMError(
                    FailureCategory.HOST_INFRA_ERROR,
                    "managed domain name resolved to the recorded UUID but the "
                    "UUID inventory was inconsistent; preserving ephemeral storage",
                    {"domain": domain, "recordedUuid": expected_uuid},
                )
            return owned_state
        if owned_state != "undefined":
            return owned_state
        if self.state(domain) == "undefined":
            return "undefined"
        raise VMError(
            FailureCategory.HOST_INFRA_ERROR,
            f"cannot resolve managed domain UUID: {domain}",
            {
                "returncode": resolved.returncode,
                "stdout": resolved.stdout,
                "stderr": resolved.stderr,
            },
        )

    def _uuid_state(self, domain_uuid: str) -> str:
        target = str(uuid.UUID(domain_uuid))
        domains = {
            value
            for value in self.virsh(
                ["list", "--all", "--uuid"], timeout=30
            ).stdout.splitlines()
            if value
        }
        if target not in domains:
            return "undefined"
        result = self.virsh(["domstate", target], timeout=30, check=False)
        state = result.stdout.strip().lower()
        if result.returncode == 0 and state:
            return state
        remaining = {
            value
            for value in self.virsh(
                ["list", "--all", "--uuid"], timeout=30
            ).stdout.splitlines()
            if value
        }
        if target not in remaining:
            return "undefined"
        raise VMError(
            FailureCategory.HOST_INFRA_ERROR,
            f"cannot query managed domain UUID state: {target}",
            {
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            },
        )

    def _owned_target(self, domain: str, domain_uuid: str) -> str:
        state = self.owned_state(domain, domain_uuid)
        target = str(uuid.UUID(domain_uuid))
        if state == "undefined":
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"recorded managed domain is undefined: {domain}",
                {"domain": domain, "recordedUuid": target},
            )
        return target

    def wait_guest_agent(
        self,
        domain: str,
        domain_uuid: str,
        timeout_seconds: int = 300,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            result = self.virsh(
                ["qemu-agent-command", target, '{"execute":"guest-ping"}'],
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

    def reboot(self, domain: str, domain_uuid: str) -> None:
        target = self._owned_target(domain, domain_uuid)
        self.virsh(["reboot", target, "--mode", "agent"], timeout=30)

    def reset(self, domain: str, domain_uuid: str) -> None:
        """Hard-reset a disposable guest that cannot service an agent reboot."""
        target = self._owned_target(domain, domain_uuid)
        self.virsh(["reset", target], timeout=30)

    def poweroff(self, domain: str, domain_uuid: str) -> None:
        target = self._owned_target(domain, domain_uuid)
        self.virsh(["shutdown", target, "--mode", "agent"], timeout=30, check=False)

    def send_keys(
        self,
        domain: str,
        domain_uuid: str,
        keys: list[str],
        *,
        hold_milliseconds: int = 100,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        self.virsh(
            [
                "send-key",
                target,
                "--holdtime",
                str(hold_milliseconds),
                *keys,
            ],
            timeout=30,
        )

    def pointer_move_absolute(
        self,
        domain: str,
        domain_uuid: str,
        x: int,
        y: int,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        if not 0 <= x <= 32767 or not 0 <= y <= 32767:
            raise ValueError("absolute pointer coordinates must be between 0 and 32767")
        command = {
            "execute": "input-send-event",
            "arguments": {
                "events": [
                    {"type": "abs", "data": {"axis": "x", "value": x}},
                    {"type": "abs", "data": {"axis": "y", "value": y}},
                ]
            },
        }
        self.virsh(
            [
                "qemu-monitor-command",
                target,
                json.dumps(command, separators=(",", ":")),
            ],
            timeout=30,
        )

    def pointer_button(
        self,
        domain: str,
        domain_uuid: str,
        button: str,
        down: bool,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        if button not in {"left", "middle", "right", "wheel-up", "wheel-down"}:
            raise ValueError("unsupported pointer button")
        command = {
            "execute": "input-send-event",
            "arguments": {
                "events": [
                    {
                        "type": "btn",
                        "data": {"down": down, "button": button},
                    }
                ]
            },
        }
        self.virsh(
            [
                "qemu-monitor-command",
                target,
                json.dumps(command, separators=(",", ":")),
            ],
            timeout=30,
        )

    def screenshot(self, domain: str, domain_uuid: str, destination: Path) -> None:
        target = self._owned_target(domain, domain_uuid)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.virsh(["screenshot", target, destination], timeout=30)

    def destroy(self, domain: str, domain_uuid: str) -> None:
        require_domain(domain)
        try:
            expected_uuid = str(uuid.UUID(domain_uuid))
        except ValueError as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "destructive cleanup requires a valid recorded domain UUID",
                {"domain": domain, "recordedUuid": domain_uuid},
            ) from error
        state = self.owned_state(domain, expected_uuid)
        target = expected_uuid
        if state == "undefined":
            return
        if state not in {"shut off", "shutoff"}:
            stop_timeout: subprocess.TimeoutExpired | None = None
            try:
                result = self.virsh(["destroy", target], timeout=30, check=False)
            except subprocess.TimeoutExpired as error:
                # A timed-out virsh client does not prove that libvirt failed to
                # apply the mutation. Reconcile only against the recorded UUID
                # before deciding whether cleanup may continue.
                stop_timeout = error
                result = None
            state = self._uuid_state(target)
            if state not in {"undefined", "shut off", "shutoff"}:
                details: dict[str, object] = {"state": state}
                if result is not None:
                    details.update(
                        {
                            "returncode": result.returncode,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                        }
                    )
                if stop_timeout is not None:
                    details["timeout"] = str(stop_timeout)
                raise VMError(
                    FailureCategory.HOST_INFRA_ERROR,
                    "cannot stop managed domain before cleanup; recorded UUID "
                    f"remained active: {domain}",
                    details,
                )
        if state != "undefined":
            undefine_timeout: subprocess.TimeoutExpired | None = None
            try:
                result = self.virsh(
                    ["undefine", target, "--nvram", "--tpm"],
                    timeout=30,
                    check=False,
                )
            except subprocess.TimeoutExpired as error:
                undefine_timeout = error
                result = None
            final_state = self._uuid_state(target)
            if final_state != "undefined" and (
                undefine_timeout is not None
                or (result is not None and result.returncode)
            ):
                fallback_timeout: subprocess.TimeoutExpired | None = None
                try:
                    fallback = self.virsh(
                        ["undefine", target, "--nvram"],
                        timeout=30,
                        check=False,
                    )
                except subprocess.TimeoutExpired as error:
                    fallback_timeout = error
                    fallback = None
                final_state = self._uuid_state(target)
                if final_state != "undefined" and (
                    fallback_timeout is not None
                    or (fallback is not None and fallback.returncode)
                ):
                    details = {"state": final_state}
                    if fallback is not None:
                        details.update(
                            {
                                "returncode": fallback.returncode,
                                "stdout": fallback.stdout,
                                "stderr": fallback.stderr,
                            }
                        )
                    if fallback_timeout is not None:
                        details["timeout"] = str(fallback_timeout)
                    if result is not None:
                        details["firstAttemptStderr"] = result.stderr
                    if undefine_timeout is not None:
                        details["firstAttemptTimeout"] = str(undefine_timeout)
                    raise VMError(
                        FailureCategory.HOST_INFRA_ERROR,
                        f"cannot undefine managed domain: {domain}",
                        details,
                    )
        else:
            final_state = "undefined"
        if final_state != "undefined":
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"managed domain still exists after cleanup: {domain}",
                {"state": final_state},
            )
        replacement_state = self.state(domain)
        if replacement_state != "undefined":
            replacement = self.virsh(["domuuid", domain], timeout=30, check=False)
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                "managed domain name was reused during cleanup; preserving "
                "ephemeral storage",
                {
                    "domain": domain,
                    "recordedUuid": expected_uuid,
                    "replacementUuid": (
                        replacement.stdout.strip().lower()
                        if replacement.returncode == 0
                        else "unavailable"
                    ),
                    "replacementState": replacement_state,
                },
            )

    def force_stop(self, domain: str, domain_uuid: str) -> None:
        target = self._owned_target(domain, domain_uuid)
        self.virsh(["destroy", target], timeout=30, check=False)

    def start(self, domain: str, domain_uuid: str) -> None:
        target = self._owned_target(domain, domain_uuid)
        self.virsh(["start", target], timeout=60)

    def detach_disk(self, domain: str, domain_uuid: str, disk_target: str) -> None:
        target = self._owned_target(domain, domain_uuid)
        if disk_target not in {"vda", "vdb"}:
            raise ValueError(f"refusing unexpected disk target: {disk_target}")
        self.virsh(["detach-disk", target, disk_target, "--config"], timeout=60)

    def attach_disk(
        self,
        domain: str,
        domain_uuid: str,
        disk: Path,
        disk_target: str,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        if disk_target not in {"vda", "vdb"}:
            raise ValueError(f"refusing unexpected disk target: {disk_target}")
        self.virsh(
            [
                "attach-disk",
                target,
                disk,
                disk_target,
                "--driver",
                "qemu",
                "--subdriver",
                "qcow2",
                "--targetbus",
                "virtio",
                "--config",
            ],
            timeout=60,
        )

    def type_text(
        self,
        domain: str,
        domain_uuid: str,
        value: str,
        *,
        submit: bool = True,
    ) -> None:
        for character in value:
            if "a" <= character <= "z":
                key = f"KEY_{character.upper()}"
            elif "0" <= character <= "9":
                key = f"KEY_{character}"
            elif character == " ":
                key = "KEY_SPACE"
            else:
                raise ValueError("recovery input contains an unsupported character")
            self.send_keys(domain, domain_uuid, [key], hold_milliseconds=80)
            # virsh returns before QEMU releases the key. Leave enough time for
            # the accelerated guest to observe release before the next press.
            time.sleep(0.12)
        if submit:
            self.send_keys(domain, domain_uuid, ["KEY_ENTER"])

    def type_serial_text(
        self,
        domain: str,
        domain_uuid: str,
        value: str,
        *,
        submit: bool = True,
    ) -> None:
        target = self._owned_target(domain, domain_uuid)
        try:
            payload = value.encode("ascii") + (b"\r" if submit else b"")
        except UnicodeEncodeError as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"serial recovery input for {domain} is not ASCII",
            ) from error

        master, slave = pty.openpty()
        tty.setraw(slave, when=termios.TCSANOW)
        process: subprocess.Popen[bytes] | None = None
        try:
            process = subprocess.Popen(
                [
                    "virsh",
                    "--connect",
                    self.uri,
                    "console",
                    target,
                    "--safe",
                ],
                stdin=slave,
                stdout=slave,
                stderr=slave,
                close_fds=True,
                env=self._session_environment(),
            )
            os.close(slave)
            slave = -1

            connected = False
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    output = os.read(master, 4096)
                    if (
                        b"Connected to domain" in output
                        or b"Escape character is" in output
                    ):
                        connected = True
                        break
                if process.poll() is not None:
                    break
            if not connected:
                raise OSError("libvirt serial console did not become ready")

            # A UART Enter key is carriage return. Send it through libvirt's
            # console stream rather than opening QEMU's PTY slave directly;
            # the latter can discard a complete write when the descriptor is
            # closed before QEMU drains its side of the pair.
            remaining = payload
            while remaining:
                written = os.write(master, remaining)
                if written <= 0:
                    raise OSError("serial console accepted no input")
                remaining = remaining[written:]
            termios.tcdrain(master)
            # Keep the console attached long enough for the guest UART to
            # consume the complete line. The boot loop separately confirms
            # serial progress and retries only while the same prompt is idle.
            time.sleep(0.5)
            os.write(master, b"\x1d")
            returncode = process.wait(timeout=5)
            if returncode:
                raise OSError(f"libvirt serial console exited with {returncode}")
        except (OSError, subprocess.TimeoutExpired) as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"could not write recovery input to {domain}",
                {"error": str(error)},
            ) from error
        finally:
            if slave >= 0:
                os.close(slave)
            os.close(master)
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

    def serial_log_size(self, domain: str) -> int:
        path = self._serial_log_path(domain)
        try:
            return path.stat().st_size
        except FileNotFoundError:
            return 0

    def read_serial_text(
        self,
        domain: str,
        *,
        start_offset: int = 0,
        max_bytes: int = 65536,
    ) -> str:
        if start_offset < 0:
            raise ValueError("serial read offset must not be negative")
        if not 1 <= max_bytes <= 1024 * 1024:
            raise ValueError("serial read limit must be between 1 and 1048576 bytes")
        path = self._serial_log_path(domain)
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags)
        except FileNotFoundError:
            return ""
        except OSError as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"could not open the serial log for {domain}",
                {"path": str(path), "error": str(error)},
            ) from error

        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise VMError(
                    FailureCategory.HARNESS_ERROR,
                    f"serial log for {domain} is not a regular file",
                    {"path": str(path)},
                )
            size = metadata.st_size
            if start_offset > size:
                start_offset = 0
            offset = max(start_offset, size - max_bytes)
            os.lseek(descriptor, offset, os.SEEK_SET)
            return os.read(descriptor, max_bytes).decode("utf-8", errors="replace")
        except OSError as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"could not read the serial log for {domain}",
                {"path": str(path), "error": str(error)},
            ) from error
        finally:
            os.close(descriptor)

    def _serial_log_path(self, domain: str) -> Path:
        managed_domain = require_domain(domain)
        run_id = managed_domain.removeprefix(DOMAIN_PREFIX)
        runs_root = self.paths.state / "runs"
        return confined_path(runs_root, runs_root / run_id / "serial.log")


def os_access(path: Path) -> bool:
    return os.access(path, os.R_OK | os.W_OK)
