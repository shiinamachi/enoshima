from __future__ import annotations

from enoshima_vm import mcp_server


class FakeService:
    def list_runs(self):
        return []

    def verification_plan(self, base_ref: str, mode: str):
        return {"operation": "plan", "base": base_ref, "mode": mode}

    def run_affected(self, base_ref: str, mode: str):
        return {"operation": "affected", "base": base_ref, "mode": mode}

    def run_plan(self, plan: str, *, base_ref: str):
        return {"operation": plan, "base": base_ref}

    def run_suite_result(
        self,
        suite: str,
        *,
        keep_on_failure: bool,
        verification_mode: str,
        base_ref: str,
    ):
        return {
            "operation": "suite",
            "suite": suite,
            "keep": keep_on_failure,
            "mode": verification_mode,
            "base": base_ref,
        }


def test_mcp_exposes_selector_affected_and_release_tools(monkeypatch) -> None:
    monkeypatch.setattr(mcp_server, "service", FakeService)

    assert mcp_server.verification_plan("HEAD^", "dev") == {
        "operation": "plan",
        "base": "HEAD^",
        "mode": "dev",
    }
    assert mcp_server.vm_run_affected("HEAD^", "checkpoint") == {
        "operation": "affected",
        "base": "HEAD^",
        "mode": "checkpoint",
    }
    assert mcp_server.vm_run_plan("release", "HEAD^") == {
        "operation": "release",
        "base": "HEAD^",
    }


def test_mcp_named_suite_uses_bounded_result_path(monkeypatch) -> None:
    monkeypatch.setattr(mcp_server, "service", FakeService)

    assert mcp_server.vm_run_suite("smoke", False, "checkpoint", "HEAD^") == {
        "operation": "suite",
        "suite": "smoke",
        "keep": False,
        "mode": "checkpoint",
        "base": "HEAD^",
    }


def test_mcp_run_list_returns_bounded_page_envelope(monkeypatch) -> None:
    monkeypatch.setattr(mcp_server, "service", FakeService)

    assert mcp_server.vm_list_runs() == {
        "schema": 1,
        "runs": [],
        "total": 0,
        "returned": 0,
        "truncated": False,
    }
