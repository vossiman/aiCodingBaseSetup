#!/usr/bin/env bats
# bw-deny-files.sh: the PreToolUse hook must block secrets and private keys
# unconditionally — NOT only inside the bubblewrap sandbox, which is how it
# shipped until 2026-08-21 (BW_DENY_PATTERNS_FILE unset => no-op => every
# agent could cat ~/.aicodingsetup/.secrets.env).

setup() {
  : "${BLUEPRINT_ROOT:?unset — run via tests/bats/run.sh}"
  HOOK="$BLUEPRINT_ROOT/configs/claude/hooks/bw-deny-files.sh"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR"
  unset BW_DENY_PATTERNS_FILE

  mkdir -p "$HOME/.aicodingsetup" "$HOME/.ssh" "$HOME/work"
  printf 'GH_TOKEN=ghp_supersecret\n' > "$HOME/.aicodingsetup/.secrets.env"
  printf '{"profile":"container"}\n'  > "$HOME/.aicodingsetup/manifest.json"
  printf 'PRIVATE KEY\n'              > "$HOME/.aicodingsetup/memory-lanes-ship"
  printf 'PRIVATE KEY\n'              > "$HOME/.ssh/id_ed25519"
  printf 'ssh-ed25519 AAAA\n'         > "$HOME/.ssh/id_ed25519.pub"
  printf 'host github.com\n'          > "$HOME/.ssh/config"
  printf 'hello\n'                    > "$HOME/work/README.md"
}

teardown() { rm -rf "$TMPDIR"; }

# Feed one tool call to the hook. The JSON goes in via a file so no test ever
# has to nest quotes inside a bash -c string.
hook() {
  printf '%s' "$1" > "$TMPDIR/in.json"
  run bash -c "bash '$HOOK' < '$TMPDIR/in.json'"
}
bash_hook() { hook "$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
file_hook() { hook "$(jq -nc --arg t "$1" --arg f "$2" '{tool_name:$t,tool_input:{file_path:$f}}')"; }

denied()  { [ "$status" -eq 0 ] && [[ "$output" == *'"deny"'* ]]; }
allowed() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

# --- must be blocked --------------------------------------------------------

@test "Bash: cat of the secrets file is denied" {
  bash_hook "cat ~/.aicodingsetup/.secrets.env"
  denied
}

@test "Bash: sourcing the secrets file is denied" {
  bash_hook 'source $HOME/.aicodingsetup/.secrets.env && echo ok'
  denied
}

@test "Bash: reading it from python is denied" {
  bash_hook "python3 -c \"print(open('$HOME/.aicodingsetup/.secrets.env').read())\""
  denied
}

@test "Bash: reading it inside a pipeline is denied" {
  bash_hook "tail -n +1 $HOME/.aicodingsetup/.secrets.env | base64"
  denied
}

@test "Bash: extensionless private key in .aicodingsetup is denied" {
  bash_hook "cat $HOME/.aicodingsetup/memory-lanes-ship"
  denied
}

@test "Bash: ssh private key is denied but its .pub is not" {
  bash_hook "cat $HOME/.ssh/id_ed25519"
  denied
  bash_hook "cat $HOME/.ssh/id_ed25519.pub"
  allowed
}

@test "Bash: writing a new .pem is denied even though it does not exist yet" {
  bash_hook "echo x > $HOME/work/new.pem"
  denied
}

@test "Read tool: the secrets file is denied" {
  file_hook Read "$HOME/.aicodingsetup/.secrets.env"
  denied
}

@test "Write tool: overwriting the secrets file is denied" {
  file_hook Write "$HOME/.aicodingsetup/.secrets.env"
  denied
}

@test "Grep tool: targeting the secrets file directly is denied" {
  hook "$(jq -nc --arg p "$HOME/.aicodingsetup/.secrets.env" \
    '{tool_name:"Grep",tool_input:{pattern:"TOKEN",path:$p}}')"
  denied
}

@test "deny reason names the escape hatch instead of just refusing" {
  file_hook Read "$HOME/.aicodingsetup/.secrets.env"
  [[ "$output" == *"secrets-check"* ]]
}

# --- must still be allowed (false positives are their own failure) ----------

@test "Bash: manifest.json in the same dir stays readable" {
  bash_hook "cat $HOME/.aicodingsetup/manifest.json"
  allowed
}

@test "Bash: listing the sensitive directory is allowed" {
  bash_hook "ls -la $HOME/.aicodingsetup/"
  allowed
}

@test "Bash: grepping for the literal string is allowed (no such file)" {
  bash_hook 'grep -rn ".secrets.env" docs/'
  allowed
}

@test "Bash: ssh config stays readable" {
  bash_hook "cat $HOME/.ssh/config"
  allowed
}

@test "Bash: an ordinary command is allowed" {
  bash_hook "git status --short && cat $HOME/work/README.md"
  allowed
}

@test "Grep tool: searching a whole directory is allowed" {
  hook "$(jq -nc --arg p "$HOME/.aicodingsetup" \
    '{tool_name:"Grep",tool_input:{pattern:"profile",path:$p}}')"
  allowed
}

@test "unrelated tools pass through" {
  hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
  allowed
}

@test "malformed input does not crash the hook" {
  hook 'not-json'
  [ "$status" -eq 0 ]
}

@test "empty input does not crash the hook" {
  hook ''
  [ "$status" -eq 0 ]
}

# --- sandbox patterns are additive, not the on/off switch -------------------

@test "BW_DENY_PATTERNS_FILE adds patterns without disabling the defaults" {
  printf 'app-config.yaml\n' > "$HOME/extra-patterns"
  printf 'db: x\n' > "$HOME/work/app-config.yaml"
  export BW_DENY_PATTERNS_FILE="$HOME/extra-patterns"

  bash_hook "cat $HOME/work/app-config.yaml"
  denied

  bash_hook "cat $HOME/.aicodingsetup/.secrets.env"
  denied
}
