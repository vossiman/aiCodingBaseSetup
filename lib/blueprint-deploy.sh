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

  # File tracked in manifest + blueprint source present + dest missing →
  # restore (not drifted_and_updating, since the user didn't modify anything;
  # the file just isn't on disk).
  if [ ! -e "$dest" ]; then
    echo "restore"
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

# ----------------------------------------------------------------------------
# Managed inventory — single source of truth for both install.sh and
# bin/aicoding-update. Each emitter prints pipe-delimited rows of the form
# <dest_abs_path>|<mode>|<source_rel_to_blueprint>. Callers consume with
#   while IFS= read -r entry; do ... done < <(managed_inventory_overwrite)
# (Do NOT read into a bash array via $() — the dest paths interpolate $HOME
# and we want shell expansion to happen at emit time, not earlier.)
# ----------------------------------------------------------------------------

# managed_inventory_overwrite — files deployed by full overwrite.
managed_inventory_overwrite() {
  cat <<EOF
$HOME/.tmux.conf|overwrite|configs/tmux/tmux.conf
$HOME/.claude/hooks/custom-statusline.js|overwrite|configs/claude/hooks/custom-statusline.js
$HOME/.bashrc.d/aicoding-env.sh|overwrite|configs/bash/env.sh
$HOME/.bashrc.d/aicoding-ssh-auth-sock.sh|overwrite|configs/bash/ssh-auth-sock.sh
$HOME/.codex/config.toml|overwrite|configs/codex/config.toml
EOF
}

# managed_inventory_merge — JSON configs deep-merged into user files.
managed_inventory_merge() {
  cat <<EOF
$HOME/.claude/settings.json|merge|configs/claude/settings.json
$HOME/.config/opencode/opencode.json|merge|configs/opencode/opencode.json
$HOME/.cursor/mcp.json|merge|configs/cursor/mcp.json
EOF
}

# Fixed marker strings for the managed ~/.bashrc block.
managed_marker_block_start() { printf '%s' '# >>> aicoding managed block — do not edit between markers >>>'; }
managed_marker_block_end()   { printf '%s' '# <<< aicoding managed block <<<'; }

# managed_bashrc_path — destination of the marker_block managed file.
managed_bashrc_path() { printf '%s' "$HOME/.bashrc"; }

# managed_bashrc_block_body — emit the body that lives between the markers.
managed_bashrc_block_body() {
  cat <<'EOF'
# Sourced from configs/bash/* via the aicoding blueprint. Edit those
# files (or your own ~/.bashrc.d/local-*.sh additions), not this block.
export PATH="/usr/local/go/bin:$PATH"
for _aicoding_f in "$HOME"/.bashrc.d/*.sh; do
  [ -r "$_aicoding_f" ] && . "$_aicoding_f"
done
unset _aicoding_f
EOF
}

# load_secrets_env — source ~/.aicodingsetup/.secrets.env if present so that
# substitute_secrets has the API-key env vars it needs. Idempotent and safe
# to call with no file present (no-op).
load_secrets_env() {
  local f="${AICODING_SECRETS_FILE:-$HOME/.aicodingsetup/.secrets.env}"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}

# substitute_secrets <content> — expand the {{HOME}} and {{*_API_KEY}}
# placeholders shipped in configs/claude/settings.json and skill SKILL.md
# files. Missing env vars expand to the empty string (same behavior as
# install.sh's old definition).
substitute_secrets() {
  local content="$1"
  content="${content//\{\{HOME\}\}/$HOME}"
  content="${content//\{\{FIRECRAWL_API_KEY\}\}/${FIRECRAWL_API_KEY:-}}"
  content="${content//\{\{BRAVE_API_KEY\}\}/${BRAVE_API_KEY:-}}"
  content="${content//\{\{CLOUDFLARE_API_TOKEN\}\}/${CLOUDFLARE_API_TOKEN:-}}"
  content="${content//\{\{CLOUDFLARE_ACCOUNT_ID\}\}/${CLOUDFLARE_ACCOUNT_ID:-}}"
  printf '%s' "$content"
}

# _substitute_file_to <src> <dest_tmp> — like substitute_secrets but reads
# from a file and writes to another file, preserving the source's exact byte
# content (including any trailing newline). Uses sed to avoid bash command
# substitution's "strip trailing newlines" behavior.
_substitute_file_to() {
  local src=$1 out=$2
  # The five placeholders are mutually independent; one sed pipeline handles
  # all of them with each value safely quoted (we escape `&`, `/`, and `\`
  # because they're sed-replacement metacharacters).
  local home_v="$HOME"
  local fc_v="${FIRECRAWL_API_KEY:-}"
  local br_v="${BRAVE_API_KEY:-}"
  local cf_t_v="${CLOUDFLARE_API_TOKEN:-}"
  local cf_a_v="${CLOUDFLARE_ACCOUNT_ID:-}"
  _esc() { printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'; }
  sed \
    -e "s/{{HOME}}/$(_esc "$home_v")/g" \
    -e "s/{{FIRECRAWL_API_KEY}}/$(_esc "$fc_v")/g" \
    -e "s/{{BRAVE_API_KEY}}/$(_esc "$br_v")/g" \
    -e "s/{{CLOUDFLARE_API_TOKEN}}/$(_esc "$cf_t_v")/g" \
    -e "s/{{CLOUDFLARE_ACCOUNT_ID}}/$(_esc "$cf_a_v")/g" \
    "$src" > "$out"
}

# deploy_overwrite_file_substituted <src> <dest> <label>
# Like deploy_overwrite_file, but expands {{HOME}} / {{*_API_KEY}} placeholders
# in src before writing. The recorded deployed_hash is the hash of the
# substituted-content file (matches what's actually on disk).
deploy_overwrite_file_substituted() {
  local src=$1 dest=$2 label=$3
  local tmp; tmp=$(mktemp)
  _substitute_file_to "$src" "$tmp"
  deploy_overwrite_file "$tmp" "$dest" "$label"
  rm -f "$tmp"
}

# deploy_merge_file_substituted <src> <dest> <label>
# Like deploy_merge_file, but expands placeholders in src before merging.
deploy_merge_file_substituted() {
  local src=$1 dest=$2 label=$3
  local tmp; tmp=$(mktemp)
  _substitute_file_to "$src" "$tmp"
  deploy_merge_file "$tmp" "$dest" "$label"
  rm -f "$tmp"
}

# manifest_check_schema — exit non-zero if the on-disk manifest's
# schema_version is higher than this library understands. Call after
# verifying the manifest file exists.
manifest_check_schema() {
  local current=1
  local manifest_schema
  manifest_schema=$(jq -r '.schema_version // 1' "$AICODING_MANIFEST" 2>/dev/null || echo 1)
  if [[ "$manifest_schema" =~ ^[0-9]+$ ]] && (( manifest_schema > current )); then
    echo "aicoding-update: manifest schema_version $manifest_schema is newer than this tool (knows up to $current)." >&2
    echo "Update aiCodingBaseSetup before running this." >&2
    exit 3
  fi
}

# classify_marker_block <dest> — echo a bucket like classify_file, specialized
# for marker_block files. The "new" hash is what deploy_marker_block will
# write (the body lines, each terminated by \n; matches compute_block_hash's
# awk-print semantics). Returns one of: up_to_date, drifted_and_updating,
# new_file.
classify_marker_block() {
  local dest=$1
  local entry deployed current
  entry=$(manifest_get_file "$dest")
  local start; start=$(managed_marker_block_start)
  local end;   end=$(managed_marker_block_end)

  if [ "$entry" = "null" ]; then
    # Not tracked yet. If the user happens to have an existing block, the
    # caller (aicoding-update) shouldn't be classifying this — adopt is
    # install.sh's job. Treat as new_file so the apply step writes it.
    echo "new_file"
    return 0
  fi

  # File truly absent on disk → restore (not drift; nothing was edited away,
  # the file simply isn't there). Distinguish from "file present but markers
  # missing", which IS user-edit drift and stays drifted_and_updating.
  if [ ! -e "$dest" ]; then
    echo "restore"
    return 0
  fi

  current=$(compute_block_hash "$dest" "$start" "$end")
  deployed=$(printf '%s' "$entry" | jq -r '.deployed_block_hash // empty')

  if [ -z "$current" ]; then
    # File present but marker block missing on disk — user removed the
    # markers; treat as drift so the apply step backs up before re-deploy.
    echo "drifted_and_updating"
    return 0
  fi

  # Compare current block hash to the body the library would deploy. We
  # build the expected hash by computing compute_block_hash on a temp file
  # with the canonical body between the markers — guarantees the same awk
  # semantics as the on-disk path.
  local tmp_expected new_hash
  tmp_expected=$(mktemp)
  {
    printf '%s\n' "$start"
    managed_bashrc_block_body
    printf '%s\n' "$end"
  } > "$tmp_expected"
  new_hash=$(compute_block_hash "$tmp_expected" "$start" "$end")
  rm -f "$tmp_expected"

  if [ "$current" = "$deployed" ] && [ "$current" = "$new_hash" ]; then
    echo "up_to_date"
  elif [ "$current" = "$deployed" ] && [ "$current" != "$new_hash" ]; then
    # Tracked, user hasn't edited the block, blueprint advanced.
    echo "will_update"
  elif [ "$current" != "$deployed" ] && [ "$current" = "$new_hash" ]; then
    echo "drifted_but_aligned"
  else
    echo "drifted_and_updating"
  fi
}

# classify_managed_files — populate the caller's BUCKETS, FILE_MODE, and
# FILE_SOURCE associative arrays with one entry per managed file (overwrite,
# merge, marker_block, blueprint skills) plus any manifest entries not in
# the current blueprint inventory (bucketed to_remove).
#
# Caller must:
#   - declare -A BUCKETS FILE_MODE FILE_SOURCE
#   - set AICODING_BLUEPRINT_CLONE to the blueprint working tree
#   - set AICODING_MANIFEST to the manifest path (read for to_remove sweep)
#
# Used by bin/aicoding-update and by install.sh's reconcile mode.
classify_managed_files() {
  local dest mode source
  # Overwrite-mode files from the blueprint inventory.
  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    FILE_MODE[$dest]=$mode
    FILE_SOURCE[$dest]=$source
    BUCKETS[$dest]=$(classify_file "$dest" "$AICODING_BLUEPRINT_CLONE/$source" "$mode")
  done < <(managed_inventory_overwrite)

  # Merge-mode files.
  while IFS='|' read -r dest mode source; do
    [[ -z "$dest" ]] && continue
    FILE_MODE[$dest]=$mode
    FILE_SOURCE[$dest]=$source
    BUCKETS[$dest]=$(classify_file "$dest" "$AICODING_BLUEPRINT_CLONE/$source" "$mode")
  done < <(managed_inventory_merge)

  # marker_block (~/.bashrc).
  local bashrc_dest
  bashrc_dest=$(managed_bashrc_path)
  FILE_MODE[$bashrc_dest]=marker_block
  FILE_SOURCE[$bashrc_dest]="(composed)"
  BUCKETS[$bashrc_dest]=$(classify_marker_block "$bashrc_dest")

  # Skills enumerated from the blueprint clone.
  local skill_dir skill_name
  for skill_dir in "$AICODING_BLUEPRINT_CLONE/skills"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    skill_name=$(basename "$skill_dir")
    dest="$HOME/.claude/skills/$skill_name/SKILL.md"
    source="skills/$skill_name/SKILL.md"
    FILE_MODE[$dest]=overwrite
    FILE_SOURCE[$dest]=$source
    BUCKETS[$dest]=$(classify_file "$dest" "$AICODING_BLUEPRINT_CLONE/$source" overwrite)
  done

  # Files in manifest but absent from blueprint inventory → to_remove.
  local manifest_files
  manifest_files=$(jq -r '.files | keys[]' "$AICODING_MANIFEST")
  while IFS= read -r dest; do
    [[ -z "$dest" ]] && continue
    [[ -z "${FILE_MODE[$dest]:-}" ]] && BUCKETS[$dest]=to_remove
  done <<<"$manifest_files"
  # Ensure a clean exit code under `set -e` — the while loop above ends with
  # whatever the last short-circuit `&&` returned (often 1 when nothing was
  # appended), which would otherwise propagate up and abort the script.
  return 0
}

# apply_managed_buckets <bucket_list> — apply blueprint state to disk for
# files whose bucket appears in the space-separated <bucket_list>. Buckets
# not listed are silently skipped (the caller reports them separately).
#
# Caller must have already called classify_managed_files (populating
# BUCKETS / FILE_MODE / FILE_SOURCE) and manifest_stage_begin. Caller is
# responsible for manifest_stage_commit afterwards.
#
# Buckets the caller can request:
#   restore               — file in manifest, missing on disk; redeploy.
#   new_file              — in blueprint, not in manifest; deploy.
#   will_update           — tracked, unedited, blueprint changed; deploy.
#   drifted_but_aligned   — refresh manifest hash, no file write.
#   merge                 — re-merge JSON merge-mode files.
#   drifted_and_updating  — back up current file, deploy blueprint version.
#   to_remove             — delete file and drop from manifest.
apply_managed_buckets() {
  local allowed=" $1 "  # space-pad for substring match
  local dest src bucket mode
  for dest in "${!BUCKETS[@]}"; do
    bucket=${BUCKETS[$dest]}
    case "$allowed" in
      *" $bucket "*) ;;
      *) continue ;;
    esac
    mode=${FILE_MODE[$dest]:-overwrite}
    src="$AICODING_BLUEPRINT_CLONE/${FILE_SOURCE[$dest]:-}"
    case "$bucket" in
      restore|new_file|will_update)
        _apply_deploy "$mode" "$dest" "$src"
        ;;
      drifted_and_updating)
        [[ -e "$dest" ]] && _backup_file "$dest"
        _apply_deploy "$mode" "$dest" "$src"
        ;;
      drifted_but_aligned)
        if [[ "$mode" = "marker_block" ]]; then
          local h
          h=$(compute_block_hash "$dest" \
              "$(managed_marker_block_start)" "$(managed_marker_block_end)")
          manifest_set_file "$dest" \
            "$(jq -n --arg s "$(managed_marker_block_start)" \
                     --arg e "$(managed_marker_block_end)" \
                     --arg h "$h" \
                '{mode:"marker_block",source:"(composed)",marker_start:$s,marker_end:$e,deployed_block_hash:$h}')"
        else
          local h
          h=$(compute_hash "$dest")
          manifest_set_file "$dest" \
            "$(jq -n --arg s "${FILE_SOURCE[$dest]}" --arg h "$h" \
                '{mode:"overwrite",source:$s,deployed_hash:$h}')"
        fi
        ;;
      merge)
        [[ -f "$src" ]] && _apply_deploy merge "$dest" "$src"
        ;;
      to_remove)
        remove_managed_file "$dest"
        ;;
    esac
  done
}

# Internal: dispatch deploy by mode. Substitutes secrets so {{HOME}} and
# {{*_API_KEY}} never reach disk.
_apply_deploy() {
  local mode=$1 dest=$2 src=$3
  case "$mode" in
    overwrite)
      deploy_overwrite_file_substituted "$src" "$dest" "${FILE_SOURCE[$dest]}"
      ;;
    merge)
      [[ -f "$dest" ]] || { mkdir -p "$(dirname "$dest")"; echo '{}' > "$dest"; }
      deploy_merge_file_substituted "$src" "$dest" "${FILE_SOURCE[$dest]}"
      ;;
    marker_block)
      deploy_marker_block "$dest" \
        "$(managed_bashrc_block_body)" \
        "$(managed_marker_block_start)" "$(managed_marker_block_end)"
      ;;
  esac
}

# Internal: timestamped sibling backup. Caller already verified file exists.
# Prints the backup-path announcement line to stdout — restores the visible
# "      backup: <path>" line the original bin/aicoding-update backup_drifted
# emitted, so users still see exactly where the backup landed.
_backup_file() {
  local dest=$1 stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  cp "$dest" "$dest.bak.$stamp"
  echo "      backup: $dest.bak.$stamp"
}
