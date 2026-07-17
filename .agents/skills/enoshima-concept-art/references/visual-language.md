# Enoshima visual language

Use `docs/DESKTOP-UI-CONCEPT.md` as the canonical visual contract. These notes make the contract operational for image generation.

## Character

- Contemporary workstation UI with a restrained Enoshima cyberpunk atmosphere.
- Deep navy canvas, layered indigo surfaces, cyan focus, violet selection, and magenta accent used sparingly.
- Prefer quiet density and decisive hierarchy over neon spectacle, glassmorphism, or decorative sci-fi chrome.
- Preserve recognizable desktop conventions for title bars, window menus, snapping, authentication, and power actions.

## Token roles

- Canvas: `#050623`
- Surface: `#0a0c3e`
- Raised surface: `#161151`
- Focus cyan: `#62d8ff`
- Selection violet: `#9a5cff`
- Accent magenta: `#e56bff`
- Primary text: `#f2ecff`
- Muted text: `#c9bfe8`
- Critical: `#ff5d8f`
- Success: `#77e0c6`
- Warning: `#ffb86b`
- Panel radius: 14px; control radius: 12px; small radius: 10px.

The rendered result may use translucent variants already defined by the shell. Do not create new semantic colors when an existing role fits.

## Typography and icons

- Use Pretendard for Korean and Inter-compatible proportions for English mock copy.
- Use weight and size before accent color to establish hierarchy.
- Use Papirus symbolic/system icon semantics. Avoid emoji and decorative glyphs for controls.

## Interaction tone

- Default motion is direct and short: 90–190ms, ease-out.
- Reduced-motion mode removes scale/slide flourishes while preserving state feedback.
- Focus rings are obvious; error messages stay adjacent to the failed action.
- Destructive actions use explicit labels and confirmation only where recovery is impossible.
