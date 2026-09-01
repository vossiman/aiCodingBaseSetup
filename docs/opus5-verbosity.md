# Opus 5 verbosity — remediation

Claude Opus 5 produces excellent code and poor *communication about* that
code: user-facing answers padded with function names, line numbers and
library internals, narration of every step, and no closing summary. This
page records the diagnosis, what has shipped, and the follow-ups that are
deliberately parked.

Status as of 2026-09-01: **Layers 1 and 2 shipped.** Layer 1 (PR #108) was
not enough on its own: with the long preset confirmed live in an Opus 5
session, the user's verdict was still "SO wordy", so Layer 2 was built.
Layer 3 was audited and needs no change in this blueprint.

## Diagnosis

**This section describes the stock default, which Layer 1 now overrides.
It is history, not current state: on this devbox Opus 5 gets the long
preset.** Keep reading it as the reason Layer 1 exists.

Claude Code ships **two system-prompt presets** and selects one per model.
By default Opus 5 got the short preset (~11k chars); Sonnet 5 got the long
one (~29k). Nearly all the response-shaping rules — verbosity limits,
narration cadence, lead-with-the-outcome — exist **only in the long
preset**.

So on Opus 5 the `Concise` output style and the `Be concise` line in
`configs/claude/CLAUDE.md` were not being ignored; they were reinforcing a
scaffold that wasn't there.

The selector, as found in the 2.1.250 binary and still present in 2.1.252
(the env var and the `simple_system_prompt` gate name both still appear in
the shipped binary, so the pin below still bites):

```js
function B(e){ if(!e) return !1;
  if(Pe(a.CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT)) return !0;   // truthy -> short preset
  if(Eo(a.CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT)) return !1;   // "0"    -> long preset
  if(!w(e)) return !0;
  if(x("tengu_velvet_tide",!1)) return !0;
  return L("simple_system_prompt", Ye(e)); }              // else: server-side flag
```

Corroboration beyond the code: a live `claude-opus-5` session had the short
preset verbatim in context — the single line `Write code that reads like
the surrounding code…` where the long preset carries a full verbosity
ruleset.

**Effort level is not the lever.** Per Anthropic's [Opus 5 prompting
guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5),
effort controls how much the model *thinks*, not how much it *says*:
"lowering effort can reduce thinking volume without reliably shortening the
visible response." Do not chase this by dropping `effortLevel`.

## Layer 1 — force the long preset (SHIPPED, PR #108)

`configs/claude/settings.json`:

```json
"env": { "CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT": "0" }
```

Two reasons, not one. The obvious one is that Opus 5 gets the
anti-verbosity rules. The subtler one is the selector's last line: left
unset, the preset choice defers to a **server-side flag**, so the default
can move without a release note. Pinning it removes that.

Trade-off, accepted: the key is global. Models already on the long preset
see no change; any on the short preset by design now pay ~18k extra prompt
chars. Cached, so marginal.

Rollout: merge, `aicoding-sync --yes`, then **a fresh session** — `env` is
read at launch, so a running session keeps whichever preset it started
with. From an agent shell `--yes` is mandatory: without a TTY,
`aicoding-sync` prints "will update" and exits without touching anything.

## Layer 2 — model-conditional hook (SHIPPED)

Layer 1 proved insufficient after real use, so this shipped as designed
below, with one addition: the hook prefers a `model` field on the hook
payload when one is present and only falls back to the transcript grep.
The match is `*opus-5*`, so context-window variants like
`claude-opus-5[1m]` are covered. Registered in three places, all covered
by `tests/bats/opus-verbosity-hook.bats`: `configs/claude/settings.json`
(second `UserPromptSubmit` hook, after `memory-hint.sh`), the
`blueprint-deploy.sh` manifest, and `MANAGED_HOOKS`.

A `UserPromptSubmit` hook, `configs/claude/hooks/opus-verbosity.sh`, that:

1. reads `transcript_path` from the hook's stdin JSON;
2. greps the last `"model":"…"` value out of that transcript (confirmed
   present — a sampled session transcript carried 351 occurrences of
   `"model":"claude-opus-5"`);
3. emits `additionalContext` **only** when it matches `claude-opus-5`,
   and exits silently otherwise.

Note the hook payload itself was not confirmed to carry a `model` field;
the transcript read is the route that is known to work. If a future
version adds `model` to the payload, prefer it — it is cheaper.

**Why a hook and not `CLAUDE.md`.** codex, cursor-agent and opencode all
read `CLAUDE.md`/`AGENTS.md` unconditionally. Opus-specific tuning placed
there would degrade three other agents that do not have the problem. The
hook is the only lever in the blueprint that can be made model-conditional.

Injected text — use Anthropic's own phrasings, since the model was tuned
against them, and state them as positives ("do this"), because the guide
notes positive examples of the wanted style outperform prohibitions:

> Before your first tool call, say in one sentence what you're about to do.
> While working, give a brief update only when you find something important
> or change direction. When you finish, lead with the outcome: your first
> sentence should answer "what happened" or "what did you find," with
> supporting detail after it for readers who want it.

Plus a line for the estate-specific complaint: cite function names, line
numbers and library internals only where they change a decision, and close
every multi-step task with a short summary.

## Layer 3 — prune counter-productive instructions (AUDITED, no change)

Audited 2026-09-01: `configs/claude/CLAUDE.md` carries none of the
instruction classes below. It has no "verify your work" or "use a subagent
to verify" step, no self-check line, and no correction-narration rule. The
one line that mentions verification ("say plainly when something is
unverified") is a truthfulness rule about claims, not an instruction to
re-check work, so it stays. Nothing to prune here.

What remains is outside this blueprint: the superpowers
`verification-before-completion` skill, and the `using-superpowers`
preamble's "1% chance a skill applies, you MUST invoke it". Both are
third-party. If Layer 2 leaves narration heavy, that pressure is the next
suspect, and the lever is which superpowers skills get installed rather
than an edit to their text.

The Opus 5 guide explicitly says several instruction *classes* backfire on
this model, compounding with built-in behaviour to burn tokens with no
quality gain. Audit `configs/claude/CLAUDE.md` and the superpowers skills
for:

- **Explicit verification steps** — "include a final verification step",
  "use a subagent to verify". The guide: Opus 5 verifies its own work
  unprompted; these cause over-verification, and "removing them reduces
  wasted tokens with no loss in quality." The `verification-before-
  completion` skill is the obvious candidate.
- **Self-check instructions** — "double-check your answer", "re-verify
  before responding". Same mechanism.
- **Correction narration.** Opus 5 narrates corrections to its own earlier
  statements more than prior models. The guide's replacement text: only
  correct an earlier statement when the error would change the user's code,
  conclusions or decisions.
- **Written deliverable length.** Separate axis from conversational
  verbosity — files Opus 5 writes to disk run long. If docs generated by
  agents in this estate are bloating, add the guide's length-calibration
  line rather than another conciseness rule.

Also available if subagent spend becomes the complaint rather than
verbosity: `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` are deterministic caps (2.1.217+).

## How to judge whether Layer 2 was enough

Subjective, and that is fine — the symptom is subjective. After
`aicoding-sync --yes`, in a **fresh** Opus 5 session (hook config is read at
launch), on an ordinary task: does the answer lead with the outcome, and
does a multi-step task end with a short summary?

Unlike Layer 1, this one is directly observable: the injected block shows
up in the session as a `UserPromptSubmit hook success:` line. If it is
absent in an Opus 5 session, the hook is not matching, and the first thing
to check is what model string the payload or transcript actually carries.

If the block is present and the answers are still padded, the remaining
suspect is the superpowers instruction load described under Layer 3, not
another conciseness rule stacked on top.
