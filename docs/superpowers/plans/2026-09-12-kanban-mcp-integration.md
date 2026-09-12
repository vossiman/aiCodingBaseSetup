# Kanban MCP Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the reviewed Kanban MCP at a pinned revision and give Claude Code, Codex, Cursor, and OpenCode credential-safe, native-session-bound claim lifecycle management.

**Architecture:** `kanban-mcp` remains owned by the Kanban repository and reaches the board only by spawning the setup-owned `kanban-post --json OP` transport without a shell. A new setup-owned `kanban-work` bridge stores native session bindings, one-use pre-call permits, claim state, and a bounded lifecycle queue in a user-only SQLite registry; the MCP calls its public JSON operations while native hooks and the OpenCode plugin feed it trusted client event payloads. Each client stays read-only for claims until its real installed binary proves identity, instruction, activity, stop, end, generation boundaries, shared-process, long-tool, failure reconciliation, and parent/child behavior against a loopback fake board.

**Tech Stack:** Python 3 standard library (`argparse`, `hashlib`, `json`, `sqlite3`, `subprocess`, `urllib`), Bash lifecycle wrappers, OpenCode JavaScript plugin, managed Claude/Codex/Cursor/OpenCode configuration, Bats, `unittest`, `uv`, and the Kanban package's locked official Python MCP SDK.

**Spec:** Kanban repository `docs/superpowers/specs/2026-09-12-agent-work-claims-design.md` (current approved worktree copy: `/home/codespace/checkouts/kanban/.claude/worktrees/feat-agent-work-claims/docs/superpowers/specs/2026-09-12-agent-work-claims-design.md`)

## Global Constraints

- Implement only the `aiCodingBaseSetup` half of the approved design; the Kanban schema, HTTP API, MCP package, workflow text, and board UI remain in the Kanban repository.
- Start from setup base `36cb2aa` and recheck setup PR #172 before editing `lib/blueprint-deploy.sh`, managed config files, or their tests.
- Do not merge or deploy until the Kanban PR has passed its review gates and its full 40-character commit is pinned here.
- `kanban-post` is the only process that reads `KANBAN_TOKEN`; no secret may enter MCP config, argv, stdin, registry, queue, results, logs, exceptions, fixtures, or qualification reports.
- Preserve the pinned production origin, refuse redirects, allow a loopback override only with `KANBAN_TEST_TOKEN`, and never add arbitrary URL, HTTP method, API path, or filesystem proxy operations.
- `kanban-post --json OP` reads exactly one JSON object from stdin and emits exactly one JSON object: `{"ok":true,"data":{"key":"KANBAN-2"}}` on a representative success or `{"ok":false,"error":{"code":409,"message":"ticket has a live claim"}}` on a representative failure. Errors exit nonzero and never print a traceback.
- Freeze remote operation names as `register_session`, `get_session`, `rebind_session`, `end_session`, `claim_ticket`, `activity`, `checkpoint_work`, `release_ticket`, `complete_ticket`, `override_claim`, `list_tickets`, `get_ticket`, `create_ticket`, `update_ticket`, `add_comment`, `link_tickets`, `unlink_tickets`, and `list_repos`.
- Every work API mutation uses a bounded opaque `operation_id`; the bridge generates UUIDs in production, while the transport also accepts deterministic bounded strings used by backend fixtures. Remote lifecycle payloads carry backend `work_session_id`, never a local handle. Backend session/claim references are bounded opaque strings (maximum 300), matching backend schemas and deterministic fixtures; percent-encode them as a single path segment. Local registry handles remain UUIDs and are never accepted by the transport. `register_session` carries `harness`, `native_session_id`, optional `subagent_id`, `run_generation`, `label`, `repo`, and `lifecycle_capable`.
- `activity` carries `work_session_id`, `claim_id`, `observed_at`, `sequence`, and `operation_id`; `release_ticket` carries `handoff`, `reason` (`paused|feedback|stopped`), optional `feedback_target`, and optional `swimlane`; `complete_ticket` carries nonempty `evidence` and `references`, defaulting to `[]`; `checkpoint_work` carries one nonempty `checkpoint` string.
- Public local bridge operations are `bind`, `lookup`, `execute`, and `instructions`. Native ingress and delivery are separate `kanban-work hook`, `drain`, and `supervise` modes and are not MCP-callable operations.
- `kanban-work --json execute` accepts `{handle,operation,payload}`, allowlists `create_ticket`, `update_ticket`, `add_comment`, `link_tickets`, `unlink_tickets`, `claim_ticket`, `checkpoint_work`, `release_ticket`, `complete_ticket`, and `end_session`, consumes a matching native pre-call permit, injects stored backend identity, and invokes `kanban-post` without a shell.
- A hook mints every handle. The MCP never accepts native session identity fields and cannot invent or adopt a handle. `bind` also requires a pre-call permit from the same native execution. `bind_work_session(handle,label?,checkout?,operation_id?)` initially uses the hook-validated checkout; a later explicit checkout validates that GitHub origin locally and calls `rebind_session`, which the backend rejects while a claim is live. A successful rebind updates repo/checkout without changing native identity or run generation.
- A pre-call permit expires 60 seconds after the native event that minted it and is consumed exactly once. Qualification clocks may be injected in tests, but production always uses this fixed TTL.
- Claim lease facts are fixed by the Kanban API: 15-minute lease, no more than one renewal per 60 seconds, observations at most 60 seconds old and at most five seconds in the future, monotonic sequence per run, and two-hour maximum supervision per still-running tool operation.
- A normal turn stop releases unfinished work to Todo. Compaction, auto-continuation, a subagent stop, or a parent yielding while a verified tool/subagent remains active must not stop the parent. Session end must reconcile remaining work; end dominates later queued activity.
- The registry is identifiers and operational state, not an adversarial security boundary against another process running as the same local user. Documentation must not claim stronger isolation.
- All four installed clients must qualify before enforcement. A missing native field or unreliable event leaves board reads available but causes `bind`/claim mutations to return a clear unsupported-adapter error and blocks rollout.
- Adapters implement only fields and events emitted by the pinned native client. Fixtures may exercise documented candidate shapes but cannot fabricate missing identity or lifecycle metadata into qualification evidence. Codex failed-call reconciliation, Cursor child-stop correlation/local lifecycle coverage, and OpenCode failed-call, resumed-session, and background-child behavior remain explicit real-client gates.
- Use the current official client surfaces as the implementation baseline: Claude Code hooks, Codex managed hooks, Cursor hooks, and an OpenCode local plugin. Recheck the installed versions and official docs during implementation because these APIs are versioned. The Kanban package uses official `mcp>=2.2.0,<3`, locked to 2.2.0, and `from mcp.server import MCPServer`; do not plan against the retired FastMCP interface.
- Planning-time installed versions were Claude Code 2.1.268, Codex 0.154.0, Cursor Agent `2026.09.10-fd3934a`, and OpenCode 1.18.30. Record only exact versions that pass in `configs/kanban/qualified-clients.json`; any unlisted version is read-only until separately qualified. Do not infer lifecycle support from semantic ordering or Cursor's dated build string.
- Qualification obtains each real client's exact version first, writes a temporary candidate matrix, and supplies that path through `AICODING_KANBAN_QUALIFIED_CLIENTS` only while `KANBAN_URL` is loopback and `KANBAN_TEST_TOKEN` is set. There is no qualification bypass flag; only an exact candidate version can become lifecycle-capable during a qualification run.
- The pinned controller must print exactly `kanban-mcp <installed metadata version>\n` for `kanban-mcp --version`; the immutable updater rejects any other shape.
- Gate every network call and detached process in install/sync tests behind `AICODINGSETUP_SKIP_NETWORK=1`; add every new agent CLI or external executable to all real-install test stubs in the same commit.
- Run the repository suite only with `bash tests/bats/run.sh`. Do not use bare `bats`, and do not write tests into the real blueprint checkout.
- Python unit tests must be reached by the standard Bats suite: Task 1 adds its module runner in kanban-post.bats; Task 2 creates kanban-work.bats running unittest discovery for `test_kanban_work*.py`, which also covers later queue/adapter modules. Use PYTHONDONTWRITEBYTECODE=1 and isolated fixtures; do not leave generated caches in the checkout.

## Frozen interfaces

### Credential-safe remote transport

`kanban-post --json OP` validates these exact input shapes before making a request:

| Operation | JSON stdin | HTTP mapping |
| --- | --- | --- |
| `list_repos` | `{}` | `GET /api/repos` |
| `list_tickets` | `{repo?,status?,swimlane?,done?}` | `GET /api/tickets` with an allowlisted query string |
| `get_ticket` | `{ticket}` | `GET /api/tickets/{ticket}` |
| `create_ticket` | `{checkout,title,body?,status?,priority?,swimlane?,due_date?}` | validate `checkout`'s GitHub origin, then `POST /api/tickets` |
| `update_ticket` | `{ticket,fields}` | `PATCH /api/tickets/{ticket}`; `fields` allowlists `title,body,status,priority,swimlane,due_date,position` |
| `add_comment` | `{ticket,body}` | `POST /api/tickets/{ticket}/comments` |
| `link_tickets` | `{ticket,target,kind}` | `POST /api/tickets/{ticket}/links`; `kind=depends_on|blocks|relates` |
| `unlink_tickets` | `{ticket,target,kind?}` | resolve the unique matching link, then `DELETE /api/tickets/{ticket}/links/{id}` |
| `register_session` | `{harness,native_session_id,subagent_id?,run_generation,label,repo,lifecycle_capable,operation_id}` | `POST /api/work/sessions` |
| `get_session` | `{work_session_id}` | `GET /api/work/sessions/{work_session_id}` |
| `rebind_session` | `{work_session_id,repo,label?,operation_id}` | `POST /api/work/sessions/{work_session_id}/rebind`; backend rejects a live claim or archived/unknown repo |
| `end_session` | `{work_session_id,handoff?,operation_id}` | `POST /api/work/sessions/{work_session_id}/end` |
| `claim_ticket` | `{work_session_id,ticket,operation_id}` | `POST /api/work/tickets/{ticket}/claim` |
| `activity` | `{work_session_id,claim_id,observed_at,sequence,operation_id}` | `POST /api/work/claims/{claim_id}/activity` |
| `checkpoint_work` | `{work_session_id,claim_id,checkpoint,operation_id}` | `POST /api/work/claims/{claim_id}/checkpoint` |
| `release_ticket` | `{work_session_id,claim_id,handoff,reason,feedback_target?,swimlane?,operation_id}` | `POST /api/work/claims/{claim_id}/release` |
| `complete_ticket` | `{work_session_id,claim_id,evidence,references,operation_id}` | `POST /api/work/claims/{claim_id}/complete` |
| `override_claim` | `{claim_id,reason,status?,swimlane?,position?,operation_id}` | `POST /api/work/claims/{claim_id}/override`; the URL claim is the expected fencing ID; transport support only, never exposed by the agent MCP |

Unknown keys are rejected with code 422. Ticket references are percent-encoded as one path segment. No operation accepts a URL, path fragment, HTTP method, header, credential, or raw request body.

`register_session`, `get_session`, and `rebind_session` return a session object with `id` and `claims`. Claim admission, activity, checkpoint, release, and completion return `{claim,ticket}`; `claim` includes `id`, `work_session_id`, `ticket_id`, lifecycle timestamps, and display fields, while the ticket snapshot includes `id,key,title,status,swimlane,position,done_at,doing_source,doing_actor`. `end_session` returns `{session,released}`. A replay returns its original receipt, so the bridge refreshes current session/ticket state before changing its registry cache.

### Local registry bridge

All public operations use the same JSON envelope as `kanban-post`:

```text
kanban-work --json bind
stdin:  {"handle":"UUID","label":"optional readable label","checkout":"optional absolute checkout","operation_id":"optional bounded string"}
data:   {"handle":"UUID","work_session_id":"UUID","harness":"claude","run_generation":"UUID","label":"worker","repo":"kanban","lifecycle_capable":true,"operation_id":"bounded string"}

kanban-work --json lookup
stdin:  {"handle":"UUID"}
data:   {"handle":"UUID","state":"minted|bound|ended","harness":"claude|codex|cursor|opencode","run_generation":"UUID","label":"readable text","repo":"kanban","lifecycle_capable":BOOL,"work_session_id":"UUID or null","active_claim":{"id":"UUID","ticket":"KANBAN-2"} or null}

kanban-work --json execute
stdin:  {"handle":"UUID","operation":"claim_ticket","payload":{"ticket":"KANBAN-2","operation_id":"optional bounded string"}}
data:   the successful `kanban-post` data, with generated `operation_id` included

kanban-work --json instructions
stdin:  {"handle":"optional UUID"}
data:   {"text":"canonical Kanban-owned workflow","lifecycle_capable":BOOL,"handle":"UUID or null"}
```

`instructions` runs installed `kanban-mcp --instructions` locally and never reads a credential. `bind` consumes a `bind_work_session` permit. For a minted handle it builds `register_session` from the registry plus the optional label and stores the returned backend ID. For an already bound handle with an explicit different checkout, it validates that checkout's GitHub origin, calls `rebind_session`, and updates the local checkout/repo/label only after success; an omitted checkout retains the current binding. A supplied changed label with no checkout change also calls `rebind_session` against the current repo and obeys the no-live-claim guard; never silently ignore it. Omitted label retains the current label. Its optional `operation_id` is preserved for an explicit retry or generated from the permitted native call just like other work operations. `execute` never trusts a payload `work_session_id`; it injects the registry value after consuming the permit. A supplied `operation_id` is preserved for explicit retry; otherwise the bridge derives a stable UUID from the permitted native call ID. Work API operations send it to the backend. Ordinary create/update/comment/link/unlink operations retain it only in the local permit/result record and strip it before `kanban-post`; after an ambiguous transport failure they report the ambiguity and require a state read instead of automatically replaying a possibly completed mutation.

The registry lives at `${XDG_STATE_HOME:-$HOME/.local/state}/aicoding/kanban-work.sqlite3`, with directory mode 0700 and database mode 0600. It retains ended generations for seven days, consumed permits for one hour, and at most 1024 queue rows. Permits have a fixed 60-second validity window. The latest release intent lives durably on the claim row and the latest end intent lives durably on the execution row; queue rows are reconstructible delivery indexes. When the queue is full, insertion deletes oldest activity rows first. If all 1024 rows are critical, the durable intent is still updated and the missing delivery row is reconstructed on the next drain. End intent suppresses and deletes activity for that generation while preserving an earlier release intent.

After every successful or replayed lifecycle receipt, including register, rebind, claim, activity, checkpoint, release, complete, and end, the bridge fetches authoritative current state with `get_session` and, when the receipt can affect a ticket, `get_ticket`. It changes its cached execution/claim state only after those refreshes succeed. A refresh failure leaves the cache stale and explicitly untrusted, fails closed for dependent mutations, and retries the refresh before further lifecycle work; an old replay receipt can never resurrect a released or replaced claim locally.

### Canonical MCP argument normalization

The native pre-call hook and the bridge import the same normalizer. It rejects unknown keys, fills the defaults below, serializes sorted compact UTF-8 JSON, and hashes those bytes with SHA-256. The digest excludes bridge-injected `work_session_id` and bridge-generated `operation_id`; a user-supplied `operation_id` remains in the normalized input.

```python
SAMPLE_HANDLE = "11111111-1111-4111-8111-111111111111"
SAMPLE_CLAIM = "22222222-2222-4222-8222-222222222222"
NORMALIZED_TOOL_ARGS = {
    "bind_work_session": {"handle": SAMPLE_HANDLE, "label": None, "checkout": None,
                          "operation_id": None},
    "create_ticket": {"handle": SAMPLE_HANDLE, "checkout": None, "title": "Follow-up", "body": None,
                      "status": None, "priority": None, "swimlane": None, "due_date": None,
                      "operation_id": None},
    "update_ticket": {"handle": SAMPLE_HANDLE, "ticket": "KANBAN-2", "fields": {}, "operation_id": None},
    "add_comment": {"handle": SAMPLE_HANDLE, "ticket": "KANBAN-2", "body": "Parser verified.", "operation_id": None},
    "link_tickets": {"handle": SAMPLE_HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3", "kind": "relates",
                     "operation_id": None},
    "unlink_tickets": {"handle": SAMPLE_HANDLE, "ticket": "KANBAN-2", "target": "KANBAN-3", "kind": None,
                       "operation_id": None},
    "claim_ticket": {"handle": SAMPLE_HANDLE, "ticket": "KANBAN-2", "operation_id": None},
    "checkpoint_work": {"handle": SAMPLE_HANDLE, "claim_id": SAMPLE_CLAIM,
                        "checkpoint": "Parser implemented; queue tests remain.",
                        "operation_id": None},
    "release_ticket": {"handle": SAMPLE_HANDLE, "claim_id": SAMPLE_CLAIM,
                       "handoff": "Queue tests remain.",
                       "reason": "paused", "feedback_target": None, "swimlane": None,
                       "operation_id": None},
    "complete_ticket": {"handle": SAMPLE_HANDLE, "claim_id": SAMPLE_CLAIM,
                        "evidence": "python3 -m unittest: 24 passed",
                        "references": [], "operation_id": None},
    "end_work_session": {"handle": SAMPLE_HANDLE, "handoff": None, "operation_id": None},
}
```

Read tools (`list_repos`, `list_tickets`, `get_ticket`, `my_work`) do not need a permit. `my_work` resolves the handle locally and calls `get_session`; it does not accept a backend session ID from the model.

### Native API references to recheck at implementation time

- Claude Code hook lifecycle and common `session_id`/`cwd` fields: <https://code.claude.com/docs/en/hooks-guide>
- Codex managed lifecycle hooks in `requirements.toml`: <https://github.com/openai/codex/blob/main/docs/config.md#lifecycle-hooks>
- Cursor common hook schema, fail-closed MCP interception, session/subagent events, and generation IDs: <https://docs.cursor.com/en/hooks>
- OpenCode plugin events: <https://opencode.ai/docs/plugins/>
- Official Python MCP SDK tag used by the Kanban lock: <https://github.com/modelcontextprotocol/python-sdk/tree/v2.2.0>

Docs and config presence are inputs to qualification, not evidence that an installed binary emitted the required payload. Capture actual payload fixtures from each installed client with fake board credentials, reduce them to the fields needed by the adapter, and keep enforcement blocked if the observed event contract is insufficient.

---

### Task 1: Structured `kanban-post` transport

**Files:**
- Modify: `bin/kanban-post`
- Modify: `tests/bats/kanban-post.bats`
- Create: `tests/python/test_kanban_post_json.py`

**Interfaces:**
- Consumes: The frozen remote operation table above and the Kanban API response contract from the approved spec.
- Produces: `kanban-post --json OP`, `dispatch_json(operation: str, payload: dict) -> tuple[int, object]`, and the exact success/error envelopes used by the MCP and `kanban-work`.

- [ ] **Step 1: Write failing JSON transport tests**

Create a loopback `ThreadingHTTPServer` test that records method, path, body, and Authorization, then exercises every allowlisted operation. Include these concrete assertions:

```python
def test_claim_maps_only_the_allowlisted_payload(self):
    result = self.run_json("claim_ticket", {
        "work_session_id": SESSION_ID,
        "ticket": "KANBAN-2",
        "operation_id": OP_ID,
    })
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(json.loads(result.stdout)["ok"], True)
    self.assertEqual(self.server.calls[-1], (
        "POST", "/api/work/tickets/KANBAN-2/claim",
        {"work_session_id": SESSION_ID, "operation_id": OP_ID},
        "Bearer " + TOKEN,
    ))

def test_unknown_operation_never_reaches_network(self):
    result = self.run_json("request", {"url": "https://example.invalid"})
    self.assertNotEqual(result.returncode, 0)
    self.assertEqual(json.loads(result.stdout), {
        "ok": False,
        "error": {"code": 422, "message": "unknown operation 'request'"},
    })
    self.assertEqual(self.server.calls, [])

def test_error_body_and_traceback_are_redacted(self):
    self.server.response = (409, {"detail": f"owner echoed {TOKEN}"})
    result = self.run_json("claim_ticket", CLAIM_INPUT)
    self.assertNotIn(TOKEN, result.stdout + result.stderr)
    self.assertNotIn("Traceback", result.stdout + result.stderr)
    self.assertEqual(json.loads(result.stdout), {
        "ok": False,
        "error": {"code": 409, "message": "owner echoed <redacted>"},
    })
```

Also test malformed/non-object/extra-key stdin, rejection of a local `handle` as an unknown remote key, invalid empty/blank/overlong session/claim references, overlong operation IDs, invalid enums/dates, query encoding, ticket-segment encoding, `fields` allowlisting, `references=[]`, repo derivation from the explicit `checkout`, repo mismatch before network, unique unlink resolution, a 204 response, redirect refusal, hostile error echo, and loopback fake-token isolation.

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `python3 -m unittest -v tests.python.test_kanban_post_json`

Expected: FAIL because `--json` is not recognized and stdout is not a JSON envelope.

- [ ] **Step 3: Split parsing, validation, dispatch, and envelope emission inside the existing helper**

Keep the existing credential functions and legacy parser. Add exact operation descriptors rather than accepting caller-supplied paths:

```python
JSON_OPERATIONS = {
    "list_repos", "list_tickets", "get_ticket", "create_ticket", "update_ticket",
    "add_comment", "link_tickets", "unlink_tickets", "register_session", "get_session",
    "rebind_session", "end_session", "claim_ticket", "activity", "checkpoint_work",
    "release_ticket", "complete_ticket", "override_claim",
}

def dispatch_json(operation: str, payload: dict) -> tuple[int, object]:
    if operation not in JSON_OPERATIONS:
        raise InputError(422, f"unknown operation {operation!r}")
    # Each branch constructs its fixed method/path/body from validated fields.

def emit_json(ok: bool, *, data=None, code=None, message=None) -> None:
    value = {"ok": True, "data": data} if ok else {
        "ok": False, "error": {"code": code, "message": message}
    }
    print(scrub(json.dumps(value, separators=(",", ":"))))
```

Use `urllib.parse.quote(ticket, safe="")` for path segments and `urllib.parse.urlencode` for the four list filters. Read stdin once with a 256 KiB limit. Catch `InputError`, `HTTPError`, `URLError`, JSON errors, and unexpected exceptions at the entry point; unexpected failures report only their exception type.

- [ ] **Step 4: Preserve legacy CLI behavior and delegate the evidence-bearing compatibility form**

Keep all existing positional/flag behavior while adding `--evidence`, repeatable `--reference`, and hidden adapter-only `--work-handle`. `--done TICKET --evidence TEXT` resolves the hinted handle's current claim with `kanban-work --json lookup`, verifies its ticket key matches `TICKET`, and delegates `complete_ticket` to `kanban-work --json execute`. The native pre-shell adapter in Task 2 must already have minted the matching permit; neither `--work-handle` nor `KANBAN_WORK_HANDLE` proves identity. `--done` without evidence retains its compatibility-phase PATCH behavior until the backend enables enforcement, whose error is passed through unchanged and points the caller to claim/complete. Never read a registry by cwd or choose the latest handle.

```python
if args.done and args.evidence:
    handle = args.work_handle or os.environ.get("KANBAN_WORK_HANDLE")
    if not handle:
        die("--done --evidence requires a bound native work session; use the Kanban MCP")
    current = run_kanban_work("lookup", {"handle": handle})
    claim = current["data"].get("active_claim")
    if not claim or claim["ticket"].upper() != args.done.upper():
        die("--done target is not the bound session's current claim; use the Kanban MCP")
    return run_kanban_work("execute", {
        "handle": handle,
        "operation": "complete_ticket",
        "payload": {"claim_id": claim["id"],
                    "evidence": args.evidence,
                    "references": args.reference or []},
    })
```

The public command remains exactly `kanban-post --done KEY --evidence TEXT [--reference TEXT ...]`. `--work-handle` is accepted only with that form and is injected by a validated native hook; a direct or peer-supplied value reaches the bridge but cannot consume the actual caller's permit. Task 1 tests use a fake bridge that returns allowed/denied envelopes and prove this delegation adds no standalone completion bypass.

Update `--selftest` to cover one read and one lifecycle JSON operation as well as existing legacy writes.

- [ ] **Step 5: Run focused and existing helper tests**

Run: `python3 -m unittest -v tests.python.test_kanban_post_json && bash tests/bats/run.sh tests/bats/kanban-post.bats`

Expected: PASS; no output contains the fake credential.

- [ ] **Step 6: Commit the transport**

```bash
git add bin/kanban-post tests/bats/kanban-post.bats tests/python/test_kanban_post_json.py
git commit -m "feat(kanban): add structured credential-safe transport"
```

### Task 2: Native registry, permit normalizer, and bridge

**Files:**
- Create: `bin/kanban-work`
- Create: `lib/kanban_work/__init__.py`
- Create: `lib/kanban_work/schema.py`
- Create: `lib/kanban_work/store.py`
- Create: `lib/kanban_work/bridge.py`
- Create: `lib/kanban_work/legacy.py`
- Create: `tests/python/test_kanban_work.py`
- Create: `tests/python/test_kanban_work_legacy.py`
- Create: `tests/bats/kanban-work.bats`
- Modify: `install.sh`
- Modify: `install-host.sh`
- Modify: `lib/provision-integrations.sh`
- Modify: `lib/sync.sh`
- Modify: `tests/bats/install.bats`
- Modify: `tests/bats/install-host.bats`
- Modify: `tests/bats/sync.bats`

**Interfaces:**
- Consumes: `kanban-post --json OP`; frozen normalized tool arguments; hook-minted native identity and pre-call permits.
- Produces: public `kanban-work --json bind|lookup|execute|instructions`, reusable `normalize_tool_args(tool: str, args: dict) -> bytes`, `parse_legacy_complete(command: str) -> LegacyComplete | None`, `prepare_legacy_complete(identity: NativeIdentity, native_call_id: str, command: str) -> PreparedLegacyComplete`, `BridgeError(code: int, message: str)`, `Store` registry methods, and an installed `~/.local/bin/kanban-work` symlink.

- [ ] **Step 1: Write failing schema and state tests**

Use a temporary `XDG_STATE_HOME`, a fake `kanban-post`, a fake `kanban-mcp`, and a temporary qualified-client matrix. Cover exact default normalization, unknown-key rejection, exact qualified-version matching, absent/unlisted version read-only behavior, loopback-only matrix override, two sessions in one checkout, a shared bridge process, peer-handle refusal, missing permit, mismatched digest, permit replay, permit acceptance at 59 seconds and rejection at 60 seconds, backend-ID injection, operation-ID preservation/generation, cross-repo `create_ticket`, explicit rebind success, rebind refusal with a live claim, failed rebind leaving the local checkout unchanged, seven-day retention, 0600/0700 modes, and no sensitive fields.

For every lifecycle receipt, include fresh and replayed responses. Assert that the bridge calls `get_session` and, for claim/checkpoint/release/complete, `get_ticket` before changing its cache. Simulate a replayed old claim receipt after release and replacement and prove it cannot resurrect the old claim. Make each refresh fail once and assert the prior cache remains stale/untrusted, dependent bind/lifecycle operations fail closed, and a later refresh is retried before work continues.

In `test_kanban_work_legacy.py`, cover the one accepted grammar and every rejection boundary: exact binary and flag order, multiple references, quoted spaces, literal dollar text inside single quotes, empty evidence, missing identity/current claim, ticket mismatch, peer handle, environment assignment, absolute/relative executable, unknown/reordered/duplicate flags, newline, semicolon, pipe, redirection, command substitution, backticks, variable expansion, glob, and trailing command. Invalid commands that begin like legacy completion must return an actionable `Use the Kanban MCP complete_ticket tool` denial; unrelated shell commands return `None` and remain outside this translator.

```python
def test_exact_legacy_completion_mints_the_complete_ticket_permit(self):
    prepared = prepare_legacy_complete(
        NativeIdentity("codex", "thread-7", None, RUN), "tool-9",
        "kanban-post --done KANBAN-2 --evidence 'pytest: 127 passed' --reference PR-17",
    )
    self.assertEqual(prepared.handle, HANDLE)
    self.assertEqual(prepared.args, {
        "handle": HANDLE, "claim_id": CLAIM_ID,
        "evidence": "pytest: 127 passed", "references": ["PR-17"],
        "operation_id": None,
    })
    self.assertEqual(prepared.rewritten_argv[-2:], ["--work-handle", HANDLE])
    self.assertTrue(self.store.has_permit(HANDLE, "complete_ticket", prepared.args))

def test_compound_legacy_completion_is_denied_without_permit(self):
    with self.assertRaisesRegex(BridgeError, "Use the Kanban MCP complete_ticket tool"):
        prepare_legacy_complete(IDENTITY, "tool-10",
            "kanban-post --done KANBAN-2 --evidence ok; echo stolen")
    self.assertFalse(self.store.has_any_permit())
```

```python
def test_omitted_defaults_hash_the_same_in_hook_and_execute(self):
    raw = {"handle": HANDLE, "ticket": "KANBAN-2"}
    expected = (b'{"handle":"' + HANDLE.encode() +
                b'","operation_id":null,"ticket":"KANBAN-2"}')
    self.assertEqual(normalize_tool_args("claim_ticket", raw), expected)

def test_peer_cannot_mint_a_bind_permit_for_hook_minted_handle(self):
    self.store.start_execution("claude", "native-a", None, RUN_A, HANDLE, CHECKOUT, True)
    peer = NativeIdentity("claude", "native-b", None, RUN_B)
    with self.assertRaisesRegex(BridgeError, "belongs to another native session"):
        self.store.permit_call(peer, "call-2", "bind_work_session",
                               bind_digest(HANDLE), self.clock.now())
    self.assertEqual(self.transport.calls, [])

def test_execute_consumes_permit_before_network(self):
    self.permit("claim_ticket", {"handle": HANDLE, "ticket": "KANBAN-2"})
    first = self.execute("claim_ticket", {"ticket": "KANBAN-2"})
    second = self.execute("claim_ticket", {"ticket": "KANBAN-2"})
    self.assertTrue(first["ok"])
    self.assertEqual(second["error"]["code"], 403)
    self.assertEqual(len(self.transport.calls), 1)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy`

Expected: FAIL because `lib.kanban_work` and `bin/kanban-work` do not exist.

- [ ] **Step 3: Implement the canonical schema module**

Define immutable specs for the ten mutating MCP tools. `normalize_tool_args` fills every listed default, validates identity UUIDs, bounded operation IDs, and enums, rejects unknown keys, and returns sorted compact JSON bytes. Add mappings:

```python
TOOL_TO_BRIDGE_OPERATION = {
    "create_ticket": "create_ticket",
    "update_ticket": "update_ticket",
    "add_comment": "add_comment",
    "link_tickets": "link_tickets",
    "unlink_tickets": "unlink_tickets",
    "claim_ticket": "claim_ticket",
    "checkpoint_work": "checkpoint_work",
    "release_ticket": "release_ticket",
    "complete_ticket": "complete_ticket",
    "end_work_session": "end_session",
}
READ_TOOLS = {"list_repos", "list_tickets", "get_ticket", "my_work"}
```

The bind digest uses tool name `bind_work_session`. Never create an alternative adapter-specific normalizer. Add `qualified_client_version(harness: str, version: str) -> bool`: it reads the blueprint's `configs/kanban/qualified-clients.json`, defaults false when absent/malformed/unlisted, and permits `AICODING_KANBAN_QUALIFIED_CLIENTS` only when `KANBAN_URL` names loopback and `KANBAN_TEST_TOKEN` is set for isolated tests. The override still requires an exact version entry; no environment value can bypass matching.

- [ ] **Step 4: Implement the narrow legacy completion parser and permit translator**

`legacy.py` must tokenize the shell string itself so it can distinguish literal text in single quotes from expansion/control syntax. Accept only a single argv whose tokens are exactly `kanban-post`, `--done`, an issue key/UUID, `--evidence`, nonempty text, followed by zero or more `--reference`, nonempty text pairs. Reject unquoted or double-quoted `$`, backticks, newlines, `;`, `|`, `&`, `<`, `>`, parentheses, globs, backslash-newline, assignments, path-qualified binaries, and all other flags before resolving identity.

For an accepted command, resolve the handle from the actual native identity supplied by the adapter, then resolve that handle's bound current claim and verify the target ticket. Normalize the exact `complete_ticket` arguments through `normalize_tool_args`, mint the permit using the native shell tool call ID, and return a safely reconstructed argv with the UUID-valued internal `--work-handle` appended. The handle is a routing hint for the later helper process; permit ownership/digest/fencing remains the authorization check. Never trust an environment handle to choose the native execution.

- [ ] **Step 5: Implement the SQLite store**

Create focused tables `executions`, `permits`, `claims`, `operations`, and `queue`. Use `BEGIN IMMEDIATE` for handle minting, permit creation/consumption, sequence allocation, queue dominance, and claim state changes. Store only native IDs, UUID identifiers, repo/checkout, capability booleans, timestamps, checkpoint/handoff text, operation kind/state, and redacted last error class.

Required method signatures are `Store.start_execution(harness: str, native_session_id: str, subagent_id: str | None, run_generation: str, handle: str, checkout: str, lifecycle_capable: bool) -> Execution`, `Store.permit_call(identity: NativeIdentity, native_call_id: str, tool: str, normalized_args: bytes, now: datetime) -> Permit`, `Store.consume_permit(handle: str, tool: str, normalized_args: bytes, now: datetime) -> Permit`, `Store.allocate_sequence(handle: str) -> int`, and `Store.enqueue(event: QueueEvent) -> None`.

Freeze `PERMIT_TTL = timedelta(seconds=60)`. A permit is valid only while `now < created_at + PERMIT_TTL`; it cannot be renewed, and an expired row cannot be consumed or reused.

Open with WAL and foreign keys, create via a temporary 0600 file followed by atomic rename, and recheck modes on every open. Cleanup only ended executions older than seven days with no queue rows; never infer current execution from cwd, PID, or newest row.

- [ ] **Step 6: Implement bridge operations and subprocess safety**

`bin/kanban-work` resolves its real blueprint root so the installed symlink can import `lib/kanban_work`. Read at most 256 KiB, dispatch only the four public operations, pass JSON through `subprocess.run([helper, "--json", operation], input=json.dumps(payload), text=True, capture_output=True, shell=False, timeout=30)`, and parse exactly one envelope.

`bind` consumes the permit first. It calls `register_session` with stored native fields for a minted handle. For a bound handle and explicit different checkout, it derives that checkout's GitHub repo, calls `rebind_session` with the stored backend ID, and refuses locally while its current claim cache is live while still relying on backend fencing for correctness. `execute` normalizes `{handle, **payload}` before consuming the permit, strips `handle`, and supplies the stored backend ID for work operations. It strips the local `operation_id` before ordinary helper operations and does not auto-retry their ambiguous transport failures. `create_ticket` defaults `checkout` to the bound checkout without changing that binding. `instructions` runs `[kanban_mcp, "--instructions"]` with no environment credentials and combines the text with safe capability state.

For register, rebind, claim, activity, checkpoint, release, complete, and end, treat the returned receipt as durable acknowledgement rather than current cache truth. Immediately fetch `get_session`; also fetch `get_ticket` for ticket-affecting operations. Commit the refreshed execution, checkout/repo/label, and claim data in one local transaction only when every required refresh succeeds. On refresh failure, preserve the previous row, mark its cache trust flag false, return a retryable local error, and require a successful authoritative refresh before another dependent bind/lifecycle mutation. Apply the same sequence to a backend replay receipt.

- [ ] **Step 7: Install and verify the bridge symlink**

Add `install_kanban_work_symlink()` beside `install_kanban_post_symlink()`. Call both helper installers explicitly from container `install.sh`, host `install-host.sh`, and `lib/sync.sh`; add `kanban-work` to `_sync_provision_artifact_matches`. Assert container and host installs plus sync create a real executable symlink pointing into the selected blueprint. This keeps Cursor/OpenCode host adapters from being configured without their bridge.

```bash
@test "install provides the native Kanban work bridge" {
  run install_kanban_work_symlink
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/kanban-work" ]
  [ "$(readlink -f "$HOME/.local/bin/kanban-work")" = "$BLUEPRINT_ROOT/bin/kanban-work" ]
}
```

- [ ] **Step 8: Run focused tests**

Run: `python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_legacy && bash tests/bats/run.sh tests/bats/install.bats tests/bats/install-host.bats tests/bats/sync.bats`

Expected: PASS, including parallel test execution without writing to the real blueprint.

- [ ] **Step 9: Commit the bridge**

```bash
git add bin/kanban-work lib/kanban_work tests/bats/kanban-work.bats tests/python/test_kanban_work.py \
  tests/python/test_kanban_work_legacy.py \
  install.sh install-host.sh lib/provision-integrations.sh lib/sync.sh \
  tests/bats/install.bats tests/bats/install-host.bats tests/bats/sync.bats
git commit -m "feat(kanban): add native session registry bridge"
```

### Task 3: Bounded lifecycle queue and activity supervision

**Files:**
- Create: `lib/kanban_work/events.py`
- Create: `lib/kanban_work/queue.py`
- Modify: `lib/kanban_work/store.py`
- Modify: `lib/kanban_work/bridge.py`
- Modify: `bin/kanban-work`
- Create: `tests/python/test_kanban_work_queue.py`

**Interfaces:**
- Consumes: bound execution/claim rows and `kanban-post` lifecycle operations.
- Produces: `ingest_event(harness, event_name, payload)`, `drain(budget_ms)`, and `supervise(handle, native_call_id)`; durable latest release/end intent plus bounded, reconstructible ordered delivery indexes.

- [ ] **Step 1: Write failing queue-ordering and time-bound tests**

Use an injected clock and fake transport. Cover startup drain, monotonic sequence, one activity enqueue per 60 seconds, stale observation drop, five-second future rejection before transport, duplicate native event idempotency, old-generation drop after resume, end dominance, release before end, 1024-row cap, oldest-activity eviction, critical-only saturation, reconstruction from durable intent, offline retry, claim fencing, authoritative post-receipt refresh failure, two-hour supervisor cap, post-tool cancellation, and crash fallback (no fabricated completion).

```python
def test_end_dominates_activity_but_preserves_release(self):
    q.enqueue(activity(handle=H, generation=G, sequence=7))
    q.enqueue(release(handle=H, generation=G, operation_id=R))
    q.enqueue(end(handle=H, generation=G, operation_id=E))
    q.enqueue(activity(handle=H, generation=G, sequence=8))
    self.assertEqual([row.kind for row in q.pending(H)], ["release_ticket", "end_session"])

def test_supervisor_stops_at_two_hours_without_fresh_native_event(self):
    q.start_operation(H, "tool-1", observed_at=t0)
    clock.advance(hours=2, seconds=1)
    q.supervise_once(H, "tool-1")
    self.assertEqual(q.pending_activity_after(t0 + timedelta(hours=2)), [])

def test_critical_only_full_queue_preserves_latest_intent_for_next_drain(self):
    q.fill_with_critical_rows(limit=1024)
    q.enqueue(end(handle=H, generation=G, operation_id=E))
    self.assertEqual(q.row_count(), 1024)
    self.assertEqual(store.execution(H).latest_end_operation_id, E)
    q.drain_once()
    self.assertIn((H, E), q.delivery_or_pending_end_pairs())
```

- [ ] **Step 2: Run queue tests and verify they fail**

Run: `python3 -m unittest -v tests.python.test_kanban_work_queue`

Expected: FAIL because event and queue modules do not exist.

- [ ] **Step 3: Implement normalized event ingestion**

Native ingress allocates `observed_at` at receipt and `sequence` transactionally. Start/resume/clear mint a new UUID `run_generation`; compaction resolves the existing generation and never starts/ends one. Tool start records `native_call_id` and queues immediate activity only when a live claim exists. Tool success/failure closes that exact operation and queues activity. Stop transactionally writes the latest release payload and operation ID onto the claim row, then indexes `release_ticket` delivery with the latest checkpoint or `Agent stopped without recording a checkpoint.` and reason `stopped`. Session end transactionally writes the latest end payload and operation ID onto the execution row, deletes/suppresses activity for the generation, and indexes `end_session` with the same handoff. Subagent stop targets the subagent row only. The durable claim/execution fields are the source of truth; queue rows only index delivery.

- [ ] **Step 4: Implement bounded delivery**

`drain` first reconstructs any missing release/end delivery index from durable current intent, then claims one row under `BEGIN IMMEDIATE`, releases the database lock before subprocess/network work, and marks success/failure in a new transaction. Queue admission never exceeds 1024 rows: it evicts oldest activity first, and when all rows are critical it updates durable intent without adding a row so the next drain reconstructs it after capacity opens. It drops activity older than 60 seconds, for an ended/old generation, for a different/current replacement claim, or behind an end intent. It retries release/end with their stored operation IDs and records only exception class plus an attempt count.

```python
def deliver(row: QueueRow, transport: Transport, now: datetime) -> Delivery:
    if row.kind == "activity" and now - row.observed_at > timedelta(seconds=60):
        return Delivery.drop("stale_activity")
    payload = row.payload | {"operation_id": row.operation_id}
    return transport.call(row.remote_operation, payload)
```

After any successful or replayed delivery receipt, call `get_session` and call `get_ticket` for claim activity/release before marking intent delivered or updating cached state. A refresh failure leaves the delivery retryable, marks the cache untrusted, and cannot clear the durable release/end intent. End always dominates activity, including when the end was persisted while a critical-only queue was full.

- [ ] **Step 5: Implement bounded supervisor mode**

`supervise` wakes no more frequently than every 60 seconds, confirms the exact operation row is still active, and enqueues activity for at most two hours from its latest fresh native event. It exits when post-tool, stop, end, generation change, missing claim, or cap occurs. `AICODINGSETUP_SKIP_NETWORK=1` disables detached spawning in tests; unit tests drive `supervise_once` directly with a fake clock.

- [ ] **Step 6: Run the focused queue and bridge tests**

Run: `python3 -m unittest -v tests.python.test_kanban_work tests.python.test_kanban_work_queue`

Expected: PASS with deterministic ordering and no sleeping test.

- [ ] **Step 7: Commit lifecycle delivery**

```bash
git add bin/kanban-work lib/kanban_work tests/python/test_kanban_work_queue.py
git commit -m "feat(kanban): queue bounded lifecycle activity"
```

### Task 4: Claude Code and Codex managed lifecycle adapters

**Files:**
- Create: `lib/kanban_work/adapters.py`
- Modify: `bin/kanban-work`
- Create: `configs/claude/hooks/kanban-work-hook.sh`
- Modify: `configs/claude/settings.json`
- Modify: `configs/codex/requirements.toml`
- Modify: `lib/blueprint-deploy.sh`
- Modify: `lib/provision-system.sh`
- Create: `tests/bats/kanban-work-hooks.bats`
- Modify: `tests/bats/codex-managed-hooks.bats`
- Modify: `tests/bats/install.bats`
- Modify: `tests/bats/sync.bats`
- Create: `tests/python/test_kanban_work_adapters.py`

**Interfaces:**
- Consumes: Claude/Codex JSON hook stdin, `kanban-work hook --harness H --event E`, the shared normalizer, and the Task 2 legacy completion translator.
- Produces: `adapt_claude_codex(harness, event_name, payload) -> AdapterResult`, hook-minted handles/instructions, actual-caller permits for Kanban MCP or the exact legacy completion, native activity/tool supervision, parent/subagent separation, stop release, and session-end reconciliation.

- [ ] **Step 1: Add shared payload fixtures and failing adapter tests**

For Claude, feed exact fixtures for `SessionStart` sources `startup`, `resume`, `clear`, `compact`, and `fork`, plus `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `StopFailure`, `SessionEnd`, `SubagentStart`, and `SubagentStop`. Assert `compact` preserves the run generation, while resume/clear/fork use the frozen fresh-generation rule and delayed prior-generation events cannot act. A Claude Stop fixture with nonempty `background_tasks` or `session_crons` must not release the parent.

For Codex 0.154.0, fixture only its native `SessionStart` sources `startup`, `resume`, `clear`, and `compact`, plus `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`, `SubagentStart`, and `SubagentStop`; do not configure or fabricate `PostToolUseFailure`. Assert stdout is valid client hook JSON, stdin text never becomes a shell argument, and wrong session/handle/digest denies the MCP call. Point `AICODING_KANBAN_QUALIFIED_CLIENTS` at a temporary exact-version matrix with loopback `KANBAN_URL` and `KANBAN_TEST_TOKEN`; missing token, non-loopback URL, and mismatched versions remain read-only.

```bash
@test "Claude pre-tool permit binds actual session to normalized MCP args" {
  start_claude_session native-a
  run_hook claude PreToolUse '{
    "session_id":"native-a","hook_event_name":"PreToolUse","tool_use_id":"call-7",
    "tool_name":"mcp__kanban__claim_ticket",
    "tool_input":{"handle":"'"$HANDLE"'","ticket":"KANBAN-2"}}
  '
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' <<<"$output"
  run_bridge execute "$HANDLE" claim_ticket '{"ticket":"KANBAN-2"}'
  [ "$status" -eq 0 ]
}

@test "compaction and child stop never release the parent claim" {
  start_parent_and_child
  run_hook claude SessionStart "$COMPACT_PAYLOAD"
  run_hook claude SubagentStop "$CHILD_STOP_PAYLOAD"
  assert_queue_lacks "$PARENT_HANDLE" release_ticket
  assert_queue_has "$CHILD_HANDLE" end_session
}
```

Repeat the actual-caller fixture through the Codex managed command and test delayed old-generation events after resume, two sessions in one checkout, normal stop, end, and missing required native IDs. Model a long unified-exec call with one original `PreToolUse.tool_use_id`, no separate event for later polls, and the original call's eventual `PostToolUse`; keep supervision open until that matching post. For a failed call with no post event, retain the unresolved operation until bounded expiry or a conservatively qualified Stop/SessionEnd reconciliation. If real qualification cannot prove that reconciliation avoids releasing active work, Codex remains read-only.

For both clients, feed a native pre-shell-tool event containing exactly `kanban-post --done KANBAN-2 --evidence 'tests pass' --reference PR-17`. Assert the adapter resolves the actual native caller and current claim, mints the same normalized `complete_ticket` permit used by MCP, and returns the client-specific updated command with only the internal handle appended. Assert peer/environment-only identity, replay, compound syntax, expansion, unknown flags, and a completion-like command whose client schema cannot be verified are denied with `Use the Kanban MCP complete_ticket tool`; unrelated shell commands remain unchanged and mint no permit.

- [ ] **Step 2: Run adapter tests and verify they fail**

Run: `python3 -m unittest -v tests.python.test_kanban_work_adapters && bash tests/bats/run.sh tests/bats/kanban-work-hooks.bats tests/bats/codex-managed-hooks.bats`

Expected: FAIL because the lifecycle hook and configuration entries are absent.

- [ ] **Step 3: Implement the shared wrapper and client-specific output**

Immediately before editing shared managed config or deploy files, recheck setup PR #172 and integrate any overlapping final state into this worktree. Rerun the focused managed-config tests after the edit.

The shell wrapper performs no parsing and no network access:

```bash
#!/usr/bin/env bash
set -u
exec "$HOME/.local/bin/kanban-work" hook --harness "$1" --event "$2"
```

Implement native payload parsing and client-specific output in `lib/kanban_work/adapters.py`; `bin/kanban-work hook` only bounds stdin, dispatches into that module, and emits its result. The adapter validates `session_id`, optional `agent_id`, `tool_use_id`, `tool_name`, and `tool_input`. At SessionStart it obtains the exact client version with a two-second, closed-stdin `claude --version` or `codex --version` subprocess and marks the handle lifecycle-capable only on an exact qualified-matrix match. SessionStart output carries the hook-minted handle and canonical text. PreToolUse allows reads, but for mutating `mcp__kanban__*` it validates actual native identity, writes the permit, and returns a deny with an actionable message on any mismatch.

For the native shell tool only, pass the verified native identity, native call ID, and exact command field to `prepare_legacy_complete`. If it returns a prepared completion, rebuild the command only from its returned argv and emit the documented client-specific updated-input field. A completion-like command that the translator rejects is denied; unrelated shell commands pass unchanged. An environment `KANBAN_WORK_HANDLE` is only a convenience hint for the later helper and never selects or proves the caller. Store that non-secret hint through `CLAUDE_ENV_FILE` when available, while still requiring explicit handle arguments for MCP mutations.

- [ ] **Step 4: Wire Claude events without disturbing existing hooks**

Add `kanban-work-hook.sh` entries to existing Claude arrays and create missing `PostToolUse`, `PostToolUseFailure`, `StopFailure`, `SubagentStart`, and `SubagentStop` arrays. The Kanban Stop/SessionEnd hook persists locally before asynchronous transcript work. Match Kanban pre-calls with `mcp__kanban__.*` and the native shell tool so the narrow legacy completion can be translated before execution; generic tool activity hooks may match all tools because the bridge is a no-op without a current claim.

- [ ] **Step 5: Wire Codex as managed hooks**

Add Codex 0.154.0's actual event set to `configs/codex/requirements.toml`; omit `PostToolUseFailure` and Claude-only fields/events. Match an operation's close by its original `PostToolUse.tool_use_id`, including a long unified-exec completed through later polling. At Stop/SessionEnd, reconcile unresolved calls conservatively only after qualification proves no live tool/child remains; otherwise leave the installed version read-only and let bounded expiry handle the claim. Render the wrapper into `${CODEX_MANAGED_DIR}/hooks` and extend sync verification. Preserve the three-second SessionEnd cap: the hook only persists queue intent and returns; any delivery is detached and bounded. Do not enable `allow_managed_hooks_only` or disable user hooks.

- [ ] **Step 6: Run adapter and managed-install tests**

Run: `python3 -m unittest -v tests.python.test_kanban_work_adapters && bash tests/bats/run.sh tests/bats/kanban-work-hooks.bats tests/bats/codex-managed-hooks.bats tests/bats/install.bats tests/bats/sync.bats`

Expected: PASS; `AICODINGSETUP_SKIP_NETWORK=1` starts no supervisor/drainer and all agent binaries are stubbed.

- [ ] **Step 7: Commit Claude/Codex adapters**

```bash
git add lib/kanban_work/adapters.py bin/kanban-work \
  configs/claude/hooks/kanban-work-hook.sh configs/claude/settings.json \
  configs/codex/requirements.toml lib/blueprint-deploy.sh lib/provision-system.sh \
  tests/bats/kanban-work-hooks.bats tests/bats/codex-managed-hooks.bats \
  tests/bats/install.bats tests/bats/sync.bats tests/python/test_kanban_work_adapters.py
git commit -m "feat(kanban): bind Claude and Codex lifecycles"
```

### Task 5: Cursor lifecycle adapter

**Files:**
- Modify: `lib/kanban_work/adapters.py`
- Modify: `bin/kanban-work`
- Modify: `configs/cursor/hooks.json`
- Create: `tests/bats/cursor-kanban-hooks.bats`
- Modify: `tests/bats/install.bats`
- Modify: `tests/bats/install-host.bats`
- Modify: `tests/python/test_kanban_work_adapters.py`

**Interfaces:**
- Consumes: Cursor common fields (`conversation_id`, `generation_id`, `cursor_version`, `workspace_roots`) and event-specific fields from `sessionStart`, `beforeSubmitPrompt`, generic `preToolUse`, `postToolUse`, `postToolUseFailure`, `stop`, `sessionEnd`, `subagentStart`, `subagentStop`, and `preCompact`; the shared normalizer and legacy translator.
- Produces: `adapt_cursor(event_name, payload) -> AdapterResult` in the shared Python adapter module, the same registry/permit/activity semantics with Cursor JSON outputs, generic `preToolUse` as the sole permit minter with `failClosed: true`, and exact legacy completion translation on that native pre-tool event.

- [ ] **Step 1: Write failing Cursor payload tests**

Fixture tests must include multi-root refusal, sessionStart handle/instructions, stable conversation plus changing prompt generation, generic pre-tool object input and `tool_use_id`, a qualified candidate `MCP:claim_ticket` name, fail-closed mismatch, matching generic post success/failure, stop versus preCompact, fire-and-forget SessionEnd, background agent identity at start, and a documented `subagentStop` without `subagent_id`. Use a loopback-only temporary exact-version matrix and prove an unlisted `cursor_version` remains read-only. The fixture name is only a candidate: installed-client qualification must capture the exact emitted MCP tool name before the version can be listed.

```bash
@test "Cursor generic preToolUse denies a peer handle before Kanban MCP execution" {
  start_cursor_session conv-a gen-a "$CHECKOUT"
  payload=$(jq -nc --arg h "$PEER_HANDLE" '{
    conversation_id:"conv-a",generation_id:"gen-a",hook_event_name:"preToolUse",
    tool_use_id:"call-7",tool_name:"MCP:claim_ticket",
    tool_input:{handle:$h,ticket:"KANBAN-2"},workspace_roots:["'"$CHECKOUT"'"]}')
  run_cursor_hook preToolUse "$payload"
  jq -e '.permission == "deny" and (.agent_message|contains("bound Cursor session"))' <<<"$output"
}
```

Add `preToolUse` shell fixtures for accepted exact legacy completion, reconstructed updated command, peer/environment-hint denial, replay, compound syntax, and unrelated shell pass-through. Assert a mutating MCP pre-event creates exactly one permit and no `beforeMCPExecution`/`afterMCPExecution` Kanban hook is configured. Track a child from `subagentStart`, then feed the documented stop shape without an ID and assert the adapter neither invents a correlation nor releases the parent; that installed version stays read-only unless real capture proves a reliable correlation.

- [ ] **Step 2: Run the Cursor tests and verify they fail**

Run: `python3 -m unittest -v tests.python.test_kanban_work_adapters && bash tests/bats/run.sh tests/bats/cursor-kanban-hooks.bats`

Expected: FAIL because only transcript hooks are configured.

- [ ] **Step 3: Add Cursor event entries and output mapping**

Extend `lib/kanban_work/adapters.py` with Cursor's distinct parser and output mapping; invoke it through the shared wrapper with `cursor` and the exact event name. Use Cursor's common `conversation_id` as `native_session_id`, exact `cursor_version` for qualification, and `generation_id` as native event ordering data while the bridge's fresh UUID remains the run generation. `sessionStart` returns `env.KANBAN_WORK_HANDLE` and `additional_context`. Configure generic `preToolUse` with `failClosed: true`; it identifies MCP calls from the exact observed tool name, uses `tool_use_id` as the native call ID, validates object `tool_input`, and is the sole permit minter. Do not configure Kanban `beforeMCPExecution` or `afterMCPExecution`; generic post success/failure closes the original call.

On Cursor's native shell `preToolUse`, pass the actual conversation/subagent/generation identity, native call ID, and exact command field to the shared Task 2 translator. Emit Cursor's documented updated-input shape only from the returned safe argv. Deny completion-like invalid/ambiguous forms with the MCP instruction, and leave unrelated shell input unchanged. `preCompact` records activity only. Never synthesize a child ID from `subagentStop` summaries/status. `stop` releases the parent only after verified tool/subagent work has ended; if real events cannot correlate child completion or prove the local lifecycle surface, qualification fails closed. Do not claim coverage for Cursor cloud agents from these user hooks.

- [ ] **Step 4: Verify managed merge/preservation**

Extend first-install, reconcile, and host tests so `hooks.json` follows its existing overwrite-managed contract, merge-managed `mcp.json` continues to preserve user servers, the blueprint hook file is installed, and no Cursor credential/config content is read or printed.

- [ ] **Step 5: Run Cursor and install tests**

Run: `python3 -m unittest -v tests.python.test_kanban_work_adapters && bash tests/bats/run.sh tests/bats/cursor-kanban-hooks.bats tests/bats/install.bats tests/bats/install-host.bats`

Expected: PASS.

- [ ] **Step 6: Commit the Cursor adapter**

```bash
git add lib/kanban_work/adapters.py bin/kanban-work configs/cursor/hooks.json \
  tests/python/test_kanban_work_adapters.py tests/bats/cursor-kanban-hooks.bats \
  tests/bats/install.bats tests/bats/install-host.bats
git commit -m "feat(kanban): bind Cursor agent lifecycles"
```

### Task 6: OpenCode lifecycle plugin

**Files:**
- Modify: `lib/kanban_work/adapters.py`
- Modify: `bin/kanban-work`
- Create: `configs/opencode/plugins/kanban-work.js`
- Modify: `configs/opencode/opencode.json`
- Modify: `lib/blueprint-deploy.sh`
- Create: `tests/fixtures/opencode/kanban-events.jsonl`
- Create: `tests/bats/opencode-kanban-plugin.bats`
- Modify: `tests/bats/install.bats`
- Modify: `tests/bats/install-host.bats`
- Modify: `tests/python/test_kanban_work_adapters.py`

**Interfaces:**
- Consumes: OpenCode plugin `event`, `tool.execute.before` input `{tool,sessionID,callID}` with mutable `output.args`, successful `tool.execute.after`, and `experimental.chat.system.transform`; the shared Python adapter/legacy translator through `kanban-work hook`.
- Produces: native session/child-session registration, canonical instruction injection, before-hook native-identity permits for flattened Kanban MCP tool names or an exact legacy completion, successful tool activity, conservative idle/error reconciliation, deleted/end reconciliation, and an explicitly unqualified state when the installed version omits required lifecycle evidence.

- [ ] **Step 1: Write failing plugin tests with a fake `kanban-work`**

Run the plugin under the installed Bun/Node runtime with captured event fixtures. Assert exact argv/stdin, no shell interpolation, sessionID-to-handle mapping, `session.created`, `session.compacted`, `session.idle`, `session.deleted`, `session.error`, child `info.parentID`, parent idle while a child remains active, flattened MCP tool names such as `kanban_claim_ticket`, tool before/successful-after, and system-prompt injection by in-place array mutation. The fixtures must use only fields present in the pinned native contract.

```javascript
const output = { system: ["base"] }
await hooks["experimental.chat.system.transform"](
  { sessionID: "ses-parent", model: {} }, output
)
assert.equal(output.system[0], "base")
assert.match(output.system.join("\n"), /Kanban work session handle:/)
assert.match(output.system.join("\n"), /Claim a ticket before implementation/)
```

Test `tool.execute.before` without `sessionID` or `callID`: reads remain available, while a mutation raises the bridge's unsupported-adapter message before the fake transport sees a call. Do not add an MCP `_meta` or nonexistent plugin-version fixture. Use a loopback-only temporary exact-version matrix. Add native shell fixtures proving exact legacy completion rewrites safely, while compound syntax, a peer/environment handle, replay, or missing session context throws the MCP guidance before execution; unrelated shell commands remain unchanged. Also fixture a failed tool with no after hook, `session.error` without a session ID, and first observation of an existing session; none may fabricate close/resume identity or qualify the client by themselves.

- [ ] **Step 2: Run the plugin tests and verify they fail**

Run: `bash tests/bats/run.sh tests/bats/opencode-kanban-plugin.bats`

Expected: FAIL because the plugin is absent.

- [ ] **Step 3: Implement the dependency-free local plugin**

Use `child_process.spawn`/`execFile` with argument arrays and JSON stdin, never Bun shell interpolation. Cache canonical instruction text once per plugin instance. Obtain the process candidate version with a bounded two-second, closed-stdin `opencode --version`; do not use nonexistent `app.version` or assume a stored session creation version represents the resumed process. Map OpenCode's session events to bridge hook ingress. Track child sessions separately from `session.created.info.parentID`. In `tool.execute.before`, recognize exact flattened Kanban MCP tool names (`kanban_<tool>`, after OpenCode's native sanitization), bind the permit to actual `sessionID` and `callID`, normalize `output.args` through `kanban-work hook`, and throw before execution when validation fails. No MCP `_meta` is required or expected.

For the native shell tool, send actual session/child context, `callID`, and the exact command field to the shared Python adapter. If the Task 2 translator returns a prepared legacy completion, mutate `output.args.command` only from its safe reconstructed argv. Throw the MCP guidance for completion-like rejected forms and do nothing for unrelated shell commands. `tool.execute.after` closes only successful calls. On idle/error, reconcile an unresolved call conservatively only if real qualification proves it is no longer running; parent idle cannot release while a tracked child or tool is active. Missing after-on-failure and indistinguishable first-observed/resumed sessions remain qualification gates, so the installed version stays read-only unless those cases are safely demonstrated. In `experimental.chat.system.transform`, mutate `output.system` in place and include only the current session's handle/capability text when `sessionID` is present.

```javascript
function bridge(args, payload) {
  return new Promise((resolve, reject) => {
    const child = spawn(KANBAN_WORK, args, { stdio: ["pipe", "pipe", "pipe"] })
    child.stdin.end(JSON.stringify(payload))
    collectBoundedJson(child, 256 * 1024, resolve, reject)
  })
}
```

Do not register a second model-visible tool or copy the workflow text into the plugin.

- [ ] **Step 4: Install the plugin as a managed file**

Add `$HOME/.config/opencode/plugins/kanban-work.js|overwrite|configs/opencode/plugins/kanban-work.js` to inventory. If the installed OpenCode version requires a `plugin` config entry, add the local path while preserving user plugins; otherwise rely on documented global plugin auto-discovery and test it with `opencode debug config`.

- [ ] **Step 5: Run plugin and install tests**

Run: `python3 -m unittest -v tests.python.test_kanban_work_adapters && bash tests/bats/run.sh tests/bats/opencode-kanban-plugin.bats tests/bats/install.bats tests/bats/install-host.bats`

Expected: PASS with no package download at plugin load and no real board request.

- [ ] **Step 6: Commit the OpenCode adapter**

```bash
git add lib/kanban_work/adapters.py bin/kanban-work \
  configs/opencode/plugins/kanban-work.js configs/opencode/opencode.json \
  lib/blueprint-deploy.sh tests/fixtures/opencode/kanban-events.jsonl \
  tests/python/test_kanban_work_adapters.py \
  tests/bats/opencode-kanban-plugin.bats tests/bats/install.bats tests/bats/install-host.bats
git commit -m "feat(kanban): add OpenCode lifecycle plugin"
```

### Task 7: Complete pre-pin acceptance, pin the Kanban MCP, and migrate copied guidance

Read `superpowers:writing-skills` before editing the existing Cursor estate
SKILL.md. This task removes duplicated workflow in favor of canonical MCP
instructions; it does not introduce another companion skill.

**Files:**
- Create: `configs/versions/kanban-mcp.rev`
- Modify: `lib/update-components.sh`
- Modify: `lib/provision.sh`
- Modify: `configs/codex/config.toml`
- Modify: `configs/cursor/mcp.json`
- Modify: `configs/opencode/opencode.json`
- Modify: `configs/claude/CLAUDE.md`
- Modify: `configs/codex/AGENTS.md`
- Modify: `configs/cursor/skills/aicoding-estate/SKILL.md`
- Modify: `tests/bats/update-components.bats`
- Modify: `tests/bats/provision.bats`
- Modify: `tests/bats/install.bats`
- Modify: `tests/bats/install-host.bats`
- Modify: `tests/bats/initial-mcp-gate.bats`
- Modify: `README.md`
- Modify: `docs/agent-parity.md`

**Interfaces:**
- Consumes: reviewed setup Tasks 1-6, Kanban Tasks 1-4 plus Kanban Task 5's pre-pin loopback acceptance/review, and a clean reviewed Kanban git commit containing `kanban-mcp`, its committed lockfile with official MCP SDK 2.2.0, `from mcp.server import MCPServer`, `bind_work_session(handle,label?,checkout?,operation_id?)`, exact `kanban-mcp <installed metadata version>\n` output for `--version`, `--instructions`, and stdio behavior; installed `kanban-post` and `kanban-work` launchers.
- Produces: immutable `mcp-kanban` release, stable `~/.local/bin/kanban-mcp`, all four client registrations with no env/header secret, and generated/canonical guidance instead of copied CLI tutorials.

- [ ] **Step 1: Review the setup transport and adapters before cross-repository acceptance**

Run the focused tests for setup Tasks 1-6 and `bash tests/bats/run.sh`, then obtain an independent review of those setup changes. Resolve verified transport, registry, normalizer, queue, and adapter findings before Kanban acceptance consumes them. Recheck setup PR #172 immediately before any shared configuration edit. This review does not require an MCP pin because it invokes the setup worktree's helpers directly.

- [ ] **Step 2: Run and review Kanban Task 5 acceptance against setup source paths**

After Kanban Tasks 1-4 pass their focused/full tests, run Kanban Task 5's loopback-only cross-repository acceptance with the reviewed setup worktree's `bin/kanban-post`, `bin/kanban-work`, registry, and adapters, and the Kanban worktree's MCP controller directly. Use only `KANBAN_TEST_TOKEN`, a loopback `KANBAN_URL`, temporary state/config paths, and exact real controller `--version`; no installed pin or production write is required. Complete Kanban Task 5's independent review and fixes. Do not make its review depend on Task 8 native-client outcomes, which belong to setup artifacts after pinning.

- [ ] **Step 3: Gate on and record the reviewed Kanban revision**

From the coordinated Kanban worktree, run:

```bash
git -C /home/codespace/checkouts/kanban/.claude/worktrees/feat-agent-work-claims status --short
git -C /home/codespace/checkouts/kanban/.claude/worktrees/feat-agent-work-claims rev-parse HEAD
git -C /home/codespace/checkouts/kanban/.claude/worktrees/feat-agent-work-claims merge-base --is-ancestor 7e2a70c HEAD
```

Require a clean reviewed head descended from `7e2a70c`, pushed to the Kanban PR, with Kanban Tasks 1-5, MCP tests, pre-pin cross-repository acceptance, and independent review complete. Verify `kanban-mcp --version` prints exactly `kanban-mcp <installed package metadata version>` plus one newline. Put the printed 40-character lowercase SHA, followed by one newline, in `configs/versions/kanban-mcp.rev`. This value cannot be written earlier because the reviewed implementation commit does not exist at plan time; do not use a branch, tag, PR ref, short SHA, or `latest` as a substitute.

- [ ] **Step 4: Write failing immutable-stage tests**

Stub `git` and `uv` around a fixture repo and assert the updater checks a 40-character revision, checks out detached, runs `uv sync --frozen --extra mcp --no-dev`, validates exact `kanban-mcp <installed metadata version>\n` output from `kanban-mcp --version` and nonempty `kanban-mcp --instructions`, activates only after validation, keeps the previous release after failure, skips network under `AICODINGSETUP_SKIP_NETWORK=1`, and records truthful receipts.

```bash
@test "kanban MCP stages the pinned repository revision and frozen lock" {
  run aicoding_update_component mcp-kanban
  [ "$status" -eq 0 ]
  grep -q 'checkout --detach '"$(cat "$BLUEPRINT_ROOT/configs/versions/kanban-mcp.rev")" "$TMP/git.log"
  grep -q 'sync --frozen --extra mcp --no-dev' "$TMP/uv.log"
  [ -x "$HOME/.local/bin/kanban-mcp" ]
}
```

- [ ] **Step 5: Implement the git/uv component adapter**

Add `mcp-kanban` to installed/managed component discovery. Reuse `_aicoding_stage_git_source` with fixed origin `https://github.com/vossiman/kanban.git` and the pinned file. Build into `$AICODING_DATA_DIR/versions/mcp-kanban/$sha`, using a staging directory and the Kanban lockfile. Activate the venv entry point through the existing immutable launcher. A current receipt requires the active revision, executable, successful `--version`, and nonempty `--instructions`; offline absence records `blocked/offline_exact_package_not_ready`.

- [ ] **Step 6: Register `kanban` in all four clients**

Extend `MANAGED_MCPS`, exact MCP readiness, shared-consumer checks, and Claude reconciliation to include `kanban-mcp`. The MCP may be installed for read tools before lifecycle qualification; `kanban-work` keeps binding/claims disabled for unlisted client versions. Add these secret-free entries:

```toml
[mcp_servers.kanban]
command = "kanban-mcp"
```

```json
{"mcpServers":{"kanban":{"command":"kanban-mcp"}}}
```

```json
{"mcp":{"kanban":{"type":"local","command":["kanban-mcp"],"enabled":true}}}
```

For Claude, reconcile an exact user-scope stdio registration to `$HOME/.local/bin/kanban-mcp`; preserve unknown user-owned registrations and use the existing recovery/rollback receipt flow. `aicoding-sync` must not stamp success unless the package and every installed client's config/registration are verified.

- [ ] **Step 7: Write protocol/config tests before migrating prose**

Use the pinned real executable with a temporary fake helper and the SDK 2.2.0 client to run both legacy and default-v2 MCP `initialize`, `tools/list`, one read call, and `--instructions`. Assert server instructions are nonempty, the frozen tool names are present, and a tool error has protocol `isError` semantics instead of a successful-looking error body. Add managed-config tests showing no `KANBAN_TOKEN`, Authorization header, secret placeholder, checkout path, or backend URL in any Kanban MCP entry. Container and host install tests must prove both `kanban-work` and the immutable `kanban-mcp` launcher exist before Cursor/OpenCode integration is reported ready.

- [ ] **Step 8: Replace copied board tutorials with canonical-source guidance**

Only after Step 5 passes, remove duplicated command/API workflow sections from `configs/claude/CLAUDE.md`, `configs/codex/AGENTS.md`, and `configs/cursor/skills/aicoding-estate/SKILL.md`. Retain the independent secret policy and a short compatibility note:

```markdown
## Kanban work

Use the installed `kanban` MCP for ticket reads, claims, checkpoints, release,
completion, comments, links, and follow-up filing. Its server instructions are
the canonical workflow. Native lifecycle adapters bind the supplied work-session
handle and release unfinished claims when a turn stops. `kanban-post` remains a
credential-safe recovery CLI; it is not a status-transition bypass.
```

Startup/plugin compatibility injection must call `kanban-work --json instructions`, which in turn calls `kanban-mcp --instructions`; do not paste the canonical workflow into setup files.

- [ ] **Step 9: Update setup documentation**

Document the pinned revision/update receipt, no-secret MCP config, local registry location/retention, same-user trust boundary, supported lifecycle behaviors, compatibility/enforcement gate, fake-board qualification command, and recovery CLI. Update the parity matrix for all four clients and cite official current hook/plugin docs.

- [ ] **Step 10: Run component, provisioning, protocol, and documentation guards**

Run: `bash tests/bats/run.sh tests/bats/update-components.bats tests/bats/provision.bats tests/bats/install.bats tests/bats/install-host.bats tests/bats/initial-mcp-gate.bats`

Expected: PASS; tests make no live GitHub/package/board request and detect any moving revision or copied workflow block.

- [ ] **Step 11: Commit the pinned integration**

```bash
git add configs/versions/kanban-mcp.rev lib/update-components.sh lib/provision.sh \
  configs/codex/config.toml configs/cursor/mcp.json configs/opencode/opencode.json \
  configs/claude/CLAUDE.md configs/codex/AGENTS.md \
  configs/cursor/skills/aicoding-estate/SKILL.md tests/bats/update-components.bats \
  tests/bats/provision.bats tests/bats/install.bats tests/bats/install-host.bats \
  tests/bats/initial-mcp-gate.bats \
  README.md docs/agent-parity.md
git commit -m "feat(kanban): pin and register the canonical MCP"
```

### Task 8: Real-client qualification and rollout evidence

**Files:**
- Create: `tools/qualify-kanban-clients`
- Create: `configs/kanban/qualified-clients.json`
- Create: `tests/qualification/fake_kanban_board.py`
- Create: `tests/qualification/qualify_kanban_clients.py`
- Create: `tests/bats/kanban-client-qualification.bats`
- Create: `docs/kanban-mcp-qualification.md`
- Modify: `README.md`
- Modify: `docs/agent-parity.md`

**Interfaces:**
- Consumes: installed real `claude`, `codex`, `agent`/`cursor-agent`, and `opencode`; pinned real `kanban-mcp`; lifecycle configs; loopback fake board and fake credential.
- Produces: setup-owned redacted JSON qualification reports per exact client version, a tracked setup qualification matrix, and a hard `qualified|unsupported` capability decision used before enforcement. This task does not modify the Kanban source tree or pinned revision.

- [ ] **Step 1: Write failing harness self-tests**

Test the harness with fake client executables that emit the expected hook/MCP transcripts. It must refuse a non-loopback board, require `KANBAN_TEST_TOKEN`, reject a report missing any required scenario, redact a fake token echoed by a client, time out a hung client, and return nonzero if any installed client is unqualified.

```python
REQUIRED_SCENARIOS = {
    "instructions", "bind", "mutating_identity_check", "activity", "turn_stop",
    "session_end", "generation_boundaries", "two_sessions_one_checkout",
    "shared_mcp_process", "long_tool", "failure_reconciliation",
    "parent_child", "crash_expiry",
}

def test_report_cannot_pass_with_fixture_only_evidence(self):
    report = qualify(fake_client=True, real_binary_observed=False)
    self.assertEqual(report["status"], "unsupported")
    self.assertIn("real client binary was not observed", report["reasons"])
```

- [ ] **Step 2: Run harness self-tests and verify they fail**

Run: `bash tests/bats/run.sh tests/bats/kanban-client-qualification.bats`

Expected: FAIL because the qualification harness does not exist.

- [ ] **Step 3: Implement a no-production-write fake board**

Bind only `127.0.0.1` on a random port, require the fixed fake bearer token, implement the work/ticket endpoints needed by the scenarios, and expose a test-control clock for expiry. Log only method, route name, operation ID, and redacted actor/session labels. Reject redirects, arbitrary host headers, and any Authorization value other than the fake token. The test clock advances 17 minutes for crash expiry instead of sleeping.

- [ ] **Step 4: Implement real-client launch adapters**

For each client, invoke its real `--version` first, parse and record the exact bounded version string, and write a temporary candidate `qualified-clients.json` containing only that harness/version pair. Create a temporary project/config overlay containing only the pinned Kanban MCP and lifecycle adapter under test while allowing the installed client to use its own normal authentication internally. Do not open, copy, parse, print, or report any live auth/config/environment value. Use each CLI's supported noninteractive mode and JSON/stream output where available. Force only the fake board's random `KANBAN_URL=http://127.0.0.1:<port>`, `KANBAN_TEST_TOKEN=FAKE-KANBAN-QUALIFICATION-TOKEN`, a temporary `XDG_STATE_HOME`, and `AICODING_KANBAN_QUALIFIED_CLIENTS=<temporary candidate path>` into child processes. The bridge must verify loopback plus fake-token context and exact version membership; there is no `AICODING_KANBAN_QUALIFY` bypass.

Record command basename and `--version`, never full argv/environment. Cap each scenario at 120 seconds and the whole client at ten minutes. A client that cannot run noninteractively or lacks a required payload is reported `unsupported`, not silently fixture-qualified.

- [ ] **Step 5: Exercise all required scenarios per real client**

For Claude Code, Codex, Cursor, and OpenCode, prove:

1. MCP initialize/tool discovery and canonical instructions reach the client.
2. Session start mints a handle and `bind_work_session` binds the same native session.
3. A peer handle is denied before a board write, including with two sessions in one checkout and a shared MCP process.
4. Claim -> native prompt/tool activity renews only the current fenced claim.
5. Claim -> Stop/session idle releases to Todo with checkpoint or stopped-without-checkpoint handoff.
6. Claim -> SessionEnd/session deleted reconciles and ends the generation.
7. Every native generation boundary the client exposes is handled correctly and delayed old events cannot release/complete new work; absence of a required boundary is reported rather than synthesized.
8. Long tool supervision stops on completion and at the two-hour cap.
9. Parent and native child work have separate handles/claims; child completion targets only the child, and parent stop/idle while a tracked child remains active does not release the parent.
10. Killing the client leaves no renewal; fake-clock expiry returns the ticket to Todo. An old worker cannot close the replacement claim.

Use unique test ticket keys and assert the fake board received no unexpected route. Do not ask a model to reveal hook payloads or credentials; capture them only in the temporary adapter qualification log with native IDs replaced by stable hashes in the final report.

Apply these exact client gates rather than filling gaps in captured fixtures:

- Claude must prove `startup|resume|clear|compact|fork`, same-generation compact, fresh safe generation boundaries, `PostToolUseFailure`, background-task-aware Stop, and child `agent_id` correlation.
- Codex 0.154.0 must prove that a long unified-exec closes on the original call ID's `PostToolUse`; it has no `PostToolUseFailure`. A failed call with no post event must reach a safe bounded Stop/SessionEnd/expiry path or Codex remains unsupported.
- Cursor must prove generic `preToolUse` supplies the exact emitted MCP tool name and call ID and is the sole fail-closed permit minter. Its documented `subagentStop` lacks `subagent_id`; inability to correlate the real event, or absence of required local lifecycle events, leaves Cursor unsupported. These results do not qualify Cursor cloud agents.
- OpenCode must prove flattened names such as `kanban_claim_ticket`, actual `tool.execute.before` `sessionID`/`callID`, bounded `opencode --version`, successful-after correlation, failed-call reconciliation, existing/resumed-session generation safety, and parent idle while `info.parentID` child work continues. Do not expect MCP `_meta` or plugin `app.version`; any unresolved gap leaves OpenCode unsupported.

- [ ] **Step 6: Make qualification status explicit and enforcement-gating**

Write reports under `out/kanban-mcp-qualification/` for `dvw pull`, preserving existing `out/` contents. Each report contains timestamp, blueprint commit, pinned Kanban revision, client/version, scenario booleans, capability status, and redacted reasons. It contains no prompt, transcript, native ID, checkout outside the temporary project, token, config, or auth path.

After all scenarios pass, promote the exact four observed client/version pairs and qualification schema version from the temporary candidates to `configs/kanban/qualified-clients.json`; never add a range or an untested later version. `kanban-work` compares the current hook/plugin-reported or bounded `--version` result to that file before minting a lifecycle-capable handle. A missing/mismatched version mints a read-only handle with the qualification command in its error. Test and qualification processes may point `AICODING_KANBAN_QUALIFIED_CLIENTS` at a temporary exact matrix only while `KANBAN_URL` is loopback and `KANBAN_TEST_TOKEN` is set; production ignores the override otherwise.

The expected file shape, if the planning-time binaries pass unchanged, is:

```json
{
  "schema": 1,
  "clients": {
    "claude": ["2.1.268"],
    "codex": ["0.154.0"],
    "cursor": ["2026.09.10-fd3934a"],
    "opencode": ["1.18.30"]
  }
}
```

If an installed version differs, record the observed passing value instead; never copy this example without a passing real-client report.

`tools/qualify-kanban-clients --all` exits zero only when all four installed real clients pass. `--client NAME` supports focused reruns. This command does not enable enforcement or touch production. Document that rollout must remain in compatibility mode until the four reports pass and the separately scoped live lifecycle verification is explicitly authorized.

- [ ] **Step 7: Run qualification self-tests and the full repository suite**

Run:

```bash
bash tests/bats/run.sh tests/bats/kanban-client-qualification.bats
bash tests/bats/run.sh
```

Expected: both PASS. Confirm the full run uses GNU parallel, reports no leaked processes, and remains network-free under its standard guard environment.

- [ ] **Step 8: Run real-client qualification against the loopback board**

Run: `tools/qualify-kanban-clients --all --output out/kanban-mcp-qualification`

Expected: four `qualified` reports. If any client is `unsupported`, keep enforcement blocked, preserve the concrete redacted setup report, and fix/requalify that setup adapter; changing the supported-client set requires a separate user decision. Record native outcomes only under setup `out/`, setup documentation, the setup matrix, and the coordinated handoff. Do not edit Kanban source or repin solely to record Task 8 outcomes.

- [ ] **Step 9: Review against the approved spec and commit qualification support**

Verify every setup-side spec clause has a test or documented rollout gate: transport secrecy, native binding, call permits, generation fencing, activity bounds, queue ordering, stop/end/expiry behavior, all clients, pinning, canonical guidance, config preservation, and no production writes.

```bash
git add tools/qualify-kanban-clients configs/kanban/qualified-clients.json tests/qualification \
  tests/bats/kanban-client-qualification.bats docs/kanban-mcp-qualification.md \
  README.md docs/agent-parity.md
git commit -m "test(kanban): qualify native client lifecycles"
```

### Task 9: Final independent review and coordinated handoff

**Files:**
- Modify only files required by verified review findings.
- Do not commit `out/kanban-mcp-qualification/`; it is a local deliverable unless the repository's existing ignore policy says otherwise.

**Interfaces:**
- Consumes: all task commits, passing full suite, four real-client reports, Kanban PR API/MCP contract, setup PR #172 final state.
- Produces: review-ready setup PR with honest compatibility/enforcement status and no unverified claims.

- [ ] **Step 1: Rebase/merge the current setup base safely and recheck shared surfaces**

Fetch origin, inspect setup PR #172, and incorporate its final changes without switching the shared checkout. Rerun focused config/install tests after resolving any overlap.

- [ ] **Step 2: Run final verification from clean state**

Run:

```bash
git status --short
bash tests/bats/run.sh
tools/qualify-kanban-clients --all --output out/kanban-mcp-qualification
```

Expected: clean tracked worktree before generated reports, full suite PASS, and four qualified reports. Check `secrets-check KANBAN_TOKEN` only for configured/set status if a separately authorized live smoke follows; never read its value.

- [ ] **Step 3: Request the mandated independent PR review**

Use `review-by-harness` with Claude Opus 5 and high effort against the complete setup diff. Ask it to check the approved spec, cross-repo operation schemas, secret handling, permit normalization, concurrency, queue dominance, hook scopes, config preservation, pin immutability, and qualification honesty. Verify each finding against source before changing code.

- [ ] **Step 4: Fix verified findings with focused tests and rerun full verification**

For each accepted finding, first add or adjust the behavioral test that demonstrates it, make the smallest fix, run the focused test, then rerun `bash tests/bats/run.sh` and affected real-client qualification scenarios. Commit each coherent fix with a message naming the behavior.

- [ ] **Step 5: Prepare the PR handoff without enabling enforcement**

The PR description must state the pinned Kanban SHA, exact client versions qualified, test commands/results, generated report path, same-user trust limitation, and that production enforcement/live lifecycle verification remain rollout steps. Do not merge, deploy, enable enforcement, or perform a production ticket mutation without the user's final approval.

## Preflight dispositions and dependency order

Implement in this cross-repository order: Kanban Tasks 1-4, setup Tasks 1-6, Kanban Task 5 pre-pin loopback acceptance and review, setup Task 7 pin/install, setup Task 8 native qualification, then setup Task 9. Task 8 outcomes stay in setup artifacts/docs; any later Kanban source change requires a new independent review, SHA, pin, and affected qualification rerun.

| Finding | Frozen disposition | Cost and reason | Plan coverage |
| --- | --- | --- | --- |
| Legacy evidence completion | Translate only exact simple `kanban-post --done KEY --evidence TEXT [--reference TEXT ...]` native shell calls into the normal `complete_ticket` permit path; reject ambiguous forms. | One shared strict parser and per-client pre-tool wiring preserve the required recovery syntax without weakening caller identity or permit checks. | Tasks 1, 2, 4, 5, 6 |
| Pin/review cycle | Review setup transport/adapters, run and review Kanban Task 5 directly against those source paths, then pin that Kanban head; keep native outcomes setup-side. | Adds a pre-pin cross-repository gate while avoiding an artificial tracked Kanban change after pin. | Tasks 7, 8, 9 |
| Native adapter ownership | Create shared `lib/kanban_work/adapters.py` in Task 4, extend it in Tasks 5-6, and route hook CLI ingress through it. | Adds one explicit Python module/test suite so native schemas and client output mappings have clear ownership. | Tasks 4, 5, 6 |
| Controller version contract | Require exact `kanban-mcp <installed metadata version>\n` and its Kanban controller test before pinning. | Adds a small controller interface that makes immutable receipts and candidate matrices verifiable. | Task 7; consumed from Kanban Task 4 |
| Qualification bootstrap | Build a temporary exact-version matrix from each real `--version` result and allow it only with loopback plus `KANBAN_TEST_TOKEN`; remove the undefined bypass flag. | Adds a temporary file per run while preserving fail-closed production matching. | Tasks 2, 4-6, 8 |
| Critical-only queue saturation | Persist latest release/end intent on claim/execution state; cap queue indexes at 1024 and reconstruct missing critical delivery after capacity opens. | Adds durable intent columns and reconstruction logic so the finite queue never loses the latest critical state. | Task 3 |
| Replay/cache freshness | Refresh authoritative session and affected ticket after every lifecycle receipt before cache mutation; failed refresh marks cache untrusted and fails closed. | Adds backend reads and retry state, preventing an idempotent old receipt from reviving stale ownership. | Tasks 2, 3 |
| Bridge installation | Install and verify `kanban-work` from container, host, and sync flows; verify host/client readiness includes the later pinned MCP. | Adds host wiring/tests so Cursor and OpenCode cannot be configured with a missing bridge. | Tasks 2, 6, 7 |

## Native contract corrections

These corrections are based on the pinned installed versions' documented/source-backed candidate contracts. They shape fixtures and fail-closed gates; only real loopback client runs can qualify a version.

| Client | Correction | Rationale and cost |
| --- | --- | --- |
| Claude Code 2.1.268 | Add clear/fork start fixtures, keep compact in-generation, retain native failure and child IDs, and block parent release for reported background work. | Adds fixture branches and state checks while using fields the client actually emits. |
| Codex 0.154.0 | Remove `PostToolUseFailure`; close long unified exec by the original call ID's eventual post, with bounded conservative failure reconciliation as a qualification gate. | Avoids an invented event at the cost of unresolved-call tracking and possible read-only qualification. |
| Cursor Agent 2026.09.10-fd3934a | Use generic fail-closed `preToolUse` as the sole MCP permit minter and generic post events for close; never invent a child ID at stop. | Removes duplicate interception and adds a real child-correlation/local-surface qualification gate. |
| OpenCode 1.18.30 | Use wrapper `sessionID`/`callID`, flattened MCP names, child `info.parentID`, and bounded CLI version lookup; remove MCP metadata/plugin-version assumptions. | Adds explicit idle/failure/resume/active-child gates and may leave the version read-only when native events cannot prove safe reconciliation. |
