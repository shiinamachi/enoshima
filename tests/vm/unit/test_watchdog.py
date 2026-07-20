from __future__ import annotations

import json
from pathlib import Path

from enoshima_vm.config import RuntimePaths
from enoshima_vm.watchdog import expire_run


def test_watchdog_ignores_completed_runs(tmp_path: Path) -> None:
    paths = RuntimePaths(tmp_path, tmp_path, tmp_path / "cache", tmp_path / "state")
    run_dir = paths.state / "runs" / "run-012345abcdef"
    run_dir.mkdir(parents=True)
    record = {
        "run_id": "run-012345abcdef",
        "domain": "enoshima-test-run-012345abcdef",
        "status": "completed",
    }
    (run_dir / "run.json").write_text(json.dumps(record), encoding="utf-8")
    assert expire_run(record["run_id"], "qemu:///session", paths) is False
    assert json.loads((run_dir / "run.json").read_text())["status"] == "completed"
