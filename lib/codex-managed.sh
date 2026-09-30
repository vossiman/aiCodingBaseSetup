# lib/codex-managed.sh - Codex managed hooks under /etc/codex.
#
# Sourced by provision-system.sh (install/sync, as the user) and by the host
# root runner's task (root/tasks.d, as root). It must stay side-effect free
# when sourced: no environment detection, no output, no other libraries.
# Callers provide the loggers (header/info/ok/warn) and, when escalation is
# possible, SUDO.

CODEX_MANAGED_DIR="${CODEX_MANAGED_DIR:-/etc/codex}"
CODEX_MANAGED_MARKER="# aiCodingBaseSetup managed file"
# The host root runner (root/) owns /etc/codex once it is installed.
AICODING_ROOT_RUNNER="${AICODING_ROOT_RUNNER:-/usr/local/libexec/aicoding-root/runner}"
AICODING_ROOT_TRIGGER="${AICODING_ROOT_TRIGGER:-/run/aicoding-root/trigger}"
AICODING_ROOT_STATUS="${AICODING_ROOT_STATUS:-/var/lib/aicoding-root/status}"

# Every script requirements.toml references, all from configs/claude/hooks:
# codex runs the same hook contract, so the same files serve both CLIs.
CODEX_MANAGED_HOOKS=(bw-deny-files.sh kanban-work-hook.sh redact-sessions-hook.sh
  redact-sessions-pending.sh memory-hint.sh check-archived-docs.sh agent-working.sh)

# codex_managed_state <blueprint-root>: compare /etc/codex with the blueprint.
# 0 current, 1 needs writing, 2 blueprint sources missing, 3 requirements.toml
# exists but this blueprint did not write it (an admin may own it).
codex_managed_state() {
  local root=$1 dir="$CODEX_MANAGED_DIR" h rendered
  for h in "${CODEX_MANAGED_HOOKS[@]}"; do
    [[ -f "$root/configs/claude/hooks/$h" ]] || return 2
  done
  [[ -f "$root/configs/codex/requirements.toml" ]] || return 2
  if [[ -f "$dir/requirements.toml" ]] \
      && ! grep -qF "$CODEX_MANAGED_MARKER" "$dir/requirements.toml" 2>/dev/null; then
    return 3
  fi
  rendered=$(sed "s|{{MANAGED_DIR}}|$dir|g" "$root/configs/codex/requirements.toml")
  [[ -f "$dir/requirements.toml" && "$rendered" == "$(cat "$dir/requirements.toml" 2>/dev/null)" ]] || return 1
  for h in "${CODEX_MANAGED_HOOKS[@]}"; do
    cmp -s "$root/configs/claude/hooks/$h" "$dir/hooks/$h" || return 1
  done
  return 0
}

# codex_managed_write <blueprint-root> [escalation-prefix]: write /etc/codex.
# Root-owned and not user-writable on purpose: a hook script an agent can edit
# is a hook an agent can neuter.
codex_managed_write() {
  local root=$1 esc=${2:-} dir="$CODEX_MANAGED_DIR" h rendered
  rendered=$(sed "s|{{MANAGED_DIR}}|$dir|g" "$root/configs/codex/requirements.toml")
  $esc mkdir -p "$dir/hooks" || { warn "cannot create $dir"; return 1; }
  for h in "${CODEX_MANAGED_HOOKS[@]}"; do
    $esc cp "$root/configs/claude/hooks/$h" "$dir/hooks/$h" || { warn "cannot write $dir/hooks/$h"; return 1; }
    $esc chmod 0755 "$dir/hooks/$h"
  done
  printf '%s\n' "$rendered" | $esc tee "$dir/requirements.toml" >/dev/null \
    || { warn "cannot write $dir/requirements.toml"; return 1; }
  $esc chmod 0644 "$dir/requirements.toml"
}

# The runner manages only the real /etc/codex, so a relocated managed dir
# (tests, experiments) never defers to it.
aicoding_root_runner_owns_codex() {
  [[ "$CODEX_MANAGED_DIR" == /etc/codex && -x "$AICODING_ROOT_RUNNER" ]]
}

# Ask the runner for an early pass. It reads nothing from the file: closing
# it after a write is the whole signal (systemd PathChanged=).
aicoding_root_runner_trigger() {
  { : > "$AICODING_ROOT_TRIGGER"; } 2>/dev/null || true
}

# First word of the runner's status file: ok or failed (empty if none yet).
aicoding_root_runner_result() {
  local word=
  read -r word _ < "$AICODING_ROOT_STATUS" 2>/dev/null || true
  printf '%s' "$word"
}

# ensure_codex_managed_hooks — install the secrets deny hook as a codex MANAGED
# hook, so it is trusted by policy and runs with no interactive review.
#
# Codex implements the same PreToolUse contract as Claude Code (verified
# against codex-cli 0.148.0), so it runs the very same script. What differs is
# trust: a hook in ~/.codex/hooks.json or <repo>/.codex/hooks.json is recorded
# against a hash and SILENTLY SKIPPED until someone runs /hooks in the TUI —
# an installed-but-inert hook, the exact bug this deny hook exists to fix.
# Hooks from requirements.toml are managed: trusted, always on, and not
# disableable from the user hook browser.
#
# Needs root, so this is fail-soft: it always returns 0. When it leaves
# /etc/codex stale on purpose it sets codex_managed_defer_reason to a result
# reason, so provision verification can report a wait instead of a failure.
ensure_codex_managed_hooks() {
  header "Codex managed secrets hook"
  codex_managed_defer_reason=

  command -v codex &>/dev/null || { info "codex not installed — skipping managed hook"; return 0; }

  local root=${SCRIPT_DIR:?} req_dest="$CODEX_MANAGED_DIR/requirements.toml" state=0
  codex_managed_state "$root" || state=$?
  case "$state" in
    0) ok "codex managed hooks up to date ($req_dest)"; return 0 ;;
    2) warn "blueprint hook sources missing — skipping"; return 0 ;;
    3)
      warn "$req_dest exists and is not blueprint-managed — leaving it untouched"
      warn "  add the PreToolUse hook from $root/configs/codex/requirements.toml by hand, or move that file aside"
      return 0
      ;;
  esac

  # On a host with the root runner, /etc/codex is the runner's: it applies the
  # CI-qualified repo version itself, so no user run ever needs sudo here.
  if [[ $EUID -ne 0 ]] && aicoding_root_runner_owns_codex; then
    aicoding_root_runner_trigger
    if [[ "$(aicoding_root_runner_result)" == failed ]]; then
      codex_managed_defer_reason=root_runner_failed
      warn "the root runner's last pass failed; see: journalctl -u aicoding-root.service"
    else
      codex_managed_defer_reason=root_runner_pending
      info "codex managed hooks are updated by the root runner (aicoding-root.service)"
    fi
    return 0
  fi

  # Root is needed for THESE WRITES ONLY — never for the installer as a whole.
  local esc=""
  if [[ $EUID -eq 0 ]]; then
    esc=""                                  # already root
  elif [[ -z "${SUDO:-}" ]]; then
    esc=""                                  # no sudo binary; a writable target still works
  elif $SUDO -n true 2>/dev/null; then
    esc="$SUDO"                             # passwordless (containers) — silent
  elif _codex_hook_can_prompt; then
    # A password is needed. Explain before the prompt appears, so the sudo
    # challenge is never an unexplained interruption mid-install.
    info "One step needs root: codex only honors hooks from $CODEX_MANAGED_DIR."
    info "  (a hook under ~/.codex would sit untrusted and inert until someone runs /hooks)"
    info "  Escalating for these writes alone — the rest of the install stays unprivileged."
    info "  To stop being asked on this host, run 'aicoding-root-install' once."
    esc="$SUDO"
  else
    # Non-interactive (scheduled update, boot, CI): never hang on a password
    # prompt. A host without the root runner needs it installed once.
    [[ "${ENV_TYPE:-}" != container ]] && codex_managed_defer_reason=root_runner_not_installed
    # Boot runs on every container start, so it stays SILENT rather than
    # printing the same unactionable warning forever.
    [[ "${AICODING_SYNC_MODE:-}" == "boot" ]] && return 0
    warn "codex managed hook needs root for $CODEX_MANAGED_DIR and this run cannot prompt"
    if [[ "${ENV_TYPE:-}" != container ]]; then
      warn "  run 'aicoding-root-install' once from a terminal; a root service then keeps it current"
    else
      warn "  run 'aicoding-install' from a terminal to grant it for that one step"
    fi
    warn "  (until then codex — unlike claude/cursor/opencode — can still read secrets)"
    return 0
  fi

  info "Installing codex managed hook into $CODEX_MANAGED_DIR"
  codex_managed_write "$root" "$esc" || { warn "codex managed hook not installed; skipping"; return 0; }
  ok "codex managed hooks installed ($req_dest)"
}

# _codex_hook_can_prompt — may this run stop and ask for a sudo password?
# Only when a human is actually watching: a boot sync or CI run must fail
# soft instead of blocking forever on an unanswerable prompt.
_codex_hook_can_prompt() {
  [[ "${AICODINGSETUP_NONINTERACTIVE:-}" == "1" ]] && return 1
  [[ "${AICODING_SYNC_MODE:-}" == "boot" ]] && return 1
  [[ -t 0 && -t 1 ]]
}
