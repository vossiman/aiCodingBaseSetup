#!/usr/bin/env bash
# Single entrypoint for the aiCodingBaseSetup bats suite. ALWAYS run tests
# through this script — never `bats` by hand. Everything a correct run needs
# is encoded here so nobody has to re-derive it per invocation:
#   - BLUEPRINT_ROOT + the offline/non-hang env guards (see below)
#   - bats discovery (PATH first, `npx --yes bats` fallback — bats is not
#     preinstalled in the devcontainer)
#   - parallel execution across all cores when GNU parallel is available
#   - per-test timing (--timing) so slow tests stay visible
#
# Usage:
#   tests/bats/run.sh                     # full suite, parallel
#   tests/bats/run.sh install sync        # only tests/bats/{install,sync}.bats
#   tests/bats/run.sh --jobs 1            # serial (debugging races)
#   tests/bats/run.sh -f 'lfs'            # bats test-name regex filter
# Bare words select test files by basename; flags pass through to bats.
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
# Point the lfs-autopull probe at a nonexistent file so install.sh runs inside
# tests never touch the container's real /usr/local/share script or write lfs
# hooks into the real repo checkout (cwd during tests is BLUEPRINT_ROOT).
# lfs-autopull.bats overrides this per-test with its own fixture.
export AICODINGSETUP_LFS_PULL_SCRIPT=/nonexistent-lfs-pull-script
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1}"

# --- bats discovery ----------------------------------------------------------
# npx caches the package after the first download, so the fallback costs ~1s,
# not a reinstall per run.
if command -v bats &>/dev/null; then
  BATS=(bats)
else
  BATS=(npx --yes bats)
fi

# --- arguments: bare words = test files, flags pass through to bats ----------
files=() passthru=() user_set_jobs=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jobs)
      user_set_jobs=1; passthru+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    -f|--filter|--filter-status|--filter-tags|--negative-filter)
      passthru+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    -*)
      passthru+=("$1"); shift ;;
    *)
      f="tests/bats/${1%.bats}.bats"
      [[ -f "$f" ]] || { echo "run.sh: no such test file: $f" >&2; exit 2; }
      files+=("$f"); shift ;;
  esac
done
[[ ${#files[@]} -gt 0 ]] || files=(tests/bats/*.bats)

# --- parallel by default ------------------------------------------------------
# bats --jobs needs GNU parallel specifically — the universal image ships
# moreutils' incompatible /usr/bin/parallel (rejects long options, suite runs
# 0 tests), hence the explicit "GNU parallel" version probe. install.sh
# provisions the real one in container mode. Every test sandboxes itself
# (mktemp HOME, stubbed sudo/apt/curl), so tests are independent; if a
# parallel-only failure ever appears, that test has a sandbox leak — fix the
# test, don't serialise the suite. The will-cite touch suppresses GNU
# parallel's one-time citation prompt non-interactively.
if [[ $user_set_jobs -eq 0 ]] && parallel --version 2>/dev/null | head -1 | grep -q "GNU parallel"; then
  mkdir -p "$HOME/.parallel" && touch "$HOME/.parallel/will-cite"
  passthru+=(--jobs "$(nproc)")
fi

exec "${BATS[@]}" --timing "${passthru[@]}" "${files[@]}"
