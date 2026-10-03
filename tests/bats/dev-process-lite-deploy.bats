#!/usr/bin/env bats
# The dev-process-lite skills deploy byte for byte, the scripts stay
# executable, and a repo with its own process is detected and not shadowed.

bats_require_minimum_version 1.5.0

setup() {
  : "${BLUEPRINT_ROOT:?unset, run via tests/bats/run.sh}"
  TMPDIR=$(mktemp -d)
  export HOME="$TMPDIR/home" AICODING_BLUEPRINT_CLONE="$BLUEPRINT_ROOT"
  export AICODING_STATE_DIR="$TMPDIR/state"
  export GIT_CEILING_DIRECTORIES="$TMPDIR"
  export DEV_PROCESS_LITE_CODEX_MODELS="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite/codex-models.json"
  export DEV_PROCESS_LITE_CURSOR_MODELS="$BLUEPRINT_ROOT/tests/bats/fixtures/dev-process-lite/cursor-models.txt"
  mkdir -p "$HOME"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  managed_config_apply >/dev/null
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "deploy: both skills land byte for byte, scripts stay executable" {
  local rel
  for rel in dev-process-lite/SKILL.md dev-process-lite/policy.md \
             dev-process-lite/detect.sh dev-process-lite/routes.sh \
             dev-process-lite/routes.default.json assess-run/SKILL.md; do
    cmp -s "$BLUEPRINT_ROOT/skills/$rel" "$HOME/.claude/skills/$rel"
  done
  [ -x "$HOME/.claude/skills/dev-process-lite/detect.sh" ]
  [ -x "$HOME/.claude/skills/dev-process-lite/routes.sh" ]
}

@test "deploy: the deployed routes.sh finds its deployed default table" {
  mkdir -p "$TMPDIR/norepo"
  cd "$TMPDIR/norepo"
  run --separate-stderr env -u CLAUDECODE -u CODEX_THREAD_ID \
    bash "$HOME/.claude/skills/dev-process-lite/routes.sh" claude implementer
  [ "$status" -eq 0 ]
  [ "$(jq -r .source <<<"$output")" = "$HOME/.claude/skills/dev-process-lite/routes.default.json" ]
}

@test "precedence: a repo with its own process is detected and its skills are not shadowed" {
  local be="$TMPDIR/be"
  git init -q "$be"
  mkdir -p "$be/docs" "$be/.claude/skills/assess" "$be/.claude/skills/dev-process" "$be/.agents/skills/dev-process"
  echo "# process" > "$be/docs/DEV_PROCESS.md"
  printf -- '---\nname: assess\n---\n' > "$be/.claude/skills/assess/SKILL.md"
  printf -- '---\nname: dev-process\n---\n' > "$be/.claude/skills/dev-process/SKILL.md"
  printf -- '---\nname: dev-process\n---\n' > "$be/.agents/skills/dev-process/SKILL.md"
  cd "$be"
  run bash "$HOME/.claude/skills/dev-process-lite/detect.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "project "*"/docs/DEV_PROCESS.md" ]]
  run comm -12 <(ls "$HOME/.claude/skills" | sort) \
               <(ls "$be/.claude/skills" "$be/.agents/skills" | grep -v ':$' | grep -v '^$' | sort -u)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
