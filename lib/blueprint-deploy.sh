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
