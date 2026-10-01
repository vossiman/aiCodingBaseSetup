# Scratchpad and design refinement

Use a feature-specific isolated worktree or disposable app, at the intended
brand and mode, outside application runtime. Start with adopted components and
native shadcn candidates. Add a legacy pattern only to investigate a useful gap.
Keep its vendor CSS/Preline runtime contained in the scratchpad or separate
legacy preview; native and production bundles must not import it.

Show the actual feature layout and meaningful content at relevant viewport
sizes. Label mock handlers, sample data and unsupported integrations. Explore
loading, empty, populated, error, disabled, focus and selected states where the
feature needs them; do not fabricate a full state matrix for static content.

Refine layout, interactions, information hierarchy and required states with
the user. Record the selected design, rejected tradeoffs that affect implementation,
primitive/backend and dependency decision. Then make a concrete feature-linked
ticket for missing pieces. Scratchpad selection does not promote vendor source
or mock behavior to production. Retain a private source/provenance link and
follow [implementation](implementation.md) for adoption.
