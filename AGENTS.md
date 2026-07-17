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
- Design work includes color, typography, spacing, hierarchy, layout,
  iconography, animation, interaction feedback, navigation, accessibility,
  concept assets, and the QML, GTK CSS, Waybar, SwayNC, Hyprlock, SDDM, or
  Hyprland configuration that controls those qualities.
- Read the affected implementation and tests together with
  `docs/DESKTOP-UI-CONCEPT.md`, `docs/DESKTOP-UX-REFERENCES.md`, and any more
  specific design document before editing. Explicit user direction and these
  repository contracts take precedence over generic skill recommendations.
- Use Taste Skill for audit-first visual direction, hierarchy, consistency,
  anti-pattern review, and final polish. Use UI/UX Pro Max for local evidence
  searches covering accessibility, interaction, typography, color, layout,
  and purposeful motion. Treat generated recommendations as candidates, not
  desired state.
- The current stack is Hyprland, QML, GTK CSS, Waybar, SwayNC, Hyprlock, and
  SDDM. Do not default to HTML/Tailwind or add web frameworks, design-system
  packages, remote fonts, CDNs, or generated assets merely because a skill
  suggests them. Do not create a parallel persisted design system.
- Do not invoke these skills for changes with no user-visible presentation or
  interaction impact, such as package declarations, services, network logic,
  inventory, or non-visual scripts.
- Validate design changes with the affected focused tests and
  `scripts/validate.sh`; retain documented internal/external display review as
  the final gate for visual behavior that static checks cannot prove.

### Concept-first surface contract

- Resolve every user-visible change to a `surface-id` in
  `docs/ui-surfaces.yaml` before editing its implementation.
- If the surface or required state has no approved concept, stop UI
  implementation and invoke `$enoshima-concept-art` together with the built-in
  image generation skill.
- Generate a three-direction candidate board, record the selected direction and
  rationale, then generate an implementation-ready state/redline board.
- Copy canonical image output into `docs/assets/concepts/<surface-id>/` and
  record prompts, references, states, invariants, and acceptance criteria in
  `docs/concepts/<surface-id>.yaml`.
- Do not mark a concept approved until its asset and spec exist. Do not treat
  generated concept pixels as golden tests.
- After implementation, compare real internal/external display screenshots with
  the approved hierarchy, spacing, typography, controls, states, localization,
  clipping, and accessibility contract.
- Run `scripts/check-ui-concept-coverage` for every design change. New visible
  QML/CSS/Waybar/SwayNC/Hyprlock/greeter/window-decoration surfaces may not be
  exempted merely because they are small or transient.

## Entrypoints

- Extend the existing `bootstrap.sh`, `scripts/validate.sh`, and
  `scripts/postflight.sh` entrypoints when adding managed workstation features.
- Do not create parallel feature-specific bootstrap, validation, convergence,
  or postflight entrypoints unless the user explicitly requests a separate
  workflow.
- Keep the default bootstrap path one-shot for all non-interactive desired
  state, and reserve only credentials, account enrollment, destructive
  approvals, and visual acceptance for documented manual gates.
