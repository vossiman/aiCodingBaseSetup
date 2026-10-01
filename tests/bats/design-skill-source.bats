#!/usr/bin/env bats

@test "design skill: committed bundle matches its source pin and has no escaping paths" {
  run python3 "$BLUEPRINT_ROOT/tools/update-design-skill.py" --check
  [ "$status" -eq 0 ]
}

@test "design skill: refresh rejects dirty sources and survives failed exports" {
  run python3 "$BLUEPRINT_ROOT/tests/test_design_skill_source.py"
  [ "$status" -eq 0 ]
}

@test "design skill: normal managed deployment installs portable bundle byte-for-byte" {
  local scratch
  scratch=$(mktemp -d)
  export HOME="$scratch/home" AICODING_MANIFEST="$scratch/manifest.json"
  mkdir -p "$HOME"
  source "$BLUEPRINT_ROOT/lib/blueprint-deploy.sh"
  manifest_stage_begin
  local rel src dest
  while IFS= read -r rel; do
    [[ "$rel" == dataprospectors-design/* ]] || continue
    src="$BLUEPRINT_ROOT/skills/$rel"
    dest="$HOME/.claude/skills/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ "$rel" == *.md ]]; then
      deploy_overwrite_file_prose "$src" "$dest" "skills/$rel"
    else
      deploy_overwrite_file "$src" "$dest" "skills/$rel"
    fi
    cmp -s "$src" "$dest"
  done < <(enumerate_skill_files "$BLUEPRINT_ROOT/skills")
  manifest_stage_commit
  [ -f "$HOME/.claude/skills/dataprospectors-design/modules/consumption.md" ]
  [ -f "$HOME/.claude/skills/dataprospectors-design/references/native-theme.css" ]
  [ -f "$HOME/.claude/skills/dataprospectors-design/SOURCE.json" ]
  rm -rf "$scratch"
}
