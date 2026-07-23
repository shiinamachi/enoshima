from __future__ import annotations

import json
import time
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Any

import yaml

from .errors import FailureCategory, VMError

if TYPE_CHECKING:
    from .service import VMService


REMOTE_SOURCE = PurePosixPath("/home/kentakang/enoshima-test/source")
REMOTE_RECOVERY_KEY = PurePosixPath(
    "/home/kentakang/enoshima-test/secrets/luks-recovery.key"
)


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


def _guest_ssh_reachable(guest: Any) -> bool:
    try:
        result = guest.exec(["true"], timeout=8, check=False)
    except VMError as error:
        if error.category != FailureCategory.SSH_TIMEOUT:
            raise
        return False
    return result.returncode == 0


def _reject_recovery_secret_echo(
    service: VMService,
    record: dict[str, Any],
    recovery_value: str,
    serial_text: str,
) -> None:
    if recovery_value not in serial_text:
        return
    serial_log = service._run_dir(record["run_id"]) / "serial.log"
    if serial_log.is_file():
        secret = recovery_value.encode()
        serial_log.write_bytes(
            serial_log.read_bytes().replace(secret, b"[REDACTED_RECOVERY_KEY]")
        )
    raise VMError(
        FailureCategory.SECURE_BOOT_FAILED,
        "the serial console echoed the disposable recovery key",
    )


REMOTE_RUNTIME_INVENTORY = PurePosixPath(
    "/home/kentakang/enoshima-test/runtime-inventory"
)


def prepare_boot_disk(service: VMService, record: dict[str, Any]) -> None:
    guest = service._guest(record)
    recovery_key = Path(record["recovery_key"])
    guest.upload_file(recovery_key, REMOTE_RECOVERY_KEY, mode=0o600)
    command = [
        "sudo",
        str(REMOTE_SOURCE / "tests/vm/scripts/prepare-boot-security.sh"),
        "/dev/vdb",
        str(REMOTE_RECOVERY_KEY),
        "/home/kentakang/.ssh/authorized_keys",
    ]
    try:
        service._run_checked(
            record,
            "prepare-boot-security",
            command,
            FailureCategory.SECURE_BOOT_FAILED,
            timeout_seconds=2 * 60 * 60,
        )
    finally:
        guest.exec(["rm", "-f", str(REMOTE_RECOVERY_KEY)], check=False)


def boot_with_recovery(
    service: VMService,
    record: dict[str, Any],
    *,
    already_running: bool = True,
    timeout_seconds: int = 600,
) -> None:
    guest = service._guest(record)
    before = ""
    if already_running:
        before = guest.exec(
            ["cat", "/proc/sys/kernel/random/boot_id"], check=False
        ).stdout.strip()
        serial_offset = service.backend.serial_log_size(record["domain"])
        service.backend.reboot(record["domain"])
    else:
        serial_offset = 0
        service.backend.start(record["domain"])

    recovery_value = Path(record["recovery_key"]).read_text(encoding="utf-8").strip()
    deadline = time.monotonic() + timeout_seconds
    submitted_prompt_count = 0
    prompt_input_attempts = 0
    prompt_input_serial_size = 0
    prompt_input_retry_at: float | None = None
    observed_down = False
    observed_prompt = False
    serial_tail = ""
    while True:
        now = time.monotonic()
        if now >= deadline:
            break
        if not _guest_ssh_reachable(guest):
            observed_down = True
            # Drain ttyS0 from the beginning of the reboot. Recovery input is
            # sent only after sd-encrypt explicitly asks for a passphrase, so
            # slow service shutdown and firmware timing cannot poison the
            # prompt or open OVMF's graphical boot menu.
            serial_tail = service.backend.read_serial_text(
                record["domain"], start_offset=serial_offset
            )
            _reject_recovery_secret_echo(service, record, recovery_value, serial_tail)
            serial_size = len(serial_tail.encode("utf-8"))
            prompt_count = serial_tail.casefold().count("enter passphrase")
            if prompt_count:
                observed_prompt = True
            if (
                prompt_input_retry_at is not None
                and serial_size > prompt_input_serial_size
            ):
                # Serial progress proves the guest consumed the submitted
                # line. A wrong key produces a fresh prompt and is handled by
                # the monotonically increasing prompt count below.
                prompt_input_retry_at = None
            if prompt_count > submitted_prompt_count:
                submitted_prompt_count = prompt_count
                prompt_input_attempts = 0
                service.backend.type_serial_text(record["domain"], recovery_value)
                prompt_input_attempts = 1
                prompt_input_serial_size = serial_size
                prompt_input_retry_at = now + 3
            elif (
                prompt_input_retry_at is not None
                and now >= prompt_input_retry_at
                and serial_size <= prompt_input_serial_size
            ):
                if prompt_input_attempts >= 3:
                    raise VMError(
                        FailureCategory.SECURE_BOOT_FAILED,
                        "the serial console did not consume recovery input",
                        {"prompt_input_attempts": prompt_input_attempts},
                    )
                service.backend.type_serial_text(record["domain"], recovery_value)
                prompt_input_attempts += 1
                prompt_input_serial_size = serial_size
                prompt_input_retry_at = now + 3
        elif observed_down:
            serial_tail = service.backend.read_serial_text(
                record["domain"], start_offset=serial_offset
            )
            _reject_recovery_secret_echo(service, record, recovery_value, serial_tail)
            after = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"], check=False
            ).stdout.strip()
            if not before or (after and after != before):
                service.backend.wait_guest_agent(record["domain"], 180)
                return
        time.sleep(2)
    raise VMError(
        FailureCategory.SECURE_BOOT_FAILED,
        "the encrypted boot disk did not accept its disposable recovery key",
        {
            "observed_ssh_down": observed_down,
            "observed_recovery_prompt": observed_prompt,
            "serial_output_bytes": len(serial_tail.encode("utf-8")),
        },
    )


def create_runtime_inventory(service: VMService, record: dict[str, Any]) -> None:
    guest = service._guest(record)
    metadata_result = guest.exec(["sudo", "cat", "/root/enoshima-boot-metadata.json"])
    try:
        metadata = json.loads(metadata_result.stdout)
    except ValueError as error:
        raise VMError(
            FailureCategory.SECURE_BOOT_FAILED,
            "boot target metadata is invalid",
            {"stdout": metadata_result.stdout[-2000:]},
        ) from error

    local = service._run_dir(record["run_id"]) / "runtime-inventory"
    (local / "group_vars").mkdir(mode=0o700, parents=True, exist_ok=True)
    (local / "host_vars").mkdir(mode=0o700, parents=True, exist_ok=True)
    group_source = service.paths.repository / "ansible/inventory/group_vars/all.yml"
    (local / "group_vars/all.yml").write_text(
        group_source.read_text(encoding="utf-8"), encoding="utf-8"
    )
    hosts = {
        "all": {
            "hosts": {
                "enoshima-vm-boot": {
                    "ansible_connection": "local",
                    "ansible_python_interpreter": "/usr/bin/python",
                }
            }
        }
    }
    host_vars = {
        "system_hostname": "enoshima-vm-boot",
        "enoshima_environment": "vm",
        "enoshima_capabilities": {
            "battery": False,
            "boot_artifacts": True,
            "btrfs_layout": True,
            "camera": False,
            "external_display": False,
            "fingerprint": False,
            "graphical_session": True,
            "hibernation": True,
            "root_luks": True,
            "secure_boot": True,
            "thunderbolt": False,
            "tpm": True,
            "virtual_gpu_3d": True,
            "vm_test_host": False,
            "wwan": False,
        },
        "root_mapper_name": "cryptroot",
        "root_luks_uuid": metadata["root_luks_uuid"],
        "root_btrfs_uuid": metadata["root_btrfs_uuid"],
        "root_btrfs_label": "ENOSHIMA_VM",
        "root_btrfs_subvolume": "@",
        "esp_partition_uuid": metadata["esp_partition_uuid"],
        "esp_partition_partuuid": metadata["esp_partition_partuuid"],
        "manage_boot_config": True,
        "manage_fstab": True,
        "managed_fstab_static_entries": [
            (
                f"UUID={metadata['root_btrfs_uuid']} / btrfs "
                "rw,noatime,compress=zstd,subvol=@ 0 0"
            ),
            (
                f"UUID={metadata['root_btrfs_uuid']} /home btrfs "
                "rw,noatime,compress=zstd,subvol=@home 0 0"
            ),
            (
                f"UUID={metadata['root_btrfs_uuid']} /var/log btrfs "
                "rw,noatime,compress=zstd,subvol=@var_log 0 0"
            ),
            (f"UUID={metadata['esp_partition_uuid']} /efi vfat rw,umask=0077 0 2"),
        ],
        "secure_boot_sign_uki": True,
        "snapper_configure_root": True,
        "desktop_hibernation_enabled": True,
        "desktop_hibernation_swap_size_gib": 32,
        "kernel_command_line": (
            "root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw "
            "console=tty0 console=ttyS0,115200n8"
        ),
        "uki_presets": [
            {
                "name": "linux",
                "kernel": "/boot/vmlinuz-linux",
                "output": "/efi/EFI/Linux/arch-linux.efi",
            },
            {
                "name": "linux-lts",
                "kernel": "/boot/vmlinuz-linux-lts",
                "output": "/efi/EFI/Linux/arch-linux-lts.efi",
            },
        ],
        "zram_size_expression": "min(ram / 4, 8192)",
        "zram_compression_algorithm": "zstd",
        "zram_swap_priority": 100,
        "desktop_login_manager": "greetd",
        "desktop_expansion_sddm_theme_enabled": True,
        "system_units_started": [
            "NetworkManager.service",
            "rtkit-daemon.service",
            "systemd-timesyncd.service",
            "systemd-userdbd.socket",
            "tlp.service",
            "tlp-pd.service",
            "remote-fs.target",
            "paccache.timer",
            "snapper-cleanup.timer",
            "snapper-timeline.timer",
        ],
        "system_units_enabled_only": ["getty@.service"],
        "user_units_started": [
            "hypridle.service",
            "hyprpaper.service",
            "hyprpolkitagent.service",
            "swaync.service",
            "waybar.service",
            "wireplumber.service",
            "xdg-user-dirs.service",
            "p11-kit-server.socket",
            "pipewire-pulse.socket",
            "pipewire.socket",
        ],
    }
    (local / "hosts.yml").write_text(
        yaml.safe_dump(hosts, sort_keys=False), encoding="utf-8"
    )
    (local / "host_vars/enoshima-vm-boot.yml").write_text(
        yaml.safe_dump(host_vars, sort_keys=False), encoding="utf-8"
    )
    for relative in (
        "hosts.yml",
        "group_vars/all.yml",
        "host_vars/enoshima-vm-boot.yml",
    ):
        guest.upload_file(local / relative, REMOTE_RUNTIME_INVENTORY / relative)
    record.setdefault("observations", {})["runtime_inventory"] = str(
        REMOTE_RUNTIME_INVENTORY
    )
    record["updated_at"] = utc_now()
    service._write_record(record)


def assert_secure_boot(service: VMService, record: dict[str, Any]) -> None:
    checks = [
        'test "$(findmnt -n -o FSTYPE /)" = btrfs',
        "sudo cryptsetup status cryptroot",
        (
            'test "$(od -An -j4 -N1 -tu1 '
            "/sys/firmware/efi/efivars/SecureBoot-* | tr -d ' ')\" = 1"
        ),
        (
            "sudo sbverify --cert /var/lib/sbctl/keys/db/db.pem "
            "/efi/EFI/Linux/arch-linux.efi"
        ),
        (
            "sudo sbverify --cert /var/lib/sbctl/keys/db/db.pem "
            "/efi/EFI/Linux/arch-linux-lts.efi"
        ),
    ]
    service._run_checked(
        record,
        "assert-secure-boot",
        ["bash", "-lc", " && ".join(checks)],
        FailureCategory.SECURE_BOOT_FAILED,
        timeout_seconds=180,
    )


def enroll_tpm(service: VMService, record: dict[str, Any]) -> None:
    command = [
        "sudo",
        "systemd-cryptenroll",
        "--tpm2-device=auto",
        "--tpm2-pcrs=7",
        "--unlock-key-file=/root/enoshima-vm-recovery-key",
        "/dev/vdb2",
    ]
    service._run_checked(
        record,
        "enroll-tpm",
        command,
        FailureCategory.SECURE_BOOT_FAILED,
        timeout_seconds=180,
    )


def test_recovery_path(service: VMService, record: dict[str, Any]) -> None:
    service._run_checked(
        record,
        "remove-tpm-slot",
        [
            "sudo",
            "systemd-cryptenroll",
            "--wipe-slot=tpm2",
            "--unlock-key-file=/root/enoshima-vm-recovery-key",
            "/dev/vdb2",
        ],
        FailureCategory.SECURE_BOOT_FAILED,
        timeout_seconds=180,
    )
    boot_with_recovery(service, record)
    service._run_checked(
        record,
        "assert-recovery-mounts",
        [
            "bash",
            "-lc",
            "mountpoint --quiet /home && mountpoint --quiet /var/log && "
            "mountpoint --quiet /efi && "
            "test -s /home/kentakang/.ssh/authorized_keys",
        ],
        FailureCategory.SECURE_BOOT_FAILED,
        timeout_seconds=60,
    )
    enroll_tpm(service, record)


def test_unsigned_rejection(service: VMService, record: dict[str, Any]) -> None:
    guest = service._guest(record)

    def restore_signed_default() -> None:
        service._run_checked(
            record,
            "restore-signed-uki-default",
            [
                "sudo",
                "bootctl",
                "set-default",
                "enoshima.conf",
            ],
            FailureCategory.SECURE_BOOT_FAILED,
        )

    def write_evidence(recovery: str) -> None:
        evidence = Path(record["artifact_dir"]) / "boot-security-negative.json"
        evidence.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        evidence.write_text(
            json.dumps(
                {
                    "unsigned_uki_booted": False,
                    "recovery": recovery,
                    "signed_entry": "enoshima.conf",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    service._run_checked(
        record,
        "select-unsigned-uki",
        [
            "sudo",
            "bootctl",
            "set-oneshot",
            "enoshima-unsigned.conf",
        ],
        FailureCategory.SECURE_BOOT_FAILED,
    )
    before = guest.exec(["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
    service.backend.reboot(record["domain"])
    deadline = time.monotonic() + 60
    observed_down = False
    while time.monotonic() < deadline:
        if not _guest_ssh_reachable(guest):
            observed_down = True
        elif observed_down:
            after = guest.exec(
                ["cat", "/proc/sys/kernel/random/boot_id"], check=False
            ).stdout.strip()
            if after and after != before:
                cmdline = guest.exec(["cat", "/proc/cmdline"]).stdout
                if "enoshima.unsigned_test=1" in cmdline:
                    raise VMError(
                        FailureCategory.SECURE_BOOT_FAILED,
                        (
                            "unsigned UKI unexpectedly booted while Secure Boot "
                            "was enabled"
                        ),
                    )
                restore_signed_default()
                write_evidence("automatic-signed-fallback")
                return
        time.sleep(2)
    if not observed_down:
        raise VMError(
            FailureCategory.SECURE_BOOT_FAILED,
            "negative Secure Boot test did not begin a reboot",
        )

    # Firmware is allowed to stop at its boot manager after rejecting the
    # one-shot unsigned entry. Reset the disposable guest so systemd-boot
    # consumes its persistent signed default without relying on menu timing.
    service.backend.reset(record["domain"])
    guest.wait_ssh(240)
    service.backend.wait_guest_agent(record["domain"], 180)
    cmdline = guest.exec(["cat", "/proc/cmdline"]).stdout
    if "enoshima.unsigned_test=1" in cmdline:
        raise VMError(
            FailureCategory.SECURE_BOOT_FAILED,
            "unsigned UKI unexpectedly booted after firmware rejection",
        )
    restore_signed_default()
    write_evidence("reset-to-persistent-signed-default")


def collect_boot_security(service: VMService, record: dict[str, Any]) -> None:
    commands = {
        "sbctl-status.txt": ["sudo", "sbctl", "status"],
        "sbctl-verify.txt": ["sudo", "sbctl", "verify"],
        "bootctl-status.txt": ["bootctl", "status", "--no-pager"],
        "cryptenroll.txt": ["sudo", "systemd-cryptenroll", "/dev/vdb2"],
        "cryptsetup-status.txt": ["sudo", "cryptsetup", "status", "cryptroot"],
        "pcrs.txt": ["sudo", "systemd-analyze", "pcrs"],
    }
    destination = Path(record["artifact_dir"]) / "boot-security"
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    guest = service._guest(record)
    for name, argv in commands.items():
        result = guest.exec(argv, timeout=180, check=False)
        (destination / name).write_text(
            result.stdout + "\n--- stderr ---\n" + result.stderr,
            encoding="utf-8",
        )
