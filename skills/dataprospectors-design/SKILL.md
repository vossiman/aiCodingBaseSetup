---
name: dataprospectors-design
description: Use when styling or building dataprospectors or customer UI, selecting catalogue components, exploring a feature design or contributing reusable UI; also for brand tokens, shadcn themes, chart palettes, logo assets, typography, status pages and standalone HTML artifacts.
---

# dataprospectors design system

Navy carries structure, gold marks rare emphasis, warm paper and ink carry
content. This private repository is authoritative for themes/assets and this
guidance. Installed bundles record their exact source revision in SOURCE.json.

## Start here

1. Identify the real feature, intended brand, application dependency pins and
   existing adopted components. Reuse a suitable production component first.
2. Load only the modules needed below. For missing standard UI choose native
   shadcn when equivalent or better; legacy patterns fill selected useful gaps.
3. Refine the feature's layout, interactions and required states with the user.
   Implement selected missing pieces and verify them before marking adoption.

| Need | Module |
| --- | --- |
| Brand rules, semantic tokens, fonts, logos, customer overrides | [Themes/assets](modules/themes-assets.md) |
| Native/legacy catalogue selection, status and dependency compatibility | [Selection](modules/selection.md) |
| Isolated exploration and design refinement | [Scratchpad](modules/scratchpad.md) |
| Application adoption, validation and reusable contributions | [Implementation](modules/implementation.md) |
| Private access, package/skill installation, pins, upgrades and rollback | [Consumption](modules/consumption.md) |

New native baseline: Node 22.12–22.x, npm 10, React 19, Tailwind 4.
Read the [tested exact baseline](references/compatibility.md) before copying
source. An older app retains its pins until a deliberate compatibility decision;
never run an unpinned latest-source installer into it.

To browse, use an exact private checkout, `npm ci`, then
`npm ci --prefix reference/inspinia-showroom` and `npm run dev:showrooms`.
Native is localhost:5174; complete legacy reference is localhost:5173. The
[selection module](modules/selection.md) explains sources and their statuses.
Installed assets and references are relative to this SKILL.md, not the process
working directory. Managed home copies are outputs; change this repo via PR.
