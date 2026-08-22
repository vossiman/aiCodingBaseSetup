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
patch_hook() { hook "$(jq -nc --arg c "$1" '{tool_name:"apply_patch",tool_input:{command:$c}}')"; }
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

@test "Grep tool: a recursive search rooted IN a sensitive directory is denied" {
  # Was "allowed" until 2026-08-21: the directory exemption let Grep return
  # file CONTENTS from ~/.aicodingsetup — a native-tool bypass needing no
  # shell at all (review 2026-08-21). Only non-sensitive dirs stay searchable.
  hook "$(jq -nc --arg p "$HOME/.aicodingsetup" \
    '{tool_name:"Grep",tool_input:{pattern:"profile",path:$p}}')"
  denied
  hook "$(jq -nc --arg p "$HOME/work" \
    '{tool_name:"Grep",tool_input:{pattern:"hello",path:$p}}')"
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

# --- codex's apply_patch tool -----------------------------------------------
# Codex sends the patch text in tool_input.command, same field name as Bash
# (verified against codex-cli 0.148.0), so the same script covers both agents.

@test "apply_patch: editing the secrets file is denied" {
  patch_hook "*** Begin Patch
*** Update File: $HOME/.aicodingsetup/.secrets.env
@@
-GH_TOKEN=ghp_supersecret
+GH_TOKEN=leaked
*** End Patch"
  denied
}

@test "apply_patch: creating a new private key is denied before it exists" {
  patch_hook "*** Begin Patch
*** Add File: $HOME/work/exfil.pem
+-----BEGIN PRIVATE KEY-----
*** End Patch"
  denied
}

@test "apply_patch: deleting a private key is denied" {
  patch_hook "*** Begin Patch
*** Delete File: $HOME/.ssh/id_ed25519
*** End Patch"
  denied
}

@test "apply_patch: an ordinary file edit is allowed" {
  patch_hook "*** Begin Patch
*** Update File: $HOME/work/README.md
@@
-hello
+goodbye
*** End Patch"
  allowed
}

@test "apply_patch: patch BODY mentioning a key-like name is not a false positive" {
  patch_hook "*** Begin Patch
*** Update File: $HOME/work/README.md
@@
-old line
+see config.key and server.pem for details
*** End Patch"
  allowed
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

# --- token oracles: paths to the VALUE that never name a denied file --------
# Blocking the secrets file is not enough on its own. The GitHub token is also
# reachable through the git credential helper, `gh auth token`, and the process
# environment — closed 2026-08-21.

@test "invoking the git credential helper directly is denied" {
  bash_hook 'printf "protocol=https\nhost=github.com\n\n" | git-credential-aicoding get'
  denied
}

@test "git credential fill is denied" {
  bash_hook 'git credential fill'
  denied
}

@test "gh auth token is denied" {
  bash_hook 'gh auth token'
  denied
}

@test "reading a process environment is denied" {
  bash_hook 'cat /proc/self/environ'
  denied
}

@test "expanding a secret variable is denied" {
  bash_hook 'echo $GH_TOKEN'
  denied
  bash_hook 'curl -H "Authorization: Bearer ${GH_TOKEN}" https://api.github.com'
  denied
  bash_hook 'echo $FIRECRAWL_API_KEY'
  denied
}

@test "dumping the environment through a filter is denied, either case" {
  bash_hook 'printenv GH_TOKEN'
  denied
  bash_hook 'env | grep -i token'
  denied
}

@test "gh's stored credential file is denied" {
  mkdir -p "$HOME/.config/gh"
  printf 'github.com:\n  oauth_token: ghp_x\n' > "$HOME/.config/gh/hosts.yml"
  bash_hook "cat $HOME/.config/gh/hosts.yml"
  denied
  file_hook Read "$HOME/.config/gh/hosts.yml"
  denied
}

# --- and the ordinary work that must keep running ---------------------------

@test "using git and gh normally is allowed" {
  bash_hook 'git push origin main'
  allowed
  bash_hook 'gh pr create --title x --body y'
  allowed
  bash_hook 'gh auth status'
  allowed
}

@test "mentioning a secret name without expanding it is allowed" {
  bash_hook 'grep -rn "GH_TOKEN" lib/'
  allowed
  bash_hook 'git config --get-all credential.https://github.com.helper'
  allowed
}

@test "a variable that merely contains SECRET in its name is allowed" {
  bash_hook 'echo "$AICODING_SECRETS_FILE"'
  allowed
}

# --- heredoc bodies are data, not arguments ---------------------------------
# Writing a doc or a test that MENTIONS the secrets path is not reading it.
# Denying that is the false positive that teaches people to route around the
# hook — hit for real while documenting this very change.

@test "a heredoc that merely mentions the secrets path is allowed" {
  bash_hook "cat > doc.md <<'EOF'
The secrets live at $HOME/.aicodingsetup/.secrets.env and are denied to agents.
EOF"
  allowed
}

@test "a heredoc script that writes docs about the path is allowed" {
  bash_hook "python3 - <<'PYEOF'
sub('README.md', 'old', 'see $HOME/.aicodingsetup/.secrets.env for details')
PYEOF"
  allowed
}

@test "a heredoc REDIRECTED into the secrets file is still denied" {
  bash_hook "cat <<'EOF' > $HOME/.aicodingsetup/.secrets.env
GH_TOKEN=overwritten
EOF"
  denied
}

@test "quoted, unquoted and dash heredoc markers all get stripped" {
  bash_hook "cat > a.md <<EOF
mentions $HOME/.aicodingsetup/.secrets.env
EOF"
  allowed
  bash_hook "cat > b.md <<-'MARK'
mentions $HOME/.aicodingsetup/.secrets.env
MARK"
  allowed
}

@test "a plain read is unaffected by the heredoc stripping" {
  bash_hook "cat $HOME/.aicodingsetup/.secrets.env"
  denied
}

# --- whole-environment dumps ------------------------------------------------
# `env | grep token` was already denied, but a BARE `env` prints every secret
# at once and slipped through (found 2026-08-21). The line to draw is dump vs
# prefix: `env` alone leaks, `env -u GH_TOKEN gh auth status` is normal usage.

@test "a bare environment dump is denied in all its spellings" {
  bash_hook 'env'
  denied
  bash_hook 'printenv'
  denied
  bash_hook 'set'
  denied
  bash_hook 'env -0'
  denied
  bash_hook 'env -u GH_TOKEN'
  denied
}

@test "a dump later in the command line is denied too" {
  bash_hook 'cd /tmp && env'
  denied
  bash_hook 'env | head -50'
  denied
}

@test "env as a command PREFIX keeps working" {
  bash_hook 'env -u GH_TOKEN gh auth status'
  allowed
  bash_hook 'env -i bash -c "echo hi"'
  allowed
  bash_hook 'env FOO=bar make test'
  allowed
}

@test "setting variables is not dumping them" {
  bash_hook 'set -euo pipefail'
  allowed
  bash_hook 'export PATH=/usr/bin:$PATH'
  allowed
}

# --- MCP configs carry live keys too ----------------------------------------
# The blueprint substitutes API keys into every agent's MCP config at deploy
# time, so the secrets file is one of six copies on disk. Denying only the
# secrets file protected nothing.

@test "each agent's MCP config is denied" {
  mkdir -p "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.cursor"
  printf 'x\n' > "$HOME/.codex/config.toml"
  printf '{}\n'  > "$HOME/.config/opencode/opencode.json"
  printf '{}\n'  > "$HOME/.cursor/mcp.json"
  printf '{}\n'  > "$HOME/.claude.json"

  bash_hook "cat $HOME/.codex/config.toml"
  denied
  bash_hook "cat $HOME/.config/opencode/opencode.json"
  denied
  bash_hook "cat $HOME/.cursor/mcp.json"
  denied
  bash_hook "cat $HOME/.claude.json"
  denied
  file_hook Read "$HOME/.codex/config.toml"
  denied
}

@test "their non-secret neighbours stay readable" {
  mkdir -p "$HOME/.codex" "$HOME/.claude"
  printf 'conventions\n' > "$HOME/.codex/AGENTS.md"
  printf '{}\n' > "$HOME/.claude/settings.json"

  bash_hook "cat $HOME/.codex/AGENTS.md"
  allowed
  bash_hook "cat $HOME/.claude/settings.json"
  allowed
  bash_hook 'claude mcp list'
  allowed
}

# --- bypasses closed after the 2026-08-21 review -----------------------------
# Each of these was verified ALLOW by the review before the fix.

@test "glob: pre-expansion glob over the secrets dir is denied" {
  # The hook sees `~/.aicodingsetup/*` — no single token resolves to a file,
  # the existence gate passed it, then the shell expanded at runtime.
  bash_hook "cat $HOME/.aicodingsetup/*"
  denied
}

@test "cd + relative path is denied" {
  # Tokens were resolved against the hook's CWD, not the command's.
  bash_hook "cd $HOME/.aicodingsetup && cat .secrets.env"
  denied
}

@test "a heredoc fed to a shell interpreter has its body scanned" {
  # Stripping killed false positives but created an execution channel.
  bash_hook "bash <<'X'
cat $HOME/.aicodingsetup/.secrets.env
X"
  denied
}

@test "an env dump redirected to a file is denied" {
  # `>` counted as a remaining command word, so is_env_dump passed it and
  # nothing denied reading /tmp afterwards.
  bash_hook 'env > /tmp/envdump.txt'
  denied
  bash_hook 'printenv > "$TMPDIR/e.txt" 2>&1'
  denied
  bash_hook 'set > /tmp/state.txt'
  denied
}

@test "declare -p on a secret variable is denied" {
  bash_hook 'declare -p GH_TOKEN'
  denied
  bash_hook 'declare GH_TOKEN=ok'
  allowed
}

@test "content commands over a sensitive directory are denied" {
  # Directories were allowed ("listing is fine") but these read contents.
  bash_hook "tar czf /tmp/a.tgz -C $HOME .aicodingsetup"
  denied
  bash_hook "cp -r $HOME/.aicodingsetup /tmp/exfil"
  denied
  bash_hook "find $HOME/.aicodingsetup -type f -exec cat {} ;"
  denied
}

@test "listing and cd still work on sensitive directories" {
  bash_hook "ls $HOME/.aicodingsetup .aicodingsetup"
  allowed
  bash_hook "cd $HOME/.aicodingsetup && ls"
  allowed
}
