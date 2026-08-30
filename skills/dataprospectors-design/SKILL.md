---
name: dataprospectors-design
description: "The dataprospectors design system: brand tokens, shadcn theme, chart palette, logo assets, typography. Use when styling, theming, branding, or building UI for any dataprospectors project or surface (product UI, internal tool, status page, artifact)."
---

# dataprospectors design system

Navy carries structure, gold is the prospector's find — rare, bright, and
only on what matters. Everything else stays quiet in warm paper and ink.

Brand inputs: navy `#243943` · gold `#f5c249` · ink `#171c1f` · paper `#f8f8f6`.
Target stack: shadcn/ui (CLI v4), Tailwind v4 (`@theme inline`), React 19.

All files referenced below live next to this SKILL.md in
`references/` and `assets/` (deployed under
`~/.claude/skills/dataprospectors-design/`).

## How to apply — decision tree

1. **shadcn / Tailwind v4 project** → replace the `:root` / `.dark` token
   blocks in `globals.css` with `references/theme.css` (keep shadcn's stock
   `@theme inline` block and append the extension mappings from the bottom
   of theme.css). Alternative: `npx shadcn@latest add <path>/references/registry.json`
   (registry item, same values; the extensions and fonts still come from
   theme.css).
2. **Plain HTML surface** (status page, internal tool, artifact with full
   control) → link or inline `references/dp-tokens.css`; it carries the
   same variables plus the navy/gold scales, with light default, OS-dark,
   and `data-theme` override states.
3. **Artifact / one-off page** → inline the token block from
   `dp-tokens.css` into the page's `<style>`; never restate values from
   memory.

## Rules

1. **Light mode**: navy primary on paper. **Dark mode**: gold primary on
   navy-black — the flip is intentional. Focus ring is gold in both.
2. **Gold as text** must be `--link` (`#7a5c05`) on light surfaces — raw
   `#f5c249` is 1.6:1 on white, unreadable. On dark, raw gold IS the text
   accent. Never put raw gold text on a light ground.
3. **Sidebar** wears navy in both modes (`--sidebar-*` group). Gold appears
   only on the active item (rail + text). Headers/footers are navy-700
   `#243943` with a gold bottom/top border.
4. **Charts**: use `--chart-1..5` in that fixed order, never cycled, never
   re-assigned when series are filtered. Light and dark values are separately
   validated palettes, not an automatic flip — take them from the tokens.
   The gold series (`--chart-2`) is below 3:1 contrast on white, so charts
   must carry direct labels or tooltips. Status colors (`--success`,
   `--destructive`, `--warning`) are reserved for state and never used as
   series colors. A 6th series folds into "Other" or small multiples.
5. **Status colors** ship with an icon or label, never color alone.
6. **Typography**: Archivo for UI and headings (weights 600–800),
   IBM Plex Mono for data/code with `font-variant-numeric: tabular-nums`
   in numeric columns. Loading: Next.js → `next/font/google`; Vite/SPA →
   `@fontsource-variable/archivo` + `@fontsource/ibm-plex-mono`; plain
   HTML → Google Fonts `<link>` with `display=swap`. Always declare
   fallbacks: `'Archivo', system-ui, sans-serif` /
   `'IBM Plex Mono', ui-monospace, monospace`.
7. **Logo** (`assets/`): prefer the SVG masters — `dp-logo.svg` (ink
   strokes + paper fill, for light surfaces) and `dp-logo-dark.svg`
   (paper strokes + navy fill, for navy/dark surfaces); the linework is
   traced from the approved raster masters and shared by both variants
   (the dark file is the same trace recolored), so the drawing matches
   exactly.
   Light variant on light surfaces ONLY, dark on navy/dark ONLY — never
   ink-on-navy. Clear space at least one barrel-ring height; minimum
   height 24px; never recolor strokes or gold. Favicon/app icon:
   `dp-favicon.svg` (gold nuggets; works on light and dark tabs), with
   `dp-favicon-512.png` / `-192` / `-32` for consumers that need raster.
   The `dp-logo-*.png` files are the original raster masters, kept for
   compatibility.
8. **Radius** is 0.5rem (`--radius`); shadows stay soft and small. Don't
   introduce new grays — derive surfaces from the navy scale (in
   dp-tokens.css) or the muted/accent tokens.
9. **Semantic quiet**: gold highlights ONE primary action per view. Bulk
   actions are `secondary`/`outline`; destructive actions always use the
   destructive tokens, never bare red hexes.

## Token quick reference

| Token | Light | Dark |
|---|---|---|
| background / foreground | `#f8f8f6` / `#171c1f` | `#0c1519` / `#eceae2` |
| primary / -foreground | `#243943` / `#f8f8f6` | `#f5c249` / `#1a2b33` |
| secondary | `#dce6ea` | `#30505c` |
| accent (hover wash) | `#fdf3d7` | `#2b3f49` |
| muted / -foreground | `#edeeea` / `#5c6a70` | `#1c2c34` / `#93a6ad` |
| destructive | `#b3372f` | `#e05d54` |
| success | `#2e7d4f` | `#4caf7d` |
| warning | `#b08312` | `#f5c249` |
| border / input / ring | `#dcdfda` / `#c9cec9` / `#f5c249` | `#2b3d46` / `#3a4f59` / `#f5c249` |
| link (gold-as-text) | `#7a5c05` | `#f5c249` |
| chart 1–5 | `#0f7fbe` `#d99a08` `#279a58` `#8a70da` `#cb5a28` | `#2f8ec7` `#bd880c` `#33ad68` `#8f77dd` `#d0632f` |
| sidebar / -primary | `#1a2b33` / `#f5c249` | `#10181d` / `#f5c249` |

Full sets (incl. navy-50…950 and gold-100…700 scales): `references/dp-tokens.css`.

## Provenance

Spike + component gallery: claude.ai/code artifact `03551eaa` (2026-08-29).
Chart palettes validated with the dataviz six-checks script per mode.
Spec: aiCodingBaseSetup
`docs/superpowers/specs/2026-08-29-dataprospectors-design-system-design.md`.
