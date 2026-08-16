# VM harness instructions

## Modes and evidence

- Keep one canonical suite definition per lane. Apply `dev`, `checkpoint`, and
  `release` behavior through `verification-modes.yaml`; do not clone suites per
  mode.
- `dev` is non-authoritative and may use a reduced matrix or reused diagnostic
  environment. `checkpoint` and `release` must use fresh disposable overlays.
- The selector owns affected suite and surface choice. Unknown runtime paths
  must fail closed as `UNMAPPED_RUNTIME_PATH`, never silently widen to all
  suites or silently skip VM coverage.
- A release plan lists every canonical suite exactly once and runs serially.

## Failure handling

- Preserve the existing detailed failure category and add a stable
  `failureOrigin` (`PRODUCT`, `TEST_FIXTURE`, or `INFRA`) and
  `failureFingerprint`.
- Normalize timestamps, run/domain IDs, ports, temporary paths, PIDs, and
  secrets out of fingerprints.
- Retry an eligible transient infrastructure failure at most once; image
  integrity failures receive no automatic retry. If the same
  fingerprint repeats without a relevant source change, return `VM_BLOCKED`.
  Never rerun an unchanged product assertion.
- Bound every long guest command with an absolute deadline and a shorter
  no-output or remote-command deadline. Classify a bounded fixture command
  stall as `TEST_FIXTURE`; reserve retryable `SSH_TIMEOUT` infrastructure
  failures for connection establishment or demonstrated transport loss.
- Persist pre-domain failures in the synthetic attempt ledger. Keep
  source-freeze identity separate from suite-specific retry identity, and
  invalidate any run whose HEAD, paths, contents, symlinks, or executable bits
  change during the attempt.
- Failed-guest repairs are diagnostic only. Authoritative evidence always
  comes from a new overlay after a relevant source or fixture change.

## Results and safety

- MCP and CLI results contain the mode, source/worktree identity, verdict,
  first failed step, origin, fingerprint, a bounded excerpt, artifact root, and
  smallest next verification. Raw journals, stack traces, image diffs, and
  JUnit remain in the artifact tree.
- Keep MCP summaries below 32 KiB and excerpts below 80 lines.
- Preserve the one-active-domain limit, isolated networking, bounded resources,
  disposable credentials, path confinement, and immutable reports.
- Keep the project MCP transport independent from mutable harness imports.
  Long run tools must start one detached worker, persist a mode-0600 operation
  ledger, and return promptly. Recover a disconnected client with the same
  operation ledger; never require killing the MCP server to reload source.
- Bound every non-durable fresh worker with a tool-appropriate deadline. On
  expiry, terminate and then kill its entire process group while keeping the
  MCP transport available for a subsequent call. A mutating supervisor must
  inherit and directly retain `active.lock`; if its proxy parent dies, parent-
  death signaling must make it terminate its payload group before releasing
  that lock.
- Hold the durable-operation lock for the worker lifetime. A competing owner is
  contention, never an orphan to kill. Bounded wait calls may observe progress
  but must not become a second source of truth for the canonical plan result.
- Give every durable operation a transport-independent absolute deadline that
  includes focused checks, both allowed suite attempts, per-attempt overhead,
  and finalization. Focused checks also require their own absolute and idle
  deadlines with raw partial-output artifacts.
- Record planned and actual final source identities under distinct names. A
  changed or unavailable final identity invalidates the result rather than
  allowing planned identity to masquerade as completed evidence.
- Reject every low-level mutating VM call while a durable operation owns that
  lock. The global lock lives at `/run/user/$UID/enoshima-vm/active.lock`,
  independent of the configurable operation-ledger state root, so a legacy
  CLI or MCP caller cannot bypass it with `ENOSHIMA_VM_STATE_ROOT`. Read-only
  status and plan calls may proceed, but no second client may alter the guest
  or its evidence during a canonical run.
- Normalize fresh MCP workers onto the canonical passwd home plus user runtime,
  config, and cache environment before opening `qemu:///session`; overwrite
  missing, empty, and noncanonical inherited XDG values. Record that logical
  session identity in every run and reject mismatched or identity-less
  destructive cleanup after a transport reconnect.
- Destroy disposable domains fail-closed: prove stop, undefine, and final
  absence before removing an overlay, seed, vTPM state, or disposable key. The
  watchdog must use the same backend contract and preserve files on failure.
- A live one-domain owner is contention, not an orphan. Never reap it from a
  prefix match alone or consume infrastructure retry budget while it is still
  owned by an active operation.
- Changes here require `make vm-unit` plus the smallest real suite selected by
  the repository verification map.
