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
Each MCP run tool starts one detached serial worker and returns an
`operationId`; use bounded `vm_wait_operation` calls until it returns the final
result. If a Codex or MCP transport restarts, recover the id with
`vm_list_operations` and continue waiting. Project configuration requires the
MCP server for Codex VM evidence; if it cannot start or recover the operation,
report `VM_BLOCKED` after focused checks instead of starting a long shell
fallback. Fresh workers use isolated bytecode-cache roots, corrupt historical
ledger entries cannot hide healthy operations, and hard-crashed workers become
recoverable `orphaned` records rather than leaving the serial lock stuck.
The operation ledger remains under the configured state root, while every
mutating proxy, CLI, and service process shares the canonical
`/run/user/$UID/enoshima-vm/active.lock`; changing `ENOSHIMA_VM_STATE_ROOT`
cannot create a second mutation lane for the same user libvirt session.
Non-durable fresh workers have tool-specific absolute deadlines and whole
process-group TERM/KILL cleanup, so one hung diagnostic cannot close or occupy
the MCP transport indefinitely. Every spawned Python role begins with `-I -S`
and a stdlib-only bootstrap that arms Linux parent-death signaling before
enabling reviewed site paths or `sitecustomize`. Mutating worker supervisors
and their child-subreaper guardians inherit the serial lock. The outer durable
supervisor runs in a named `systemd --user` scope with absolute `RuntimeMaxSec`
and bounded `TimeoutStopSec`; it alone disarms transport-parent death after the
safety bootstrap. A proxy SIGKILL therefore leaves the operation recoverable,
while guardian/payload parent loss and pre-import hangs are still terminated
before mutation ownership is released.
The per-run deadline watchdog is the intentional exception: it runs as a named
`systemd --user` transient service outside that ancestry, never inherits
`active.lock`, and remains able to expire a VM after a proxy, supervisor,
guardian, or Codex task disappears. The domain is not started until the watchdog
has published proof that it loaded the harness and can access the same run record
and libvirt session. Normal cleanup proves the exact recorded watchdog identity
has stopped before deleting disposable storage or credentials; the watchdog
independently proves domain teardown, retries transient teardown failures within
its bounded finalization window (including missing, malformed, non-object, or
temporarily unreadable run records), and only then removes ephemera at expiry.
Fresh proxy workers overwrite missing or noncanonical inherited home, runtime,
config, and cache values with the passwd home and `/run/user/$UID`, keeping
`qemu:///session` on one logical libvirt daemon across reconnects. Each run
records that logical session identity; destructive cleanup refuses an unknown
or mismatched identity. VM destruction and the watchdog both prove that the
managed domain is stopped, undefined, and absent before removing disposable
disks, seed media, vTPM state, or SSH keys.
Durable supervisors use a transport-independent deadline derived from two
attempts of every canonical suite's declared `timeout_minutes`, plus two hours
for focused checks, 30 minutes per attempt, and one hour for finalization. The
canonical release plan's full suite list—not its affected selector view—sizes
that deadline. Focused checks themselves have a two-hour absolute and
20-minute no-output deadline. Operation summaries distinguish `planned*`
source identity from reconciled `actual*` final identity and fail closed on a
change. Terminal ledger envelopes are capped at 128 KiB and revalidated against
their recorded status/result at commit, status, and wait boundaries; summaries
are capped at 32 KiB and diagnostics at 80 lines/16 KiB.

## Failure and evidence contract

Every failed run records `failureOrigin` (`PRODUCT`, `TEST_FIXTURE`, or
`INFRA`) and a normalized `failureFingerprint`. Do not retry unchanged product
or fixture failures. Eligible transient infrastructure receives at most one
retry; image-integrity failures receive none. The same fingerprint twice for a
suite-specific dependency digest returns `VM_BLOCKED` before another VM is
created. Shared harness, validation, bootstrap, and managed-runtime inputs feed
every suite that consumes those steps. Pre-domain failures retain raw artifacts.
Long guest commands have a ten-minute no-output budget by default, while
OpenSSH connect and keepalive options detect dead transports sooner. Bootstrap
uses a narrower 32-minute no-output exception so the explicitly bounded
30-minute Flatpak module can return its buffered libostree result. A cold
bootstrap has a 155-minute absolute deadline. Explicit repeat-convergence
bootstraps have a 30-minute absolute and ten-minute idle deadline because their
expensive downloads and builds must already be current. The VM gives mise two
ten-minute attempts and fixes the independently bounded Codex Desktop build to
two 30-minute attempts, so one transient download failure in either phase can
recover without silently turning either command into an unbounded wait. The
release-equivalent reboot lane has a 195-minute watchdog so a bounded cold
bootstrap and all ten desktop reboot iterations can both finish. A stalled bounded remote fixture is recorded as
`TEST_FIXTURE`, so it cannot trigger a second full-overlay infrastructure retry;
bootstrap and setup transport failures remain `INFRA` only when connection
establishment or the SSH transport actually fails. Timeout output is retained
in the step artifact before cleanup.
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
- `scripts/`: guest boot-security setup and the stable MCP/fresh-worker proxy
- `src/enoshima_vm/`: shared CLI/MCP service and safety boundaries
- `unit/`: configuration, template, image, confinement, and watchdog tests

Never add a host shell escape, arbitrary host path mount, unmanaged-domain
operation, LAN bridge, passthrough device, persistent credential, or mutable VM
image to this project.
