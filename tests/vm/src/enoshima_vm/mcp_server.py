from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from .results import bound_verification_plan, summarize_run_list, summarize_run_record
from .service import VMService

INSTRUCTIONS = (
    "Use repository verification_plan before selecting work. Prefer one synchronous "
    "vm_run_affected call for checkpoint evidence and vm_run_plan for frozen release "
    "qualification; do not poll a terminal. Keep at most one disposable domain active. "
    "Never treat repairs made inside a dirty guest as a passing test. Host paths, "
    "host shell execution, device passthrough, LAN bridges, and non-Enoshima libvirt "
    "domains are unavailable. Reports persist; overlays, seed media, vTPM state, and "
    "disposable SSH keys are removed by vm_destroy."
)

mcp = FastMCP("enoshima-vm", instructions=INSTRUCTIONS, json_response=True)


def service() -> VMService:
    return VMService()


READ_ONLY = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=False,
)
WRITE = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=False,
    idempotentHint=False,
    openWorldHint=False,
)
DESTRUCTIVE = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=True,
    idempotentHint=True,
    openWorldHint=False,
)


@mcp.tool(annotations=WRITE)
def vm_create(suite: str = "smoke", source_ref: str = "working-tree") -> dict[str, Any]:
    """Create and boot one constrained disposable VM without running its suite."""
    return summarize_run_record(service().create(suite, source_ref=source_ref))


@mcp.tool(annotations=WRITE)
def vm_run_suite(
    suite: str = "smoke",
    keep_on_failure: bool = False,
    verification_mode: str = "checkpoint",
    base_ref: str = "origin/main",
) -> dict[str, Any]:
    """Run one dev/checkpoint suite with repository retry and source-freeze policy."""
    return service().run_suite_result(
        suite,
        keep_on_failure=keep_on_failure,
        verification_mode=verification_mode,
        base_ref=base_ref,
    )


@mcp.tool(annotations=READ_ONLY)
def verification_plan(
    base_ref: str = "origin/main",
    mode: str = "checkpoint",
) -> dict[str, object]:
    """Return changed paths and the trusted affected verification selection."""
    return bound_verification_plan(service().verification_plan(base_ref, mode))


@mcp.tool(annotations=WRITE)
def vm_run_affected(
    base_ref: str = "origin/main",
    mode: str = "checkpoint",
) -> dict[str, object]:
    """Run selected affected suites serially with the repository retry budget."""
    return service().run_affected(base_ref, mode)


@mcp.tool(annotations=WRITE)
def vm_run_plan(
    plan: str = "release",
    base_ref: str = "origin/main",
) -> dict[str, object]:
    """Run one trusted repository plan with unique serial suites."""
    return service().run_plan(plan, base_ref=base_ref)


@mcp.tool(annotations=READ_ONLY)
def vm_status(run_id: str) -> dict[str, Any]:
    """Return the persisted run metadata and current managed-domain state."""
    return summarize_run_record(service().status(run_id))


@mcp.tool(annotations=WRITE)
def vm_wait(run_id: str, timeout_seconds: int = 1200) -> dict[str, Any]:
    """Wait for SSH, cloud-init, and the QEMU guest agent to become ready."""
    return summarize_run_record(service().wait(run_id, timeout_seconds))


@mcp.tool(annotations=WRITE)
def vm_upload_worktree(run_id: str) -> dict[str, object]:
    """Upload tracked and non-ignored untracked files from the current worktree."""
    return service().upload_worktree(run_id)


@mcp.tool(annotations=WRITE)
def vm_exec(
    run_id: str,
    argv: list[str],
    timeout_seconds: int = 300,
) -> dict[str, object]:
    """Execute an argv vector inside the disposable guest, never on the host."""
    return service().exec_bounded(run_id, argv, timeout_seconds=timeout_seconds)


@mcp.tool(annotations=WRITE)
def vm_reboot(run_id: str, timeout_seconds: int = 600) -> dict[str, object]:
    """Reboot a managed guest and prove completion with a changed boot ID."""
    return service().reboot(run_id, timeout_seconds)


@mcp.tool(annotations=WRITE)
def vm_poweroff(run_id: str) -> dict[str, str]:
    """Request a guest-agent shutdown for a managed disposable VM."""
    return service().poweroff(run_id)


@mcp.tool(annotations=WRITE)
def vm_screenshot(
    run_id: str,
    name: str = "desktop",
    output: str | None = None,
) -> dict[str, object]:
    """Capture a PNG from the guest compositor into the managed artifact root."""
    return service().screenshot(run_id, name, output)


@mcp.tool(annotations=READ_ONLY)
def vm_query_desktop(run_id: str) -> dict[str, object]:
    """Read Hyprland monitor, workspace, client, focus, and input state."""
    return service().query_desktop_bounded(run_id)


@mcp.tool(annotations=WRITE)
def vm_collect_artifacts(run_id: str) -> dict[str, object]:
    """Collect the fixed log, unit, package, journal, and guest report set."""
    return service().collect(run_id)


@mcp.tool(annotations=DESTRUCTIVE)
def vm_destroy(run_id: str) -> dict[str, object]:
    """Destroy only the named Enoshima VM and irreversibly remove its secrets/disks."""
    return service().destroy(run_id)


@mcp.tool(annotations=READ_ONLY)
def vm_list_runs(
    cursor: str | None = None,
    limit: int = 20,
) -> dict[str, object]:
    """List newest persisted run reports with a bounded continuation cursor."""
    return summarize_run_list(service().list_runs(), cursor=cursor, limit=limit)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
