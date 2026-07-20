from __future__ import annotations

from pathlib import Path, PurePosixPath

from .guest import Guest

COLLECTION_COMMANDS: tuple[tuple[str, list[str]], ...] = (
    ("packages.txt", ["pacman", "-Q"]),
    (
        "system-units.txt",
        ["systemctl", "list-unit-files", "--no-pager", "--no-legend"],
    ),
    (
        "system-units-failed.txt",
        ["systemctl", "--failed", "--no-pager", "--no-legend"],
    ),
    (
        "user-units.txt",
        ["systemctl", "--user", "list-unit-files", "--no-pager", "--no-legend"],
    ),
    (
        "user-units-failed.txt",
        ["systemctl", "--user", "--failed", "--no-pager", "--no-legend"],
    ),
    ("journal-boot.txt", ["sudo", "journalctl", "-b", "--no-pager"]),
    ("dmesg.txt", ["sudo", "dmesg"]),
    ("cloud-init-status.txt", ["sudo", "cloud-init", "status", "--long"]),
)


def collect_fixed_artifacts(
    guest: Guest,
    artifact_dir: Path,
    remote_artifact_dir: PurePosixPath,
) -> list[str]:
    artifact_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    collected: list[str] = []
    for name, argv in COLLECTION_COMMANDS:
        result = guest.exec(argv, timeout=180, check=False)
        body = result.stdout
        if result.stderr:
            body += "\n--- stderr ---\n" + result.stderr
        (artifact_dir / name).write_text(body, encoding="utf-8")
        collected.append(name)

    remote_exists = (
        guest.exec(["test", "-d", str(remote_artifact_dir)], check=False).returncode
        == 0
    )
    if remote_exists:
        guest.download(remote_artifact_dir, artifact_dir / "guest", recursive=True)
        collected.append("guest/")
    return collected
