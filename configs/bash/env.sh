# aiCodingBaseSetup — container-wide environment variables.
# Sourced from ~/.bashrc via the aicoding managed block in ~/.bashrc.
# Add export lines here; they apply to every container deployed from
# this blueprint after running install.sh or aicoding-sync.

# NO SECRET IS EXPORTED HERE (2026-08-27). This file used to source
# ~/.aicodingsetup/.secrets.env with `set -a`, putting every key in the
# environment of every shell, and then unset GH_TOKEN/GITHUB_TOKEN again.
#
# That half-measure was measured and found wanting: on 2026-08-27 a
# `docker compose config` run — an ordinary, read-only command that renders
# resolved values — printed a live OPENROUTER_API_KEY into an agent
# transcript, because compose interpolates ${VAR} from the shell environment.
# GH_TOKEN was the only key safe from that, and only because of the unset
# below. The deny hook stops `printenv`/`env`/`gh auth token`; it cannot stop
# every tool that happens to expand a variable it was legitimately given.
#
# Nothing in this blueprint needs the export. Each consumer already reads the
# secrets file directly, which is why removing GH_TOKEN broke nothing either:
#   git            — git-credential-aicoding reads the file per request.
#   gh             — ensure_gh_stored_auth (lib/sync.sh) logs in from the file
#                    on every boot sync; gh then uses ~/.config/gh/hosts.yml.
#   MCP configs    — substitute_secrets / _substitute_file_to
#                    (lib/blueprint-deploy.sh) expand {{FIRECRAWL_API_KEY}} &
#                    co. at DEPLOY time, and load_secrets_env sources the file
#                    itself for that. It never used the interactive shell.
#   memory-hint    — reads MEMORY_ROUTER_TOKEN from the file when the env var
#                    is absent (configs/memory/memory-hint) — the pattern to
#                    copy for anything new.
#   memory-lanes   — scripts/stack-env.sh reads the file directly.
#
# If you genuinely need a value in YOUR OWN shell, scope it to one command
# rather than to every process you will ever start:
#
#   OPENROUTER_API_KEY="$(sed -n 's/^OPENROUTER_API_KEY=//p' \
#     ~/.aicodingsetup/.secrets.env)" some-command
#
# Agents must not do that: the deny hook blocks reading the file, and a value
# in an agent's transcript outlives the session. Have the agent run a script
# that mints/consumes the secret in one process and prints only a status.
#
# The unsets are belt-and-braces: they clear anything an earlier ~/.bashrc.d
# fragment, a parent process, or a devcontainer `remoteEnv` may have exported.
# The list covers every key in .secrets.env.example plus the ones other repos
# keep in the same file (LOGFIRE_TOKEN, DOKPLOY_API_TOKEN, KANBAN_TOKEN). Add
# new keys here too — but note the sourcing is gone, so a key that is NOT
# listed is no longer exported either; these lines only undo someone else's
# export.
unset GH_TOKEN GITHUB_TOKEN
unset FIRECRAWL_API_KEY BRAVE_API_KEY
unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
unset MEMORY_ROUTER_TOKEN OPENROUTER_API_KEY
unset LOGFIRE_TOKEN DOKPLOY_API_TOKEN KANBAN_TOKEN

# DISPLAY default for the dvw clipboard bridge (2026-08-28). cursor-agent
# only tries its `xclip ... -o` paste candidates when DISPLAY is set, so a
# container without one never consults the clip-shim at all. There is no X
# server here — :0 is a signpost, not a promise; tools that exec xclip get
# the shim, tools that speak X11 directly fail exactly as before. If a
# future codex route runs Xvfb, :0 is where it will live. Only defaulted,
# never overridden (X11-forwarded sessions keep theirs).
export DISPLAY="${DISPLAY:-:0}"
