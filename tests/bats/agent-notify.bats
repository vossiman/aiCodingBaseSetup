#!/usr/bin/env bats
# Unit tests for bin/agent-notify. tmux and curl are stubbed: tmux records
# set-option/display calls to files, curl records its argv. Real network and
# real tmux are never touched.

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  CLI="$BLUEPRINT_ROOT/bin/agent-notify"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset AGENT_NOTIFY_DISABLE AICODINGSETUP_SKIP_NETWORK NTFY_URL NTFY_TOPIC NTFY_TOKEN
  mkdir -p "$HOME/.aicodingsetup" "$HOME/stubs"
  printf 'NTFY_TOPIC=test-topic-xyz\n' > "$HOME/.aicodingsetup/.secrets.env"

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

@test "flags window and sends push with topic from secrets file" {
  run "$CLI" --source claude --priority high --title "claude waiting"
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"
  grep -q 'test-topic-xyz' "$HOME/curl-calls"
  grep -q 'X-Priority: high' "$HOME/curl-calls"
}

@test "already-flagged window does not push again (episode dedupe)" {
  export TMUX_STUB_WAITING="1754700000"
  run "$CLI" --source claude
  unset TMUX_STUB_WAITING
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/curl-calls" ]
}

@test "focused window of an attached session: no flag, no push" {
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

@test "active window of a detached session still flags and pushes" {
  export TMUX_STUB_FOCUS="1 0"
  run "$CLI" --source claude
  unset TMUX_STUB_FOCUS
  [ "$status" -eq 0 ]
  grep -q 'set-option -w -t @7 @waiting' "$HOME/tmux-calls"
  grep -q 'test-topic-xyz' "$HOME/curl-calls"
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

@test "kill switch and SKIP_NETWORK suppress the push but still exit 0" {
  export AGENT_NOTIFY_DISABLE=1
  run "$CLI" --source claude
  unset AGENT_NOTIFY_DISABLE
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/curl-calls" ]

  export AICODINGSETUP_SKIP_NETWORK=1
  run "$CLI" --source claude
  unset AICODINGSETUP_SKIP_NETWORK
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/curl-calls" ]
}

@test "missing NTFY_TOPIC logs and exits 0" {
  rm "$HOME/.aicodingsetup/.secrets.env"
  run "$CLI" --source claude
  [ "$status" -eq 0 ]
  grep -q 'NTFY_TOPIC' "$HOME/.cache/aicoding/agent-notify.log"
}

@test "curl failure logs and exits 0" {
  export CURL_STUB_EXIT=7
  run "$CLI" --source claude
  unset CURL_STUB_EXIT
  [ "$status" -eq 0 ]
  grep -q 'push failed' "$HOME/.cache/aicoding/agent-notify.log"
}

@test "outside tmux still pushes, without flagging" {
  unset TMUX TMUX_PANE
  run "$CLI" --source codex --title "codex done"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/tmux-calls" ] || { run grep 'set-option' "$HOME/tmux-calls"; [ "$status" -ne 0 ]; }
  grep -q 'test-topic-xyz' "$HOME/curl-calls"
}

@test "codex config wires notify to agent-notify above the first table" {
  local cfg="$BLUEPRINT_ROOT/configs/codex/config.toml"
  grep -q 'notify = \["{{HOME}}/.local/bin/agent-notify"' "$cfg"
  # notify must appear before the first [table] or codex ignores it
  awk '/^\[/{exit 1} /^notify = /{found=1} END{exit !found}' "$cfg"
}

@test "tmux.conf wires alert hooks, clear-on-select, and waiting marker" {
  local conf="$BLUEPRINT_ROOT/configs/tmux/tmux.conf"
  grep -q 'alert-bell.*agent-notify --source tmux-bell' "$conf"
  grep -q 'alert-silence.*agent-notify --source tmux-silence' "$conf"
  grep -q 'alert-activity.*monitor-silence' "$conf"
  grep -q 'after-select-window.*-u.*@waiting' "$conf"
  grep -q '@catppuccin_window_default_text "#{?#{@waiting},⏸ ,}#W"' "$conf"
  grep -q '@catppuccin_window_current_text "#{?#{@waiting},⏸ ,}#W"' "$conf"
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
