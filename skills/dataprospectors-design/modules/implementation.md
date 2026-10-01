# Application implementation and contribution

Implement only missing pieces selected for the actual feature. Reuse adopted
production components, then compatible standard shadcn source; a selected gap
may use a justified specialist library. Record upstream revision, copied source,
local adaptations, primitive/backend, exact dependency baseline and license.
Keep application data fetching, domain rules and business logic in the app.

## Adoption record

Record alongside the app's component or feature documentation:

- Feature/ticket and selected design; status from the selection module.
- Source path/revision, license, adaptations and primitive/backend.
- Supported Node/React/Tailwind versions, direct dependency pins and lockfile.
- Usage example, public props and required states.
- Actual test commands/results, keyboard/focus behavior, accessibility,
  relevant responsive sizes and supported brand/light/dark combinations.

Verify real behavior, including disabled actions, focus return, keyboard paths
and errors relevant to the feature. Exercise fonts, assets and semantic tokens
in the consuming app. Do not treat showroom handlers as application behavior.
Only mark application-adopted production after these checks and actual feature
integration. A showroom pass is evidence about that baseline only.

## Contribute generally reusable pieces

Propose a PR to the design repo containing the component, meaningful usage and
state examples, tests and the adoption/provenance/compatibility record. A new
`packages/ui` component must be demanded by a selected real feature, not by the
size of the legacy catalogue. Register a project extension separately from
upstream examples and link any legacy inspiration. Review API/dependencies and
licensing; retain the app's business logic there. Record the supported baseline
and deliberate upstream upgrade procedure. Broad conversion is outside scope.
