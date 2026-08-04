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
- Changes here require `make vm-unit` plus the smallest real suite selected by
  the repository verification map.
