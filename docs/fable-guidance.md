# Fable 5.1 guidance hook

`configs/claude/hooks/fable-guidance.sh` is a `UserPromptSubmit` hook that
injects a short response-shape block only when the session model is Fable 5
or Mythos 5 (same model, matched as `*fable-5*` and `*mythos-5*`). It is the
Fable twin of `opus-verbosity.sh` (see `opus5-verbosity.md`): same model
detection, same silent exit 0 on every failure, same four wiring points
(`configs/claude/settings.json`, the `blueprint-deploy.sh` manifest,
`MANAGED_HOOKS`, and `tests/bats/fable-guidance-hook.bats`).

Source: Anthropic's prompting guide for this model,
https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1

## What Claude Code already injects for Fable 5.1

Observed in a live Fable 5.1 session's system prompt and tool-result
trailers on 2026-09-02, so the hook does not repeat them:

- Ask for user-facing progress updates ("Before you start, say in a line
  what you're about to do ... Close with a short recap").
- Finish the whole task ("You are operating autonomously ...", "Before
  ending your turn, check your last paragraph ...").
- Batch independent tool calls ("First privately list what you need next
  ...", appended after tool results).
- Delivering work / scope ("The requested scope is the deliverable ...").

## What the hook adds

The sections the harness leaves out, condensed to one line each:

- Writing density: literal phrases, no mannered prose.
- One idea per sentence; numbers and identifiers out of prose unless they
  change what the reader does.
- Prefer targeted edits over whole-file rewrites.
- Keep changes and tests to what the task asks for; report extras as
  follow-ups instead of doing them.

The test `guidance does not repeat what the harness already injects` pins
the boundary: if the harness drops one of its blocks, move that text here.
