from __future__ import annotations

import xml.etree.ElementTree as ET

from enoshima_vm.config import RuntimePaths
from enoshima_vm.service import VMService


def test_junit_report_preserves_step_failure_and_duration(tmp_path) -> None:
    paths = RuntimePaths(
        tmp_path,
        tmp_path,
        tmp_path / "cache",
        tmp_path / "state",
    )
    service = VMService(paths)
    destination = service._write_junit(
        {
            "suite": "fixture",
            "artifact_dir": str(tmp_path / "artifacts"),
            "category": "POSTFLIGHT_FAILED",
            "error": "postflight failed",
            "steps": [
                {
                    "action": "bootstrap",
                    "status": "passed",
                    "duration_seconds": 1.25,
                },
                {
                    "action": "postflight",
                    "status": "failed",
                    "duration_seconds": 0.75,
                },
            ],
        }
    )
    root = ET.parse(destination).getroot()
    assert root.attrib["tests"] == "2"
    assert root.attrib["failures"] == "1"
    assert root.attrib["time"] == "2.000"
    failed = root.findall("testcase")[1].find("failure")
    assert failed is not None
    assert failed.attrib["type"] == "POSTFLIGHT_FAILED"
    assert failed.text == "postflight failed"
