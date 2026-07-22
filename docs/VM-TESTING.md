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

Every suite starts from a new qcow2 overlay and uploads the current worktree,
including non-ignored untracked files. It therefore tests uncommitted edits,
not a fresh clone of the remote default branch.

Before bootstrap, suites also seed valid
`~/.cache/codex-desktop/electron/electron-v*-linux-*.zip` archives into the
guest's matching build cache. The runner verifies every transfer with SHA-256
and records the archive name, size, and digest in the run observations. This
keeps repeated release suites independent of a transient GitHub release-asset
stall; if no host cache exists, the production installer retains its normal
network download path. Set `ENOSHIMA_VM_CODEX_ELECTRON_CACHE_DIR` to select a
different host cache directory.

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

The lanes have distinct purposes:

- `smoke` follows the latest signed Arch cloud image and current repositories.
- `converge`, `reboot`, `desktop`, `login`, and `ui-review` use a versioned signed image and the
  complete Arch Linux Archive repository snapshot declared in
  `tests/vm/images/manifest.yaml`.
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
  recovery-key path, and verifies an unsigned UKI cannot boot.

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

## Codex control surface

The project-scoped `.codex/config.toml` starts the STDIO `enoshima_vm` MCP
server from the locked Python project. The server exposes:

```text
vm_create             vm_run_suite          vm_status
vm_wait               vm_upload_worktree    vm_exec
vm_reboot             vm_poweroff           vm_screenshot
vm_query_desktop      vm_collect_artifacts  vm_destroy
vm_list_runs
```

The service rejects unmanaged run IDs and libvirt domains, allows only the
`enoshima-test-` prefix, limits active domains to one, caps CPU/RAM/disk, binds
SSH forwarding to `127.0.0.1`, creates no host filesystem mounts or device
passthrough, and rejects LAN-enabled suite definitions. The guest firewall
allows established traffic and DNS while rejecting private address ranges.
Every service action is written to a mode-0600 JSONL audit log with sensitive
arguments redacted.

Codex should use `vm_run_suite` for a final verdict. The lower-level tools are
for evidence gathering and bounded diagnosis. Destruction requires explicit
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

`.github/workflows/vm-trusted.yml` runs fast, convergence, reboot, desktop, and
greetd-login lanes for trusted `main` pushes. Manual dispatch additionally
exposes the exhaustive `ui-review` and release-level `full` lanes without
running untrusted pull-request code on the hypervisor. The separate
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
