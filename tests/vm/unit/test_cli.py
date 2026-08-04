from __future__ import annotations

import json

from enoshima_vm.cli import dispatch, parser
from enoshima_vm.results import MAX_SUMMARY_BYTES


class PlanService:
    def clean(self) -> dict[str, object]:
        return {"cleaned": []}

    def verification_plan(self, base: str, mode: str) -> dict[str, object]:
        return {
            "schema": 1,
            "base": base,
            "mode": mode,
            "changedPaths": [f"path-{index}-" + "x" * 300 for index in range(500)],
            "reasons": {
                f"suite-{index}": ["reason-" + "y" * 300 for _ in range(10)]
                for index in range(100)
            },
        }


def test_cli_verification_plan_is_bounded() -> None:
    args = parser().parse_args(["verification-plan"])

    result = dispatch(PlanService(), args)

    assert result["truncated"] is True
    assert len(json.dumps(result, sort_keys=True).encode()) <= MAX_SUMMARY_BYTES
