from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
from datetime import UTC, datetime

from .config import RuntimePaths
from .security import confined_path, require_domain, require_run_id

FINAL_STATES = {"completed", "destroyed", "expired"}


def expire_run(run_id: str, uri: str, paths: RuntimePaths | None = None) -> bool:
    paths = paths or RuntimePaths.discover()
    require_run_id(run_id)
    runs_root = paths.state / "runs"
    run_dir = confined_path(runs_root, runs_root / run_id)
    record_path = confined_path(run_dir, run_dir / "run.json")
    if not record_path.is_file():
        return False
    record = json.loads(record_path.read_text(encoding="utf-8"))
    if record.get("status") in FINAL_STATES:
        return False
    domain = require_domain(record["domain"])
    subprocess.run(
        ["virsh", "--connect", uri, "destroy", domain],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=30,
    )
    subprocess.run(
        ["virsh", "--connect", uri, "undefine", domain, "--nvram", "--tpm"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=30,
    )
    for name in ("root.qcow2", "boot.qcow2", "seed.iso"):
        target = confined_path(run_dir, run_dir / name)
        target.unlink(missing_ok=True)
    for name in ("ssh", "cloud-init", "secrets", "swtpm"):
        target = confined_path(run_dir, run_dir / name)
        if target.exists():
            shutil.rmtree(target)
    record["status"] = "expired"
    record["result"] = "failed"
    record["category"] = "HARNESS_ERROR"
    record["error"] = "maximum VM run duration exceeded"
    record["updated_at"] = datetime.now(UTC).isoformat()
    record.pop("private_key", None)
    record.pop("recovery_key", None)
    record.pop("login_password", None)
    temporary = record_path.with_suffix(".json.watchdog")
    temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, record_path)
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id")
    parser.add_argument("timeout_seconds", type=int)
    parser.add_argument("uri")
    args = parser.parse_args()
    time.sleep(args.timeout_seconds)
    expire_run(args.run_id, args.uri)


if __name__ == "__main__":
    main()
