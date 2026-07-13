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
