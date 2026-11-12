#!/usr/bin/env bats
# SG-PROCESS-KILL: agents never send signals to processes.
#
# Owner rule 2026-11-12. A subagent ran `kill` on a parent PID it had looked
# up; the PID was the systemd user manager, and the owner's desktop session
# ended mid-work. Earlier incidents with the same cause: `pkill -f` killed
# the calling shell, `pkill -P 1` killed a devcontainer, and an unscoped
# `pkill` killed a sibling session's tests. The hook blocks the command forms
# below; the allowed list is the floor of normal work that must keep running.

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/bw-deny-files.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset BW_DENY_PATTERNS_FILE
}

teardown() { rm -rf "$TMPDIR"; }

hook() {
  printf '%s' "$1" > "$TMPDIR/in.json"
  run bash -c "bash '$HOOK' < '$TMPDIR/in.json'"
}
bash_hook() { hook "$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"; }

kill_denied() { [ "$status" -eq 0 ] && [[ "$output" == *'"deny"'* && "$output" == *SG-PROCESS-KILL* ]]; }
allowed()     { [ "$status" -eq 0 ] && [ -z "$output" ]; }

# Each argument is one command. Reports the first one that slips through.
expect_denied() {
  local c
  for c in "$@"; do
    bash_hook "$c"
    kill_denied || { echo "not denied: $c"; echo "output: $output"; return 1; }
  done
}
expect_allowed() {
  local c
  for c in "$@"; do
    bash_hook "$c"
    allowed || { echo "not allowed: $c"; echo "output: $output"; return 1; }
  done
}

@test "signal commands are denied" {
  expect_denied \
    'kill 1942' \
    'kill -9 $PPID' \
    'kill -0 123' \
    'pkill -f flutter' \
    'pkill -P 1' \
    'killall node' \
    'skill -u bob' \
    'snice +5 -p 12' \
    'tkill 3' \
    'xkill' \
    'fuser -k 8080/tcp' \
    'fuser -km /mnt' \
    'fuser --kill 3000/tcp' \
    'tmux kill-server' \
    'npx kill-port 3000' \
    'reboot'
}

@test "qualified and wrapped signal commands are denied" {
  expect_denied \
    '/bin/kill 5' \
    '/usr/bin/kill -TERM 5' \
    '\kill 5' \
    '"kill" 5' \
    'command kill 5' \
    'builtin kill 5' \
    'exec kill 5' \
    'sudo kill 1' \
    'sudo -n kill 1' \
    'sudo -u root pkill x' \
    'doas kill 1' \
    'env kill 3' \
    'env FOO=1 kill 3' \
    'env -S "kill 1"' \
    'FOO=1 kill 2' \
    'nohup kill 1 &' \
    'setsid kill 2' \
    'timeout 5 kill 3' \
    'busybox kill 1' \
    'pgrep foo | xargs kill' \
    'pgrep foo | xargs -r kill -9' \
    'xargs -n 1 kill < pids' \
    'find /proc -name x -exec kill {} \;'
}

@test "kill in any command position is denied" {
  expect_denied \
    'cd /tmp && kill 4' \
    'true; kill 4' \
    'false || kill 4' \
    'kill 1 2>/dev/null' \
    '2>/dev/null kill 1' \
    'echo $(kill 4)' \
    'echo "pid $(pkill x)"' \
    'echo `kill 4`' \
    'for p in 1 2; do kill $p; done' \
    'if true; then kill 1; fi' \
    '{ kill 1; }' \
    '(kill 1)'
}

@test "service managers stopping units or sessions are denied" {
  expect_denied \
    'systemctl kill foo' \
    'systemctl --user stop pipewire' \
    'systemctl --user restart foo.service' \
    'systemctl --user kill foo' \
    'systemctl --user try-restart foo' \
    'sudo systemctl stop nginx' \
    'loginctl terminate-session 2' \
    'loginctl terminate-user 1000' \
    'loginctl kill-user vossi'
}

@test "kill reached through strings a shell runs is denied" {
  expect_denied \
    "sh -c 'kill 1'" \
    'bash -c "pkill node"' \
    "bash -lc 'killall x'" \
    "bash -o pipefail -c 'kill 3'" \
    "sudo sh -c 'kill 1'" \
    "eval 'kill 1'" \
    "trap 'kill 0' EXIT" \
    'watch -n 1 kill 3' \
    "su -c 'kill 1'" \
    "ssh host 'kill 123'" \
    'ssh -p 22 host pkill x' \
    'docker exec web kill 1' \
    'docker compose exec -T web pkill x' \
    'kubectl exec pod -- kill 1' \
    'adb shell kill 123' \
    "adb -s emulator-5554 shell 'pkill app'"
  # A heredoc fed to a shell runs its body.
  expect_denied "$(printf 'bash <<%sX%s\nkill 1\nX' "'" "'")"
  # An unquoted-marker heredoc expands command substitutions in its body.
  expect_denied "$(printf 'cat > f <<EOF\n$(kill 1)\nEOF')"
}

@test "the denial names the rule and the safe alternatives" {
  bash_hook 'kill 1942'
  kill_denied
  [[ "$output" == *"agents never send signals to processes"* ]]
  [[ "$output" == *"docker stop <name>"* ]]
  [[ "$output" == *"ask the owner"* ]]
}

@test "wrapper options that take no value do not hide the command" {
  expect_denied \
    'watch -d kill 123' \
    'ionice -t kill 123' \
    'flock -n /tmp/x.lock kill 123' \
    'flock -w 5 /tmp/x.lock pkill node' \
    'flock /tmp/x.lock -c "kill 1"' \
    'flock -c "kill 1" /tmp/x.lock'
  expect_allowed \
    'watch -d make test' \
    'ionice -c 3 make' \
    'flock /tmp/x.lock make test' \
    'flock -n 9'
}

@test "commands that only signal their own child or a named container stay allowed" {
  expect_allowed \
    'timeout 5 make test' \
    'timeout -s KILL 30 flutter test' \
    'timeout --kill-after=5 60 npm test' \
    'docker stop web' \
    'docker kill web' \
    'docker rm -f web' \
    'docker compose down' \
    'make down' \
    'adb shell am force-stop com.example.app' \
    'adb emu kill' \
    'adb -s emulator-5554 emu kill'
}

@test "mentions of kill in prose, patterns and file names stay allowed" {
  expect_allowed \
    'git commit -m "fix the kill switch"' \
    "git commit -m 'pkill was the bug'" \
    'git log --grep=kill' \
    'grep -rn kill .' \
    "rg 'pkill -f' docs" \
    'grep -n "kill -9" notes.md' \
    'rg -w killall' \
    'cat lib/kill_switch.dart' \
    'flutter test test/kill_switch_test.dart' \
    './kill_switch.sh' \
    'echo "never run kill 1"' \
    'echo kill' \
    'ls # then kill it' \
    'sed -i s/kill/stop/ f.txt' \
    'command -v kill' \
    'type kill' \
    'man kill'
  # Commit messages written through a heredoc are data.
  expect_allowed \
    "$(printf 'git commit -F - <<%sEOF%s\nkill the bug\npkill was wrong\nEOF' "'" "'")" \
    "$(printf 'git commit -m "$(cat <<%sEOF%s\nkill the process tree\nEOF\n)"' "'" "'")" \
    "$(printf 'cat <<EOF > notes.md\nkill the bug\nEOF')"
  # A single-quoted or escaped substitution is literal text.
  expect_allowed \
    "echo '\$(kill 123)'" \
    "git commit -m 'document \$(kill 123)'" \
    "$(printf 'cat <<EOF > notes.md\n\\$(kill 1)\nEOF')"
  # A substitution in an unquoted-marker heredoc body does run.
  expect_denied "$(printf 'cat <<EOF > notes.md\n$(kill 1)\nEOF')"
}

@test "read-only service and process queries stay allowed" {
  expect_allowed \
    'systemctl status foo' \
    'systemctl --user status' \
    'systemctl --user list-units' \
    'systemctl --user daemon-reload' \
    'loginctl list-sessions' \
    'pgrep -f flutter' \
    'ps -o pid,comm -p 1' \
    'tmux ls' \
    "ssh host 'docker ps'" \
    'docker exec web ls' \
    'kubectl exec pod -- ls'
}

# Cursor and OpenCode cannot run the hook, so they carry glob deny rules for
# the direct and common wrapped forms.
@test "fallback configs deny the direct signal commands" {
  local cursor="$BLUEPRINT_ROOT/configs/cursor/cli-config.json"
  local opencode="$BLUEPRINT_ROOT/configs/opencode/opencode.json"
  jq -e '.permissions.deny | contains(["Shell(kill)", "Shell(pkill)", "Shell(killall)", "Shell(xargs:*kill*)", "Shell(fuser:*-*k*)", "Shell(systemctl:*stop*)", "Shell(loginctl:*terminate-*)"])' "$cursor"
  jq -e '.permission.bash | ."kill *" == "deny" and ."pkill *" == "deny" and ."killall *" == "deny" and ."sudo kill *" == "deny" and ."xargs kill *" == "deny" and ."*systemctl *stop *" == "deny"' "$opencode"
  # The allow-all default must still come first: OpenCode's last match wins.
  jq -e '.permission.bash | keys_unsorted[0] == "*"' "$opencode"
}

@test "global instructions state the rule for Claude and Codex" {
  grep -q '^## Processes: never kill them' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q '^## Processes: never kill them' "$BLUEPRINT_ROOT/configs/codex/AGENTS.md"
}
