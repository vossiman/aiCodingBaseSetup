# Secrets store: prompt for missing keys, never rewrite

Status: draft rev 2, 2026-11-22, after a Codex `gpt-6.2-astra` review.
Ticket AICODINGBASESETUP-111, PR #289.

## Problem

`load_or_prompt_secrets()` in `lib/provision-secrets.sh` deletes keys from
`~/.aicodingsetup/.secrets.env`. When it can prompt, it rebuilds the file
from scratch and writes only the keys listed in `.secrets.env.example`
(guard at line 72, write loop at line 79). Every other key, every comment
and the key order are lost.

The owner keeps the same 11 keys on every machine (Surface laptop, Mint
desktop, devpod containers):

```
GH_TOKEN  KANBAN_TOKEN  FIRECRAWL_API_KEY  BRAVE_API_KEY
CLOUDFLARE_API_TOKEN  CLOUDFLARE_ACCOUNT_ID  BUGSINK_AUTH_TOKEN
LOGFIRE_READ_API_TOKEN  MEMORY_WRITE_TOKEN
LEANIPTV_DIAG_TOKEN_PROD  LEANIPTV_DIAG_TOKEN_STAGING
```

On `main` the example lacks `BUGSINK_AUTH_TOKEN` and
`LOGFIRE_READ_API_TOKEN`, so the next interactive install deletes both. It
went unnoticed because no interactive host install has run in months.

## Where the function runs today

Prompting is allowed when stdin is a tty, `ENV_TYPE` is not `container`,
and `AICODINGSETUP_NONINTERACTIVE` is not `1` (lines 39-42).

| Path | Caller | Can prompt | Effect on an existing file |
|---|---|---|---|
| Update (`aicoding-sync`, six-hourly scheduler) | `load_secrets_env` (`lib/blueprint-deploy.sh:174`, called at `lib/sync.sh:644`, `:791`) sources the file | n/a | read only |
| Container install | `install.sh:99` | no | untouched (line 72 guard); the file is also a read-only bind mount |
| Host install (WSL, Mint) | `install-host.sh:160` | yes, with a tty | **rebuilt from the example's keys** |
| `install.sh` run by hand on a non-container Linux box with a tty | `install.sh:99` | yes | **rebuilt** |
| Any install, no file yet | either | either | created from the example's keys |

## Why the rewrite exists

The function is bootstrap code: on a new machine there is no file, so it
asks for each key and writes one. Rebuilding an existing file dates from
when the example was the complete list of keys. Since then helpers and
other repos (`bin/bugsink-api`, `bin/dokploy-api`, `bin/kuma-admin`,
`bin/leaniptv-diag`, memory-lanes) have added keys to the same file, and the
example has not kept pace. The rewrite turns the example into an allowlist,
which nobody intends.

## Design

The example's meaning changes: it lists the keys a **fresh machine is asked
for**, not the keys **allowed to survive**.

1. **Never rebuild an existing file.** Append only the keys the user was
   just prompted for, including ones they skipped (`KEY=`), so a second run
   does not ask again. Every existing byte stays as it was.
2. **Append in place.** Use `>>`, never a temp file plus rename: containers
   bind the single file, which pins its inode. If the file does not end in a
   newline, write one first; then one blank separator line, then the new
   keys.
3. **Create only when missing**, with `umask 077` around the create so the
   file is mode 600 from its first open, not after a later `chmod`.
4. **Serialize writers.** Take `flock` on `$SECRETS_DIR/.secrets.lock` for
   the read-prompt-write sequence and re-read the file under the lock before
   writing. Two installs on one host are unlikely, but the lock is three
   lines and rules out duplicate keys or a truncated create.
5. **Fail loudly on a read-only store.** If the append or create fails,
   `err` and return non-zero; never print "Secrets saved". When nothing
   needs writing, the file is never opened for writing.
6. **Fix the reader.** The current `IFS='=' read -r key value` loop drops a
   trailing `=` from a value (`K=abc=` reads as `abc`, verified in bash)
   and skips an unterminated last line, which would then be prompted for
   and appended a second time. Replace it with: read whole lines including
   an unterminated last one (`|| [[ -n $line ]]`), strip a trailing CR,
   ignore blank and `#` lines, accept an optional `export ` prefix, split
   once at the first `=` (`${line%%=*}` / `${line#*=}`), and skip keys that
   are not valid identifiers with a warning naming the line number, never
   the value. Quoting is left alone: values are stored and read raw, as all
   current readers (`bin/*` helpers, `memory-hint`, `load_secrets_env`)
   already expect.
7. **Reject unsafe prompt input.** `load_secrets_env` sources the file as
   shell, so a typed value containing whitespace, quotes, `$`, backtick or
   backslash could break or execute during sync. Tokens never contain
   these; refuse such input and re-prompt.
8. **Exports stay as they are:** only the example's keys (line 91). Rev 1
   proposed exporting every key in the file; that would hand unrelated
   credentials to every package and plugin process the installer spawns,
   and a key named like `PATH` would change installer behaviour. Install's
   only consumer is the renderer, which uses named placeholders
   (`lib/blueprint-deploy.sh:240`); helpers read the file themselves.
9. **Example file contents** become the owner's 11 keys, each with a short
   comment naming its reader. `DOKPLOY_API_TOKEN` and the Kuma keys that
   PR #289 added come out again: nothing asks for them on a fresh machine,
   and once the rewrite is gone they survive anyway. Add
   `LOGFIRE_READ_API_TOKEN` to the `configs/bash/env.sh` unset list.

## Tests

The interactive path needs explicit setup: host bats forces
`AICODINGSETUP_NONINTERACTIVE` and redirects stdin
(`tests/bats/install-host.bats:14`, `:95`). Source
`lib/provision-secrets.sh` in an isolated `$HOME`, clear the opt-out, set
`ENV_TYPE=linux`, and drive the function under `script -qc` with synthetic
answers on stdin.

- Existing file holding an unknown key, a comment and a custom order: the
  original bytes are an exact prefix of the result, only prompted keys are
  appended, the inode is unchanged.
- File without a trailing newline: the append starts on a new line.
- Skipped prompt is written as `KEY=`; a second run asks nothing and leaves
  the file byte-identical.
- Reader: `K=abc=`, CRLF lines, `export K=v`, an unterminated last line and
  an invalid key name are parsed as specified.
- Prompt input with a space or `$` is refused.
- Fresh create: exactly the example's keys, mode 600.
- Read-only file with a missing key: non-zero, no "saved" message.
- Keep `install.bats:956` (non-interactive install leaves the file
  byte-identical).
- Replace PR #289's helper-membership regression
  (`tests/bats/regressions.bats:257`) with the behaviour tests above.

## Not changing

- `load_secrets_env` and the update path.
- The deny hook and the read-only container mount.
- The "empty means skipped" rule.

## Open question

**`MEMORY_ROUTER_TOKEN`.** The owner does not set it. `MEMORY_WRITE_TOKEN`
already wins for MCP config (`lib/provision.sh:560`,
`lib/blueprint-deploy.sh:227`), but `configs/memory/memory-hint:43` reads
only `MEMORY_ROUTER_TOKEN`, so automatic hints have no token on the owner's
machines. Recommendation: make `memory-hint` fall back to
`MEMORY_WRITE_TOKEN` (it also authorizes search) and drop
`MEMORY_ROUTER_TOKEN` from the example, which then matches the 11 keys
exactly. The alternative is to keep it and set it everywhere (12 prompts).
