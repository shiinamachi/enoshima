---
name: ui-ux-pro-max
description: "Project-scoped UI/UX design intelligence for this Arch desktop repository. Use together with design-taste-frontend only when changing or reviewing user-visible QML, GTK CSS, Waybar, SwayNC, Hyprlock, SDDM, concept assets, color, typography, spacing, layout, accessibility, interaction, motion, or data visualization. Search a local database with 84 styles, 192 palettes, 74 font pairings, 192 product types, 99 UX guidelines, 105 icon entries, 16 motion presets, and 25 chart types. Skip non-visual system, package, service, network, and scripting work."
---

# UI/UX Pro Max - Design Intelligence

Searchable database of UI/UX design rules with priority-based recommendations: 84 styles, 192 color palettes, 74 font pairings, 192 product types with reasoning rules, 99 UX guidelines, 105 icon entries, 16 GSAP motion presets, and 25 chart types across 22 technology stacks.

## Repository adapter

Treat this repository's existing design system as authoritative. Read
`AGENTS.md`, `docs/DESKTOP-UI-CONCEPT.md`,
`docs/DESKTOP-UX-REFERENCES.md`, the affected implementation, and its tests
before searching. Database output is evidence and a source of candidates, not
desired state to apply automatically.

This project uses Hyprland, QML, GTK CSS, Waybar, SwayNC, Hyprlock, and SDDM.
None is a supported stack in this skill. Do not default to `html-tailwind`, do
not translate GSAP snippets literally, and do not introduce a web framework,
font, icon set, package, or design system because a result recommends it. Use
stack-agnostic `ux`, `style`, `color`, `typography`, `icons`, and `web` domain
results, then translate applicable principles into the existing toolkit.

The existing desktop design documents already serve as the master design
system. Do not use `--persist` or `--force`, and do not create a parallel
`design-system/` tree. Prefer accessibility, keyboard/focus behavior,
interaction clarity, performance, purposeful motion, and consistency over a
style match. Discard any recommendation that conflicts with the approved
dark-first Cyberpunk Library palette, local font policy, semantic tokens, or
functional behavior.

## When to Apply

Use this Skill when the task involves **UI structure, visual design decisions, interaction patterns, or user experience quality control**: designing new pages, creating/refactoring UI components, choosing color/typography/spacing/layout systems, reviewing UI for UX/accessibility/consistency, implementing navigation/animation/responsive behavior, or improving perceived quality and usability.

Skip it for pure backend logic, API/database design, non-visual performance work, infrastructure/DevOps, or non-visual scripts — unless the task changes how something **looks, feels, moves, or is interacted with**.

## Rule Categories by Priority

*Follow priority 1→10 to decide which category to focus on first; use `--domain <Domain>` to query full details. The full rule text for every category lives in `references/quick-reference.md` — read it on demand rather than loading it every time.*

| Priority | Category | Impact | Domain | Key Checks (Must Have) | Anti-Patterns (Avoid) |
|----------|----------|--------|--------|------------------------|------------------------|
| 1 | Accessibility | CRITICAL | `ux` | Contrast 4.5:1, Alt text, Keyboard nav, Aria-labels | Removing focus rings, Icon-only buttons without labels |
| 2 | Touch & Interaction | CRITICAL | `ux` | Min size 44×44px, 8px+ spacing, Loading feedback | Reliance on hover only, Instant state changes (0ms) |
| 3 | Performance | HIGH | `ux` | WebP/AVIF, Lazy loading, Reserve space (CLS &lt; 0.1) | Layout thrashing, Cumulative Layout Shift |
| 4 | Style Selection | HIGH | `style`, `product` | Match product type, Consistency, SVG icons (no emoji) | Mixing flat & skeuomorphic randomly, Emoji as icons |
| 5 | Layout & Responsive | HIGH | `ux` | Mobile-first breakpoints, Viewport meta, No horizontal scroll | Horizontal scroll, Fixed px container widths, Disable zoom |
| 6 | Typography & Color | MEDIUM | `typography`, `color` | Base 16px, Line-height 1.5, Semantic color tokens | Text &lt; 12px body, Gray-on-gray, Raw hex in components |
| 7 | Animation | MEDIUM | `ux`, `gsap` | Duration 150–300ms, Motion conveys meaning, Spatial continuity | Decorative-only animation, Animating width/height, No reduced-motion |
| 8 | Forms & Feedback | MEDIUM | `ux` | Visible labels, Error near field, Helper text, Progressive disclosure | Placeholder-only label, Errors only at top, Overwhelm upfront |
| 9 | Navigation Patterns | HIGH | `ux` | Predictable back, Bottom nav ≤5, Deep linking | Overloaded nav, Broken back behavior, No deep links |
| 10 | Charts & Data | LOW | `chart` | Legends, Tooltips, Accessible colors | Relying on color alone to convey meaning |

For the full rule list per category (all 99 UX guidelines with rationale), read `references/quick-reference.md`. For app-specific polish rules (icons, touch feedback, dark mode contrast, safe areas) and the canonical pre-delivery checklist, read `references/pro-rules.md`.

---

## Running the search tool

The search script lives inside this skill's own directory. Resolve it from the
Git root so the command works from any subdirectory:

```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "<query>" --domain <domain>
```

Requires Python 3.x and no external dependencies.

## Workflow

### Step 1: Analyze User Requirements

Extract from the user request:
- **Product type**: SaaS, e-commerce, portfolio, dashboard, entertainment, tool, productivity, or hybrid
- **Target audience & context**: age group, usage context (commute, leisure, work)
- **Style keywords**: playful, vibrant, minimal, dark mode, content-first, immersive, etc.
- **Stack**: detect from the project. For this repository, record the actual QML/GTK/Hyprland surface and skip stack-specific searches because there is no matching stack. Never substitute `html-tailwind`.

### Step 2: Explore a Design System (new surfaces only)

For a genuinely new surface, use `--design-system` once to explore
recommendations with reasoning. Treat the result as a candidate set and
reconcile it against the repository design documents before implementation.
For changes to existing surfaces, start with focused domain searches instead.

```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "<product_type> <industry> <keywords>" --design-system [-p "Project Name"]
```

This searches product/style/color/landing/typography domains in parallel, applies reasoning rules from `ui-reasoning.csv`, and returns pattern, style, colors, typography, effects, and anti-patterns to avoid.

**Example:**
```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "beauty spa wellness service" --design-system -p "Serenity Spa"
```

### Step 2b: Do not persist in this repository

Do not pass `--persist`, `--output-dir`, `--page`, or `--force`. The existing
desktop design documents are the maintained source of truth.

### Step 2c: Design Dials (optional)

Three optional 1-10 sliders that tune `--design-system` output without changing your query. Add any combination of them to the same command:

```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "<query>" --design-system --variance <1-10> --motion <1-10> --density <1-10>
```

| Dial | Low (1-3) | Mid (4-7) | High (8-10) |
|------|-----------|-----------|-------------|
| `--variance` | Centered / minimal (biases toward Minimalism-style categories) | Balanced / modern | Bold / asymmetric (biases toward Brutalism, Bento Grids) |
| `--motion` | Subtle micro-interactions | Standard scroll/stagger motion | Complex choreography (pin, Flip, SplitText) |
| `--density` | Spacious (24-96px spacing scale) | Standard (16-64px, current default) | Dense/dashboard (8-32px spacing scale) |

- `--motion` attaches a ready-to-use GSAP snippet (with framework notes, Do/Don't, and performance notes) pulled from `--domain gsap`, matched to the resolved tier (Subtle/Standard/Complex).
- `--density` overrides the `--space-*` CSS variable table in the ASCII/markdown/MASTER.md output — use it for dashboards (high) vs. marketing pages (low) without hand-editing tokens.
- Leaving a dial unset keeps that part of the output exactly as it was before (no behavior change).

**Example:**
```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "internal analytics dashboard" --design-system --variance 8 --motion 7 --density 8 -p "Ops Console"
```

### Step 3: Supplement with Detailed Searches (as needed)

```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "<keyword>" --domain <domain> [-n <max_results>]
```

| Need | Domain | Example |
|------|--------|---------|
| Product type patterns | `product` | `--domain product "entertainment social"` |
| More style options | `style` | `--domain style "glassmorphism dark"` |
| Color palettes | `color` | `--domain color "entertainment vibrant"` |
| Font pairings | `typography` | `--domain typography "playful modern"` |
| Individual Google Fonts | `google-fonts` | `--domain google-fonts "sans serif popular variable"` |
| Chart recommendations | `chart` | `--domain chart "real-time dashboard"` |
| UX best practices | `ux` | `--domain ux "animation accessibility"` |
| Landing page structure | `landing` | `--domain landing "hero social-proof"` |
| Icon recommendations | `icons` | `--domain icons "navigation outline"` |
| GSAP animation presets | `gsap` | `--domain gsap "scroll reveal stagger"` |
| React/Next.js performance | `react` | `--domain react "rerender memo list"` |
| App/native interface guidelines | `web` | `--domain web "accessibilityLabel touch safe-areas"` |

Domain is auto-detected from the query if `--domain` is omitted — but auto-detection can misroute overlapping terms (e.g. "font" matches both `typography` and `google-fonts`). If results look off-topic, pass `--domain` explicitly.

### Step 4: Stack Guidelines

Skip this step for the current desktop stack. Use it only if a future task
introduces one of the explicitly supported stacks in an in-scope surface.

```bash
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "<keyword>" --stack <stack>
```

**Available stacks:** `react`, `nextjs`, `vue`, `svelte`, `astro`, `nuxtjs`, `nuxt-ui`, `angular`, `laravel`, `swiftui`, `react-native`, `flutter`, `jetpack-compose`, `html-tailwind`, `shadcn`, `threejs`, `javafx`, `wpf`, `winui`, `avalonia`, `uno`, `uwp`. Use the stack detected in Step 1.

---

## If a search returns 0 results

Do not fabricate output. Instead:
1. Retry once with broader or differently-worded keywords (try product + style separately rather than combined).
2. If still empty, fall back to the priority table above and say explicitly to the user that this recommendation came from the built-in defaults, not a database match (e.g. "no palette match for X, using general SaaS defaults").
3. Never present a 0-result search as if it returned data.

## Example Workflow

**User request:** "Make an AI search homepage." (stack detected as Next.js from `package.json`)

```bash
# Step 2: design system
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "AI search tool modern minimal" --design-system -p "AI Search"

# Step 3: supplement
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "search loading animation" --domain ux

# Step 4: stack guidelines
python3 "$(git rev-parse --show-toplevel)/.agents/skills/ui-ux-pro-max/scripts/search.py" "suspense streaming bundle" --stack nextjs
```

Then synthesize the design system + detailed searches and implement.

## Output Formats

`--design-system` supports `-f ascii` (default, terminal display), `-f markdown` (documentation), and `--json` (machine-readable, includes the raw design system dict plus persistence status).

## Tips for Better Results

- Use **multi-dimensional keywords** — combine product + industry + tone + density: `"entertainment social vibrant content-dense"`, not just `"app"`
- Try different phrasings for the same need: `"playful neon"` → `"vibrant dark"` → `"content-first minimal"`
- For an existing desktop surface, start with focused `--domain` searches. Use
  `--design-system` only to explore a genuinely new surface.
- Pass a stack only when the project actually uses one of the supported
  stacks. Skip stack guidance for this repository's current desktop surfaces.

| Problem | What to Do |
|---------|------------|
| Can't decide on style/color | Re-run `--design-system` with different keywords |
| Dark mode contrast issues | `references/quick-reference.md` §6: `color-dark-mode` + `color-accessible-pairs` |
| Animations feel unnatural | `references/quick-reference.md` §7: `spring-physics` + `easing` + `exit-faster-than-enter` |
| Form UX is poor | `references/quick-reference.md` §8: `inline-validation` + `error-clarity` + `focus-management` |
| Navigation feels confusing | `references/quick-reference.md` §9: `nav-hierarchy` + `bottom-nav-limit` + `back-behavior` |
| Layout breaks on small screens | `references/quick-reference.md` §5: `mobile-first` + `breakpoint-consistency` |
| Performance / jank | `references/quick-reference.md` §3: `virtualize-lists` + `main-thread-budget` + `debounce-throttle` |

## Before Delivering App UI

For this desktop repository, read `references/quick-reference.md` sections 1-7
and apply only platform-appropriate rules. Read `references/pro-rules.md` only
for a native/mobile surface; its touch and safe-area checklist does not apply
one-to-one to desktop shell UI. Finish with the repository's relevant tests,
`scripts/validate.sh`, and manual display acceptance when visual behavior
cannot be proven statically.
