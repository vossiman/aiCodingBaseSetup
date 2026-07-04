#!/usr/bin/env bash
# Run all aiCodingBaseSetup bats tests. Exports BLUEPRINT_ROOT so tests can
# locate the library being tested.
set -euo pipefail
cd "$(dirname "$0")/../.."
export BLUEPRINT_ROOT="$PWD"

# --- Keep the suite offline & non-hanging in the devcontainer ----------------
# Tests run the real install.sh / sync.sh, which otherwise reach the network.
# Two recurring hang sources, neutralised here so every test (including ones
# added later) inherits the guard rather than re-deriving its own stub list:
#
#  1. Network provisioning in install.sh pulls external tooling: a Chromium
#     browser (`npx playwright install`), the Claude/opencode/codex installers,
#     Go, uv, the TPM tmux plugins, and the bw-AICode vendor clone.
#     AICODINGSETUP_SKIP_NETWORK=1 makes install.sh skip every one of those —
#     the config-deploy + reconcile logic the tests exercise still runs. Gating
#     at the source (one flag) means a NEW test that runs install.sh inherits the
#     guard instead of having to re-stub the right set of network commands.
#  2. git-over-SSH to github.com (refresh_blueprint's fetch, ls-remote) hangs
#     for the full SSH timeout when the forwarded ssh-agent has rotated stale
#     (a known every-few-days devcontainer quirk). BatchMode + a short
#     ConnectTimeout turn that into a fast, fail-open miss → cached-clone
#     fallback, which the tests already expect.
export AICODINGSETUP_SKIP_NETWORK=1
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1}"

bats tests/bats/*.bats
