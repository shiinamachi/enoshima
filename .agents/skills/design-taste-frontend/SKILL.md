---
name: design-taste-frontend
description: Project-scoped design critique and redesign workflow for the Arch desktop surfaces in this repository. Use together with ui-ux-pro-max when changing or reviewing user-visible color, typography, spacing, hierarchy, layout, iconography, motion, interaction feedback, accessibility, QML, GTK CSS, Waybar, SwayNC, Hyprlock, SDDM, or concept assets. Skip non-visual system, package, service, network, and scripting work.
---

# Taste Skill for the Cyberpunk Library desktop

Use Taste Skill as a contextual critique layer, not as a replacement design
specification. This repository is a desktop shell built with QML, GTK CSS,
Waybar, SwayNC, Hyprlock, SDDM, and Hyprland configuration. It is not the
React/Tailwind landing-page stack assumed by the upstream defaults.

## Authority order

Apply decisions in this order:

1. The user's explicit direction for the current task.
2. `AGENTS.md`, `docs/DESKTOP-UI-CONCEPT.md`,
   `docs/DESKTOP-UX-REFERENCES.md`, and any more specific design document.
3. Existing semantic tokens, implementation contracts, tests, and toolkit
   constraints in the affected surface.
4. Applicable Taste Skill heuristics.

The established dark-first Cyberpunk Library language is intentional. Its
cyan focus, violet selection, magenta expression, and semantic
success/warning/critical colors override upstream generic bans on purple,
neon, or multiple semantic accents. The documented control/panel/pill radius
roles override a one-radius heuristic.

## Workflow

1. Read the affected implementation, its tests, and the relevant repository
   design documents before proposing a visual change.
2. Treat changes to an existing surface as **Redesign - Preserve** unless the
   user explicitly authorizes an overhaul. Inventory the current hierarchy,
   tokens, states, interactions, and accessibility behavior first.
3. State a concise design read and choose reasoned 1-10 values for design
   variance, motion intensity, and visual density. Interpret the dials for a
   desktop shell, not a marketing page.
4. Invoke `ui-ux-pro-max` for evidence and quality-control searches relevant
   to the task. Accessibility, interaction, and performance findings take
   precedence over stylistic novelty.
5. Consult the vendored upstream reference selectively:
   `references/taste-skill-v2.md`.
   - Read sections 0, 1, 4, 5, 6, 11, and 14 for visual work.
   - Read web architecture, hero, CTA, SEO, and design-system package sections
     only when the actual task involves a web surface where they apply.
   - Use section 9 as an anti-pattern vocabulary, not a blanket override of
     this repository's approved visual language.
6. Translate useful findings into the existing QML, CSS, Lua, or native
   configuration. Preserve semantic token names and avoid parallel design
   systems.
7. Review the result for visual hierarchy, repetition, copy clarity, focus
   visibility, keyboard access, non-color state cues, purposeful motion,
   reduced-motion/reduced-transparency behavior, scaling, and complete
   loading/empty/error/disabled states where applicable.
8. Run the relevant repository tests and `scripts/validate.sh`. Keep actual
   internal/external display review as the final visual acceptance gate when
   the change cannot be proved from static checks.

## Project guardrails

- Do not introduce React, Next.js, Tailwind, Motion, GSAP, icon packages,
  design-system packages, remote fonts, CDNs, or generated imagery merely
  because the upstream skill recommends them.
- Do not replace Pretendard, Jetendard, Papirus-Dark, or the managed semantic
  palette without explicit scope and license review.
- Do not require dual light/dark modes when the project explicitly defines a
  dark-first surface. Preserve the documented accessible fallback profiles.
- Do not force marketing-page rules about heroes, logo walls, CTAs, section
  counts, or SEO onto desktop shell components.
- Do not change navigation labels, interaction bindings, analytics-relevant
  identifiers, accessibility semantics, or functional states silently.
- Do not generate or fetch visual assets unless the task actually needs new
  assets and the user has placed that work in scope.
- Do not use this skill for a change with no user-visible presentation or
  interaction impact.
