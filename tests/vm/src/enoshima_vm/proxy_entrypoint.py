"""Stdlib-only public entrypoint for the transport-owning durable MCP proxy."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> None:
    # Keep this module free of harness and third-party imports: a broken
    # mutable service module must not close Codex's stdio transport at startup.
    installed_proxy = Path(__file__).with_name("mcp_proxy.py")
    source_proxy = Path(__file__).resolve().parents[2] / "scripts" / "mcp_proxy.py"
    # Editable/source checkouts may also retain an older wheel copy under the
    # virtual environment. Prefer the checkout so a newly opened transport
    # cannot silently execute that stale packaged proxy; wheel-only installs
    # still use their force-included copy.
    proxy = source_proxy if source_proxy.is_file() else installed_proxy
    if not proxy.is_file():
        raise RuntimeError(f"durable MCP proxy is unavailable: {proxy}")
    os.execv(sys.executable, [sys.executable, str(proxy)])


if __name__ == "__main__":
    main()
