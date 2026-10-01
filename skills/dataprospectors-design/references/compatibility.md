# Native showroom compatibility

Pinned upstream collection: shadcn-ui/ui new-york-v4, revision
`b0fcb58a6e7c4df1a88f7f6327b083592c2dfd9c`.

Node 22, npm 10, React 19.3.0, Tailwind 4.3.3, Vite 7.3.6, TypeScript 5.9.3.
Exact direct versions are in package.json; package-lock.json records the tested
transitive baseline. Registry-defined fixed versions are retained for Base UI,
Recharts and Embla. Compatible source-manifest ranges are resolved and pinned.

The collection primarily uses Radix primitives; its combobox uses Base UI and
message-scroller uses @shadcn/react. Each family records backend/source metadata
in src/catalog/coverage.json. Existing individual Radix imports are retained only
where appropriate; copied source may use the upstream radix-ui aggregate package.

Adaptations: aliases, local demo assets, Vite-safe image/link wrappers, shared-theme
Sonner wiring, accessible demo feedback, chart palette mapping and showcase sizing.
Next/server-action and alternate form-framework examples are excluded from the
React Hook Form baseline. Local demo state implies no application backend.

Upstream showroom examples remain distinct from application-adopted production
components. Standard shadcn wins over an equivalent legacy pattern; selected
useful gaps can become project extensions with separate validation.

Official integration: https://ui.shadcn.com/docs/installation/vite

## Coverage and local adaptations

64 families, 246 named examples. coverage.json records family source, backend,
exact direct dependencies, named states and inapplicable presentation-only input
states. Source lives in components/ui and examples; family pages load lazily.
Code panels load actual source with the selected family rather than embedding
all example source in the initial catalogue bundle.

Forms retain the upstream Zod 3.25.76 / resolver 3.10.0 baseline. Data Table uses
TanStack Table 9.2.4 and a two-row page size so pagination is demonstrable. Charts
map the upstream sample series to the canonical chart tokens and include local
line/area/pie examples plus a textual data summary. Demo actions remain local.
