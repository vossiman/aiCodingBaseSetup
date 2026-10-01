# Component selection and compatibility

Inspect the application's adopted components first. Reuse one when behavior,
accessibility, styling flexibility and maintenance fit the selected feature.
For missing standard UI, prefer an equivalent or better native shadcn example.
Only explore legacy patterns when there is a useful gap.

## Browse at an exact repository revision

- Native: `apps/showroom`, localhost:5174, `#/components/<family>`; 64 families
  and 246 named panels. Actual source/code links, states and per-family backend
  and dependency metadata are in `src/catalog/coverage.json`.
- Complete legacy: `reference/inspinia-showroom`, localhost:5173; 234 reference
  pages. Source links live in `src/showroom/catalog.json`.
- [Overlap map](../references/legacy-pattern-map.md) helps identify gaps; its
  absence never blocks selected feature work.

Use a private checkout at the recorded revision; do not distribute purchased
source or expose either showroom publicly. Startup commands are in SKILL.md.

## Status is evidence

| Status | Meaning |
| --- | --- |
| Legacy reference | Vendor design/source inspiration; no native compatibility claim |
| Upstream showroom example | Verified in the showroom's pinned baseline; app adoption pending |
| Scratchpad | Disposable feature exploration; mock handlers identified |
| Project extension | Generally reusable selected gap, with its own validation record |
| Application-adopted production | Used by an actual feature and verified in that app's baseline |

The repo currently has no `packages/ui` production catalogue. Do not invent an
adopted component or infer adoption from a rendered example.

Read [compatibility.md](../references/compatibility.md), the app lockfile and
family metadata before copying source. Match primitive backend (Radix, Base UI
or other), peer dependencies, React/Tailwind versions and framework assumptions.
Pin upstream revision and exact resolved versions in the app lockfile. Reuse the
app's existing compatible primitive rather than silently mixing backends.

For React 18/Tailwind 3 or another older baseline, retain pins and assess an
older compatible implementation or a scoped adaptation. The Tailwind 4 mapping
is not Tailwind 3 configuration. Record that decision and test it locally. Do
not blindly run `shadcn@latest add` or upgrade the application to match an example.
