# Enoshima VM testing

Enoshima uses disposable Arch Linux guests to exercise the same
`bootstrap.sh`, `scripts/validate.sh`, and `scripts/postflight.sh` entrypoints
used on the workstation. The runner orchestrates those entrypoints; it does not
maintain a second installation path.

## Test boundary

| Tier | Target | Automated evidence |
| --- | --- | --- |
| T0 | Current worktree | Shell, YAML, Ansible, QML/config, package, and runner unit checks |
| T1 | Latest Arch cloud VM | Clean bootstrap and structured postflight report |
| T2 | Pinned Arch cloud VM | Second convergence, package/chezmoi idempotency, reboot |
| T3 | Pinned Arch desktop VM | Hyprland IPC, virtual displays, key/pointer input, greetd login, registry-driven screenshots |
| T4 | OVMF/vTPM boot VM | GPT, LUKS2, Btrfs, UKIs, Secure Boot rejection, TPM and recovery |
| T5 | Physical `tpx1c13` | OLED/EDID/120 Hz, i915/VPU, camera, fingerprint, WWAN, battery, suspend, dock, Lenovo firmware |

VM success never substitutes for T5 hardware acceptance. In particular, the
runner neither enrolls workstation Secure Boot keys nor changes the
workstation LUKS or TPM state.

## Verification workflow

Routine changes use the repository-owned selector in
`tests/verification-map.yaml`; they do not start with a hand-picked broad VM
lane. The selector returns the focused checks, registered UI surfaces, VM
suites, and T5 physical gates required by the current change. It is independent
of the Codex model and reasoning settings.

The selector computes one sorted union from all of these change sources:

- committed changes in `BASE...HEAD`
- staged changes
- unstaged changes
- non-ignored untracked files

Renames contribute both paths. The selection records `HEAD`, the selected
paths, and a digest of their current contents. Generated paths declared by the
map do not affect that digest. Before each selected VM suite and after a
passing suite, the runner verifies `HEAD` and the original selected-path digest
are still unchanged. A change to that planned source identity requires a new
plan.

Registered implementation paths in `docs/ui-surfaces.yaml` select their
surface evidence and the appropriate desktop, login, and `ui-review` lanes.
Other managed paths use explicit rules in `tests/verification-map.yaml`. Known
documentation, metadata, generated, and T0-only changes may omit VM execution
with a recorded `vmOmittedReason`. A changed path under a declared runtime area
that matches neither a registered surface nor a verification rule fails as
`UNMAPPED_RUNTIME_PATH`. This fail-closed result must be fixed in the map; it is
never converted silently into either no VM work or `vm-full`.

The three evidence modes apply overrides to the same canonical suite YAML:

| Mode | Scope and cost | Evidence contract |
| --- | --- | --- |
| `dev` | Affected suites; one Electron and reboot iteration; representative affected UI states; fail fast | Diagnostic only and never completion evidence. Policy permits a reused diagnostic environment, although the current runner still creates a fresh overlay. |
| `checkpoint` | Affected suites; three Electron and reboot iterations; all required states/locales/scales for affected UI surfaces; fail fast | Authoritative evidence from a fresh overlay for one recoverable work unit. |
| `release` | Frozen, duplicate-free release plan; twenty Electron iterations, ten reboot iterations, and the full UI matrix | Authoritative fresh-overlay evidence for the final source identity. Non-blocking suite failures are retained while the remaining plan runs; a `VM_BLOCKED` result stops it. |

The current release plan is serial and lists every canonical suite once, in
this exact order:

```text
smoke -> converge -> reboot -> desktop -> login -> ui-review -> boot-security
```

An eligible transient infrastructure failure may create one second fresh
attempt for a plan entry; it does not duplicate that suite in the release
plan. Image checksum, signature, keyring, and manifest-integrity failures are
not retryable. The synchronous MCP and trusted CI outer budgets cover two full
attempts of every canonical suite plus setup, evidence, and cleanup headroom.

## Host provisioning

The `vm_test_host` capability on `tpx1c13` installs the native packages in
`packages/vm-host.txt`. VM guests explicitly set the capability to false, so
QEMU and libvirt are not recursively installed during guest convergence.

Apply the normal desired state, then check KVM and the unprivileged libvirt
connection:

```bash
./bootstrap.sh --conflict-policy backup
make vm-preflight
virt-host-validate qemu
virsh --connect qemu:///session uri
```

`make vm-preflight` requires read/write access to `/dev/kvm`, `virsh`,
`qemu-img`, SSH tools, `gpgv`, and a NoCloud image builder. The default URI is
`qemu:///session`; override it only for a dedicated trusted runner:

```bash
ENOSHIMA_VM_LIBVIRT_URI=qemu:///system make vm-preflight
```

No base image or VM disk belongs in Git. Verified base images are cached under
`~/.cache/enoshima-vm/images`; run records and reports live under
`~/.local/state/enoshima-vm/runs`. Set `ENOSHIMA_VM_CACHE_ROOT` and
`ENOSHIMA_VM_STATE_ROOT` to move those two confined roots.

## Running suites

Use the selector before routine implementation verification. `BASE` defaults
to `origin/main`, and `MODE` defaults to `checkpoint` for the read-only plan and
focused-check targets:

```bash
make verification-plan BASE=origin/main MODE=checkpoint
make check-affected BASE=origin/main MODE=checkpoint
make vm-dev BASE=origin/main
make vm-checkpoint BASE=origin/main

# Run once, only after code and canonical evidence are frozen.
make vm-release BASE=origin/main
```

`verification-plan` prints changed paths, focused checks, affected surfaces,
ordered suites, T5 gates, source identity, and selection reasons without
running a check. `check-affected` runs only the selected focused/static checks;
it does not run a VM. Run `vm-dev` only for feedback, then use a fresh passing
`vm-checkpoint` as the completion evidence for the work unit. `vm-release`
runs the fixed plan above after all work units and evidence are frozen.

`make vm-full` is a compatibility alias for `make vm-release`; it is not a
second plan and must not be added after `vm-release`. `make vm-trusted` is the
corresponding alias for affected checkpoint verification.

Before bootstrap, suites also seed valid
`~/.cache/codex-desktop/electron/electron-v*-linux-*.zip` archives and the
installed source checkout's `Codex.dmg`, plus the managed Node runtime archive,
into the guest's matching build caches. The runner validates the archive
containers and Apple UDIF trailer, verifies every transfer with SHA-256,
requires the managed Node archive to match
`packages/codex-desktop-node-runtime.sha256`, requires the DMG to match
`packages/codex-desktop-dmg-sha256.txt`, and records each name, size, and digest
in the run observations. A stale but structurally valid host payload therefore
fails before guest bootstrap instead of poisoning a long release run. The
installer consumes these verified caches, so repeated release suites do not
depend on either the 600 MiB DMG or managed Node runtime download completing
during bootstrap. If a host cache is absent, the production installer retains
its normal network download path. Set
`ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR`, `ENOSHIMA_VM_CODEX_NODE_ARCHIVE`, or
`ENOSHIMA_VM_CODEX_DMG` to select a different host cache location.

Pinned bootstrap suites also maintain a base-image-scoped package payload cache
under `~/.cache/enoshima-vm/pacman`. Only complete regular
`*.pkg.tar.<compression>` payloads and their detached `.sig` files are retained;
partial downloads, repository databases, locks, and guest configuration never
enter the cache. A bootstrap run imports any previously verified payload before
Ansible and exports newly completed packages even when a later bootstrap step
fails. The runner bounds individual and aggregate sizes, rejects links and
unsafe archive members, checks the seed transfer with SHA-256, and keeps each
Arch image snapshot in a separate directory. Pacman still validates the pinned
repository metadata, checksums, and package signatures before installation.
This cache removes repeated multi-gigabyte Archive downloads without changing
Arch's full-upgrade transaction or making a repaired overlay count as a passing
run.

Initial SSH readiness allows 20 minutes because the reproducible cloud image
can spend up to 18 minutes completing its bounded Archive package downloads
before sshd becomes reachable. Reboot SSH cycling and ordinary guest commands
retain their separate five-minute limits.

The NoCloud seed runtime-masks `systemd-time-wait-sync.service`. QEMU already
provides the current host RTC, while the isolated guest may never receive an
external NTP reply; without the runtime-only mask, Arch's `pacman-init.service`
can hold `cloud-final` and sshd behind `time-sync.target`. The mask exists only
inside the disposable guest and does not alter the workstation policy.

The seed also routes guest DNS directly through Cloudflare and Quad9. QEMU's
slirp proxy otherwise inherits the first host `resolv.conf` entry, which can be
an unreachable Docker or VPN resolver even when the host's resolver stack can
fall through to a working secondary. These public DNS endpoints use the same
internet-only egress boundary as package mirrors; private LAN ranges remain
blocked.

The VM profile makes NetworkManager the managed network owner and masks the
cloud image's stale `systemd-networkd-wait-online.service`. This prevents a
managed reboot from leaving a failed two-minute wait job after networking has
already converged through NetworkManager.

The direct lane targets remain available for harness development and bounded
investigation:

```bash
make vm-smoke
make vm-converge
make vm-reboot
make vm-desktop
make vm-login
make vm-ui-review
make vm-boot-security
make vm-full
```

Direct lane runs do not prove that the selector's complete affected set was
covered. For repository task completion, use `vm-checkpoint` or `vm-release`.

The current runner creates a new qcow2 overlay in every mode and uploads the
current worktree, including non-ignored untracked files. It therefore tests
uncommitted edits, not a fresh clone of the remote default branch. The `dev`
contract permits future diagnostic reuse, so a fresh `dev` overlay still does
not become authoritative evidence.

The lanes have distinct purposes:

- `smoke` follows the latest signed Arch cloud image and current repositories.
- `converge`, `reboot`, `desktop`, `login`, and `ui-review` use a versioned signed image and the
  complete Arch Linux Archive repository snapshot declared in
  `tests/vm/images/manifest.yaml`.
- `converge` retains a virtual GPU across its reboot so the managed
  greetd/Hyprland greeter is validated against a real compositor backend after
  the second, idempotent bootstrap.
- `reboot` logs in through production greetd, waits for a real application
  client, and asks Hyprland to spawn `desktop-power` from the active local
  Wayland session. This preserves the same login1/polkit identity as the Power
  Menu instead of accidentally testing a remote SSH authorization path. Every
  one of its ten iterations must close the initial application set, change the
  boot ID, log in again, and verify the persisted power checkpoint.
- `desktop` enables virtio-gpu 3D/SPICE, logs in through the production greetd
  and Enoshima Greeter path to obtain a real seat0 session, creates 2880×1800
  at 1.5× and 2560×1440 at 1× headless outputs, proves the Ghostty and
  workspace key bindings, validates monitor/input/client IPC state, waits for
  the launcher layer, and validates desktop and launcher PNG evidence. It also
  drives a pinned, network-independent Electron fixture through Wayland and
  XWayland with the managed-app Enoshima system-decoration policy,
  tiled/floating/maximized modes, and twenty repetitions of Enoshima caption
  actions. The matrix fails
  on a wrong address, lost client, unexpected process exit, coredump, or failed
  minimize/restore/maximize/close-reopen transition. The
  greeter evidence is captured through its real Wayland socket because the
  accelerated `virtio-vga-gl` scanout does not expose a QEMU `screendump`
  surface.
- `login` leaves production greetd enabled, assigns a per-run hex password,
  initializes an empty disposable login keyring with that same password,
  captures the greeter console, types the password through QEMU input, and
  proves the real user Hyprland session becomes reachable. This prevents a
  first-use keyring prompt from obscuring desktop evidence without weakening
  production authentication. It never adds autologin to production
  configuration.
- `ui-review` logs in through that same production path, reads the required
  state, locale, and scale matrix from `docs/ui-surfaces.yaml`, keeps a
  1280×800 logical canvas across 1×, 1.25×, and 2× headless outputs, and
  renders the production Quickshell components with VM-only deterministic
  model inputs. It also launches the production Enoshima Greeter binary for
  its approved visual states while the `login` lane continues to prove real
  greetd/PAM authentication, drives the production SwayNC process through its
  notification D-Bus protocol, and launches an undecorated GTK Wayland client
  through the real native title-bar plugin. It covers all ten registered
  surfaces and all 432 required state/locale/scale matrix entries. Quickshell
  review acknowledgements include a traversal of the live visible text tree;
  truncation or painted bounds outside the allocated item is recorded as a
  text-overflow failure in the capture sidecar. A capture is accepted only
  after two consecutive compositor frames are stable: either at most 0.25% of
  pixels changed, normalized RMSE remains at most 0.004, or ImageMagick's SSIM
  error remains at most 0.005. A failure retains the preceding frame, a
  difference image, and the best measured values so a real animation cannot be
  confused with harmless GPU quantization noise.
- `boot-security` creates a separate 96 GiB sparse disk, partitions only guest
  `/dev/vdb`, builds LUKS2 and Btrfs subvolumes, creates and signs UKIs with
  disposable keys, enrolls the VM firmware, tests PCR 7 TPM unlock, proves the
  recovery-key path, and verifies an unsigned UKI cannot boot. Its secure
  domain also provides the virtual GPU required by the enabled production
  greetd service after boot.

The boot-security lane initially unlocks with a randomly generated disposable
recovery key because Secure Boot changes PCR 7 after key enrollment. It then
enrolls the vTPM and proves both automatic unlock and recovery after removing
the TPM slot. The login password, recovery key, boot disk, OVMF NVRAM, vTPM
state, seed, overlay, and SSH key are removed on cleanup.

Use the CLI directly for investigation:

```bash
MISE_CONFIG_FILE=home/dot_config/mise/config.toml mise exec -- \
  uv run --locked --project tests/vm enoshima-vm run smoke --keep-on-failure

MISE_CONFIG_FILE=home/dot_config/mise/config.toml mise exec -- \
  uv run --locked --project tests/vm enoshima-vm list-runs

MISE_CONFIG_FILE=home/dot_config/mise/config.toml mise exec -- \
  uv run --locked --project tests/vm enoshima-vm clean
```

Repairs made interactively in a failed VM are diagnostic only. A passing result
must come from a new overlay.

## Reports and failure handling

Each run records its source commit, dirty flag, worktree hash, untracked-file
list, lifecycle state, current step, and classified failure. Categories include
image, VM boot, guest-agent, SSH, validation, bootstrap, postflight,
idempotency, reboot, desktop, visual, Secure Boot, and harness failures.

Collected evidence includes package state, failed and configured system/user
units, current-boot journal, `dmesg`, cloud-init status, bootstrap JSON/logs,
postflight JSON, Hyprland JSON, screenshots, and boot-security reports. The
runner also writes one JUnit testcase per suite step and preserves reports after
deleting mutable VM media.

All postflight skips are explicit. A suite has a checked allowlist, and any
unexpected skip fails the run. A background watchdog enforces the suite's
maximum duration and removes disposable media even when the controlling
process disappears. `--keep-on-failure` leaves a failed VM available only until
that same deadline.

Affected and release operations classify the first actionable failure with a
`failureOrigin` of `PRODUCT`, `TEST_FIXTURE`, or `INFRA`, and attach a stable
`failureFingerprint`. The fingerprint excludes volatile run/domain IDs,
timestamps, forwarded ports, temporary paths, PIDs, and long hexadecimal
values so the retry decision follows the failure rather than one disposable
guest.

Product and test-fixture failures are not retried against an unchanged
suite-specific retry digest. Each digest hashes the complete current source
snapshot matched by that suite's retry dependencies; it never derives identity
from only the current diff. Checkpoint selection and retry dependencies are
separate: shared runner, validation, bootstrap, and managed-runtime inputs feed
every suite that consumes them, while lane-specific contracts and runtime
inputs invalidate only their consumer lanes. Documentation, host-only tests,
and instructions remain excluded from later suite-step identity. A failure in
the early `run_validate` step instead compares the complete frozen source-tree
digest, so changing a validation test unblocks that validation failure without
unfreezing an unrelated later desktop assertion. Non-authoritative `dev`
failures never block a later checkpoint or release attempt. The separate
source-freeze identity covers HEAD and the complete tracked plus
non-ignored-untracked upload payload, including paths, contents,
symlink targets, and executable modes. The runner freezes an immutable archive,
derives the actual digest from that archive, and uploads it only when it matches
the plan. A transient infrastructure failure receives at most one additional
fresh-overlay attempt. If the same infrastructure fingerprint is recorded
twice without a relevant source change, current and later operations return
`VM_BLOCKED` before creating another VM.

Failures before a domain can be created are persisted as immutable run records,
with raw error details and a traceback under their artifact tree, so retry
history survives later calls. A record becomes fresh and mode-authoritative
only after an overlay exists. KVM, libvirt, qcow2, host-filesystem, and explicit
transport or timeout failures are classified as `INFRA`; harness/schema errors remain
`TEST_FIXTURE`. If HEAD, changed paths, content, symlink targets, or executable
bits move during any attempt, its persisted record is marked non-authoritative
and source-invalidated before the operation stops.

Each run summary, run list, selector view, low-level exec/query result, and
affected/release operation response is intentionally bounded to 32 KiB. A run
summary includes at most 80 excerpt lines (and at most 16 KiB of excerpt text),
plus the mode, source identity, verdict, first failed step, origin,
fingerprint, artifact root, and next verification. Large selector views retain
counts and bounded previews in both MCP and CLI output. Manual
exec output and large desktop queries are written to artifacts before a
bounded preview is returned. Full journals, stack traces, screenshot
differences, observations, and JUnit output stay under the run artifact tree.
A complete affected/release report is retained as
`plans/<operation-id>/plan.json` under the configured state root; the response
returns that directory as `artifactRoot` and only the first full actionable
failure needed for triage. The runner creates this report before focused checks
or VM creation, atomically updates it after each check and suite attempt, and
keeps it non-authoritative until the operation reaches a final verdict. A host
restart, cancellation, or outer timeout therefore leaves the latest incomplete
plan and every completed artifact available for recovery.

`vm_list_runs` returns newest records first in a bounded page with `total`,
`truncated`, and `nextCursor`; pass the cursor back to continue. Worktree upload
returns counts and a bounded untracked-file sample while preserving the full
manifest under the run artifact tree. Focused checks capture stdout and stderr
to a dedicated artifact directory. Named, affected, and release run entrypoints
execute those checks and revalidate the source freeze before starting a VM.

## Codex control surface

The project-scoped `.codex/config.toml` starts the STDIO `enoshima_vm` MCP
server from the locked Python project. The server exposes:

```text
verification_plan     vm_run_affected       vm_run_plan
vm_create             vm_run_suite          vm_status
vm_wait               vm_upload_worktree    vm_exec
vm_reboot             vm_poweroff           vm_screenshot
vm_query_desktop      vm_collect_artifacts  vm_destroy
vm_list_runs
```

For Codex, `verification_plan` is the read-only selector view,
`vm_run_affected` is the synchronous `dev` or `checkpoint` execution, and
`vm_run_plan` is the synchronous frozen `release` execution. One call owns the
serial suite sequence and returns its bounded result; do not poll a terminal,
`vm_status`, or `vm_wait` while it runs. Heavy suites are never split across
agents.

The MCP server is required by project configuration and its tool timeout spans
the release plan's full declared 30.5-hour budget. If the server cannot start
or perform VM work, Codex must finish the selected focused checks and report
`VM_BLOCKED` with the missing suite evidence. It must not fall back to a long
`make vm-*` shell process or interactive terminal polling. The CLI and Make
targets remain available to a human operator and for short, bounded harness
diagnosis.

The service rejects unmanaged run IDs and libvirt domains, allows only the
`enoshima-test-` prefix, limits active domains to one, caps CPU/RAM/disk, binds
SSH forwarding to `127.0.0.1`, creates no host filesystem mounts or device
passthrough, and rejects LAN-enabled suite definitions. The guest firewall
allows established traffic and both UDP/TCP DNS to QEMU's isolated proxy while
rejecting every other private address range.
Every service action is written to a mode-0600 JSONL audit log with sensitive
arguments redacted.

Codex should use `vm_run_affected` for affected checkpoint evidence and
`vm_run_plan` for final release evidence. `vm_run_suite` accepts only `dev` or
`checkpoint`, applies the same retry/source-freeze policy to one named lane,
and cannot claim release authority. Only `vm_run_plan release` can create a
release result, and its loader enforces the exact canonical order and unique
membership. The lower-level tools are for evidence gathering and bounded
diagnosis, not a repaired-guest passing result. Destruction requires explicit
approval in the project MCP policy.

## Image and update policy

Both image lanes require SHA-256 validation and verification with the dedicated
Arch `arch-boxes` release key before a base image enters the cache. The
repository-pinned public key is copied verbatim from the official `arch-boxes`
project README and has primary fingerprint
`1B9A16984A4E8CB448712D2AE0B78BF4326C6F8F`. `arch-cloud-latest` obtains the
current checksum at run time. `arch-cloud-reproducible` pins a versioned image,
checksum, signature, and one full archive date. Never pin or downgrade
individual Arch packages and never replace `pacman -Syu` with a partial upgrade.

When advancing the reproducible lane:

1. Select one versioned image from the official Arch image index.
2. Update its image URL, checksum, signature URL, and matching archive date in
   `tests/vm/images/manifest.yaml`.
3. Confirm that date's `core`, `extra`, and `multilib` repository databases
   exist in the Arch Linux Archive.
4. Run T0, `vm-converge`, `vm-desktop`, `vm-ui-review`, and
   `vm-boot-security` before merging.

References: [official Arch cloud image index](https://geo.mirror.pkgbuild.com/images/latest/),
[Arch cloud-init guidance](https://wiki.archlinux.org/title/Cloud-init), and
[the Model Context Protocol Python SDK](https://github.com/modelcontextprotocol/python-sdk).

## Trusted CI

`.github/workflows/validate.yml` runs static validation and runner unit tests on
GitHub-hosted infrastructure for pushes and pull requests. It never reaches a
self-hosted hypervisor.

`.github/workflows/vm-trusted.yml` runs the selector-driven `vm-trusted`
checkpoint target for trusted `main` pushes. Manual dispatch additionally
exposes named individual lanes, exhaustive `ui-review`, and the `full` alias
for the release plan without running untrusted pull-request code on the
hypervisor. The separate
`.github/workflows/vm-boot-security.yml` runs on a manual or scheduled trusted
host. Both require the `self-hosted`, `linux`, `x64`, `enoshima-kvm`, and
`trusted` labels, use read-only repository permissions, serialize all KVM jobs,
store state in the runner temporary directory, upload reports, and always clean
the domain.

Do not add `pull_request`, `pull_request_target`, fork code, repository-write
tokens, production keys, LAN bridges, or physical device passthrough to either
trusted workflow.

## Physical release gate

Before treating a desktop or boot change as released, run the normal
postflight checks on `tpx1c13` and review the hardware behaviors excluded from
the VM. Suspend/hibernate, TPM enrollment, Secure Boot key changes, firmware
updates, WWAN changes, and applying real boot artifacts remain explicit manual
operations under the installation and workstation contracts.

The selector carries applicable T5 obligations into `physicalGates` in the
plan and operation result:

| Change class | T5 gate identifiers |
| --- | --- |
| Restart and sleep | `suspend-resume`, `sleep-battery-drain`, `post-resume-thermal` |
| Display hardware | `internal-oled-edid-refresh-rate`, `external-display-dock` |
| Visible UI review | `internal-external-display-review` |
| Authentication hardware | `fingerprint-enrollment-authentication` |
| Boot security | `secure-boot-enrollment`, `tpm-unlock-recovery` |
| WWAN | `wwan-connectivity-shutdown` |

Preserve applicable names in the final verification report until they are
completed on `tpx1c13`. A passing checkpoint or release plan never clears a T5
gate.
