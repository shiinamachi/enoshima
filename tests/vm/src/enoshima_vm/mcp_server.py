from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

from .service import VMService

INSTRUCTIONS = (
    "Use this server only for disposable Enoshima test domains. Create at most one "
    "run, wait for readiness, upload the current worktree, execute or inspect the "
    "guest, collect artifacts, then destroy it. Never treat repairs made inside a "
    "dirty guest as a passing test: rerun the suite from a fresh overlay. Host paths, "
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
    return service().create(suite, source_ref=source_ref)


@mcp.tool(annotations=WRITE)
def vm_run_suite(suite: str = "smoke", keep_on_failure: bool = False) -> dict[str, Any]:
    """Run a complete declarative suite from a fresh overlay and clean it up."""
    return service().run_suite(suite, keep_on_failure=keep_on_failure)


@mcp.tool(annotations=READ_ONLY)
def vm_status(run_id: str) -> dict[str, Any]:
    """Return the persisted run metadata and current managed-domain state."""
    return service().status(run_id)


@mcp.tool(annotations=WRITE)
def vm_wait(run_id: str, timeout_seconds: int = 1200) -> dict[str, Any]:
    """Wait for SSH, cloud-init, and the QEMU guest agent to become ready."""
    return service().wait(run_id, timeout_seconds)


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
    return service().exec(run_id, argv, timeout_seconds=timeout_seconds)


@mcp.tool(annotations=WRITE)
def vm_reboot(run_id: str, timeout_seconds: int = 600) -> dict[str, object]:
    """Reboot a managed guest and prove completion with a changed boot ID."""
    return service().reboot(run_id, timeout_seconds)


@mcp.tool(annotations=WRITE)
def vm_poweroff(run_id: str) -> dict[str, str]:
    """Request a guest-agent shutdown for a managed disposable VM."""
    return service().poweroff(run_id)


@mcp.tool(annotations=WRITE)
def vm_screenshot(run_id: str, name: str = "desktop") -> dict[str, str]:
    """Capture a PNG from the guest compositor into the managed artifact root."""
    return service().screenshot(run_id, name)


@mcp.tool(annotations=READ_ONLY)
def vm_query_desktop(run_id: str) -> dict[str, object]:
    """Read Hyprland monitor, workspace, client, focus, and input state."""
    return service().query_desktop(run_id)


@mcp.tool(annotations=WRITE)
def vm_collect_artifacts(run_id: str) -> dict[str, object]:
    """Collect the fixed log, unit, package, journal, and guest report set."""
    return service().collect(run_id)


@mcp.tool(annotations=DESTRUCTIVE)
def vm_destroy(run_id: str) -> dict[str, object]:
    """Destroy only the named Enoshima VM and irreversibly remove its secrets/disks."""
    return service().destroy(run_id)


@mcp.tool(annotations=READ_ONLY)
def vm_list_runs() -> list[dict[str, object]]:
    """List persisted Enoshima VM run reports."""
    return service().list_runs()


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
