#!/usr/bin/env bats

setup() {
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR" AICODING_STATE_DIR="$TMPDIR/state"
  export AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  unset AICODING_PROFILE
  # umask 0002 is the container default and the condition under which the
  # 664 modes were observed live.
  umask 0002
}

teardown() {
  rm -rf "$TMPDIR"
}

# A private, git-backed blueprint with one shipped-then-retired source.
retired_clone() {
  local clone="$TMPDIR/clone"
  git init -q -b main "$clone"
  mkdir -p "$clone/commands" "$clone/configs" "$clone/lib"
  printf 'old command\n' > "$clone/commands/gone.md"
  git -C "$clone" add .
  git -C "$clone" -c user.email=t@t -c user.name=t commit -qm ship
  git -C "$clone" rm -q commands/gone.md
  git -C "$clone" -c user.email=t@t -c user.name=t commit -qm retire
  jq -n '{mixed:{}, retired_files:[{dest:".claude/commands/gone.md", source:"commands/gone.md"}], retired_keys:[]}' \
    > "$clone/configs/managed-config.json"
  export AICODING_BLUEPRINT_CLONE="$clone"
}

@test "rule 1: a fresh home receives every owned file, and a second pass writes nothing" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  managed_config_apply > "$TMPDIR/first"
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ -x "$HOME/.claude/hooks/bw-deny-files.sh" ]
  [ -f "$HOME/.claude/skills/review-by-harness/SKILL.md" ]
  [ "$(stat -c %a "$HOME/.claude/CLAUDE.md")" = 600 ]
  [ "$(stat -c %a "$HOME/.claude/hooks/bw-deny-files.sh")" = 700 ]
  run managed_config_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed config already current"* ]]
  [[ "$output" != *"updated:"* ]]
}

@test "rule 1: a hand-edited owned file is overwritten without a backup or prompt" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.claude/hooks"
  printf 'mine\n' > "$HOME/.claude/hooks/memory-hint.sh"
  chmod 0664 "$HOME/.claude/hooks/memory-hint.sh"
  run managed_config_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated: $HOME/.claude/hooks/memory-hint.sh"* ]]
  cmp -s "$BLUEPRINT_ROOT/configs/claude/hooks/memory-hint.sh" "$HOME/.claude/hooks/memory-hint.sh"
  [ "$(stat -c %a "$HOME/.claude/hooks/memory-hint.sh")" = 600 ]
  [ -z "$(find "$HOME" -name '*.bak.*')" ]
}

@test "rule 1: prose gets HOME only, configs get secrets, raw assets stay byte-exact" {
  export FIRECRAWL_API_KEY=fc-secret
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/src"
  printf 'home={{HOME}} key={{FIRECRAWL_API_KEY}}\n' > "$TMPDIR/src/t"
  _render_managed_source "$TMPDIR/src/t" "$HOME/.claude/commands/x.md" "$TMPDIR/prose"
  _render_managed_source "$TMPDIR/src/t" "$HOME/.local/bin/x" "$TMPDIR/config"
  [ "$(cat "$TMPDIR/prose")" = "home=$HOME key={{FIRECRAWL_API_KEY}}" ]
  [ "$(cat "$TMPDIR/config")" = "home=$HOME key=fc-secret" ]
  managed_config_apply >/dev/null
  local asset
  asset=$(cd "$BLUEPRINT_ROOT/skills" && find . -type f ! -name '*.md' | head -1)
  cmp -s "$BLUEPRINT_ROOT/skills/$asset" "$HOME/.claude/skills/$asset"
}

@test "rule 1: dry run reports pending writes and changes nothing" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_config_apply --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would update: $HOME/.claude/CLAUDE.md"* ]]
  [ ! -e "$HOME/.claude/CLAUDE.md" ]
}

@test "rule 1: a gate veto leaves the file alone and records the reason" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  veto() { [[ "$1" != */.cursor/hooks.json ]] || { echo cursor_not_installed; return 1; }; }
  MANAGED_CONFIG_GATE=veto managed_config_apply >/dev/null
  [ ! -e "$HOME/.cursor/hooks.json" ]
  [ "${MANAGED_RESULT[$HOME/.cursor/hooks.json]}" = blocked:cursor_not_installed ]
  [ "${MANAGED_RESULT[$HOME/.claude/CLAUDE.md]}" = updated ]
}

@test "rule 2: settings.json enforces owned keys, seeds once, keeps personal content" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.claude"
  jq -n '{effortLevel:"low", personal:{a:1},
          permissions:{allow:["Bash(mine:*)"], deny:["Read(/mine)"]},
          env:{MY_VAR:"1", CLAUDE_CODE_NO_FLICKER:"0"},
          hooks:{MyEvent:[{x:1}], Stop:[{mine:true}]},
          enabledPlugins:{"mine@x":true, "superpowers@claude-plugins-official":false}}' \
    > "$HOME/.claude/settings.json"
  managed_config_apply >/dev/null
  local s="$HOME/.claude/settings.json" b="$TMPDIR/rendered.json"
  _substitute_file_to "$BLUEPRINT_ROOT/configs/claude/settings.json" "$b"
  jq -e '.effortLevel == "low" and .personal == {a:1} and .env.MY_VAR == "1"
         and .hooks.MyEvent == [{x:1}] and .enabledPlugins["mine@x"] == true' "$s"
  jq -e --slurpfile b "$b" '.env.CLAUDE_CODE_NO_FLICKER == $b[0].env.CLAUDE_CODE_NO_FLICKER
         and .hooks.Stop == $b[0].hooks.Stop
         and .enabledPlugins["superpowers@claude-plugins-official"] == true
         and .outputStyle == $b[0].outputStyle
         and (.permissions.allow | index("Bash(mine:*)")) != null
         and (.permissions.deny | index("Read(/mine)")) != null
         and ($b[0].permissions.deny - .permissions.deny) == []' "$s"
  [ "$(stat -c %a "$s")" = 600 ]
}

@test "rule 2: a malformed mixed file is reported and never overwritten" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.cursor" "$HOME/.codex"
  printf '{broken\n' > "$HOME/.cursor/mcp.json"
  printf 'model = \n' > "$HOME/.codex/config.toml"
  run managed_config_apply
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.cursor/mcp.json")" = '{broken' ]
  [ "$(cat "$HOME/.codex/config.toml")" = 'model = ' ]
  [[ "$output" == *"left unreadable file unchanged"*"$HOME/.cursor/mcp.json"* ]]
}

@test "rule 2: Codex keeps personal model, projects and servers; owned keys follow the blueprint" {
  export KANBAN_TOKEN=kb MEMORY_ROUTER_TOKEN=mr
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
model = "personal-model"
approval_policy = "untrusted"

[projects."/work"]
trust_level = "trusted"

[tui]
alternate_screen = "always"

[mcp_servers.mine]
command = "mine"
TOML
  managed_config_apply >/dev/null
  local c="$HOME/.codex/config.toml"
  grep -qx 'model = "personal-model"' "$c"
  grep -qx 'approval_policy = "never"' "$c"
  grep -qx 'sandbox_mode = "danger-full-access"' "$c"
  grep -qx 'trust_level = "trusted"' "$c"
  grep -qx 'alternate_screen = "always"' "$c"
  grep -q '^status_line = ' "$c"
  grep -qx '\[mcp_servers.mine\]' "$c"
  grep -qx '\[mcp_servers.firecrawl\]' "$c"
  grep -qF 'Bearer kb' "$c"
  grep -q '^multi_agent_v2 = true' "$c"
}

@test "rule 2: a fresh Codex config is the rendered template" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  managed_config_apply >/dev/null
  _substitute_file_to "$BLUEPRINT_ROOT/configs/codex/config.toml" "$TMPDIR/expected"
  cmp -s "$TMPDIR/expected" "$HOME/.codex/config.toml"
}

@test "rule 2: a missing secret removes the blueprint's MCP entry but keeps a user's own" {
  unset KANBAN_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.cursor"
  echo '{"mcpServers":{"kanban":{"url":"https://kanban.dataprospectors.at/mcp","headers":{"Authorization":"Bearer revoked"}}}}' \
    > "$HOME/.cursor/mcp.json"
  managed_config_apply >/dev/null
  if grep -q revoked "$HOME/.cursor/mcp.json"; then false; fi
  echo '{"mcpServers":{"kanban":{"url":"http://127.0.0.1:9/mcp"}}}' > "$HOME/.cursor/mcp.json"
  managed_config_apply >/dev/null
  jq -e '.mcpServers.kanban.url == "http://127.0.0.1:9/mcp"' "$HOME/.cursor/mcp.json"
}

@test "rule 2: the bashrc block is enforced between markers; the rest of .bashrc stays" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  printf 'export MINE=1\n' > "$HOME/.bashrc"
  chmod 0644 "$HOME/.bashrc"
  managed_config_apply >/dev/null
  grep -qx 'export MINE=1' "$HOME/.bashrc"
  grep -qxF "$(managed_marker_block_start)" "$HOME/.bashrc"
  sed -i 's|/usr/local/go/bin|/edited|' "$HOME/.bashrc"
  managed_config_apply >/dev/null
  grep -q '/usr/local/go/bin' "$HOME/.bashrc"
  [ "$(grep -cxF "$(managed_marker_block_start)" "$HOME/.bashrc")" -eq 1 ]
  [ "$(stat -c %a "$HOME/.bashrc")" = 644 ]
}

@test "rule 2: every JSON template key is owned or seeded" {
  local data="$BLUEPRINT_ROOT/configs/managed-config.json" rel src
  for rel in $(jq -r '.mixed | keys[] | select(endswith(".json"))' "$data"); do
    src=$(jq -r --arg r "$rel" '.mixed[$r].source' "$data")
    jq -e --slurpfile d "$data" --arg r "$rel" '
      ($d[0].mixed[$r] | (.owned + .seeded) | map(sub("(\\.\\*|\\[\\])$"; "") | split(".")[0])) as $covered
      | keys - $covered == []' "$BLUEPRINT_ROOT/$src"
  done
}

@test "rule 3: a retired file that still matches a shipped version is removed" {
  retired_clone
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.claude/commands"
  printf 'old command\n' > "$HOME/.claude/commands/gone.md"
  run _managed_retire_files 0
  [[ "$output" == *"removed retired file"* ]]
  [ ! -e "$HOME/.claude/commands/gone.md" ]
}

@test "rule 3: a hand-edited retired file is kept and reported once" {
  retired_clone
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.claude/commands"
  printf 'my edit\n' > "$HOME/.claude/commands/gone.md"
  run _managed_retire_files 0
  [[ "$output" == *"kept retired file (changed locally): $HOME/.claude/commands/gone.md"* ]]
  run _managed_retire_files 0
  [ -z "$output" ]
  [ "$(cat "$HOME/.claude/commands/gone.md")" = 'my edit' ]
}

@test "rule 3: an absent retired file is not a conflict" {
  retired_clone
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run _managed_retire_files 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rule 3: retired keys are removed only when they equal a shipped value" {
  unset KANBAN_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.config/opencode"
  echo '{"mcp":{"kanban":{"type":"local","command":["kanban-mcp"],"enabled":true}}}' > "$HOME/.config/opencode/opencode.json"
  managed_config_apply >/dev/null
  jq -e '.mcp.kanban == null' "$HOME/.config/opencode/opencode.json"
  echo '{"mcp":{"kanban":{"type":"local","command":["my-kanban"],"enabled":true}}}' > "$HOME/.config/opencode/opencode.json"
  managed_config_apply >/dev/null
  jq -e '.mcp.kanban.command == ["my-kanban"]' "$HOME/.config/opencode/opencode.json"
}

@test "rule 3: the retired local Codex Kanban server is removed, a personal one kept" {
  unset KANBAN_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.codex"
  printf '[mcp_servers.kanban]\ncommand = "kanban-mcp"\nrequired = true\nstartup_timeout_sec = 30\n' > "$HOME/.codex/config.toml"
  managed_config_apply >/dev/null
  if grep -q 'kanban' "$HOME/.codex/config.toml"; then false; fi
  printf '[mcp_servers.kanban]\ncommand = "my-kanban"\n' > "$HOME/.codex/config.toml"
  managed_config_apply >/dev/null
  grep -qx 'command = "my-kanban"' "$HOME/.codex/config.toml"
}

@test "rule 4: profile comes from the env, then the profile file, else container" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  [ "$(aicoding_profile)" = container ]
  aicoding_stamp_write profile host
  [ "$(aicoding_profile)" = host ]
  AICODING_PROFILE=minimal-pi
  [ "$(aicoding_profile)" = minimal-pi ]
}

@test "rule 4: a host keeps Codex on-request and workspace-write" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  aicoding_stamp_write profile host
  managed_config_apply >/dev/null
  grep -qx 'approval_policy = "on-request"' "$HOME/.codex/config.toml"
  grep -qx 'sandbox_mode = "workspace-write"' "$HOME/.codex/config.toml"
  [ -f "$HOME/.bashrc.d/aicoding-boot-sync.sh" ]
  [ ! -e "$HOME/.tmux.conf" ]
}

@test "rule 4: migration moves profile and stamps out of the manifest before deleting it" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  local shared="$HOME/.aicodingsetup"
  mkdir -p "$AICODING_STATE_DIR" "$shared" "$HOME/.codex/.aicoding-sync"
  echo '{"profile":"host","provision_commit":"p1","blueprint_commit":"b1","files":{}}' > "$AICODING_STATE_DIR/manifest.json"
  echo '{"files":{}}' > "$shared/manifest.json"
  aicoding_remove_legacy_state
  [ -f "$AICODING_STATE_DIR/manifest.json" ]
  aicoding_migrate_legacy_state
  [ "$(cat "$AICODING_STATE_DIR/profile")" = host ]
  [ "$(aicoding_stamp_read provision_commit)" = p1 ]
  [ "$(aicoding_stamp_read blueprint_commit)" = b1 ]
  aicoding_remove_legacy_state
  [ ! -e "$AICODING_STATE_DIR/manifest.json" ]
  [ ! -e "$shared/manifest.json" ]
  [ ! -e "$HOME/.codex/.aicoding-sync" ]
}

@test "rule 4: a moved blueprint stamp drops aicoding-status's cache" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_UPDATE_STATE="$TMPDIR/updates"
  mkdir -p "$AICODING_UPDATE_STATE"
  echo '{}' > "$AICODING_UPDATE_STATE/aicoding.json"
  aicoding_stamp_blueprint aaa
  [ ! -e "$AICODING_UPDATE_STATE/aicoding.json" ]
  echo '{}' > "$AICODING_UPDATE_STATE/aicoding.json"
  aicoding_stamp_blueprint aaa
  [ -e "$AICODING_UPDATE_STATE/aicoding.json" ]
}

@test "release order: an older release leaves shared files to the newer one" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _managed_release_ordinal() { echo 500; }
  local mine=500
  mkdir -p "$HOME/.claude/hooks"
  echo "$((mine + 100)) newer" > "$HOME/.claude/.aicoding-release"
  printf 'newer hook\n' > "$HOME/.claude/hooks/memory-hint.sh"
  run managed_config_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"left "*" shared files to the newer release"* ]]
  [ "$(cat "$HOME/.claude/hooks/memory-hint.sh")" = 'newer hook' ]
  [ ! -e "$HOME/.codex/config.toml" ]
  [ -f "$HOME/.bashrc.d/aicoding-env.sh" ]
  [ "$(cat "$HOME/.claude/.aicoding-release")" = "$((mine + 100)) newer" ]
}

@test "release order: a release at least as new writes and claims the shared roots" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _managed_release_ordinal() { echo 500; }
  local mine=500
  mkdir -p "$HOME/.claude"
  echo "$((mine - 100)) older" > "$HOME/.claude/.aicoding-release"
  managed_config_apply >/dev/null
  [ -f "$HOME/.claude/CLAUDE.md" ]
  read -r time sha < "$HOME/.claude/.aicoding-release"
  [ "$time" = "$mine" ]
  [ "$sha" = "$(git -C "$BLUEPRINT_ROOT" rev-parse HEAD)" ]
}

@test "release order: a shallow checkout has no ordinal and never holds back" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  git clone -q --depth 1 "file://$BLUEPRINT_ROOT" "$TMPDIR/shallow"
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/shallow"
  run _managed_release_ordinal
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "release order: a local --blueprint run writes but never moves the marker" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  export AICODING_BLUEPRINT_LOCAL=1
  _managed_release_ordinal() { echo 500; }
  local mine=500
  mkdir -p "$HOME/.claude"
  echo "$((mine + 100)) newer" > "$HOME/.claude/.aicoding-release"
  managed_config_apply >/dev/null
  [ -f "$HOME/.claude/CLAUDE.md" ]
  [ "$(cat "$HOME/.claude/.aicoding-release")" = "$((mine + 100)) newer" ]
}

@test "managed_inventory: covers owned, raw, mixed, block, skills and commands" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory
  [[ "$output" == *"$HOME/.local/bin/aicoding-worktree|raw|bin/aicoding-worktree"* ]]
  [[ "$output" == *"$HOME/.codex/config.toml|mixed|configs/codex/config.toml"* ]]
  [[ "$output" == *"$HOME/.claude/settings.json|mixed|configs/claude/settings.json"* ]]
  [[ "$output" == *"$HOME/.bashrc|block|"* ]]
  [[ "$output" == *"$HOME/.claude/skills/review-by-harness/SKILL.md|owned|skills/review-by-harness/SKILL.md"* ]]
  [[ "$output" == *"$HOME/.claude/commands/"*"|owned|commands/"* ]]
  [[ "$output" == *"$HOME/.tmux.conf|owned|"* ]]
}

@test "library: sources cleanly under set -euo pipefail" {
  bash -c "set -euo pipefail; . '$BLUEPRINT_ROOT/lib/blueprint-deploy.sh'"
}

@test "_substitute_file_to: strips memory-router from cursor mcp.json when token absent" {
  unset MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/cursor"
  cp "$BLUEPRINT_ROOT/configs/cursor/mcp.json" "$TMPDIR/clone/configs/cursor/mcp.json"
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/out.json"
  run jq -e '.mcpServers["memory-router"]' "$TMPDIR/out.json"
  [ "$status" -ne 0 ]
  # Other servers survive the strip.
  jq -e '.mcpServers.context7' "$TMPDIR/out.json"
}

@test "_substitute_file_to: keeps memory-router with substituted header when token set" {
  export MEMORY_ROUTER_TOKEN=tok-123
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/cursor"
  cp "$BLUEPRINT_ROOT/configs/cursor/mcp.json" "$TMPDIR/clone/configs/cursor/mcp.json"
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/out.json"
  jq -e '.mcpServers["memory-router"].headers.Authorization == "Bearer tok-123"' "$TMPDIR/out.json"
}

@test "_substitute_file_to: strips the codex memory-router section when token absent" {
  unset MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/codex"
  cp "$BLUEPRINT_ROOT/configs/codex/config.toml" "$TMPDIR/clone/configs/codex/config.toml"
  _substitute_file_to "$TMPDIR/clone/configs/codex/config.toml" "$TMPDIR/out.toml"
  if grep -q '^\[mcp_servers.memory-router\]' "$TMPDIR/out.toml"; then false; fi
  # Removed servers must not leave explanatory comments suggesting availability.
  if grep -q 'memory-router\|memory_search' "$TMPDIR/out.toml"; then false; fi
  # No dangling empty bearer anywhere in the rendered file.
  if grep -q 'Bearer "' "$TMPDIR/out.toml"; then false; fi
  # Other content is intact.
  grep -q '^model' "$TMPDIR/out.toml"
}

@test "_substitute_file_to: renders the hosted kanban MCP with the bearer for all three configs" {
  export KANBAN_TOKEN=kb-fake-render
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  local name
  for name in cursor/mcp.json opencode/opencode.json codex/config.toml; do
    mkdir -p "$TMPDIR/clone/configs/${name%/*}"
    cp "$BLUEPRINT_ROOT/configs/$name" "$TMPDIR/clone/configs/$name"
  done
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/cursor.json"
  _substitute_file_to "$TMPDIR/clone/configs/opencode/opencode.json" "$TMPDIR/opencode.json"
  _substitute_file_to "$TMPDIR/clone/configs/codex/config.toml" "$TMPDIR/codex.toml"
  jq -e '.mcpServers.kanban == {"url":"https://kanban.dataprospectors.at/mcp","headers":{"Authorization":"Bearer kb-fake-render"}}' "$TMPDIR/cursor.json"
  jq -e '.mcp.kanban.type == "remote" and .mcp.kanban.url == "https://kanban.dataprospectors.at/mcp"
         and .mcp.kanban.headers.Authorization == "Bearer kb-fake-render" and .mcp.kanban.oauth == false' \
    "$TMPDIR/opencode.json"
  run python3 -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["mcp_servers"]["kanban"])' "$TMPDIR/codex.toml"
  [ "$status" -eq 0 ]
  [ "$output" = "{'url': 'https://kanban.dataprospectors.at/mcp', 'http_headers': {'Authorization': 'Bearer kb-fake-render'}, 'required': False}" ]
  # No harness still launches the local stdio server.
  if grep -q 'kanban-mcp' "$TMPDIR/cursor.json" "$TMPDIR/opencode.json" "$TMPDIR/codex.toml"; then false; fi
  for name in cursor.json opencode.json codex.toml; do
    [ "$(stat -c %a "$TMPDIR/$name")" = 600 ]
  done
}

@test "_substitute_file_to: strips kanban from all three configs when KANBAN_TOKEN is absent" {
  unset KANBAN_TOKEN
  export MEMORY_ROUTER_TOKEN=tok-keep
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  local name
  for name in cursor/mcp.json opencode/opencode.json codex/config.toml; do
    mkdir -p "$TMPDIR/clone/configs/${name%/*}"
    cp "$BLUEPRINT_ROOT/configs/$name" "$TMPDIR/clone/configs/$name"
  done
  _substitute_file_to "$TMPDIR/clone/configs/cursor/mcp.json" "$TMPDIR/cursor.json"
  _substitute_file_to "$TMPDIR/clone/configs/opencode/opencode.json" "$TMPDIR/opencode.json"
  _substitute_file_to "$TMPDIR/clone/configs/codex/config.toml" "$TMPDIR/codex.toml"
  run jq -e '.mcpServers.kanban' "$TMPDIR/cursor.json"; [ "$status" -ne 0 ]
  run jq -e '.mcp.kanban' "$TMPDIR/opencode.json"; [ "$status" -ne 0 ]
  if grep -q '^\[mcp_servers.kanban\]\|kanban.dataprospectors' "$TMPDIR/codex.toml"; then false; fi
  # The other token-gated server is independent and survives.
  jq -e '.mcpServers["memory-router"].headers.Authorization == "Bearer tok-keep"' "$TMPDIR/cursor.json"
  jq -e '.mcp["memory-router"]' "$TMPDIR/opencode.json"
  grep -q '^\[mcp_servers.memory-router\]' "$TMPDIR/codex.toml"
  python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$TMPDIR/codex.toml"
}

@test "_substitute_file_to: strips both token-gated servers when neither token is set" {
  unset KANBAN_TOKEN MEMORY_ROUTER_TOKEN
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$TMPDIR/clone/configs/codex"
  cp "$BLUEPRINT_ROOT/configs/codex/config.toml" "$TMPDIR/clone/configs/codex/config.toml"
  _substitute_file_to "$TMPDIR/clone/configs/codex/config.toml" "$TMPDIR/codex.toml"
  if grep -q 'Bearer' "$TMPDIR/codex.toml"; then false; fi
  grep -q '^\[mcp_servers.context7\]' "$TMPDIR/codex.toml"
}

@test "Codex rendered comments stay generic while configured server and HOME values render" {
  export MEMORY_ROUTER_TOKEN=synthetic-comment-test
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  _substitute_file_to "$BLUEPRINT_ROOT/configs/codex/config.toml" "$TMPDIR/out.toml"
  grep '^#' "$TMPDIR/out.toml" > "$TMPDIR/comments"
  # Prose explains substitution without itself becoming a path or placeholder.
  if grep -qF "$HOME" "$TMPDIR/comments"; then false; fi
  if grep -qF '{{' "$TMPDIR/comments"; then false; fi
  grep -qF "notify = [\"$HOME/.local/bin/codex-turn-done\"]" "$TMPDIR/out.toml"
  grep -q '^\[mcp_servers.memory-router\]' "$TMPDIR/out.toml"
  grep -q 'memory_search tool' "$TMPDIR/comments"
  grep -qF 'Authorization = "Bearer synthetic-comment-test"' "$TMPDIR/out.toml"
}

@test "managed_inventory_overwrite: includes global claude CLAUDE.md" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/CLAUDE.md|owned|configs/claude/CLAUDE.md"
}

@test "managed_inventory_overwrite: includes bw-deny-files hook" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/hooks/bw-deny-files.sh|owned|configs/claude/hooks/bw-deny-files.sh"
}

@test "shared destination lock lives in the shared root and excludes a second writer" {
  mkdir -p "$HOME/.claude"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  aicoding_shared_locks_acquire "$HOME/.claude/hooks/x.sh"
  [ -f "$HOME/.claude/.aicoding-update.lock" ]
  run bash -c '. "$1/lib/blueprint-deploy.sh"; aicoding_shared_locks_acquire "$HOME/.claude/settings.json"' _ "$BLUEPRINT_ROOT"
  [ "$status" -ne 0 ]
}

@test "OpenCode config writers with separate runtime data contend on the config root" {
  mkdir -p "$HOME/.config/opencode" "$TMPDIR/other-home/.config"
  ln -s "$HOME/.config/opencode" "$TMPDIR/other-home/.config/opencode"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  aicoding_shared_locks_acquire "$HOME/.config/opencode/opencode.json"
  [ -f "$HOME/.config/opencode/.aicoding-update.lock" ]
  run bash -c 'export HOME="$2"; . "$1/lib/blueprint-deploy.sh"; aicoding_shared_locks_acquire "$HOME/.config/opencode/opencode.json"' \
    _ "$BLUEPRINT_ROOT" "$TMPDIR/other-home"
  [ "$status" -ne 0 ]
}

@test "managed root locks cover both OpenCode config and runtime data" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  aicoding_shared_locks_acquire_managed_roots
  local root
  for root in "$HOME/.config/opencode" "$HOME/.local/share/opencode"; do
    [ -f "$root/.aicoding-update.lock" ]
    run bash -c '. "$1/lib/blueprint-deploy.sh"; aicoding_shared_locks_acquire "$2/resource"' \
      _ "$BLUEPRINT_ROOT" "$root"
    [ "$status" -ne 0 ]
  done
}

@test "owned hook restoration requires historical generated provenance" {
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/clone"
  git init -q -b main "$AICODING_BLUEPRINT_CLONE"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/configs/claude/hooks" "$HOME/.claude/hooks"
  local source_path=configs/claude/hooks/example.sh dest="$HOME/.claude/hooks/example.sh"
  printf '#!/bin/sh\necho old\n' > "$AICODING_BLUEPRINT_CLONE/$source_path"
  git -C "$AICODING_BLUEPRINT_CLONE" add .
  git -C "$AICODING_BLUEPRINT_CLONE" -c user.email=t@t -c user.name=t commit -qm old
  cp "$AICODING_BLUEPRINT_CLONE/$source_path" "$dest"
  printf '#!/bin/sh\necho new\n' > "$AICODING_BLUEPRINT_CLONE/$source_path"
  git -C "$AICODING_BLUEPRINT_CLONE" -c user.email=t@t -c user.name=t commit -qam new
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"

  run owned_file_has_generated_provenance "$dest" "$source_path"
  [ "$status" -eq 0 ]
  printf '#!/bin/sh\necho user edit\n' > "$dest"
  run owned_file_has_generated_provenance "$dest" "$source_path"
  [ "$status" -ne 0 ]
}

@test "owned hook provenance works after Git metadata is removed" {
  export AICODING_BLUEPRINT_CLONE="$TMPDIR/release"
  local source_path=configs/claude/hooks/example.sh
  local dest="$HOME/.claude/hooks/example.sh"
  mkdir -p "$AICODING_BLUEPRINT_CLONE/.aicoding-generated-provenance/$source_path" \
    "$(dirname "$dest")"
  printf '#!/bin/sh\necho old\n' \
    > "$AICODING_BLUEPRINT_CLONE/.aicoding-generated-provenance/$source_path/old"
  printf '#!/bin/sh\necho old\n' > "$dest"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"

  run owned_file_has_generated_provenance "$dest" "$source_path"
  [ "$status" -eq 0 ]

  printf '#!/bin/sh\necho edited\n' > "$dest"
  run owned_file_has_generated_provenance "$dest" "$source_path"
  [ "$status" -ne 0 ]
}

@test "cursor cli-config fragment: valid JSON, statusLine reuses the claude script" {
  jq -e '.statusLine.type == "command"' "$BLUEPRINT_ROOT/configs/cursor/cli-config.json"
  jq -re '.statusLine.command' "$BLUEPRINT_ROOT/configs/cursor/cli-config.json" \
    | grep -qF '{{HOME}}/.claude/hooks/custom-statusline.js'
}

@test "codex config fragment: carries a [tui] status_line item list" {
  grep -qE '^status_line = \[' "$BLUEPRINT_ROOT/configs/codex/config.toml"
  grep -q 'context-used' "$BLUEPRINT_ROOT/configs/codex/config.toml"
}

@test "codex config fragment: disables the alternate screen (tmux scrollback)" {
  grep -qE '^alternate_screen = "never"' "$BLUEPRINT_ROOT/configs/codex/config.toml"
}

@test "managed_inventory_overwrite: includes bash aliases" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.bashrc.d/aicoding-aliases.sh|owned|configs/bash/aliases.sh"
}

@test "managed_inventory_overwrite: includes git credential fallback helper" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.local/bin/git-credential-aicoding|owned|configs/git/git-credential-aicoding"
}

@test "claude settings fragment: cross-session messaging policy keys" {
  jq -e '.crossSessionInbound == "accept"' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  jq -e '.isolatePeerMachines == true' "$BLUEPRINT_ROOT/configs/claude/settings.json"
}

@test "claude CLAUDE.md fragment: parallel-session coordination protocol" {
  grep -q '^## Parallel-session coordination' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'gate evidence' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'dedicated git worktree' "$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
}

@test "claude CLAUDE.md fragment: retrieval read path goes through memory_search" {
  CM="$BLUEPRINT_ROOT/configs/claude/CLAUDE.md"
  grep -q 'memory_search' "$CM"
  grep -q 'memory-router' "$CM"
  # Fallback and non-blocking clauses must both survive edits.
  grep -q 'grepping the local `~/homelab-wiki` clone' "$CM"
  grep -qi 'rather than blocking' "$CM"
  # The old unconditional "consult the wiki clone first" sentence is gone
  # (it wrapped across two lines, so compare with newlines flattened).
  if tr '\n' ' ' < "$CM" | grep -q 'consult *`~/homelab-wiki` before re-deriving'; then false; fi
}

@test "managed_inventory_overwrite: llmwiki distill hook + distiller agent rows, nudge row gone" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run managed_inventory_overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "$HOME/.claude/hooks/llmwiki-distill.sh|owned|configs/claude/hooks/llmwiki-distill.sh"
  echo "$output" | grep -qF "$HOME/.claude/agents/llmwiki-distiller.md|owned|configs/claude/agents/llmwiki-distiller.md"
  if echo "$output" | grep -q 'llmwiki-nudge'; then false; fi
}

@test "claude settings fragment: Stop hook is the async distill launcher" {
  jq -e '
    [.hooks.Stop[].hooks[]
      | select(.command | contains("{{HOME}}/.claude/hooks/llmwiki-distill.sh"))]
    | length == 1 and .[0].async == true and .[0].timeout == 600
  ' "$BLUEPRINT_ROOT/configs/claude/settings.json"
  if grep -q 'llmwiki-nudge' "$BLUEPRINT_ROOT/configs/claude/settings.json"; then false; fi
}

@test "enumerate_skill_files: lists nested files relative to root, sorted" {
  mkdir -p "$TMPDIR/skills/b-skill/assets" "$TMPDIR/skills/a-skill"
  echo x > "$TMPDIR/skills/a-skill/SKILL.md"
  echo y > "$TMPDIR/skills/b-skill/SKILL.md"
  echo z > "$TMPDIR/skills/b-skill/assets/logo.png"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/skills"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a-skill/SKILL.md" ]
  [ "${lines[1]}" = "b-skill/SKILL.md" ]
  [ "${lines[2]}" = "b-skill/assets/logo.png" ]
}

@test "enumerate_skill_files: empty for missing root" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run enumerate_skill_files "$TMPDIR/no-such-dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude settings fragment: read-only shell commands are allow-listed" {
  local f="$BLUEPRINT_ROOT/configs/claude/settings.json"
  for rule in 'Bash(cd:*)' 'Bash(grep:*)' 'Bash(rg:*)' 'Bash(cat:*)' \
              'Bash(head:*)' 'Bash(tail:*)' 'Bash(sed -n:*)' 'Bash(ls:*)' \
              'Bash(find:*)' 'Bash(wc:*)'; do
    jq -e --arg r "$rule" '.permissions.allow | index($r) != null' "$f" \
      || { echo "missing allow rule: $rule"; return 1; }
  done
  jq -e '.permissions.allow == (.permissions.allow | unique)' "$f"
}

@test "aicoding_shared_locks_release frees the writer locks for another process" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  mkdir -p "$HOME/.claude"
  aicoding_shared_locks_acquire "$HOME/.claude/.aicoding-managed"
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -ne 0 ]
  aicoding_shared_locks_release
  run flock -n "$HOME/.claude/.aicoding-update.lock" true
  [ "$status" -eq 0 ]
  [ "${#_AICODING_SHARED_LOCK_FDS[@]}" -eq 0 ]
}

@test "aicoding_shared_locks_release is a no-op when nothing is held" {
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  run aicoding_shared_locks_release
  [ "$status" -eq 0 ]
}
