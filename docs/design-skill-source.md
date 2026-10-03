# Authoritative dataprospectors design guidance

DATAPROSPECTORSDESIGNSYSTEM-6 (linked to DEVMACHINE-29) moves authoring to the
private `vossiman/dataprospectors-design-system` repository. This blueprint
contains a **generated installation bundle**, not a second editable source.
`skills/dataprospectors-design/SOURCE.json` pins the full source commit,
theme version and SHA-256 of every installed file.

The bundle contains modular guidance, native theme inputs/fonts, retained legacy
token/registry inputs and existing brand assets. It contains no purchased vendor
implementation. Private source/showroom links remain private GitHub links.
The existing installer and sync enumerate the whole directory and deploy it to
`~/.claude/skills/dataprospectors-design`; the existing shared-skills mechanism
exposes it through `~/.agents/skills`. Install/sync never clone or execute code
from the private design repo. Current app token copies and app lockfiles remain
pinned; shared guidance updates do not upgrade app dependencies.

## Refresh the source pin

Use authenticated git/gh with access to the private source. Do not put credentials
in URLs/arguments. Review and merge the source PR first, then check out its exact
40-character SHA in an isolated clean checkout (Node 22.12–22.x is required for
its exporter):

```sh
python3 tools/update-design-skill.py --source /path/to/design-checkout --revision SOURCE_SHA
python3 tools/update-design-skill.py --check
bash tests/bats/run.sh
```

The refresh rejects dirty or mismatched source and noncanonical origin, invokes that revision's exporter
in a temporary sibling directory, checks provenance/file hashes, then replaces
the bundle. Failed export/validation leaves the previous bundle unchanged.
No moving branch, runtime private-repository fetch or second hand-maintained
skill snapshot is involved. Edit guidance in the source repo; never edit the
bundle or managed home copies directly. `--check` needs only Python and the
committed bundle; no network or Node dependency is added to sync/install.

Open a blueprint PR containing the generated diff and exact source SHA, source
PR/test evidence, `--check` result and full suite result. Obtain review and merge
authorization under this repository's existing convention. A dependent blueprint
PR may be prepared before the source PR merges; it must not land first.

Rollback restores a previously reviewed blueprint bundle/pin through a PR,
then runs normal sync. For application package upgrades/rollback, use the skill's
consumption module and each app's own checks. Original `references/dp-tokens.css`,
`theme.css`, `registry.json` and assets remain present for old reference users;
new native input is `references/native-theme.css`. Installed file modes and
Markdown substitution follow the existing credential-safe skill deploy policy.

Origin validation accepts the canonical GitHub repository through HTTPS,
`git@github.com:vossiman/dataprospectors-design-system[.git]`, or
`ssh://git@github.com/vossiman/dataprospectors-design-system[.git]` (default SSH
port22). Credentials, wrong repositories/hosts and query/fragment suffixes are
rejected before export without echoing the URL. Git/gh authentication remains
external to the bundle and refresh tool.
