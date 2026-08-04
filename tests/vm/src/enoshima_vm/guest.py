from __future__ import annotations

import json
import shlex
import socket
import subprocess
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path, PurePosixPath

from .errors import FailureCategory, VMError
from .process import CommandResult, run
from .source import SourceIdentity, create_source_archive

INITIAL_SSH_TIMEOUT_SECONDS = 1200
# One retry for caller-declared idempotent transport operations. A failed
# affected suite may receive one separate fresh-overlay INFRA retry.
RETRYABLE_SSH_ATTEMPTS = 2


class Guest:
    def __init__(self, port: int, private_key: Path, user: str = "kentakang") -> None:
        self.port = port
        self.private_key = private_key
        self.user = user

    def ssh_base(self) -> list[str]:
        return [
            "ssh",
            "-i",
            str(self.private_key),
            "-p",
            str(self.port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            f"{self.user}@127.0.0.1",
        ]

    def exec(
        self,
        argv: Sequence[str],
        *,
        timeout: float = 300,
        check: bool = True,
    ) -> CommandResult:
        if not argv:
            raise ValueError("guest argv must not be empty")
        remote_command = shlex.join(argv)
        try:
            result = run(
                [*self.ssh_base(), "--", remote_command],
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                f"guest command timed out: {argv[0]}",
            ) from error
        if result.returncode == 255:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                f"guest SSH transport failed: {argv[0]}",
                {"stderr": result.stderr[-2000:]},
            )
        if check and result.returncode:
            raise VMError(
                FailureCategory.VALIDATION_FAILED,
                f"guest command failed: {argv[0]}",
                {
                    "command": str(argv[0]),
                    "exit_code": result.returncode,
                    "stderr_tail": result.stderr[-4000:],
                },
            )
        return result

    def exec_retryable(
        self,
        argv: Sequence[str],
        *,
        timeout: float = 300,
        check: bool = True,
    ) -> CommandResult:
        """Run a caller-declared idempotent command across transient SSH loss."""
        last_result: CommandResult | None = None
        last_timeout: VMError | None = None
        for attempt in range(RETRYABLE_SSH_ATTEMPTS):
            try:
                result = self.exec(argv, timeout=timeout, check=False)
            except VMError as error:
                if error.category != FailureCategory.SSH_TIMEOUT:
                    raise
                last_timeout = error
            else:
                last_timeout = None
                if result.returncode != 255:
                    if check and result.returncode:
                        raise VMError(
                            FailureCategory.VALIDATION_FAILED,
                            f"guest command failed: {argv[0]}",
                            {
                                "command": str(argv[0]),
                                "exit_code": result.returncode,
                                "stderr_tail": result.stderr[-4000:],
                            },
                        )
                    return result
                last_result = result
            if attempt + 1 < RETRYABLE_SSH_ATTEMPTS:
                time.sleep(0.2 * (attempt + 1))

        if last_timeout is not None:
            raise last_timeout
        if last_result is None:
            raise AssertionError("retryable SSH command produced no result")
        if check:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                "retryable guest command lost its SSH transport",
                {
                    "command": str(argv[0]),
                    "attempts": RETRYABLE_SSH_ATTEMPTS,
                    "stderr": last_result.stderr[-2000:],
                },
            )
        return last_result

    def wait_ssh(self, timeout_seconds: int = INITIAL_SSH_TIMEOUT_SECONDS) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=2):
                    pass
            except OSError:
                time.sleep(2)
                continue
            try:
                result = self.exec(["true"], timeout=10, check=False)
            except VMError as error:
                if error.category != FailureCategory.SSH_TIMEOUT:
                    raise
                time.sleep(2)
                continue
            if result.returncode == 0:
                return
            time.sleep(2)
        raise VMError(
            FailureCategory.SSH_TIMEOUT,
            f"SSH did not become ready on 127.0.0.1:{self.port}",
        )

    def wait_ssh_cycle(self, timeout_seconds: int = 300) -> None:
        deadline = time.monotonic() + timeout_seconds
        observed_down = False
        while time.monotonic() < deadline:
            try:
                result = self.exec(["true"], timeout=8, check=False)
            except VMError as error:
                if error.category != FailureCategory.SSH_TIMEOUT:
                    raise
                observed_down = True
                time.sleep(2)
                continue
            if result.returncode != 0:
                observed_down = True
            elif observed_down:
                return
            time.sleep(2)
        raise VMError(
            FailureCategory.REBOOT_FAILED,
            "guest SSH did not complete a down/up reboot cycle",
        )

    def wait_cloud_init(self, timeout_seconds: int = 1200) -> None:
        deadline = time.monotonic() + timeout_seconds
        last_result = CommandResult(("cloud-init", "status"), 1, "", "")
        while time.monotonic() < deadline:
            try:
                last_result = self.exec(
                    ["sudo", "cloud-init", "status", "--long"],
                    timeout=15,
                    check=False,
                )
            except VMError as error:
                if error.category != FailureCategory.SSH_TIMEOUT:
                    raise
                time.sleep(2)
                continue
            if last_result.returncode == 0 and "status: done" in last_result.stdout:
                readiness = self.exec(
                    [
                        "bash",
                        "-lc",
                        "test -f /var/lib/enoshima-cloud-ready && "
                        "command -v ansible-playbook chezmoi git hyprctl jq make "
                        "python3 rg yq >/dev/null",
                    ],
                    timeout=15,
                    check=False,
                )
                if readiness.returncode == 0:
                    return
                output = self.exec(
                    [
                        "sudo",
                        "tail",
                        "-n",
                        "160",
                        "/var/log/cloud-init-output.log",
                    ],
                    timeout=15,
                    check=False,
                )
                raise VMError(
                    FailureCategory.VM_BOOT_ERROR,
                    "cloud-init completed without the required guest tools",
                    {
                        "status": last_result.stdout[-4000:],
                        "cloud_init_output": output.stdout[-12000:],
                    },
                )
            if "status: error" in last_result.stdout:
                break
            time.sleep(2)
        raise VMError(
            FailureCategory.VM_BOOT_ERROR,
            "cloud-init did not complete successfully",
            {
                "stdout": last_result.stdout[-4000:],
                "stderr": last_result.stderr[-4000:],
            },
        )

    def upload_worktree(
        self,
        repository: Path,
        remote: PurePosixPath,
        *,
        expected_commit: str | None = None,
        expected_tree_hash: str | None = None,
    ) -> SourceIdentity:
        if not remote.is_absolute() or len(remote.parts) < 4:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"unsafe remote source root: {remote}",
            )
        with tempfile.TemporaryDirectory(prefix="enoshima-source-") as temporary:
            archive = Path(temporary) / "source.tar"
            identity = create_source_archive(repository, archive)
            if expected_commit is not None and identity.commit != expected_commit:
                raise VMError(
                    FailureCategory.SOURCE_INVALIDATED,
                    "source commit changed before worktree upload",
                    {"expected": expected_commit, "actual": identity.commit},
                )
            if (
                expected_tree_hash is not None
                and identity.tree_hash != expected_tree_hash
            ):
                raise VMError(
                    FailureCategory.SOURCE_INVALIDATED,
                    "immutable upload archive does not match the verification plan",
                    {
                        "expected": f"sha256:{expected_tree_hash}",
                        "actual": f"sha256:{identity.tree_hash}",
                    },
                )
            remote_command = (
                f"rm -rf -- {shlex.quote(str(remote))} && "
                f"install -d -m 0700 {shlex.quote(str(remote))} && "
                f"tar -xf - -C {shlex.quote(str(remote))}"
            )
            with archive.open("rb") as payload:
                try:
                    result = subprocess.run(
                        [*self.ssh_base(), "--", remote_command],
                        stdin=payload,
                        capture_output=True,
                        timeout=600,
                        check=False,
                    )
                except subprocess.TimeoutExpired as error:
                    raise VMError(
                        FailureCategory.SSH_TIMEOUT,
                        "source archive upload timed out",
                    ) from error
                except OSError as error:
                    raise VMError(
                        FailureCategory.HOST_INFRA_ERROR,
                        "cannot start the immutable worktree upload",
                        {"error": str(error)},
                    ) from error
            if result.returncode:
                raise VMError(
                    (
                        FailureCategory.SSH_TIMEOUT
                        if result.returncode == 255
                        else FailureCategory.HARNESS_ERROR
                    ),
                    "cannot upload the immutable worktree archive",
                    {
                        "ssh_status": result.returncode,
                        "ssh_stdout": result.stdout.decode(errors="replace")[-2000:],
                        "ssh_stderr": result.stderr.decode(errors="replace")[-2000:],
                    },
                )
            return identity

    def download(
        self,
        remote: PurePosixPath,
        local: Path,
        *,
        recursive: bool = False,
        timeout: float = 300,
    ) -> None:
        local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        argv = [
            "scp",
            "-i",
            str(self.private_key),
            "-P",
            str(self.port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
        ]
        if recursive:
            argv.append("-r")
        argv.extend([f"{self.user}@127.0.0.1:{remote}", str(local)])
        try:
            run(argv, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                f"guest artifact download timed out: {remote}",
            ) from error
        except subprocess.CalledProcessError as error:
            raise VMError(
                (
                    FailureCategory.SSH_TIMEOUT
                    if error.returncode == 255
                    else FailureCategory.HARNESS_ERROR
                ),
                f"cannot collect guest artifact: {remote}",
                {"error": str(error)},
            ) from error
        except OSError as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"cannot start guest artifact download: {remote}",
                {"error": str(error)},
            ) from error

    def upload_file(
        self,
        local: Path,
        remote: PurePosixPath,
        *,
        mode: int = 0o600,
        timeout: float = 120,
    ) -> None:
        if not local.is_file():
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"local upload source is unavailable: {local}",
            )
        parent = remote.parent
        self.exec(["install", "-d", "-m", "0700", str(parent)])
        argv = [
            "scp",
            "-i",
            str(self.private_key),
            "-P",
            str(self.port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            str(local),
            f"{self.user}@127.0.0.1:{remote}",
        ]
        try:
            run(argv, timeout=timeout)
            self.exec(["chmod", f"{mode:o}", str(remote)])
        except VMError:
            raise
        except subprocess.TimeoutExpired as error:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                f"guest file upload timed out: {remote}",
            ) from error
        except subprocess.CalledProcessError as error:
            raise VMError(
                (
                    FailureCategory.SSH_TIMEOUT
                    if error.returncode == 255
                    else FailureCategory.HARNESS_ERROR
                ),
                f"cannot upload guest file: {remote}",
                {"error": str(error)},
            ) from error
        except OSError as error:
            raise VMError(
                FailureCategory.HOST_INFRA_ERROR,
                f"cannot start guest file upload: {remote}",
                {"error": str(error)},
            ) from error


def source_identity_json(identity: SourceIdentity) -> dict[str, object]:
    return {
        "source_commit": identity.commit,
        "dirty": identity.dirty,
        "worktree_hash": f"sha256:{identity.tree_hash}",
        "file_count": len(identity.files),
        "untracked_file_count": len(identity.untracked_files),
        "untracked_files_sample": [
            name if len(name) <= 256 else name[:243] + "...<truncated>"
            for name in identity.untracked_files[:10]
        ],
        "untracked_files_truncated": len(identity.untracked_files) > 10,
    }


def parse_json_result(result: CommandResult, description: str) -> object:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise VMError(
            FailureCategory.HARNESS_ERROR,
            f"guest returned invalid JSON for {description}",
            {"stdout": result.stdout[-2000:]},
        ) from error
