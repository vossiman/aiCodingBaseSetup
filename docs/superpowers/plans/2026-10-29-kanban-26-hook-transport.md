# KANBAN-26 Hook Transport Implementation Plan

> **For agentic workers:** execution follows dev-process-lite. The overseer assigns each task to an implementer subagent in its own worktree, branched from `kanban-26-hook-transport`, and merges accepted tasks back into that branch. One integrated cross-vendor review runs at the end. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lifecycle hooks reach the board through an in-process transport inside `kanban-work`, and `kanban-post` with its legacy completion translator is gone from the blueprint.

**Architecture:** `HttpTransport` in `lib/kanban_work/transport.py` replaces `SubprocessTransport`. It carries over `bin/kanban-post`'s credential rules (store read in process, pinned host, loopback-only override with a test token, no redirects, scrubbed errors) for exactly six lifecycle operations. `kanban-work selftest` replaces `kanban-post --selftest`. Then the binary, the legacy translator, the installer and every text reference go, and provisioning removes the stale `~/.local/bin/kanban-post` symlink.

**Tech Stack:** Python 3 standard library (`urllib.request`, `http.server` in tests), `unittest`, bash, bats via `tests/bats/run.sh`.

**Spec:** kanban repo, `docs/superpowers/specs/2026-10-29-mcp-only-entrypoint-design.md` (commit `a13033b` on branch `kanban-26-mcp-only`), section 4 and tasks B1 to B4. Base: aiCodingBaseSetup `origin/main` `120a999`.

## Global Constraints

- No em dash (the long dash character) in any file this plan touches or in commit messages.
- Run the suite only through `bash tests/bats/run.sh [name]`, never bare `bats`. Python tests run with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest ...` from the worktree root; the release tree is digested and must not gain bytecode.
- No test reaches the network or the real secrets store: tests set `HOME` to a temp dir, `KANBAN_URL` to a loopback fake board and `KANBAN_TEST_TOKEN` to a fake.
- Never read `~/.aicodingsetup/.secrets.env`, never print a token, never run `claude mcp get`.
- The production host stays pinned to `https://kanban.dataprospectors.at`. `KANBAN_URL` is honoured only for `127.0.0.1`, `localhost`, `::1`, and then only `KANBAN_TEST_TOKEN` is sent.
- The transport serves exactly six operations: `register_session`, `session_activity`, `release_active`, `cancel_stop`, `end_session`, `mcp_instructions`.
- Commit trailer: `Co-Authored-By:` naming the model that wrote the commit (for example `Claude Sonnet 5.5 <noreply@anthropic.com>` or `Claude Opus 5.5 <noreply@anthropic.com>`).

## Review Focus

1. **Missing credential.** No secrets store, or a store without `KANBAN_TOKEN`: the transport raises `BridgeError(401, ...)`, the same code `kanban-post` returned (`bin/kanban-post:597`), so the queue's handling does not change. A `KANBAN_TOKEN` in the process environment is ignored. Tests in Task 1.
2. **A board that echoes the credential** in an error body: the raised message contains `<redacted>`, never the token. Test in Task 1.
3. **A redirect** from the board: refused with `BridgeError(502, ...)`, and the Authorization header is not sent to the new location. Test in Task 1.
4. **A non-loopback `KANBAN_URL`**: refused before any request and before the store is read. Test in Task 1.
5. **Upgrade with a leftover `~/.local/bin/kanban-post`**: provisioning removes it when it is a symlink into an aicoding release `bin/kanban-post`, and leaves a regular file or a foreign symlink alone. Tests in Task 3.

---

### Task 1: `HttpTransport` and `kanban-work selftest`

Role: **complex-implementer** (credential handling). Shares no files with Tasks 2 to 4 except that Task 2 later deletes what this task stops using.

**Files:**
- Modify: `lib/kanban_work/transport.py` (replace `SubprocessTransport`, `RELEASE_HELPER`, `_environment`; keep `derive_github_repo`, `fetch_instructions`)
- Create: `lib/kanban_work/selftest.py`
- Modify: `lib/kanban_work/queue.py:12,40`, `lib/kanban_work/__init__.py:8,12`, `bin/kanban-work` (`main`, new `selftest` branch)
- Create: `tests/python/test_kanban_work_transport.py`
- Modify: `tests/bats/kanban-work.bats` (one new test)

**Interfaces:**
- Produces:
  - `LIFECYCLE_OPERATIONS: frozenset[str]` (the six names above).
  - `class HttpTransport:` `__init__(self, *, home: Path | None = None, environ: Mapping[str, str] | None = None)`; defaults are `Path.home()` and `os.environ`. `__call__(self, operation: str, payload: dict, *, timeout: float = DEFAULT_TIMEOUT) -> dict | list`. Raises `ValueError` for an operation outside `LIFECYCLE_OPERATIONS` (programming error, never sent) and `BridgeError(code, message)` for everything the board or network does.
  - `fetch_instructions(transport=None, *, timeout=3.0)` keeps its signature, defaulting to `HttpTransport()`.
  - `lib/kanban_work/selftest.py: run_selftest() -> int` (0 on success; prints `selftest: ok` or one `FAIL <reason>` line per failure).
- Consumes: `BridgeError(code: int, message: str)` from `lib/kanban_work/schema.py`.

Routes (copy from `bin/kanban-post:426-494`):

| operation | method | path | body |
| --- | --- | --- | --- |
| `register_session` | POST | `/api/work/sessions` | payload |
| `session_activity` | POST | `/api/work/sessions/{id}/activity` | payload minus `work_session_id` |
| `release_active` | POST | `/api/work/sessions/{id}/release-active` | same |
| `cancel_stop` | POST | `/api/work/sessions/{id}/cancel-stop` | same |
| `end_session` | POST | `/api/work/sessions/{id}/end` | same |
| `mcp_instructions` | GET | `/api/mcp/instructions` | none |

`{id}` is `urllib.parse.quote(work_session_id, safe="")`; a missing or non-string `work_session_id` is a `ValueError`. Field validation that `kanban-post` did on these payloads is not carried over: the payloads are built in this package and the board validates them.

Error mapping (keeps `SubprocessTransport`'s contract, `transport.py:41-57`): HTTP status >= 400 raises `BridgeError(status, detail)` where `detail` is the body's `detail` string, else its compact JSON, else `"board returned HTTP error"` (as `bin/kanban-post:560-570`); socket timeout raises `BridgeError(504, "kanban transport timed out")`; any other network failure `BridgeError(502, "cannot reach the board: <reason>")`; a success body that is not a JSON object or array raises `BridgeError(502, "kanban transport returned invalid success data")`. Every message passes through a scrub that replaces the token in use with `<redacted>`, and so does every successful response: the decoded success data is scrubbed (each string in it) before `__call__` returns it, as `bin/kanban-post:202-205` scrubs all output (design review finding 1: `fetch_instructions` puts success data into agent context, `adapters.py:65`). Deadline: `timeout` bounds the whole call, connection, headers and body together, as the subprocess timeout does today (`transport.py:35`); read the body in chunks and raise `BridgeError(504, "kanban transport timed out")` once `time.monotonic()` passes the deadline, and set each socket timeout to the time left (design review finding 2: urllib's timeout is per socket operation, so a slowly streaming body could outlast the hook budget).

- [ ] **Step 1: Write the failing tests** in `tests/python/test_kanban_work_transport.py`, using `tests.python.fake_board.FakeBoardServer`, `TOKEN`, `INSTRUCTIONS` plus a small local `http.server` for hostile answers:
  - `test_each_lifecycle_operation_reaches_its_route`: for all six operations, the fake board records the expected method and path; `register_session` sends the full payload; the others omit `work_session_id` from the body.
  - `test_mcp_instructions_returns_board_text`: `fetch_instructions(HttpTransport(home=..., environ=env))` equals `INSTRUCTIONS`.
  - `test_unknown_operation_is_a_value_error_and_sends_nothing`: `create_ticket` raises `ValueError`; the board saw zero requests.
  - `test_board_error_carries_status_and_detail`: a 409 with `{"detail": "conflict"}` raises `BridgeError` with `code == 409` and message `"conflict"`.
  - `test_echoed_token_is_redacted`: a 500 whose detail is the Authorization header value; `TOKEN not in str(error)` and `"<redacted>" in error.message`.
  - `test_redirect_is_refused_and_not_followed`: a 302 to a second loopback server; raises `BridgeError` with `code == 502`; the second server saw no request.
  - `test_non_loopback_override_is_refused_before_any_request`: `KANBAN_URL=https://kanban.example.invalid`; raises `BridgeError` whose message contains `loopback`; no socket opened (patch `urllib.request.OpenerDirector.open` to fail the test if called).
  - `test_test_url_requires_test_token`: `KANBAN_URL` set, `KANBAN_TEST_TOKEN` unset, a store holding `KANBAN_TOKEN=real-looking`; raises `BridgeError(401, ...)` and the store value is never sent.
  - `test_missing_store_or_token_is_401`: no `KANBAN_URL`, `home` without `.aicodingsetup/.secrets.env`, and separately a store without the key; both raise `BridgeError` with `code == 401`, and an `environ` holding `KANBAN_TOKEN=from-env` changes nothing.
  - `test_store_token_is_sent_as_bearer`: no `KANBAN_URL`; patch the default base URL to the fake board (module constant `DEFAULT_URL`) and write a store with `KANBAN_TOKEN="<TOKEN>"` (quotes stripped, as `bin/kanban-post:143`); the request carries `Authorization: Bearer <TOKEN>`.
  - `test_timeout_is_504`: a server that never answers, `timeout=0.2`; `code == 504`.
  - `test_slow_streaming_body_hits_the_deadline`: a server that sends headers, then one body byte every 0.1 s for 5 s; `timeout=0.5`; raises `BridgeError` 504 and the call returns within 1.5 s.
  - `test_token_echoed_in_a_success_body_is_redacted`: a 200 `{"instructions": "Bearer <TOKEN>"}` for `mcp_instructions`; `fetch_instructions` returns text with `<redacted>` and without the token; `kanban-work` stdout and stderr captured in the same run do not contain the token.
  - `test_empty_success_body_is_502`.
- [ ] **Step 2: Run them to see them fail.** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work_transport` fails with `ImportError: cannot import name 'HttpTransport'`.
- [ ] **Step 3: Implement `HttpTransport`** in `lib/kanban_work/transport.py` per the tables above. Port `base_url`, `token` and `NoRedirects` from `bin/kanban-post:94-147,214-221` as private functions that read `self.environ` and `self.home` and raise `BridgeError` instead of exiting; the redirect handler raises `BridgeError(502, "refusing to follow a redirect")`. Read the store only when `KANBAN_URL` is unset. Change the module docstring to describe the in-process transport. Switch `queue.py` and `__init__.py` to `HttpTransport` (export name `HttpTransport` replaces `SubprocessTransport`).
- [ ] **Step 4: Run the new tests and the existing package tests.** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -s tests/python -p 'test_kanban_work*.py'` passes. `test_kanban_work_e2e.py` now exercises `HttpTransport` through the real `bin/kanban-work` against `FakeBoardServer` with no change to its hook tests.
- [ ] **Step 5: Write the selftest test.** Add to `tests/bats/kanban-work.bats`: `@test "kanban-work selftest proves the credential rules"` running `env PYTHONDONTWRITEBYTECODE=1 "$BLUEPRINT_ROOT/bin/kanban-work" selftest`, asserting status 0 and output containing `selftest: ok`. Run `bash tests/bats/run.sh kanban-work`; it fails.
- [ ] **Step 6: Implement `run_selftest()`** in `lib/kanban_work/selftest.py`, modelled on `bin/kanban-post:639-750`: a throwaway `HOME` with a store holding a fake token, a loopback server that echoes Authorization in a 500 body and serves a 302 on `/redirect`; checks that the echoed token is redacted from the raised message, that the redirect is refused and Authorization reached only the first server, and that `https://kanban.example.invalid` is refused. It calls `HttpTransport` in process with explicit `home` and `environ`, never the real store. Wire `bin/kanban-work`: `sys.argv[1:] == ["selftest"]` returns `run_selftest()` as the exit code.
- [ ] **Step 7: Run** `bash tests/bats/run.sh kanban-work` (passes) and `bash tests/bats/run.sh` (full suite green; at this point `kanban-post` still exists and its own tests still pass).
- [ ] **Step 8: Commit** `feat: kanban-work reaches the board in process (KANBAN-26)`.

### Task 2: Delete `kanban-post` and the legacy completion translator

Role: **implementer**. Depends on Task 1. Shares `tests/bats/opencode-kanban-plugin.bats` and `tests/bats/cursor-kanban-hooks.bats` with no other task.

**Files:**
- Delete: `bin/kanban-post`, `lib/kanban_work/legacy.py`, `tests/bats/kanban-post.bats`, `tests/python/test_kanban_post_json.py`, `tests/python/test_kanban_work_legacy.py`
- Modify: `lib/kanban_work/adapters.py:18` (import), `:466-487` (Claude and Codex `_tool_start`: drop `prepared_command` and the `updatedInput` rewrite), `:1100-1130` (OpenCode `_tool_before`: drop `prepared_command`, the `DENIAL` raise and the `args` rewrite)
- Modify: `configs/opencode/plugins/kanban-work.js:107-115,172` and its `LEGACY_GUIDANCE` constant
- Modify: `tests/python/test_kanban_work_adapters.py` (legacy cases near `:596-678`, `:1018-1063`, `:1306-1310`), `tests/python/test_kanban_work_e2e.py` (docstring `:1`, `run_post` and the three completion tests near `:250-280`), `tests/python/test_kanban_work_queue.py:35` (docstring), `tests/bats/opencode-kanban-plugin.bats`, `tests/bats/cursor-kanban-hooks.bats`

**Interfaces:**
- Consumes: `HttpTransport` from Task 1 (nothing in the package may import or spawn `kanban-post` after this task).

- [ ] **Step 1: Replace the legacy tests** with pass-through tests: in `test_kanban_work_adapters.py` add `test_kanban_post_command_is_not_rewritten` for Claude, Codex and OpenCode, asserting that a shell call `kanban-post --done KANBAN-2 --evidence ok` produces no `updatedInput` (Claude/Codex) and no `args` (OpenCode), and no `DENIAL` error. Delete the cases that assert rewriting or denial. In the OpenCode plugin bats, replace the legacy-guidance test with one asserting a `kanban-post` bash call is not blocked.
- [ ] **Step 2: Run** `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v tests.python.test_kanban_work_adapters`; the new tests fail.
- [ ] **Step 3: Delete the files and the call sites listed above.**
- [ ] **Step 4: Run** the kanban-work Python suite and `bash tests/bats/run.sh opencode-kanban-plugin cursor-kanban-hooks kanban-work`; all pass.
- [ ] **Step 5: Commit** `refactor: remove kanban-post and its legacy completion path (KANBAN-26)`.

### Task 3: Install, sync and stale-symlink removal

Role: **implementer**. Independent of Task 2's files; may run in parallel with Tasks 2 and 4 after Task 1. Owns every edit to `lib/provision-integrations.sh`, including its comments.

**Files:**
- Modify: `lib/provision-integrations.sh:143-160` (delete `install_kanban_post_symlink` and its comment block; rewrite the `install_kanban_work_symlink` comment: "reads the board credential in process"), `:187`, `:260` (comments name `kanban-work` instead of `kanban-post`)
- Modify: `install.sh:143`, `install-host.sh:192`, `lib/sync.sh:892` (drop the call), `lib/sync.sh:930` (drop `kanban-post` from the artifact list)
- Modify: `lib/provision.sh` (new `_provision_remove_kanban_post`, called beside `_provision_remove_local_kanban_mcp` at `:683`)
- Test: `tests/bats/install.bats`, `tests/bats/install-host.bats`, `tests/bats/sync.bats`

**Interfaces:**
- Produces: `_provision_remove_kanban_post()` in `lib/provision.sh`. Removes `$HOME/.local/bin/kanban-post` only when it is a symlink whose target path ends in `/bin/kanban-post` and lies under `${AICODING_DATA_DIR:-$HOME/.local/share/aicoding}` or the blueprint checkout (`$SCRIPT_DIR`). Never fails (returns 0); prints `info "kanban-post: removed the retired board client"` when it removed something.

- [ ] **Step 1: Write the failing tests:** in `install.bats` and `install-host.bats`, assert a fresh install leaves no `~/.local/bin/kanban-post`; in `sync.bats`, three tests: a stale symlink into a release `bin/kanban-post` is removed; a regular file at that path is kept; a symlink to `/usr/local/bin/kanban-post` is kept. Update any existing assertion that expects the symlink.
- [ ] **Step 2: Run** `bash tests/bats/run.sh install install-host sync`; the new tests fail.
- [ ] **Step 3: Implement** the deletions and `_provision_remove_kanban_post` (model it on `_provision_remove_local_kanban_mcp`, `lib/provision.sh:437-454`).
- [ ] **Step 4: Run** `bash tests/bats/run.sh install install-host sync`; all pass.
- [ ] **Step 5: Commit** `chore: stop installing kanban-post and remove the stale link (KANBAN-26)`.

### Task 4: Instructions, docs and the deny-hook allowlist

Role: **implementer, low effort** (mechanical text). Parallel with Tasks 2 and 3 after Task 1. Must not touch `lib/provision-integrations.sh` (Task 3 owns it).

**Files:**
- Modify: `configs/claude/CLAUDE.md:88`, `configs/codex/AGENTS.md:103`, `configs/cursor/skills/aicoding-estate/SKILL.md:52` (drop the "`kanban-post` remains a credential-safe recovery CLI" sentence; keep the MCP workflow text)
- Modify: `README.md:84-88,270`, `.secrets.env.example:20` (`KANBAN_TOKEN` is read by `kanban-work`), `docs/agent-parity.md:73`
- Modify: `skills/review-by-harness/prompts/{agents-fix,agents-review,fix,review}.md` ("never call the kanban MCP write tools" replaces "never run `kanban-post`"), `skills/review-by-harness/SKILL.md:267` (the kanban MCP `list_tickets` after a run is the board check, replacing `kanban-post --list-tickets`)
- Modify: `configs/claude/hooks/bw-deny-files.sh:169` (remove `kanban-post` from `NON_READER_COMMANDS`)
- Modify: comments in `bin/dokploy-api`, `bin/kuma-admin`, `bin/measure-remote`, `configs/cloudflare/cloudflare-render`, `configs/memory/memory-hint` ("same shape as kanban-post" names `git-credential-aicoding` or `kanban-work`), `lib/kanban_work/events.py:23`
- Test: `tests/bats/secrets-deny-hook.bats:742-814` (the nine `kanban-post` examples become `printf`), `tests/bats/review-by-harness.bats`, `tests/bats/memory-hint.bats`, `tests/bats/initial-mcp-gate.bats:135` (keep it: it guards that guidance names no `kanban-post` command)

- [ ] **Step 1: Update the tests first:** switch the deny-hook examples to `printf`, and update any review-by-harness or memory-hint assertion that quotes the old wording to the new wording.
- [ ] **Step 2: Run** `bash tests/bats/run.sh secrets-deny-hook review-by-harness memory-hint initial-mcp-gate`; the changed assertions fail.
- [ ] **Step 3: Edit the files listed above.**
- [ ] **Step 4: Run** the same command; all pass.
- [ ] **Step 5: Commit** `docs: drop kanban-post from instructions and allowlists (KANBAN-26)`.

### Task 5: Integration check (overseer)

- [ ] **Step 1:** Merge Tasks 2 to 4 into `kanban-26-hook-transport`.
- [ ] **Step 2:** `git grep -n kanban-post -- ':!docs/superpowers/plans/2026-09-*'` lists only `_provision_remove_kanban_post`, its tests, the pass-through tests from Task 2 and `initial-mcp-gate.bats`. Dated plans from September stay as history.
- [ ] **Step 3:** `bash tests/bats/run.sh` is green, and `bin/kanban-work selftest` prints `selftest: ok`.
