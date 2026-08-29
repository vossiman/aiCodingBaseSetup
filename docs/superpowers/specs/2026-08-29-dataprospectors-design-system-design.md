# dataprospectors design system — central skill

Status: draft for review
Date: 2026-08-29
Approved direction: spike artifact "Dataprospectors Design System"
(claude.ai/code artifact 03551eaa, session 2026-08-29) — all values below
were validated there and approved by the owner.

## Purpose

A central aicoding skill, `dataprospectors-design`, that gives any agent
session the complete dataprospectors visual identity: brand colors, derived
token scales, typography, component conventions, chart palette, logo assets,
and per-stack application mechanics. Sessions styling any dataprospectors
surface (product UI, internal tool, status page, artifact) invoke the skill
instead of improvising a look.

Target stack: shadcn/ui (CLI v4) on Tailwind v4 (`@theme inline`) and
React 19; with explicit fallbacks for plain-HTML surfaces and artifacts.

## Brand inputs (fixed)

| Role | Value |
|---|---|
| Brand navy (structure: header, footer, headings, primary) | `#243943` |
| Brand gold (the find: links, highlights, focus, accents) | `#f5c249` |
| Ink (text near-black, navy-biased) | `#171c1f` |
| Paper (warm near-white ground) | `#f8f8f6` |

Core stance: navy carries structure, gold is rare and marks what matters,
everything else stays quiet in paper and ink.

## Skill contents

```
skills/dataprospectors-design/
├── SKILL.md              # trigger + rules + decision tree (substituted deploy)
├── references/
│   ├── theme.css         # full shadcn CSS-variable block, :root + .dark
│   ├── registry.json     # shadcn registry:theme item (same values)
│   └── dp-tokens.css     # framework-free variable set for plain HTML
└── assets/
    ├── dp-logo-light.png # ink strokes + paper fill, transparent bg
    ├── dp-logo-dark.png  # paper strokes + navy fill, transparent bg
    ├── dp-favicon-512.png
    ├── dp-favicon-192.png
    └── dp-favicon-32.png
```

The logo PNGs are the approved generated masters (Nano Banana 2 from the
owner's original; final keyed/cropped versions). An SVG trace remains a
wanted follow-up, out of scope here.

### SKILL.md content outline

1. **Trigger** (frontmatter description): styling, theming, or building UI
   for any dataprospectors project or surface.
2. **Decision tree**:
   - shadcn/Tailwind-v4 project → paste `references/theme.css` block into
     `globals.css` (or `npx shadcn@latest add <path-to>/registry.json`).
   - Plain HTML tool / status page → link or inline `dp-tokens.css`.
   - Artifact / one-off page → inline the token block from the skill text.
3. **Rules** (each one sentence, with the token that enforces it):
   - Light mode: navy primary on paper; dark mode: gold primary on
     navy-black. Focus ring is gold in both.
   - Gold as *text* must be `#7a5c05` on light (raw `#f5c249` is 1.6:1 on
     white); raw gold is the text accent on dark only.
   - Sidebar wears navy in both modes (`--sidebar-*` group); gold only on
     the active item's rail/text.
   - Charts use the fixed 5-color order below; never cycle, never reuse
     status colors as series; per-mode values, not an automatic flip.
   - Status colors (success `#2e7d4f`/`#4caf7d`, destructive
     `#b3372f`/`#e05d54`, warning = gold ramp) are reserved for state.
   - Typography: Archivo (headings/UI, 600–800), IBM Plex Mono (data,
     code, tabular numerals). Font loading per stack: `next/font/google`
     (Next.js), `@fontsource` (Vite/SPA), Google Fonts link (plain HTML);
     always with real fallback stacks.
   - Logo: light variant on light surfaces only, dark on dark; clear space
     ≥ one barrel-ring height; min height 24px; never recolor strokes;
     favicon is the nuggets mark.
4. **Full token tables** (light + dark) — the values validated in the spike,
   including navy scale 50–950, gold scale 100–700, all shadcn semantic
   tokens, `--sidebar-*`, `--chart-1..5`.

### Chart palette (validated)

Categorical, fixed order; validated with the dataviz six-checks script
(CVD separation, lightness band, chroma floor, contrast) per mode:

- Light (on white): `#0f7fbe` `#d99a08` `#279a58` `#8a70da` `#cb5a28`
  (gold series is sub-3:1 on white → charts must direct-label or tooltip,
  which the skill states as a requirement)
- Dark (on `#15232a`): `#2f8ec7` `#bd880c` `#33ad68` `#8f77dd` `#d0632f`

## Deployment change (required)

`lib/provision-managed-files.sh` and `lib/blueprint-deploy.sh` currently
deploy exactly one file per skill: `skills/<name>/SKILL.md`. This skill
ships references and binary assets, so skill deployment becomes:

- Enumerate **all files** under `skills/<name>/` recursively, via ONE
  shared helper used by both deploy paths (`provision-managed-files.sh`
  install loop and the `blueprint-deploy.sh` inventory). This is a safety
  requirement, not style: the sync-side `to_remove` sweep deletes any
  manifest entry absent from the inventory, so divergent enumeration would
  make `aicoding-sync` delete files `aicoding-install` just deployed.
- `.md` files keep the existing substituted-overwrite path
  (`deploy_overwrite_file_substituted`); all other files deploy via the
  existing verbatim `deploy_overwrite_file` (plain cp + sha256 manifest
  entry — substitution's sed pass would corrupt PNGs).
- Add `dataprospectors-design` to `MANAGED_SKILLS`
  (`provision-managed-files.sh`) so the unmanaged-components scan doesn't
  flag it.
- Existing single-file skills (`cloudflare-browser`) are unaffected; the
  per-file manifest entries mean files later removed from a skill are
  cleaned up by the normal `to_remove` bucket.

## Out of scope

- Hosting `registry.json` at a public URL (`design.dataprospectors.at`) —
  the registry item works from a local path; hosting is a later decision.
- SVG master / print assets for the logo.
- A Tailwind preset npm package.
- Restyling any existing project (each project applies the skill in its
  own session/PR).

## Acceptance

1. `aicoding-sync --blueprint` deploys the full skill directory; the skill
   appears in Claude/codex/cursor skill listings.
2. A fresh shadcn (Tailwind v4) test app themed via `theme.css` renders
   navy/gold in light and dark with no unstyled shadcn token left on
   defaults (spot-check: button variants, sidebar, ring, chart colors).
3. `dp-tokens.css` drops into a plain HTML page and provides the same
   variables without Tailwind.
4. Logo assets deploy byte-identical (no substitution corruption).
