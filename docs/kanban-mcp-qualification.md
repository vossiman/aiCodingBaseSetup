# Kanban MCP native-client qualification

`tools/qualify-kanban-clients` is currently a preflight reporter. It starts a
loopback-only fake board, invokes each selected installed client's real
`--version` command with closed stdin and a timeout, and writes an allowlisted
JSON report under `out/kanban-mcp-qualification/`. The report records every
required native lifecycle scenario as unobserved. It accepts no transcript or
external fixture as qualification proof and does not launch a model, mutate
client configuration, read authentication, enable enforcement, or contact the
production board.

Run all preflights or one focused preflight with:

```bash
tools/qualify-kanban-clients --all --output out/kanban-mcp-qualification
tools/qualify-kanban-clients --client codex --output out/kanban-mcp-qualification
```

The command exits nonzero while any selected client is unsupported. Exact
versions enter `configs/kanban/qualified-clients.json` only after a real native
run proves every required scenario against the fake board. That matrix is
currently empty, so read tools remain available and lifecycle mutations stay
in compatibility mode.

The rollout scope is Codex-first. Claude Code, Cursor, and OpenCode are not a
prerequisite for a later Codex-only rollout, and all remain unsupported until
separately qualified. Codex 0.154.0 is also unsupported today: its nonexecuting
`app-server` hook inventory does not load the same configuration as
`codex exec --ignore-user-config`, so it cannot prove which hooks would execute
in the model launch. A version observation or an inventory from that different
configuration is not native lifecycle evidence.

The other current preflight blockers are explicit. Claude restricted mode
still needs reviewed managed-layer provenance. Cursor has no exclusive hook,
plugin, and MCP configuration mode that retains installed authentication.
OpenCode merges configuration, and its pure mode removes the lifecycle plugin,
so it cannot isolate the candidate plugin and MCP while retaining installed
authentication.

Qualification reports contain only timestamp, blueprint commit, pinned Kanban
revision, client and exact version, scenario booleans, status, and redacted
reasons. Raw output, prompts, transcripts, native identifiers, credentials,
configuration paths, authentication paths, and checkout paths are excluded.
Generated reports are local deliverables for `dvw pull`; they are not committed.

The fake board binds only `127.0.0.1` on a random port, requires the fixed
qualification token, rejects an unexpected Host header or credential, and has
an accelerated test clock for lease expiry. Its route log keeps only method,
route name, bounded operation ID, and hashes of actor/session labels.
