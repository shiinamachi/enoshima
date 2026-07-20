# VM harness development

The complete operator and security contract is in
[`docs/VM-TESTING.md`](../../docs/VM-TESTING.md).

This Python project owns only disposable VM lifecycle and orchestration. Suite
YAML calls the repository's existing validation, bootstrap, and postflight
entrypoints. CLI and MCP use the same `VMService` implementation.

```bash
uv lock --check
uv run --locked pytest
uv run --locked ruff check src unit
uv run --locked enoshima-vm preflight smoke
```

Key directories:

- `images/`: signed latest and reproducible base-image definitions
- `suites/`: declarative test order, resources, and allowed skips
- `templates/`: NoCloud and constrained libvirt definitions
- `scripts/`: guest-only boot-security disk preparation
- `src/enoshima_vm/`: shared CLI/MCP service and safety boundaries
- `unit/`: configuration, template, image, confinement, and watchdog tests

Never add a host shell escape, arbitrary host path mount, unmanaged-domain
operation, LAN bridge, passthrough device, persistent credential, or mutable VM
image to this project.
