# AGENTS.md

## Communication

- Perform internal reasoning and technical analysis in English.
- Respond to the user in Korean unless the user explicitly requests another
  language.

## Change management

- Preserve user-owned and unrelated changes already present in the worktree.
- Keep each change narrowly scoped and independently reversible.
- Commit completed, recoverable work units as soon as they are verified, even
  when the overall session or requested feature is not yet complete.
- Do not wait until the end of a session to create all commits.
- Stage only the files that belong to the current work unit.
- Before committing, review the staged diff and run checks appropriate to the
  affected files.
- Use Conventional Commits for every commit message, for example
  `feat(hyprland): add cyberpunk desktop theme` or
  `fix(fcitx5): map right alt to Hangul toggle`.
- Do not amend, squash, rebase, reset, or otherwise rewrite existing commits
  unless the user explicitly requests it.

## Repository boundaries

- Use Ansible for root-owned system state and native package declarations.
- Use chezmoi sources under `home/` for selected user configuration.
- Keep observed machine state under `state/` descriptive; do not consume it as
  desired configuration.
- Never commit credentials, private keys, account data, Wine prefixes, cloud
  tokens, VM disk images, caches, or mutable user documents.
- Preserve Arch Linux's full-upgrade model; never automate a partial upgrade.

## Design changes

- Before modifying or reviewing user-visible appearance or interaction, invoke
  and follow both repository-scoped skills: `$design-taste-frontend` and
  `$ui-ux-pro-max`.
- Resolve every user-visible change to a `surface-id` in
  `docs/ui-surfaces.yaml` before editing. If the surface or required state has
  no approved concept, stop implementation and invoke `$enoshima-concept-art`
  with the built-in image generation skill.
- Follow the nearest nested `AGENTS.md` for surface-specific design, security,
  localization, accessibility, evidence, and focused-test contracts.

## Entrypoints

- Extend the existing `bootstrap.sh`, `scripts/validate.sh`, and
  `scripts/postflight.sh` entrypoints when adding managed workstation features.
- Do not create parallel feature-specific bootstrap, validation, convergence,
  or postflight entrypoints unless the user explicitly requests a separate
  workflow.
- Keep the default bootstrap path one-shot for all non-interactive desired
  state, and reserve only credentials, account enrollment, destructive
  approvals, and visual acceptance for documented manual gates.

## Verification

- Use the repository verification selector; do not manually broaden routine
  implementation work to `vm-full`.
- Run selected focused/static checks first. Use `dev` mode only for diagnostic
  feedback; it is never completion evidence.
- A recoverable work unit is complete after its fresh affected `checkpoint`
  passes. Commit that unit before starting unrelated work.
- Run the single, duplicate-free `release` plan only after code and canonical
  evidence are frozen.
- Use the project-scoped `enoshima_vm` MCP server for VM work that can exceed
  five minutes. If it is unavailable, do not fall back to long `make vm-*`
  commands or interactive terminal polling; finish focused checks and report
  `VM_BLOCKED` with the missing verification.
- Only fresh `vm_run_suite`/`vm_run_affected` checkpoint results or the exact
  `vm_run_plan release` result are authoritative for their declared scope.
  Named and affected runners cannot claim release authority. Low-level tools
  and repaired guests are diagnostic only.
- Stop after the same infrastructure fingerprint occurs twice without a
  relevant source change. Keep raw logs in artifacts and return only the first
  actionable failure and its artifact path.
- VM-harness, suite, plan, image, MCP, or verification-workflow changes require
  `make vm-unit` and the smallest real suite selected by the repository map.
- Documentation-only, comment-only, and non-executable metadata changes may
  omit VM execution when the selector records that reason. Workflow metadata
  that changes test execution is not documentation-only.
- Preserve every T5 physical gate returned by the verification plan. VM success
  never substitutes for `docs/VM-TESTING.md` physical acceptance.
- In the final response, name each verification mode and VM suite run, its
  result and artifact location, plus any remaining T5 gate or exact blocker.

## Agent coordination

- Auxiliary agents inherit the current session model and reasoning settings;
  repository files must not set model-specific routing.
- Use at most three auxiliary agents for read-heavy exploration, impact
  analysis, log triage, or evidence review. Keep at most one write-capable
  agent active and never assign overlapping files.
- Heavy VM suites run serially. Do not split a release plan across agents.
