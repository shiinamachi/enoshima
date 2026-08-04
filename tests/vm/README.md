# VM harness development

The complete operator and security contract is in
[`docs/VM-TESTING.md`](../../docs/VM-TESTING.md).

This Python project owns only disposable VM lifecycle and orchestration. Suite
YAML calls the repository's existing validation, bootstrap, and postflight
entrypoints. CLI and MCP use the same `VMService` implementation.

## Verification architecture

Keep one canonical suite YAML per lane. `verification-modes.yaml` applies the
three cost/evidence profiles without cloning suite definitions:

- `dev` is fail-fast and non-authoritative. It reduces Electron and reboot
  repetitions to one and uses representative affected UI states. Policy
  permits diagnostic reuse, but the current service still creates a fresh
  overlay for every `dev` run.
- `checkpoint` is fail-fast, authoritative, and requires fresh overlays. It
  runs only affected suites, uses three Electron and reboot repetitions, and
  covers the full required matrix for affected UI surfaces.
- `release` is authoritative and requires fresh overlays. It uses the full UI
  matrix, twenty Electron repetitions, and ten reboot repetitions.

`../verification-map.yaml` maps the union of `BASE...HEAD`, staged, unstaged,
and non-ignored untracked paths to focused checks, registered UI evidence,
checkpoint suites, and T5 physical gates. Runtime paths without a rule or a
registered `docs/ui-surfaces.yaml` implementation fail closed as
`UNMAPPED_RUNTIME_PATH`. Documentation, metadata, generated, and T0-only paths
can omit VM execution only with a recorded reason.

Use these public entrypoints; `vm-dev` is optional diagnostic feedback:

```bash
make verification-plan BASE=origin/main MODE=checkpoint
make check-affected BASE=origin/main MODE=checkpoint
make vm-dev BASE=origin/main
make vm-checkpoint BASE=origin/main
make vm-release BASE=origin/main
```

The first command only prints the trusted selection. The second runs its
focused/static checks without a VM. `vm-dev` is diagnostic; a fresh passing
`vm-checkpoint` is authoritative for an affected work unit. Run `vm-release`
once after code and canonical evidence are frozen. `vm-full` is exactly an
alias for `vm-release`, not additional coverage.

`plans/release.yaml` lists one serial entry for every canonical lane in this
exact order:

```text
smoke -> converge -> reboot -> desktop -> login -> ui-review -> boot-security
```

The CLI equivalents are `verification-plan`, `check-affected`,
`run-affected --mode dev|checkpoint`, and `run-plan release`. The shared MCP
surface provides `verification_plan`, `vm_run_affected`, and `vm_run_plan`.
The two run tools are synchronous: use one call for the serial operation and
do not poll a terminal or low-level status tool while it is active. Project
configuration requires the MCP server for Codex VM evidence; if it is
unavailable, report `VM_BLOCKED` after focused checks instead of starting a
long shell fallback.

## Failure and evidence contract

Every failed run records `failureOrigin` (`PRODUCT`, `TEST_FIXTURE`, or
`INFRA`) and a normalized `failureFingerprint`. Do not retry unchanged product
or fixture failures. Eligible transient infrastructure receives at most one
retry; image-integrity failures receive none. The same fingerprint twice for a
suite-specific dependency digest returns `VM_BLOCKED` before another VM is
created. Shared harness, validation, bootstrap, and managed-runtime inputs feed
every suite that consumes those steps. Pre-domain failures retain raw artifacts.
Source-freeze validation compares the plan with the actual entries of an
immutable upload archive, including paths, contents, symlinks, and executable
bits. Repairs inside a failed guest remain diagnostic;
authoritative evidence always starts from a new overlay.

Run summaries, run lists, selector previews, low-level exec/query results, and
affected/release operation responses stay below 32 KiB and include only the
first full actionable failure with a bounded excerpt of at most 80 lines. Raw
journals, stack traces, focused-check streams, full source manifests, manual
command output, desktop JSON, screenshot diffs, and JUnit remain in artifacts.
Run lists are newest-first cursor pages. The complete serial-operation report is
retained under
`$ENOSHIMA_VM_STATE_ROOT/plans/<operation-id>/plan.json` (or the default state
root), and the returned `artifactRoot` points to it. Preserve every
`physicalGates` entry for T5 execution on `tpx1c13`; VM success does not satisfy
those gates.

Changes to the harness, selector, verification modes, or release plan require
`make vm-unit` and the smallest real suite selected by the map.

```bash
uv lock --check
uv run --locked pytest
uv run --locked ruff check src unit
uv run --locked enoshima-vm preflight smoke
```

Key directories:

- `images/`: signed latest and reproducible base-image definitions
- `plans/`: duplicate-free serial verification plans
- `suites/`: declarative convergence, desktop, greetd, and boot-security order
- `templates/`: NoCloud and constrained libvirt definitions
- `scripts/`: guest-only boot-security disk preparation
- `src/enoshima_vm/`: shared CLI/MCP service and safety boundaries
- `unit/`: configuration, template, image, confinement, and watchdog tests

Never add a host shell escape, arbitrary host path mount, unmanaged-domain
operation, LAN bridge, passthrough device, persistent credential, or mutable VM
image to this project.
