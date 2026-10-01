# Themes and assets

The default brand is dataprospectors; customer CI overrides semantic tokens.
Navy carries structure, gold is rare emphasis, paper and ink carry content.

Use the native package contract in [theme-package.md](../references/theme-package.md).
CSS sources: [native-theme.css](../references/native-theme.css), [tailwind.css](../references/tailwind.css),
[fonts.css](../references/fonts.css). These are canonical inputs, not values to
reconstruct from memory. Native CSS has explicit brand/mode selectors. Missing
attributes select dataprospectors/light; apps own OS preference and persistence.
Read [consumption.md](consumption.md) for pinned package installation.

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
   in numeric columns. Load the package's `fonts.css` for local fonts; the app can supply an
   equivalent local-font pipeline. Always declare
   fallbacks: `'Archivo', system-ui, sans-serif` /
   `'IBM Plex Mono', ui-monospace, monospace`.
7. **Logo** ([assets/](../assets/)): `dp-logo-light.png` (ink strokes, paper fill) on
   light surfaces ONLY; `dp-logo-dark.png` (paper strokes, navy fill) on
   navy/dark ONLY — never ink-on-navy. The logo stays raster on purpose:
   vectorizing the painterly mark was tried and rejected (2026-08-31).
   Clear space at least one barrel-ring height; minimum height 24px;
   never recolor the strokes. Favicon/app icon: prefer `dp-favicon.svg`
   (flat vector gold nuggets; crisp at any size, works on light and dark
   tabs), with `dp-favicon-512.png` / `-192` / `-32` for consumers that
   need raster.
8. **Radius** is 0.5rem (`--radius`); shadows stay soft and small. Don't
   introduce new grays — derive surfaces from the navy scale (in
   references/legacy-dp-tokens.css) or the muted/accent tokens.
9. **Semantic quiet**: gold highlights ONE primary action per view. Bulk
   actions are `secondary`/`outline`; destructive actions always use the
   destructive tokens, never bare red hexes.


## Legacy inputs

[legacy-dp-tokens.css](../references/legacy-dp-tokens.css) and
[legacy-theme.css](../references/legacy-theme.css) preserve historical scales and
legacy integrations. They are provenance/retained consumer inputs; new native
apps use native-theme.css. Do not load both token systems into one root. Do not add
Preline or purchased vendor styles to application runtime.
