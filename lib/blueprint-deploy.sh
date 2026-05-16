# aiCodingBaseSetup — blueprint deployment primitives.
# Sourced by install.sh and bin/aicoding-update. Pure shell functions only;
# no top-level side effects. Caller is responsible for `set -euo pipefail`.

: "${AICODING_MANIFEST:=$HOME/.aicodingsetup/manifest.json}"
: "${AICODING_BLUEPRINT_CLONE:=/tmp/aicoding}"

# compute_hash <path> — echo the sha256 hex of file content; empty if missing.
compute_hash() {
  [ -e "$1" ] || { echo ""; return 0; }
  sha256sum "$1" | awk '{print $1}'
}

# compute_block_hash <path> <start_marker> <end_marker> — sha256 of content
# strictly between the start and end marker lines (exclusive). Each captured
# line retains its trailing newline (so two lines hash "line1\nline2\n").
# Returns empty string if either marker is absent.
compute_block_hash() {
  local path=$1 start=$2 end=$3
  [ -e "$path" ] || { echo ""; return 0; }
  # Both markers must be present (as full-line matches) for a block to exist.
  grep -qxF "$start" "$path" || { echo ""; return 0; }
  grep -qxF "$end"   "$path" || { echo ""; return 0; }
  awk -v s="$start" -v e="$end" '
    $0 == s { in_block = 1; next }
    $0 == e { in_block = 0; exit }
    in_block { print }
  ' "$path" | sha256sum | awk '{print $1}'
}

# read_manifest — echo the manifest JSON; empty manifest if missing.
read_manifest() {
  if [ -f "$AICODING_MANIFEST" ]; then
    cat "$AICODING_MANIFEST"
  else
    echo '{"schema_version":1,"files":{}}'
  fi
}

# write_manifest <json> — atomically write the manifest JSON to disk.
write_manifest() {
  local json=$1
  local dir
  dir=$(dirname "$AICODING_MANIFEST")
  mkdir -p "$dir"
  local tmp="$AICODING_MANIFEST.tmp"
  printf '%s\n' "$json" | jq '.' > "$tmp"
  mv "$tmp" "$AICODING_MANIFEST"
}

# In-memory staged manifest; modified by manifest_set_file /
# manifest_remove_file between stage_begin and stage_commit.
_aicoding_pending_manifest=""

manifest_stage_begin() {
  _aicoding_pending_manifest=$(read_manifest)
}

manifest_stage_commit() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _aicoding_pending_manifest=$(printf '%s' "$_aicoding_pending_manifest" \
    | jq --arg t "$now" '.deployed_at = $t')
  write_manifest "$_aicoding_pending_manifest"
  _aicoding_pending_manifest=""
}

manifest_stage_set_top() {
  local key=$1 val=$2
  _aicoding_pending_manifest=$(printf '%s' "$_aicoding_pending_manifest" \
    | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
}

# manifest_get_file <path> — echo the per-file JSON object, or "null".
manifest_get_file() {
  read_manifest | jq --arg p "$1" '.files[$p] // null'
}

# manifest_set_file <path> <entry_json> — merge a per-file entry into the
# in-memory staged manifest (caller must have called manifest_stage_begin).
manifest_set_file() {
  local path=$1 entry=$2
  _aicoding_pending_manifest=$(printf '%s' "$_aicoding_pending_manifest" \
    | jq --arg p "$path" --argjson e "$entry" '.files[$p] = $e')
}

# manifest_remove_file <path> — drop a per-file entry from the staged manifest.
manifest_remove_file() {
  local path=$1
  _aicoding_pending_manifest=$(printf '%s' "$_aicoding_pending_manifest" \
    | jq --arg p "$path" 'del(.files[$p])')
}

# classify_file <dest_path> <src_path> <mode> — echoes one of:
#   up_to_date, will_update, drifted_but_aligned, drifted_and_updating,
#   new_file, to_remove, merge.
classify_file() {
  local dest=$1 src=$2 mode=$3

  if [ "$mode" = "merge" ]; then
    echo "merge"
    return 0
  fi

  local entry
  entry=$(manifest_get_file "$dest")

  if [ "$entry" = "null" ]; then
    [ -e "$src" ] && { echo "new_file"; return 0; }
    echo "up_to_date"  # neither tracked nor present in blueprint; no-op.
    return 0
  fi

  if [ ! -e "$src" ]; then
    echo "to_remove"
    return 0
  fi

  local current new deployed
  current=$(compute_hash "$dest")
  new=$(compute_hash "$src")
  deployed=$(printf '%s' "$entry" | jq -r '.deployed_hash // empty')

  if [ "$current" = "$deployed" ] && [ "$current" = "$new" ]; then
    echo "up_to_date"
  elif [ "$current" = "$deployed" ] && [ "$current" != "$new" ]; then
    echo "will_update"
  elif [ "$current" != "$deployed" ] && [ "$current" = "$new" ]; then
    echo "drifted_but_aligned"
  else
    echo "drifted_and_updating"
  fi
}

# deploy_overwrite_file <src> <dest> <source_label_relative_to_blueprint>
# Copies src to dest and records {mode: overwrite, source, deployed_hash}
# in the pending manifest. Caller must wrap with manifest_stage_begin/commit.
deploy_overwrite_file() {
  local src=$1 dest=$2 label=$3
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  local h
  h=$(compute_hash "$dest")
  local entry
  entry=$(jq -n --arg s "$label" --arg h "$h" \
    '{mode:"overwrite", source:$s, deployed_hash:$h}')
  manifest_set_file "$dest" "$entry"
}

# _json_merge_into <target_path> <source_path> — deep-merge source into
# target; source wins for scalars; "allow" arrays are unioned; other arrays:
# source wins.
_json_merge_into() {
  local target=$1 source=$2
  if [ ! -f "$target" ]; then
    cp "$source" "$target"
    return
  fi
  local merged
  merged=$(jq -s '
    def deep_merge(key):
      if length == 2 then
        .[0] as $a | .[1] as $b |
        if ($a|type)=="object" and ($b|type)=="object" then
          ($a|keys_unsorted) + ($b|keys_unsorted) | unique
          | map(. as $k |
              if ($a|has($k)) and ($b|has($k)) then
                {($k): ([$a[$k],$b[$k]] | deep_merge($k))}
              elif ($b|has($k)) then {($k): $b[$k]}
              else {($k): $a[$k]} end)
          | add // {}
        elif ($a|type)=="array" and ($b|type)=="array" then
          if key == "allow" then ($a + $b) | unique else $b end
        else
          if ($b == null or $b == "") then $a else $b end
        end
      else .[0] end;
    [.[0],.[1]] | deep_merge("")
  ' "$target" "$source")
  printf '%s\n' "$merged" > "$target"
}

# deploy_merge_file <src> <dest> <source_label>
deploy_merge_file() {
  local src=$1 dest=$2 label=$3
  mkdir -p "$(dirname "$dest")"
  _json_merge_into "$dest" "$src"
  local entry
  entry=$(jq -n --arg s "$label" '{mode:"merge", source:$s}')
  manifest_set_file "$dest" "$entry"
}

# deploy_marker_block <dest> <body> <start_marker> <end_marker>
# Inserts or replaces a guarded block in dest. If markers are absent,
# appends `<start>\n<body>\n<end>` at the end. If markers exist, replaces
# the content between them (the markers themselves are preserved).
deploy_marker_block() {
  local dest=$1 body=$2 start=$3 end=$4
  mkdir -p "$(dirname "$dest")"
  touch "$dest"

  if grep -qxF "$start" "$dest" && grep -qxF "$end" "$dest"; then
    # Replace existing block.
    local tmp="$dest.tmp"
    awk -v s="$start" -v e="$end" -v b="$body" '
      $0 == s { print; print b; in_block = 1; next }
      $0 == e { print; in_block = 0; next }
      !in_block { print }
    ' "$dest" > "$tmp"
    mv "$tmp" "$dest"
  else
    # Append a new block at the end.
    {
      printf '\n%s\n' "$start"
      printf '%s\n' "$body"
      printf '%s\n' "$end"
    } >> "$dest"
  fi

  local h
  h=$(compute_block_hash "$dest" "$start" "$end")
  local entry
  entry=$(jq -n --arg s "$start" --arg e "$end" --arg h "$h" \
    '{mode:"marker_block", source:"(composed)", marker_start:$s, marker_end:$e, deployed_block_hash:$h}')
  manifest_set_file "$dest" "$entry"
}

remove_managed_file() {
  local dest=$1
  rm -f "$dest"
  manifest_remove_file "$dest"
}
