# Preserve local settings during blueprint sync

Status: implemented on the feature branch after task-scoped review fixes;
final whole-branch review remains pending. Only blueprint source and fixture
tests changed. No live settings were read, changed, or deployed.

## Decision: keep three-way comparison, drop file snapshots

Use explicit ownership for model, effort, and trust. For other Codex settings,
compare current and incoming values with a fingerprint of the last acknowledged
blueprint value. Store fingerprints, not old config files. The comparison
needs equality information, not recoverable historical values.

Without history, sync must either overwrite differing local values or stop
updating settings once they exist. Neither gives both preservation and safe
blueprint updates. An untouched tui.alternate_screen should receive an upstream
change; a personal tui.status_line should survive an unrelated update.

Drop rendered snapshots, immutable generations, transaction pointers, and a
separate conflict-resolution database. One shared receipt holds per-setting
fingerprints. Unresolved settings retain their old fingerprint; explicitly
accepting either side advances that setting's fingerprint.

## Verified cause and scope

At blueprint commit 694a1bb, Codex config is an overwrite target
(lib/blueprint-deploy.sh:574) and its model default is gpt-5.6-sol.
The --yes path replaces locally edited files after backup. Project trust
tables are excluded from drift hashing but still deleted during replacement.
Model edits cause drift directly; trust is lost as collateral on a rewrite.

Implement Codex TOML first: install, adoption, reconciliation, boot, manual
sync, and preview. Generated instructions and owned hooks retain their current
policy. JSON and tmux are outside this first implementation. JSON is not
already equivalent: its current merge preserves additional keys but overwrites
blueprint scalar values and most arrays.

This implements the earlier three-way idea at setting level, without a text
merge tool or full historical value display.

## Setting ownership

- **User-owned:** existing model, model_reasoning_effort, and the complete
  projects subtree. Existing model/effort values never change; absent
  model/effort values may receive blueprint defaults. Never seed, overwrite,
  or delete trust from the blueprint. Preserve trusted and untrusted decisions.
  These settings produce no conflict warnings.
- **Mergeable:** every other setting supplied by the blueprint. Includes
  features, UI preferences, notify, and individual MCP settings. Do not
  replace an entire MCP table merely because its name is in the blueprint.
- **Local-only:** settings absent from both receipt and incoming blueprint.
  Preserve silently; never enroll them just because they exist locally.

An existing model is user-owned even if it originally came from the blueprint.
Future fleet model changes seed missing values only. This exception takes
precedence over the general merge rule. Retaining Astra does not change the
fleet default. Correcting an already-reset selection is repo-local unless the
user explicitly requests broader scope.

### Profile-derived settings

Keep approval_policy and sandbox_mode mergeable, preserving the current
ability to make local changes. Do not introduce Opus's proposed new enforcement
policy for these keys, notify, or MCP tables through this bug fix.

Render incoming values for the active manifest profile. During first adoption,
surface differing profile-derived values as a one-time adoption notice, not
an invented historical conflict. Unattended modes preserve them; interactive
adoption may explicitly select the current profile values.

After adoption, a changed profile is a file-level incompatibility: skip the
file and identify the two profiles. One shared config cannot simultaneously
satisfy different host/container defaults. Deliberate profile migration is a
separate action; sync must not toggle sandbox posture between callers.

## Three-way rule

B is the recorded fingerprint, L the current local fingerprint, and N the
incoming rendered blueprint fingerprint. Missing is an explicit sentinel,
distinct from all TOML values, including an empty table.

| Condition, in order | Result | Receipt for this setting |
| --- | --- | --- |
| L = N | Already resolved; no config write | Acknowledge N |
| N = B | Keep local silently | Keep B |
| L = B | Apply blueprint change | Acknowledge N |
| Otherwise | Keep local; report conflict | Keep B until resolved |

Only incompatible blueprint changes cause conflicts. A local preference
against an unchanged default is silent. Local-only additions never reach the
conflict branch. Removing a formerly managed key is also a blueprint change:
delete it only when local still equals B; otherwise retain it as a conflict.

Explicit keep-local and take-blueprint choices both acknowledge N. Repeats
stop warning about that same incoming change; a later incompatible change can
warn again. Unattended preservation does not acknowledge a conflict. Editing
local to equal N, or an upstream reversion to B, resolves it naturally.

Retain acknowledged missing sentinels where needed to distinguish a deletion
from a never-managed setting. Never replace the receipt with fingerprints of
the merged local document: that loses the distinction between blueprint and
user values.

### Tables, arrays, and equality

Use path segments, not dotted strings, as setting identifiers; TOML quoted
keys can contain dots. Recurse into compatible tables. Arrays, including arrays
of tables, are atomic. The receipt includes types, table structure, and subtree
fingerprints for replacements/removals. At a parent type change, compare the
whole parent rather than recursing through an incompatible scalar.

Deleting a table with local children is a parent conflict unless local and
incoming already agree. Do not delete untracked children with their parent.
A newly introduced blueprint parent colliding with an existing local scalar
is a parent conflict, not permission to discard the scalar.

Fingerprint a deterministic typed representation with SHA-256. Use a typed
Merkle tree: derive parent fingerprints from ordered child names/fingerprints,
so a receipt with unresolved children can recompute its acknowledged parent
fingerprint without retaining plaintext values. Distinguish
booleans, integers, floats, strings, dates/times, tables, arrays, and missing.
Sort table keys, preserve array order, ignore formatting, and define stable
normalization for dates/times and NaN/infinity. Reparse output before writing.
An unchanged semantic result preserves the original config bytes.

## Receipt and credentials

Use ~/.codex/.aicoding-sync/config-state.json beside the shared config.
Directory mode 0700; receipt and temporary files 0600. Store:

- receipt format version 1;
- blueprint origin, clean commit where known, raw template digest, source kind
  (tracking or explicit local), and profile;
- per-path acknowledged fingerprints, type/structure metadata, and missing
  sentinels. No local-only paths, recoverable values, or rendered content.

The receipt follows the shared settings mount; the container-local manifest
continues to describe local provisioning. Fingerprints are sensitive derived
data, not anonymization. Add this state directory to the secrets deny coverage
in the same change, with read/glob/shell-path tests. Never print receipts or
credential-value fingerprints in sync output.

Render only the incoming blueprint through existing substitution. Fingerprint
actual local and incoming credential values in memory. If a token rotates,
unchanged local credentials receive the new token; independently changed
credentials conflict. Re-rendering an old template with today's secrets would
lose that distinction, so do not use that approach.

During baseline-free adoption, preserve an existing different credential
without asserting a historical conflict: sync cannot know whether it is a
stale token or a manual credential.

Keep rendered previews/candidates temporary and private, cleaning them on
failure. Do not add persistent config backups in the smart path. Local conflicts
are retained and safe updates are previewed interactively. Existing legacy
backups remain untouched.

Public previews show key paths and operations. Only explicitly allowlisted
non-sensitive settings may show local/incoming values; other paths show
"changed" or "removed". Use existing redaction as an additional safeguard,
not as permission to print arbitrary values that may not be in the secret
store. Historical plaintext values are unavailable by design.

## Writers, failures, and provenance

Hold an advisory lock in the shared state directory during apply. Re-read and
plan under the lock. Preview approval is tied to hashes of both config and
receipt; invalidate choices if either changed. Recheck the config immediately
before atomic replacement. Codex does not honor this lock, so a residual
application-write race remains.

Write config atomically first, then receipt atomically. Never acknowledge an
upstream change before its config write succeeds. On receipt-write failure,
report failure and retain the old receipt. Replay is conservative: applied
settings equal N; later local edits survive or produce conflicts. A lost
keep-local acknowledgment can repeat a prompt, but must not lose a value.
When only acknowledgment changes, write only the receipt. Regression tests
must prove replay safety for additions, edits, removals, and parent changes.
There are no generations, transaction pointers, or recovery daemon.

For clean tracking clones, allow equal or provably newer revisions from the
same origin/profile. Reject a provably older revision. If a recorded revision
is unavailable, ancestry diverges, or profile differs, skip this file with a
diagnostic; boot never waits for input or guesses.

Preserve --blueprint as a deliberate development workflow. Record its raw
template digest and source kind; a dirty working tree is not identified by
HEAD alone. Explicit local invocations may move between revisions from the
same origin/profile, but still obey the merge rules. Later ordinary sync
refuses to silently switch a receipt from local provenance to tracking.
An explicit --blueprint invocation selecting the clean tracking checkout
authorizes that transition and records tracking provenance. Different origins
are refused. Document this return-to-tracking operation in CLI help.

A missing receipt allows conservative adoption. A corrupt, unreadable, or
unsupported existing receipt instead preserves the config and reports error;
never silently reinterpret damaged state as a fresh installation.

These protections cover upgraded writers. Old sync code understands neither
the receipt nor its lock. Upgrade every writer sharing a Codex directory
before claiming preservation is guaranteed. A local manifest schema bump
cannot protect the file from an old sibling with a different manifest.

## Adoption and modes

- Missing config: deploy the rendered template without project trust and seed
  its receipt. Missing model values receive the existing default. This also
  applies when a valid shared receipt exists, after provenance/profile checks:
  restore is a whole-file operation, not a local deletion of every setting.
  Fingerprints cannot recover preferences/trust from a deleted file. Invalid
  or incompatible existing receipts still prevent restoration.
- Legacy managed config without receipt: retain existing values, add absent
  defaults, and acknowledge incoming fingerprints as the starting point.
  Do not infer old deletions or warn about ordinary differences as conflicts.
- Existing untracked personal config without shared receipt: boot and installer
  reconcile leave it byte-for-byte untouched. Interactive sync offers adoption;
  --yes authorizes conservative adoption, replacing its old clobber behavior.
- Existing shared receipt with missing local manifest entry: validate provenance
  and adopt managed status locally; do not repeat baseline-free migration.
- Invalid/unsupported TOML or unavailable dependency: preserve the config, do
  not advance state, and produce a visible file-level error.

Safe changes apply in boot, first-run, installer reconcile, and --yes.
Conflicts retain local values unattended. Interactive conflict choices are
keep-local or take-blueprint; EOF preserves local without acknowledging an
unanswered conflict. An explicit keep-local choice acknowledges it.

Dry-run writes no config, receipt, lock file, or manifest. It reports a
read-only plan that apply must recompute. Model/effort exceptions, trust, and
local-only keys are silent. Operational failures and provenance/profile
mismatches remain separate diagnostics, not setting conflicts.

## Concrete integration and dependency

Introduce mode toml_merge and managed_inventory_smart for Codex config.
Leave generic JSON merge unchanged. A pure planner returns config_changed,
state_changed, conflicts, and error; public output never includes secrets.

Add smart_update, smart_conflict, and smart_error classification results.
Existing missing/untracked buckets retain their adoption meaning. A conflict
may coexist with safe updates; conflict-only plans must remain actionable for
interactive resolution and unattended reporting. State-only plans write no
config. Do not put smart errors into a successful apply receipt.

Integrate inventory, classification, and dispatch in lib/blueprint-deploy.sh;
install/adoption/reconciliation in lib/provision-managed-files.sh; and counts,
early no-op checks, apply sets, previews, and receipts in lib/sync.sh.
Never fall through to the generic overwrite/backup path. If Codex config is
removed from inventory, preserve its personal content and report retirement
rather than deleting the whole file.

Write mode toml_merge and source identity in manifest schema 2. Accept and
migrate schema 1; old readers reject schema 2 through the existing check.
This guards readers of that manifest only, not sibling containers. Keep
aicoding-status's current revision/provisioning scope; do not add a new config
parser there. Surface smart-merge failures in sync output.

Use Python >=3.8 and vendor the unmodified tomlkit 0.13.3 runtime under
lib/vendor/, with its MIT license, upstream version, and archive checksum.
Vendor only runtime/license files, not bytecode or upstream tests. This
provides an exact formatting-preserving writer on the first new sync, including
existing containers and offline tests, without runtime pip/uv or an image
rebuild prerequisite.

The upstream package supports Python >=3.8 and ships a platform-independent
wheel. [Package metadata](https://pypi.org/project/tomlkit/0.13.3/).
Wheel SHA-256:
c89c649d79ee40629a9fda55f8ace8c6a1b42deb912b2a8fd8d942ddadb606b0.
Add Python version checks to container/host prerequisites. Hosts retain their
manual-install convention. Probe runtime availability before classification;
missing runtime is an error, never an overwrite fallback.

## Validation and delivery

Run fixture-only tests through bash tests/bats/run.sh:

1. Astra, effort, and both trust values survive safe updates in every mode.
   Local edits against an unchanged blueprint produce no conflict.
2. Cover each comparison row, missing values, arrays, nested tables, type
   changes, and deleting a table containing local children.
3. Conflicts persist unattended, resolve when equal or explicitly accepted,
   stay silent after keep-local, and recur for new incompatible changes.
4. Separate legacy managed adoption from untracked host configs. Boot/reconcile
   leave the latter untouched. Repeated sync writes no config.
5. Credential rotation applies to unchanged values and conflicts with independent
   edits. Receipts/logs/previews/errors contain no raw credentials; guards
   prevent agent reads of state. Persist no rendered candidates.
6. Simulate two containers, locks, changed previews, config/receipt write
   failures and replay, unavailable revisions, old/divergent sources, dirty
   local blueprints, return to tracking, and different profiles.
7. Missing Python/vendor, invalid TOML, corrupt receipt, and schema migration
   preserve existing values and report failures.
8. Test comments, quoted dotted keys, type-aware fingerprints, formatting
   no-ops, and conflict-only/state-only classification and receipts.

The implementation includes fixture-only engine, integration, guard, minimum
Python, help-text, and failure-path regressions. Template comments and README
document default-only model/effort behavior, silent preferences, true
conflicts, adoption, return to tracking, and mixed-writer rollout. The full
default-parallel suite is the final implementation gate before review and PR.
Updating this design performs no merge, fleet rollout, or live settings change.
