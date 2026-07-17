---
name: enoshima-concept-art
description: Create, register, and approve concept art for Enoshima desktop surfaces before changing user-visible QML, GTK CSS, Waybar, SwayNC, Hyprlock, SDDM, greeter, window-decoration, snap-assist, or interaction UI. Use whenever a surface has no approved entry in docs/ui-surfaces.yaml, when adding a new visible state, or when implementation has materially drifted from its approved concept.
---

# Enoshima Concept Art

Use this workflow before implementation. The approved concept is a design contract, not a decorative afterthought.

## Workflow

1. Read `docs/ui-surfaces.yaml`, `docs/DESKTOP-UI-CONCEPT.md`, and `docs/DESKTOP-UX-REFERENCES.md`.
2. Find the affected `surface-id`. If none exists, add a planned entry before generating images.
3. Read [visual-language.md](references/visual-language.md), [prompt-template.md](references/prompt-template.md), and [surface-checklist.md](references/surface-checklist.md).
4. Inspect the implementation, its focused tests, and the closest approved concept assets.
5. Generate one three-direction candidate board with the built-in `imagegen` skill. Treat existing images as style references, not edit targets.
6. Select one direction using hierarchy, interaction clarity, accessibility, localization, and stack feasibility. Record the decision in the surface spec.
7. Generate a final concept board for the selected direction, including all required states and redline callouts.
8. Copy project-bound output into `docs/assets/concepts/<surface-id>/`; never leave the canonical asset only under `$CODEX_HOME/generated_images`.
9. Save the exact prompts and reference paths in `docs/concepts/<surface-id>.yaml`.
10. Set `concept.status: approved` only after the asset, state spec, selection rationale, and implementation constraints are complete.
11. Run `scripts/check-ui-concept-coverage` before editing UI code.
12. Implement from shared Enoshima tokens, then capture a real screenshot and perform the manual comparison recorded by the registry.

Do not use generated images as pixel-perfect golden tests. Compare structure, hierarchy, spacing, typography, state coverage, contrast, localization, and scale behavior.

## Image Generation Contract

- Use 16:9 desktop framing unless the surface contract requires a narrower crop.
- Show the UI at a plausible 1920×1080 logical desktop scale.
- Use Korean primary copy and enough English examples to expose overflow risk.
- Keep text legible and avoid decorative pseudo-text in interaction-critical areas.
- Use Papirus symbolic icon names in the spec; do not invent a parallel icon family.
- Preserve a calm, dense workstation character: restrained bloom, clear borders, limited accent hierarchy, and purposeful motion only.
- Include default, hover/focus, pressed, disabled, busy, success, and error states when relevant.
- Keep a visible 40px minimum pointer target and a 44px preferred target for primary controls.
- Document which elements are invariant and which may adapt across scale or locale.

## Validation

Run:

```bash
scripts/check-ui-concept-coverage
python3 .agents/skills/enoshima-concept-art/scripts/validate-concept-manifest docs/ui-surfaces.yaml
```

The validator fails when a visible implementation is unregistered, an approved asset/spec is missing, or a token-consuming QML file introduces direct palette literals.
