# dev-process-lite: the generic parts of the balance-extract dev process

Date: 2026-10-03. Status: proposed, not yet implemented.

## Problem

`vossiman/balance-extract` grew a mature process for agent-driven
development: an overseer that keeps a decision journal, a separate short
session that assesses a finished run, closed rules for when to file a ticket
instead of fixing, closed rules for when to interrupt the owner, a routes
table that pins harness, model and effort per role, a PR template with a
required independent-review section, and two project hooks that inject the
requirements and a ship-check. Most of that is generic. Today none of it
reaches other repos: the blueprint ships the reviewer defaults as prose
(`configs/claude/CLAUDE.md:216-220`, `skills/review-by-harness/SKILL.md:24-29`)
and nothing else.

The user agreed to lift six items. The 7.4k-line `scripts/dev_process/`
engine (preflight receipts, launch, audit, gc), `ci_select.py` and GitHub
rulesets stay out. Everything balance-extract-specific (Robert, OpenRouter,
corpus, holdout, USD caps, stage help, the develop branch flow) is stripped.

Hard requirement added during design: a repo that has its own process must
keep using it after the blueprint installs the lite version. balance-extract
must see no conflict and no double loading. Section "Precedence" settles that.

## Goals

- One canonical policy text, shipped to every machine, with thin adapters
  per agent, the way balance-extract splits `docs/DEV_PROCESS.md` from its
  `dev-process` and `assess` skills.
- The global CLAUDE.md addition stays under ten lines, because it loads in
  every session.
- Existing repos opt in file by file. `aicoding-sync` never writes into a
  project repo (`README.md:137`: the templates are not deployed anywhere).
- Codex, Cursor and OpenCode get the same policy through the paths they
  already read (`docs/agent-parity.md`). Runs start from Claude, Codex or
  Cursor; OpenCode is not an entry harness (section 4).
- No rule that already exists in the global CLAUDE.md, `review-by-harness`,
  `worktree-session` or the kanban MCP instructions is restated. The lite
  policy refines those; it does not copy them.
- A project-specific process always wins, by an explicit detection rule.

## Non-goals

- No engine: no receipts, no launch wrapper, no evidence binding, no gc.
- No enforcement: no CI status, no branch protection, no PreToolUse block.
- No change to how `review-by-harness` runs a review.
- No per-project Codex hooks (Codex project hooks are not managed by the
  blueprint today; `docs/agent-parity.md` lists managed hooks under
  `/etc/codex` only).

## Where each piece lives

| Piece | Location in the blueprint | Reaches machines via | Reaches repos via |
|---|---|---|---|
| Policy text (items 1, 2, 3) | `skills/dev-process-lite/policy.md` | synced to `~/.claude/skills/` (`lib/blueprint-deploy.sh:362-366`), mirrored to `~/.agents/skills` for Codex (`lib/sync.sh:217-224`), scanned by Cursor from `~/.claude/skills` (`lib/sync.sh:211`) | the global rule below; nothing to copy |
| Overseer adapter | `skills/dev-process-lite/SKILL.md` | same | same |
| Assessment adapter | `skills/assess-run/SKILL.md` | same | same |
| Detection helper | `skills/dev-process-lite/detect.sh`, `routes.sh` | same | same |
| Default routes (item 4) | `skills/dev-process-lite/routes.default.json` | same | optional copy to `<repo>/.dev-process/routes.json` |
| Global rule (one paragraph) | `configs/claude/CLAUDE.md`, `configs/codex/AGENTS.md`, `configs/cursor/skills/aicoding-estate/SKILL.md` | managed config | n/a |
| PR template (item 5) | `templates/project/dot-github/pull_request_template.md.tpl` | not deployed | new repos; existing repos copy it |
| Project hooks (item 6) | `templates/project/dot-claude/settings.json.tpl`, `templates/project/dot-claude/hooks/north-star.sh`, `templates/project/dot-claude/hooks/ship-check.sh` | not deployed | new repos; existing repos copy them |
| Ignore rules | `templates/project/dot-gitignore.tpl` | not deployed | new repos; existing repos add two lines |
| Scaffold conventions | `templates/project/AGENTS.md.tpl` (new section) | not deployed | new repos |

Why the policy lives inside a skill directory and not under `docs/`: the
skill tree is the only blueprint path that reaches every machine and every
agent (`docs/agent-parity.md`, "Estate skills" row). A doc under `docs/` would
exist only in blueprint checkouts. Claude Code loads a skill's `SKILL.md`
only; files beside it are read on demand, so a 150-line `policy.md` costs
nothing until a session needs it.

Why two skills and not one: the overseer and the assessor are different
sessions with different jobs, and balance-extract already proved that split.
The assessor must not spawn workers or edit code; giving it its own skill
keeps that boundary visible in the skill description.

## The policy text

`skills/dev-process-lite/policy.md` has four sections. It is written for a
reader who has the global CLAUDE.md loaded, so it names the existing rules
instead of repeating them. Target length: under 150 lines.

### 1. Overseer log

An overseer is any session that coordinates more than one task: it prepares
work for subagents or worker sessions, reads their diffs, and decides what
merges. A single session doing one ticket end to end is not an overseer and
keeps no log.

The overseer keeps `.claude/dev-process-runs/<session>/overseer.md`, written
for a reader who did not watch the run. `<session>` is `CLAUDE_CODE_SESSION_ID`
for Claude and `CODEX_THREAD_ID` for Codex; balance-extract found that Codex
can inherit a stale `CLAUDE_CODE_SESSION_ID` from whatever launched it
(balance-extract `docs/DEV_PROCESS.md:286-288`), so a Codex overseer must not
use it. Append an entry at each milestone (task prepared, handed off,
accepted, blocked or abandoned; review bound; PR opened), never per tool
call. Hard cap: 120 lines. Five fixed sections, in this order:

- **Plan**: plan or spec path and revision, tickets, base revision, the
  overseer's session id and its current name (the `name` of the
  `~/.claude/sessions/*.json` entry whose `sessionId` matches; read it, do
  not wait for a rename).
- **Decisions**: each decision the plan did not settle, with a one-sentence
  reason and the record, commit or file that shows it. The implementer
  role chosen per task (section 4) and any reassignment go here.
- **Deviations**: where delivery differs from the plan, including unmet
  acceptance criteria, skipped validation, diff-only reviews and overridden
  blocking findings, each with the reason.
- **Open questions**: what the owner or an assessment must decide. Empty
  means the overseer claims none.
- **Board**: tickets closed, filed and left open. Each filed ticket names its
  accepted reason from section 2; each open one names its blocker.

Entries point at evidence instead of restating it, and never contain secrets
or customer data.

### 2. Finish in the run, close what is old

Kept from balance-extract `docs/DEV_PROCESS.md:624-694`, generalized:

- **Do the work in the run.** A defect, gap or review finding found during a
  run goes to a worker in that run when the fix touches what the run already
  works on or a worker could finish it in about an hour. "Out of scope" and
  "pre-existing" are not reasons to file. The overseer widens scope for
  small work without asking and records it under Decisions.
- **A ticket is a mechanism, not a slot.** A work ticket names one mechanism
  and holds about three to four agent tasks. It never names one data row,
  one document or one test case; those are evidence rows in the ticket.
- **Fix review findings at once.** A verified finding that is easy to fix
  goes onto the open PR's branch before merge. A change to Markdown, a
  comment, a name or a link never gets its own ticket, branch or PR.
- **File a ticket only when the run cannot do the work.** The accepted
  reasons are closed:
  1. it needs an answer from the owner or a third party (then it is a
     feedback ticket in `waiting_for_feedback`, or links to one);
  2. it needs a paid action or another authorization the run does not hold;
  3. another live session owns the files (global sibling rules);
  4. it is a separate piece of work larger than one worker task, which the
     run's tickets do not need in order to close.
- Search the board first (`mcp__kanban__search`): a finding an open ticket
  covers becomes a comment there; findings sharing a cause go into one
  ticket with a checklist. A run about to file a third ticket, or more than
  it closes, re-reads its list.
- **Close the run's tickets.** When the agreed scope was delivered but the
  title promised more, close it anyway, comment what was delivered, and file
  the remainder as bounded tickets linked `relates`.
- **Split old tickets.** A work ticket still open three days after a run
  worked on it, or carried through two runs, is closed with a comment and
  replaced by bounded remainders. Feedback tickets and untouched backlog are
  exempt.

Dropped from the original: the printed-document and `invented` finding rules,
the stage-help rule, and the develop-to-main flow. They are specific to a
document-extraction product.

Relationship to existing rules: the kanban MCP instructions define the
transitions (claim, checkpoint, release, complete); this section only decides
*whether* a ticket is filed. `review-by-harness` already tells its reviewer
not to file tickets (`skills/review-by-harness/SKILL.md`, section "The
harness gets session rules"); this section tells the overseer what to do
with the findings instead.

### 3. When the overseer comes back to the owner

Kept from balance-extract `docs/DEV_PROCESS.md:696-718`, with the USD figure
removed. The overseer decides, records under Decisions, and carries on. It
stops for the owner only when:

- an action needs an authorization the run does not hold: a paid action
  above the project's stated cap, sending a message outside the repo, a
  production or storage change, a release;
- the next step would be destructive or could not be undone;
- every remaining task is blocked on a person's answer.

Merging a reviewed, green PR under the repo's merge policy and cleaning up
the run's own worktrees need no owner go, unless the repo's CLAUDE.md says
"ask before merging" (devMachine and aicoding both do; that rule wins).
In a run the owner declared overnight or unattended, the overseer never
stops: the blocked step is parked under Open questions, the rest finishes,
and the owner reads one closeout.

### 4. Routes

Executable model and effort choices per role come from a routes table, not
from prose. Lite roles: `overseer`, `implementer`, `complex-implementer`,
`reviewer`, `assessor`, the same role names balance-extract uses.
Entry harnesses: `claude`, `codex`, `cursor`. OpenCode is not an entry
point: it reads the policy through `AGENTS.md` and can do single-ticket
work, but a run that coordinates tasks starts from Claude, Codex or Cursor,
because only those have a `review-by-harness` adapter and a verified model
list.

**Schema.** balance-extract's `.dev-process/routes.json` layout unchanged
(`version: 1`, `routes.<entry>.<role>`), with one addition: a route names
either an exact `model` or a `family`. `model` is an exact id and wins when
both are present, so balance-extract's pinned routes keep working without
edits. `family` is resolved at launch (owner decision 2026-10-03): a route
should name a tier, not a version, because the CLIs ship new versions
faster than a routes file is edited. `effort` is the harness effort level
for Claude and Codex; for Cursor it is the suffix of the selector.

**Resolver.** `routes.sh [entry] [role]` beside the skill applies the lookup
order (`<repo>/.dev-process/routes.json` when present, else the skill's
`routes.default.json`; a project file missing the entry table uses the
default file's table and says so), resolves the route, prints it as JSON and
prints the exact id it chose. The overseer writes that id into the log's
Plan section next to the family. Rules per harness, from the installed CLIs
on 2026-10-03:

- `claude`: families `fable`, `opus`, `sonnet`, `haiku`. The CLI accepts
  the family name as a `--model` alias for its latest version (`claude
  --help`), so the resolver passes the alias through. The exact id is
  whatever the harness reports at session start; when it reports none, the
  log records the alias and "exact id not observable", the same wording
  balance-extract uses for unobservable models.
- `codex`: families are the slug suffix (`sol`, `astra`, `luna`, `terra`).
  The resolver reads `codex debug models` JSON, keeps slugs with
  `visibility: list` that end in `-<family>`, drops any slug whose `upgrade`
  field is set (a retiring model; `gpt-5.5` retires 2026-10-14 with upgrade
  `gpt-6.1-sol`), and picks the highest version parsed from
  `gpt-<version>-<family>`. Today `sol` resolves to `gpt-6.1-sol`, `astra`
  to `gpt-6-astra`, `luna` to `gpt-6-luna`; the `gpt-5.6-*` slugs are
  marked older and lose to `6.1`.
- `cursor`: the resolver reads `cursor-agent --list-models`, which prints
  versioned selectors with the effort in the name and no aliases except
  `auto`. A family is the vendor-model token (`grok`, `claude-opus`,
  `claude-fable`, `gpt`), the selector pattern is
  `[cursor-]<family>-<version>-<effort>[-fast]`; the `cursor-` prefix
  marks a Cursor-tuned variant and is matched but not required, because
  the list on 2026-10-03 carries `grok-4.7-*` without the prefix next to
  `cursor-grok-4.6-*` with it. The resolver picks the highest version that
  has the route's effort suffix. Today `grok` with `xhigh` resolves to
  `grok-4.7-xhigh`; Cursor lists no `gpt-6` selector at all, so a `gpt`
  family on Cursor resolves to a 5.6 selector or blocks.

**Failure.** No match blocks the launch with the family, the harness and
the list consulted. The resolver never substitutes another family or
harness, the rule balance-extract's preflight already follows. An exact
`model` pin is checked against the same list (Codex and Cursor) or against
the `claude-<family>-<version>` shape (Claude); a pin that is not installed
blocks too. An entry name other than the three above blocks with "start
runs from Claude, Codex or Cursor".

**Entry detection.** `CLAUDECODE` set means `claude`, `CODEX_THREAD_ID`
means `codex` (the markers `review-by-harness` already reads,
`docs/agent-parity.md`, "Review from either CLI"); the Cursor estate skill
names `cursor` in its text. An explicit argument wins.

**Defaults** in `routes.default.json`:

| entry | role | harness | family | effort | resolves today |
|---|---|---|---|---|---|
| claude | overseer | claude | `opus` | high | `claude-opus-5-5` |
| claude | implementer | claude | `sonnet` | low | `claude-sonnet-5-5` |
| claude | complex-implementer | claude | `opus` | high | `claude-opus-5-5` |
| claude | reviewer | codex | `sol` | high | `gpt-6.1-sol` |
| claude | assessor | claude | `opus` | high | `claude-opus-5-5` |
| codex | overseer | codex | `sol` | high | `gpt-6.1-sol` |
| codex | implementer | codex | `luna` | medium | `gpt-6-luna` |
| codex | complex-implementer | codex | `sol` | high | `gpt-6.1-sol` |
| codex | reviewer | claude | `opus` | high | `claude-opus-5-5` |
| codex | assessor | codex | `sol` | high | `gpt-6.1-sol` |
| cursor | overseer | cursor | `grok` | xhigh | `grok-4.7-xhigh` |
| cursor | implementer | cursor | `grok` | medium | `grok-4.7-medium` |
| cursor | complex-implementer | cursor | `grok` | xhigh | `grok-4.7-xhigh` |
| cursor | reviewer | codex | `astra` | high | `gpt-6-astra` |
| cursor | assessor | cursor | `grok` | xhigh | `grok-4.7-xhigh` |

Notes on the rows:

- The implementer follows task complexity (owner decision 2026-10-03,
  revised the same day). `implementer` runs the balanced tier: Sonnet 5.5
  scores 70.6% on Terminal-Bench 4.0 against Opus 5.5's 66.4%, sits within
  about two points on CursorBench, and costs half
  (https://www.anthropic.com/claude-sonnet-5-5). The vendor documents
  `medium` for well-specified tasks
  (https://platform.claude.com/docs/en/build-with-claude/effort), and low
  effort means fewer tool calls and checks. The phase 1 measurement
  (Evidence and caveats) found no difference between `low` and `medium`
  when the plan carries the code, so the `claude` row ships at `low`; the
  overseer raises it to `medium` when a brief leaves design choices to
  the implementer. Codex and Cursor rows stay at `medium` until measured.
- Codex `luna` is the owner's choice as the Sonnet-level counterpart.
  There is no public evidence that `gpt-6-luna` is Sonnet-level; the row
  is marked "unproven, revisit with own evals" in the JSON comment and in
  Evidence and caveats below.
- `complex-implementer` runs the workhorse at `high`, the level the vendor
  documents for harder and longer tasks. Use `xhigh` for a long-horizon
  task expected to run past about 30 minutes (same source). Opus and Sol
  at `medium` are the documented middle step between the two roles.
- Cursor's `implementer` uses `medium`: Cursor's unlabeled default selector
  is the `high` one (`cursor-grok-4.6-high` prints as plain "Grok 4.6"), so
  `medium` is the one step below default, matching the Claude and Codex
  rows. Grok's `low` selectors are the mechanical-edit tier.
- Every reviewer is cross-vendor to the entry harness.
- The Cursor reviewer row is the one place a frontier family sits in the
  defaults. The global rule says Fable and Astra need an explicit user
  override; the owner gave that override for exactly this row on
  2026-10-03, with `claude` family `fable` as the documented alternative
  (a comment next to the row in the JSON). The guard test allows a
  frontier family in `cursor.reviewer` and nowhere else in the default
  file. Project routes files are the owner's override in writing and are
  not checked (balance-extract pins Fable and Astra).

**Choosing the implementer role.** The overseer picks the role per task
and records the choice under Decisions with the criterion that decided it.
A task is `implementer` work when all of these hold:

1. the plan or spec names the files to touch and the acceptance criteria,
   so the worker makes no design choice;
2. it stays inside one module or one mechanism, with no change to an
   interface, a data format, a lock or ownership model, or a public CLI;
3. a unit test or a scripted check can prove it done without a person
   reading the result;
4. a worker can finish it in about an hour (the same bound section 2 uses
   for widening scope).

Anything else is `complex-implementer`.

**Escalation ladder.** After a failed attempt the overseer raises effort
first (`medium` to `high`, then `xhigh`), and only then moves up a model
tier (`sonnet` to `opus`, `luna` to `sol`, which is the
`complex-implementer` route). Each step is recorded under Decisions as a
reassignment naming the first task, the way balance-extract records
reviewer escalations (`docs/DEV_PROCESS.md:57-59`); the failed attempt's
branch is dropped, not patched. A task never moves down. There is no
direct public evidence for escalate-on-failure cascades in coding agents;
the ladder is the cheapest ordering of the two levers and is one of the
things the effort sweep below should test.

**Tests are the contract.** When the acceptance tests were written in a
prior step (red first), an implementer does not edit the tests it is
judged by. A test change needs the overseer's approval, recorded under
Decisions with the reason. The cross-vendor review stays the backstop for
an implementer that quietly weakened a test.

**Evidence and caveats.** The numbers above are vendor numbers: Opus 5.5
at `medium` beating Opus 5 at `max` at about a fifth of the cost
(https://www.anthropic.com/claude-opus-5-5) and the Sonnet 5.5 figures
come from Anthropic's own pages. Effort gains are not monotonic (Sonnet
5.5 at `max` scores below `xhigh` on one benchmark on the same page).
Pass rate overstates quality, and the gap grows with task size and for
weaker models (SpecBench, https://arxiv.org/html/2605.21384v1); SWE-bench
Verified is contaminated and no longer a usable signal
(https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/).
So the defaults are a starting point. The phase 1 build measured `implementer` effort by running this process on itself (PR #249): three tasks ran twice from the same base, once at `low` and once at `medium`, on Sonnet 5.5 with a plan that carried the code. All three pairs produced byte-identical commits, the same cross-vendor review result and similar cost (0.29 to 0.37 USD per run); `medium` took 6 to 20 seconds longer. Every other task passed at `low` without escalation, and the verified review findings were defects in the plan, not in the implementer output. This supports `low` for briefs that carry the code; it says nothing about briefs that leave design to the implementer. The owner moved the `claude` implementer default to `low` on 2026-10-03; Codex and Cursor stay at `medium` until measured. Use `medium` when a brief leaves design choices to the implementer. A wider effort sweep (the vendor's advice at the effort page), including `luna` against `sol`, follows once phase 4 has produced real runs.

**Tier parity** across the three entry harnesses, as resolved today. A
route names the tier; this table is the reference for what that means per
vendor and is refreshed when the resolver's rules change:

| tier | Claude | Codex | Cursor |
|---|---|---|---|
| frontier | `fable` (`claude-fable-5-1`) | `astra` (`gpt-6-astra`) | `claude-fable` (`claude-fable-5-thinking-high`); no Grok or GPT frontier listed |
| workhorse | `opus` (`claude-opus-5-5`) | `sol` (`gpt-6.1-sol`) | `grok` (`grok-4.7-xhigh`) |
| balanced (implementer) | `sonnet` (`claude-sonnet-5-5`) | `luna` (`gpt-6-luna`, unproven) | `grok` at `medium` (`grok-4.7-medium`) |
| reviewer of this entry | Codex `sol` | Claude `opus` | Codex `astra` (alt: Claude `fable`) |

**Relationship to existing prose.** The reviewer families match the
defaults in `configs/claude/CLAUDE.md:216-220`, `configs/codex/AGENTS.md:120-123`
and `skills/review-by-harness/SKILL.md:24-29` at the family level (Opus for
Claude, Sol for Codex). Those texts and the identifier table in
`skills/review-by-harness/SKILL.md:33-42` (verified 2026-09-09) name exact
ids that are already stale: Codex now lists `gpt-6.1-sol` as the current
Sol and marks `gpt-5.6-sol` older, and Claude reports `claude-opus-5-5` for the `opus` alias. Phase 2 updates them to name families
with the current ids as examples, and the guard test compares families, not
frozen ids (Testing, item 4). `review-by-harness` must keep working in a
repo with no routes file and in a session that never loaded the lite skill,
so it keeps its own table and the routes file does not replace it.

## The two skills

### `dev-process-lite`

Frontmatter description: "Use when coordinating more than one task in a
repo that has no `docs/DEV_PROCESS.md`: delegation, routes, review
findings, board state and the overseer log. Not for a single-ticket
session."

Body, in order:

1. Run `bash ~/.claude/skills/dev-process-lite/detect.sh`. If it prints `project <path>`, say so in one line and
   stop; that repo's own skills apply. (Section "Precedence".)
2. Read `policy.md` beside this file.
3. Run `bash ~/.claude/skills/dev-process-lite/routes.sh [entry]`: it applies the section 4
   lookup order and entry detection, prints the selected table as JSON, and
   prints a fallback note when it substituted the `claude` table.
4. Keep the overseer log; add `.claude/dev-process-runs/` to
   `.git/info/exclude` if it is not ignored yet, the same way the global
   rule handles `.claude/worktrees/` (`configs/claude/CLAUDE.md:153-159`).
5. Use `worktree-session` for every worker branch and `review-by-harness`
   for the one integrated review, with the reviewer route passed as
   `--harness` and `--model`, plus `--effort` only when the reviewer
   harness is claude or codex (Cursor's effort is in its model selector;
   `review-by-harness/run.sh` rejects `--effort` for cursor).
6. Before closeout, check the Board section against policy section 2.

No new tool names. The skill describes tasks, so Codex can follow it with
its own tools (parity rule in `docs/agent-parity.md`, "Differences that
remain").

### `assess-run`

Frontmatter description: "Use in a fresh short session to assess a finished
dev-process-lite run from its overseer log and integrated diff, without
re-reading the overseer conversation. Takes the run session id or lists
runs when omitted. Not for repos with their own `docs/DEV_PROCESS.md`."

Body: balance-extract's `.claude/skills/assess/SKILL.md` with the engine
parts removed. The assessor reads, in order, the overseer log, the
`review-by-harness` report under `.claude/worktrees/review-pr<N>-<harness>/.review-round/`
if present, and `git diff --stat <base>...<head>` plus the PR body. It checks
the five sections and the 120-line cap, spot-checks one Decisions and one
Deviations entry against the diff, checks Board against policy section 2
and the owner-return list in section 3, answers the Open questions, and
reports in under 300 words with a verdict: `sound` (names who merges),
`fix first` (names the fix, goes back to the overseer as a task) or `stop`
(names the contradiction, owner decides).

Hand-back is conditional, and the skill body says so. `ListAgents` and
`SendMessage` exist only in Claude Code, and `~/.claude/sessions/*.json`
lists only Claude sessions; a Codex overseer's `CODEX_THREAD_ID` is never in
it, and Codex cannot message independent sessions (`configs/codex/AGENTS.md:143-145`,
`docs/agent-parity.md`, "Independent session messages" row). So:

- Claude assessor and the Plan section names a Claude session id: resolve
  the name through `~/.claude/sessions/*.json`, run `ListAgents`, and send
  the report with `SendMessage` only when that name is listed. Never claim a
  send that did not succeed (same wording as `worktree-session`).
- Any other combination (Codex or Cursor assessor; or a Codex
  overseer id in Plan): report only. The report ends with one line saying
  the owner relays the verdict to the overseer, and names the overseer id.

It never spawns workers, edits code or moves the board. Step 1 is the same
`detect.sh` check.

The assessor route is `assessor` from the routes table. The owner starts the
session with that model; the skill does not switch models.

### `detect.sh`

A ten-line bash script, fail-open, exit 0 always:

```
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo lite; exit 0; }
if [ -f "$root/docs/DEV_PROCESS.md" ]; then echo "project $root/docs/DEV_PROCESS.md"; else echo lite; fi
```

It exists so the rule is testable with bats and identical in both skills.

## Precedence: a project-specific process always wins

### Detection rule

A repository has its own development process when `docs/DEV_PROCESS.md`
exists at its git top level. Nothing else is checked: not `.dev-process/`,
not the presence of project skills. Reasons:

- The lite process shares the `.dev-process/routes.json` path and schema on
  purpose (section 4), so that directory cannot be the marker.
- A project that adopts the full process does so by writing a policy doc;
  balance-extract's `AGENTS.md:21-22` points at exactly that file. One
  file, one rule, no marker file to forget.
- The lite policy never lives at that path in a project. New repos reference
  the shared skill from `AGENTS.md`; they do not get a copy of `policy.md`.

Consequence: in a repo with `docs/DEV_PROCESS.md`, the lite skills stop at
step 1, the lite routes default is never consulted, and the global rule
sends the agent to that document.

### What defers

- **Global rule text** (all three managed files): "A repo with
  `docs/DEV_PROCESS.md` follows that document and its own skills. Any other
  repo follows the shared `dev-process-lite` skill when a session
  coordinates more than one task." The project document is named first, so
  an agent reading only the global text already knows the order.
- **Skill descriptions** carry "has no `docs/DEV_PROCESS.md`" and "Not for
  repos with their own `docs/DEV_PROCESS.md`", so implicit matching in Claude
  Code and Codex (both match on description) prefers the project skill.
- **Skill bodies** start with `detect.sh`.
- **Templates** are never applied to an existing repo by any blueprint code,
  so balance-extract's `.claude/settings.json`, `.github/pull_request_template.md`
  and `.gitignore` stay untouched.

### Skill name collisions, verified

Claude Code 2.1.288 is installed. Its skills reference, section "Resolve
skills that share a name" (code.claude.com/docs/en/skills, read
2026-10-03), says: "Two of enterprise, personal, and project: Enterprise over
personal, and personal over project. With `deploy` in both `~/.claude/skills/`
and the project's `.claude/skills/`, `/deploy` runs the personal one."

The blueprint deploys shared skills to `~/.claude/skills/`, the personal
location. So a shared skill named `assess` or `dev-process` would **shadow**
balance-extract's `.claude/skills/assess` and `.claude/skills/dev-process`
in every Claude session. That is the opposite of the requirement.

Codex 0.160.0 is installed. Its skills reference (developers.openai.com/codex/skills,
read 2026-10-03) says: "If two skills share the same `name`, Codex doesn't
merge them; both can appear in skill selectors." Codex reads
`$HOME/.agents/skills` (the blueprint's symlink to `~/.claude/skills`) and
`$REPO_ROOT/.agents/skills`, where balance-extract keeps its `dev-process`.
A same-named shared skill would therefore load twice and leave the choice
to the model.

Decision: the shared skills are named `dev-process-lite` and `assess-run`.
Neither name exists in balance-extract. A guard test refuses a `skills/assess`
or `skills/dev-process` directory in the blueprint, with this section as
the reason. The names are the mechanism; the detection rule is the backstop
for a session that loads the lite skill anyway.

Cursor scans `~/.claude/skills` plus the project; the estate skill
(`configs/cursor/skills/aicoding-estate/SKILL.md`) carries the global text,
so the same deferral applies. OpenCode reads `AGENTS.md`, which in
balance-extract names its own process.

### Verification that balance-extract is unaffected

Run after the implementation PR is synced to a container:

1. `comm -12 <(ls ~/.claude/skills) <(ls <be>/.claude/skills <be>/.agents/skills | sort -u)`
   prints nothing. (No shared name collides with a project skill.)
2. `bash ~/.claude/skills/dev-process-lite/detect.sh` run inside the
   balance-extract clone prints `project .../docs/DEV_PROCESS.md`.
3. `git -C <be> status --short` is empty before and after `aicoding-sync`.
   (The blueprint wrote nothing into the repo.)
4. `claude -p '/dev-process-lite' --output-format text` inside
   balance-extract answers that the repo has its own process and names
   `docs/DEV_PROCESS.md`; `claude -p '/assess-run'` does the same.
5. `claude -p '/assess'` inside balance-extract answers from the project
   skill (it asks for a run session id or lists
   `.claude/dev-process-runs/`), which shows the project skill still
   resolves under its own name.
6. `codex exec` with `$dev-process` inside balance-extract shows one skill
   of that name in `/skills`, from `.agents/skills`.

Steps 1 to 3 go into the bats suite with a fixture repo that contains
`docs/DEV_PROCESS.md` and a project `.claude/skills/assess/SKILL.md`. Steps
4 to 6 are live checks in the implementation PR's test plan; stubbed tests
cannot prove model behavior (`docs/agent-parity.md`, "Validation").

## Global rule text

One paragraph appended to `configs/claude/CLAUDE.md` after "Parallel-session
coordination", and the same paragraph in `configs/codex/AGENTS.md` and the
Cursor estate skill:

```
## Dev process

A repo with `docs/DEV_PROCESS.md` follows that document and its own skills.
Any other repo follows the shared `dev-process-lite` skill when a session
coordinates more than one task: an overseer log per run, the finish-in-the-run
ticket rules, the short list of reasons to interrupt the owner, and a routes
table for harness, model and effort per role. Assess a finished run from a
fresh session with `assess-run`. A single-ticket session needs none of this.
```

Six lines. Model names stay out of it; they live in the routes file and in
the `review-by-harness` paragraph that already exists at
`configs/claude/CLAUDE.md:216-220`.

## Templates for new projects

### `AGENTS.md.tpl`: new section "Development process"

Four sentences: this repo has no `docs/DEV_PROCESS.md`, so the shared
`dev-process-lite` skill applies; routes are in `.dev-process/routes.json`
(edit it to pin models for this repo; adding `docs/DEV_PROCESS.md` later
switches the repo to its own process); `docs/REQUIREMENTS.md`, when present,
is the North Star and is injected at session start, so keep it under about
150 lines; `docs/SHIP_CHECK.md`, when present, is read back after every
`git commit`.

### `.dev-process/routes.json`

A copy of `routes.default.json`. Committed, so the repo's pins are reviewed
in PRs the same way balance-extract reviews its routes.

### `dot-github/pull_request_template.md.tpl`

```
## Change

Describe the problem and the resulting behavior.

## Validation

State the checks run and their results, with commands and exit codes.

## Independent review

Reviewer harness/model/effort, reviewed commit, findings and disposition.
"none" needs a reason.
```

The "Stage explanations" section from balance-extract is dropped. The
`review-by-harness` skill gets one added sentence in "Your job when it
finishes": paste harness, model, effort, reviewed commit and each finding's
disposition into the PR's "Independent review" section when the PR has one.
The blueprint repo itself and devMachine adopt the template in the
implementation PR, which gives the section a first real user.

### `dot-claude/settings.json.tpl` and two hook scripts

The hooks become scripts under `dot-claude/hooks/`, referenced as
`${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.sh`, the pattern Claude Code's
hooks reference uses for its `block-rm.sh` example. Inline one-liners (what
balance-extract has) cannot escape arbitrary file content into JSON safely;
a script can.

- `north-star.sh`, SessionStart, matcher `startup|resume`: if
  `docs/REQUIREMENTS.md` exists, print a one-line header and the file to
  stdout (SessionStart stdout is added as context). If the file has more
  than 200 lines, print the header plus a warning naming the length instead
  of the file. Missing file: print nothing. Always exit 0.
- `ship-check.sh`, PostToolUse, matcher `Bash`, `"if": "Bash(git commit*)"`
  (the `if` field is in the hooks reference, read 2026-10-03): if
  `docs/SHIP_CHECK.md` exists, emit
  `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":<file as JSON string>}}`
  using `python3 -c 'import json,sys;...'` for the escaping. Missing file:
  print nothing. Always exit 0.

Both follow the fail-open contract of `configs/claude/hooks/check-archived-docs.sh:6-11`.
`SHIP_CHECK.md` is the project's own list of questions (balance-extract's
six are product-specific and stay there); the template ships an example
with three generic questions: tests ran, docs updated, nothing filed that
could have been fixed.

### `dot-gitignore.tpl`

```
.claude/worktrees/
.claude/dev-process-runs/
```

Run journals are operational storage, not product evidence: balance-extract
ignores `/.claude/*` except settings and skills (its `.gitignore`), and
nothing reads a journal after assessment. Existing repos add the second
line to `.git/info/exclude`, which the lite skill does in step 4.

## Adoption by existing repos

Nothing is required. The global rule and the shared skills apply to every
repo without `docs/DEV_PROCESS.md` as soon as `aicoding-sync` runs. Three
optional refinements, each one copy from a blueprint checkout or the active
release under `~/.local/share/aicoding/versions/`:

1. `.dev-process/routes.json`, to pin models for the repo.
2. `.github/pull_request_template.md`, to make the review section a habit.
3. `.claude/settings.json` plus `.claude/hooks/`, once the repo has a
   `docs/REQUIREMENTS.md` worth injecting. Merge the hooks into an existing
   settings file by hand; do not overwrite project permissions.

The `dev-process-lite` skill lists these three in a closing "Opt-in files"
section so an agent asked to "adopt the dev process here" knows what to
copy and what to leave alone.

## Testing

New file `tests/bats/dev-process-lite.bats`, run through `tests/bats/run.sh`
like every other suite (`CLAUDE.md`, section Tests):

1. Deployment: after `managed_config_apply` into a scratch `HOME`,
   `~/.claude/skills/dev-process-lite/{SKILL.md,policy.md,detect.sh,routes.sh,routes.default.json}`
   and `~/.claude/skills/assess-run/SKILL.md` exist byte-for-byte (pattern
   from `tests/bats/design-skill-source.bats:22-36`).
2. Collision guard: `skills/assess` and `skills/dev-process` do not exist.
3. `detect.sh`: prints `lite` in a fixture repo without the doc, `project
   <path>` with it, `lite` outside any repo, exit 0 in all three.
4. Routes and resolver: `routes.default.json` parses, has `version: 1`
   and exactly the three entry tables `claude`, `codex`, `cursor`, each
   with the five roles; each role has `harness` and exactly one of `model`
   or `family`; `implementer` and `complex-implementer` share `harness`
   in every entry, `implementer` has the lower `effort`, and the
   `claude` and `codex` implementer rows name the balanced family
   (`sonnet`, `luna`) while their complex rows name the workhorse
   (`opus`, `sol`); every reviewer row has `harness` different from its entry;
   no row names a frontier family (`fable`, `astra`) or a frontier exact
   id except `cursor.reviewer`, which must. `routes.sh` is tested against
   fixture model lists under `tests/fixtures/dev-process-lite/`: a `codex
   debug models` JSON with `gpt-5.5` (upgrade set), `gpt-5.6-sol`,
   `gpt-6.1-sol`, `gpt-6-astra` and `gpt-6-luna`, where `sol` resolves to
   `gpt-6.1-sol`, `astra` to `gpt-6-astra`, and `terra` blocks; a
   `cursor-agent --list-models` text with `grok-4.7-xhigh`,
   `grok-4.7-medium`, `cursor-grok-4.6-xhigh`, `cursor-grok-4.6-high-fast`,
   `claude-fable-5-thinking-high` and `gpt-5.6-sol-high`, where `grok` at
   `xhigh` resolves to `grok-4.7-xhigh` (unprefixed 4.7 beats prefixed
   4.6), `grok` at `high` with fast to `cursor-grok-4.6-high-fast`, and
   `gpt` at `xhigh` blocks; a Claude route where the
   alias passes through unchanged. An exact `model` pin present in the
   fixture list is returned unchanged with `family` ignored; a pin absent
   from the list blocks; an `opencode` or unknown entry blocks with the
   "start runs from" message; a project routes file lacking the `cursor`
   table falls back to the default file's table with a note on stdout.
   Cross-file guard: the reviewer families in `routes.default.json`
   (`claude.reviewer` is Codex `sol`, `codex.reviewer` is Claude `opus`)
   must be the families the prose in `configs/claude/CLAUDE.md`,
   `configs/codex/AGENTS.md` and `skills/review-by-harness/SKILL.md`
   names; the test compares family words, never exact ids, so a CLI
   version bump does not go red. Changing one without the others still
   does.
5. Parity: the "## Dev process" paragraph is byte-identical in the three
   managed files.
6. Template hooks: `settings.json.tpl` is valid JSON; `north-star.sh` with
   `CLAUDE_PROJECT_DIR` pointing at an empty dir prints nothing and exits 0;
   with a 10-line `docs/REQUIREMENTS.md` it prints the header and the file;
   with a 300-line one it prints the warning. `ship-check.sh` prints nothing
   without `docs/SHIP_CHECK.md`, and with a file containing quotes, a
   backslash and a newline it prints JSON that `jq -e
   .hookSpecificOutput.additionalContext` accepts and that round-trips to
   the file content.
7. PR template: contains the three `##` headings in order.
8. Policy guard: `policy.md` is under 150 lines and contains no em dash;
   the overseer log cap `120` appears in both `policy.md` and
   `skills/assess-run/SKILL.md`.
9. Precedence fixture: a fixture repo with `docs/DEV_PROCESS.md` and
   `.claude/skills/assess/SKILL.md`; the `comm` check from the verification
   section prints nothing against the deployed skill list, and `detect.sh`
   prints `project`.

Live checks (not stubbed, listed in the implementation PR's test plan):
steps 4 to 6 of the verification section, run in a balance-extract clone,
plus one real overseer run on a small devMachine ticket that produces a log
and one `assess-run` session that reads it.

## Phased implementation outline

1. **Policy and skills.** `skills/dev-process-lite/` (SKILL.md, policy.md, routes.sh,
   detect.sh, routes.default.json) and `skills/assess-run/SKILL.md`. Tests
   1 to 4, 8, 9. No change to any managed instruction file yet, so a
   session that never invokes the skill sees nothing new. Built with this
   process, run by hand from this spec: an overseer log, routed
   implementers, a cross-vendor review and an assessment, plus the
   `low` against `medium` implementer measurement in "Evidence and
   caveats".
2. **Global rule and parity.** The "## Dev process" paragraph in the three
   managed files; one sentence in `review-by-harness` about the PR section;
   the stale identifier table in `skills/review-by-harness/SKILL.md:33-42`
   and the exact ids in the three managed texts rewritten as families with
   the ids current on that day as examples, re-verified against the
   installed CLIs; `docs/agent-parity.md` gains a "Dev process" capability
   row and the tier-parity table. Test 5 and the cross-file part of test 4.
   The balance-extract verification runs here, because this is the first
   phase a balance-extract session can observe.
3. **Templates.** `AGENTS.md.tpl` section, `.dev-process/routes.json`,
   `dot-github/pull_request_template.md.tpl`, `dot-claude/settings.json.tpl`
   with the two hook scripts and the example `docs/SHIP_CHECK.md`,
   `dot-gitignore.tpl`; `README.md:137` and `docs/PHASES.md:44` updated to
   list the new template files. Tests 6 and 7. The blueprint and devMachine
   adopt the PR template in the same PR.
4. **First use and lessons.** One real run on devMachine with the log and
   an assessment; whatever that teaches about the 120-line cap or the
   section names goes back into `policy.md` by PR, and the environment
   lessons go to the homelab-wiki `aicoding` page per the global rule.

Each phase is one PR, reviewed by `review-by-harness` with the default
reviewer route, so the process reviews itself from phase 2 on.
