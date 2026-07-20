from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from .config import RuntimePaths
from .errors import FailureCategory, VMError
from .process import run


@dataclass(frozen=True, slots=True)
class CloudInitResult:
    seed: Path
    private_key: Path
    public_key: Path


class CloudInitBuilder:
    def __init__(self, paths: RuntimePaths) -> None:
        self.paths = paths
        self.environment = Environment(
            loader=FileSystemLoader(paths.project / "templates"),
            autoescape=False,
            undefined=StrictUndefined,
            keep_trailing_newline=True,
        )

    def build(self, run_dir: Path, run_id: str, user: str) -> CloudInitResult:
        private_key = run_dir / "ssh" / "id_ed25519"
        private_key.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    f"enoshima-vm-{run_id}",
                    "-f",
                    private_key,
                ],
                timeout=30,
            )
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "cannot generate the disposable SSH key",
                {"error": str(error)},
            ) from error
        private_key.chmod(0o600)
        public_key = private_key.with_suffix(".pub")
        public_key_text = public_key.read_text(encoding="utf-8").strip()

        cloud_dir = run_dir / "cloud-init"
        cloud_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        context = {"run_id": run_id, "user": user, "public_key": public_key_text}
        for name in ("user-data", "meta-data", "network-config"):
            rendered = self.environment.get_template(f"{name}.j2").render(**context)
            (cloud_dir / name).write_text(rendered, encoding="utf-8")

        seed = run_dir / "seed.iso"
        if shutil.which("cloud-localds"):
            argv = [
                "cloud-localds",
                "--network-config",
                cloud_dir / "network-config",
                seed,
                cloud_dir / "user-data",
                cloud_dir / "meta-data",
            ]
        elif shutil.which("xorriso"):
            argv = [
                "xorriso",
                "-as",
                "genisoimage",
                "-output",
                seed,
                "-volid",
                "CIDATA",
                "-joliet",
                "-rock",
                cloud_dir / "user-data",
                cloud_dir / "meta-data",
                cloud_dir / "network-config",
            ]
        else:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "cloud-localds or xorriso is required to build the NoCloud seed",
            )
        try:
            run(argv, timeout=60)
        except Exception as error:
            raise VMError(
                FailureCategory.HARNESS_ERROR,
                "cannot build the NoCloud seed image",
                {"error": str(error)},
            ) from error
        seed.chmod(0o600)
        return CloudInitResult(seed, private_key, public_key)
