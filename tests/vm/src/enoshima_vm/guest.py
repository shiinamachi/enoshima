from __future__ import annotations

import json
import shlex
import socket
import subprocess
import time
from collections.abc import Sequence
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path, PurePosixPath

from .errors import FailureCategory, VMError
from .process import CommandResult, run


@dataclass(frozen=True, slots=True)
class SourceIdentity:
    commit: str
    dirty: bool
    worktree_hash: str
    files: tuple[str, ...]
    untracked_files: tuple[str, ...]


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
            return run(
                [*self.ssh_base(), "--", remote_command],
                timeout=timeout,
                check=check,
            )
        except subprocess.TimeoutExpired as error:
            raise VMError(
                FailureCategory.SSH_TIMEOUT,
                f"guest command timed out: {argv[0]}",
            ) from error

    def wait_ssh(self, timeout_seconds: int = 300) -> None:
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=2):
                    pass
            except OSError:
                time.sleep(2)
                continue
            result = self.exec(["true"], timeout=10, check=False)
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
            result = self.exec(["true"], timeout=8, check=False)
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
        result = self.exec(
            ["sudo", "cloud-init", "status", "--wait", "--long"],
            timeout=timeout_seconds,
            check=False,
        )
        if result.returncode or "status: done" not in result.stdout:
            raise VMError(
                FailureCategory.VM_BOOT_ERROR,
                "cloud-init did not complete successfully",
                {"stdout": result.stdout[-4000:], "stderr": result.stderr[-4000:]},
            )

    @staticmethod
    def source_identity(repository: Path) -> SourceIdentity:
        commit = run(["git", "rev-parse", "HEAD"], cwd=repository).stdout.strip()
        dirty = bool(run(["git", "status", "--porcelain"], cwd=repository).stdout)
        raw_files = run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=repository,
        ).stdout
        files = tuple(sorted(name for name in raw_files.split("\0") if name))
        untracked_raw = run(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=repository,
        ).stdout
        untracked = tuple(sorted(name for name in untracked_raw.split("\0") if name))
        digest = sha256()
        for name in files:
            path = repository / name
            if not path.is_file() or path.is_symlink():
                continue
            digest.update(name.encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        return SourceIdentity(commit, dirty, digest.hexdigest(), files, untracked)

    def upload_worktree(
        self, repository: Path, remote: PurePosixPath
    ) -> SourceIdentity:
        identity = self.source_identity(repository)
        file_list = b"\0".join(name.encode() for name in identity.files) + b"\0"
        tar_process = subprocess.Popen(
            [
                "tar",
                "--null",
                "--files-from=-",
                "--create",
                "--file=-",
            ],
            cwd=repository,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert tar_process.stdin is not None
        assert tar_process.stdout is not None
        remote_command = (
            f"install -d -m 0700 {shlex.quote(str(remote))} && "
            f"tar -xf - -C {shlex.quote(str(remote))}"
        )
        ssh_process = subprocess.Popen(
            [*self.ssh_base(), "--", remote_command],
            stdin=tar_process.stdout,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        tar_process.stdout.close()
        tar_process.stdin.write(file_list)
        tar_process.stdin.close()
        ssh_stdout, ssh_stderr = ssh_process.communicate(timeout=600)
        tar_stderr = tar_process.stderr.read() if tar_process.stderr else b""
        tar_status = tar_process.wait()
        if tar_status or ssh_process.returncode:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "cannot upload the current worktree",
                {
                    "tar_status": tar_status,
                    "tar_stderr": tar_stderr.decode(errors="replace")[-2000:],
                    "ssh_status": ssh_process.returncode,
                    "ssh_stdout": ssh_stdout.decode(errors="replace")[-2000:],
                    "ssh_stderr": ssh_stderr.decode(errors="replace")[-2000:],
                },
            )
        return identity

    def download(
        self,
        remote: PurePosixPath,
        local: Path,
        *,
        recursive: bool = False,
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
            run(argv, timeout=300)
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"cannot collect guest artifact: {remote}",
                {"error": str(error)},
            ) from error

    def upload_file(
        self,
        local: Path,
        remote: PurePosixPath,
        *,
        mode: int = 0o600,
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
            run(argv, timeout=120)
            self.exec(["chmod", f"{mode:o}", str(remote)])
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                f"cannot upload guest file: {remote}",
                {"error": str(error)},
            ) from error


def source_identity_json(identity: SourceIdentity) -> dict[str, object]:
    return {
        "source_commit": identity.commit,
        "dirty": identity.dirty,
        "worktree_hash": f"sha256:{identity.worktree_hash}",
        "file_count": len(identity.files),
        "untracked_files": list(identity.untracked_files),
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
