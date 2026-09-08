#!/usr/bin/env bats
# Unit tests for bin/agent-notify. tmux is stubbed: set-option/display calls
# are recorded to files, real tmux is never touched. A curl stub is kept only
# to prove the retired ntfy push is really gone — nothing may invoke it.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  CLI="$BLUEPRINT_ROOT/bin/agent-notify"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset AGENT_NOTIFY_DISABLE AICODINGSETUP_SKIP_NETWORK NTFY_URL NTFY_TOPIC NTFY_TOKEN
  mkdir -p "$HOME/.aicodingsetup" "$HOME/stubs"
  printf 'NTFY_TOPIC=test-topic-xyz\n' > "$HOME/.aicodingsetup/.secrets.env"
  # ^ a populated secrets file: even with a topic present, nothing may push.

  # tmux stub: display -p prints a canned window id / flag value; set-option
  # and show-options record argv. TMUX_STUB_WAITING simulates an existing
  # flag; TMUX_STUB_FOCUS simulates '#{window_active} #{session_attached}'
  # (defaults to an unfocused, detached window).
  cat > "$HOME/stubs/tmux" <<'STUB'
#!/bin/sh
echo "$@" >> "$HOME/tmux-calls"
case "$1" in
  display*|display-message)
    case "$*" in
      *window_active*) echo "${TMUX_STUB_FOCUS:-0 0}" ;;
      *window_id*) echo "@7" ;;
      *host*|*#H*) echo "testbox" ;;
      *window_name*) echo "mywin" ;;
    esac ;;
  show-options) printf '%s\n' "${TMUX_STUB_WAITING:-}" ;;
esac
exit 0
STUB
  cat > "$HOME/stubs/curl" <<'STUB'
#!/bin/sh
echo "$@" >> "$HOME/curl-calls"
exit "${CURL_STUB_EXIT:-0}"
STUB
  chmod +x "$HOME/stubs/tmux" "$HOME/stubs/curl"
  export PATH="$HOME/stubs:$PATH"
  export TMUX=/tmp/fake,1,0 TMUX_PANE=%3
}

teardown() { case "${TMPDIR:-}" in */tmp.*) rm -rf "$TMPDIR" ;; esac }

@test "flags window; push payload flags are accepted and ignored" {
  run "$CLI" --source claude --priority high --title "claude waiting" --body "hi"
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"
  [ ! -f "$HOME/curl-calls" ]
}

@test "already-flagged window keeps its original timestamp (episode dedupe)" {
  export TMUX_STUB_WAITING="1754700000"
  run "$CLI" --source claude
  unset TMUX_STUB_WAITING
  [ "$status" -eq 0 ]
  # dvw sorts on this epoch — a second hook in the same episode must not move it
  run grep 'set-option -w -t @7 @waiting [0-9]' "$HOME/tmux-calls"
  [ "$status" -ne 0 ]
}

@test "focused window of an attached session: no flag" {
  export TMUX_STUB_FOCUS="1 2"
  run "$CLI" --source claude
  unset TMUX_STUB_FOCUS
  [ "$status" -eq 0 ]
  if grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"; then false; fi
  [ ! -f "$HOME/curl-calls" ]
}

@test "focused+attached window clears a stale flag (re-arms the episode)" {
  export TMUX_STUB_FOCUS="1 1"
  export TMUX_STUB_WAITING="1754700000"
  run "$CLI" --source claude
  unset TMUX_STUB_FOCUS TMUX_STUB_WAITING
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -u -t @7 @waiting' "$HOME/tmux-calls"
  [ ! -f "$HOME/curl-calls" ]
}

@test "active window of a detached session still flags" {
  export TMUX_STUB_FOCUS="1 0"
  run "$CLI" --source claude
  unset TMUX_STUB_FOCUS
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"
}

@test "explicit --window skips TMUX_PANE lookup and validates id format" {
  run "$CLI" --source tmux-bell --window @12
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @12 @waiting' "$HOME/tmux-calls"
  run "$CLI" --source tmux-bell --window '; rm -rf /'
  [ "$status" -eq 0 ]           # never non-zero…
  run grep 'rm -rf' "$HOME/tmux-calls"
  [ "$status" -ne 0 ]           # …and never embeds an unvalidated id
}

@test "kill switch suppresses the flag but still exits 0" {
  export AGENT_NOTIFY_DISABLE=1
  run "$CLI" --source claude
  unset AGENT_NOTIFY_DISABLE
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/tmux-calls" ]
}

@test "the retired ntfy push is gone: no network, no secrets read" {
  # Secrets file holds a topic and curl is on PATH — neither may be touched.
  run "$CLI" --source claude
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/curl-calls" ]
  # No push code left: no curl, no NTFY_* env, no secrets read. (The header
  # comment still names ntfy to explain the removal, so match code, not prose.)
  run grep -nE 'curl|NTFY_|secrets\.env' "$BLUEPRINT_ROOT/bin/agent-notify"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "outside tmux: no flag, no error" {
  unset TMUX TMUX_PANE
  run "$CLI" --source codex --title "codex done"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/tmux-calls" ]
  [ ! -f "$HOME/curl-calls" ]
}

@test "codex positional JSON payload is tolerated" {
  run "$CLI" --source codex '{"last-assistant-message":"done"}'
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"
  [ ! -f "$HOME/curl-calls" ]
}

@test "codex config wires notify to agent-notify above the first table" {
  local cfg="$BLUEPRINT_ROOT/configs/codex/config.toml"
  # notify goes through codex-turn-done, which flags the window via
  # agent-notify and then sweeps transcripts with redact-sessions.
  grep -q 'notify = \["{{HOME}}/.local/bin/codex-turn-done"' "$cfg"
  # notify must appear before the first [table] or codex ignores it
  awk '/^\[/{exit 1} /^notify = /{found=1} END{exit !found}' "$cfg"
}

@test "tmux.conf preserves waiting hooks but displays application titles in both tab states" {
  local conf="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  grep -q 'alert-bell.*agent-notify --source tmux-bell' "$conf"
  grep -q 'alert-silence.*agent-notify --source tmux-silence' "$conf"
  grep -q 'alert-activity.*monitor-silence' "$conf"
  grep -q 'after-select-window.*-u.*@waiting' "$conf"
  # One label for both tab states, badged only for sure sources, falling
  # back to #W for untitled panes (their #T is the hostname).
  grep -q '^set -g @_ctp_tab_label "#{?#{m/r:^(claude|codex)$,#{@waiting_source}},⏸ ,}#{?#{==:#T,#h},#W,#{=25:pane_title}}"$' "$conf"
  grep -q '^set -gF @catppuccin_window_text "#{@_ctp_tab_label}"$' "$conf"
  grep -q '^set -gF @catppuccin_window_current_text "#{@_ctp_tab_label}"$' "$conf"
  # Every place that clears @waiting clears @waiting_source too, and resumed
  # output (alert-activity) clears both: a producing agent is not waiting.
  for hook in after-select-window client-attached alert-activity; do
    grep -q "$hook.*-u.*@waiting .*-u.*@waiting_source" "$conf"
  done
}

@test "--clear drops both flags on the window and sets nothing" {
  run "$CLI" --clear --window @7
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -u -t @7 @waiting$' "$HOME/tmux-calls"
  grep -q 'set-option -w -u -t @7 @waiting_source' "$HOME/tmux-calls"
  if grep -q 'set-option -w -t' "$HOME/tmux-calls"; then false; fi
}

@test "agent-notify records @waiting_source and lets a sure source upgrade a heuristic flag" {
  run "$CLI" --source tmux-silence --window @7
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting_source tmux-silence' "$HOME/tmux-calls"
  rm -f "$HOME/tmux-calls"
  TMUX_STUB_WAITING=1700000000 run "$CLI" --source claude --window @7
  [ "$status" -eq 0 ]
  if grep -q 'set-option -w -t @7 @waiting 1' "$HOME/tmux-calls"; then false; fi
  grep -q 'set-option -w -t @7 @waiting_source claude' "$HOME/tmux-calls"
  rm -f "$HOME/tmux-calls"
  TMUX_STUB_WAITING=1700000000 run "$CLI" --source tmux-bell --window @7
  if grep -q '@waiting_source' "$HOME/tmux-calls"; then false; fi
  rm -f "$HOME/tmux-calls"
  TMUX_STUB_FOCUS="1 1" run "$CLI" --source claude --window @7
  grep -q 'set-option -w -u -t @7 @waiting_source' "$HOME/tmux-calls"
}

@test "tmux.conf clears @waiting on reattach and does not bell-notify the current window" {
  local conf="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  # Bell must not alert for the focused window (bell-action any would notify
  # the window you're already looking at) — same policy as activity/silence.
  grep -q '^set -g bell-action other' "$conf"
  # A window whose flag survived because it was already current when the
  # client detached must have it cleared on reattach too (after-select-window
  # only fires on an actual window *change*, which attach-to-same-window is
  # not — verified on an isolated tmux rig, see the comment above the hook).
  grep -q 'client-attached.*-u.*@waiting' "$conf"
}
