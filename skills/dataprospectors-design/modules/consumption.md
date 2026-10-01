# Versioned consumption and installation

## Private source and supported baseline

Use authenticated `git`/`gh` with access to `vossiman/dataprospectors-design-system`.
Do not embed tokens in URLs, manifests, logs or commands. A CSS-only app needs
no React. Themes 0.1.0 supports the optional React 19 adapter; native Tailwind
mapping requires Tailwind 4. Exact showroom dependencies and upstream revision
are in [compatibility.md](../references/compatibility.md). Node 22.12–22.x and
npm 10 are the build/verification baseline, not a blanket app upgrade mandate.

## Pack from an exact revision

Choose a reviewed full 40-character Git commit (not a moving branch). In an
isolated private checkout, substitute that revision for `SOURCE_SHA` below:

```sh
git clone https://github.com/vossiman/dataprospectors-design-system.git design-source
cd design-source
git checkout --detach SOURCE_SHA
npm ci
npm run build -w @dataprospectors/themes
mkdir -p out
npm pack -w @dataprospectors/themes --pack-destination out
```

Copy `out/dataprospectors-themes-0.1.0.tgz` into the consuming repo's private
`vendor/` directory and rename it to include the source SHA. Record source SHA,
package version and `sha256sum` in an adoption/dependency record. Commit the
tarball and app lockfile to the private app (or store in a private immutable
artifact service). Do not use a Git URL for the monorepo as an npm dependency;
the theme package is a workspace, not its root. The design package is never
published to the public npm registry; its Fontsource dependencies still resolve
from the normal dependency registry.

```sh
npm install --save-exact ./vendor/dataprospectors-themes-SOURCE_SHA.tgz
```

The resulting `file:vendor/...tgz` dependency and lockfile allow `npm ci` without
access to the design repository. npm still needs the normal dependency registry.
Run the consuming app's build and checks. CSS-only usage imports
`@dataprospectors/themes/fonts.css` and `theme.css`; Tailwind 4 additionally
loads `tailwind.css` after `tailwindcss`. See [theme-package.md](../references/theme-package.md)
for root attributes, React provider, customer override selectors and logo URL
imports. With Vite use exported assets with `?url`; other bundlers must resolve
and copy package assets and Fontsource font files into their build output.
Do not point deployed pages at local `node_modules` or skill installation paths.

## Self-contained skill bundle

From a clean exact checkout, run (destination must not exist):

```sh
node scripts/export-skill.mjs /absolute/new/directory/dataprospectors-design
```

The exporter resolves canonical files into a self-contained directory with
SKILL.md, modules/, references/, assets/ and SOURCE.json (repository, source
revision, package version and SHA-256 file hashes). No node dependencies are
needed for export. Relative links work outside the checkout. SOURCE.json exists
in exported bundles; in a source checkout `git rev-parse HEAD` identifies the
revision. Assets and references in the checkout are links to canonical sources.

For a repo-local install, copy the whole exported directory under
`.agents/skills/dataprospectors-design/` in that consuming repo. Check the agent
runtime discovers that directory. Do not copy only SKILL.md. Managed estate
installs use aiCodingBaseSetup's generated bundle under
`skills/dataprospectors-design/`, deployed to `~/.claude/skills/` and exposed
through its existing shared `~/.agents/skills` mechanism. Change the source repo
and refresh the blueprint pin through a PR; never patch managed home copies.
Showrooms require a private checkout at the source revision; the installed skill
bundle does not distribute purchased vendor source or a running showroom.

## Upgrade and rollback

Review source changes, theme API/tokens, family metadata and upstream revisions.
Produce a new revision-named tarball and bundle; update the app's dependency
record and lockfile deliberately, then run behavior, font/asset and relevant
brand/mode checks. Keep app package and guidance revisions explicit; guidance
updates do not silently upgrade app dependencies. Older consumers retain their
existing pins until their own upgrade is validated.

Rollback by restoring the previous tarball path, dependency record and lockfile
and running `npm ci`. Restore the previous whole skill bundle/source pin. For
managed estate installations revert the blueprint pin/bundle through a PR and
use normal sync. Keep the last known good package/bundle until validation passes.

`npm run verify` in the source repo exercises an isolated packed consumer;
that is integration evidence, not a substitute for the consuming app's checks.
