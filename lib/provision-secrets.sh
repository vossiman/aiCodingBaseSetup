# lib/provision-secrets.sh - interactive and non-interactive secrets setup
# for install.sh. Relies on install.sh globals and logging helpers; sourced
# only (no shebang / set -e), matching lib/*.sh.

# load_secrets_env sources the store as shell, so only characters that are
# literal in an unquoted assignment are allowed (no ~, &, ;, quotes, $, ...).
_secret_value_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._:/+=@%,-]*$ ]]
}

# Parse KEY=value lines into the associative array named by $1. Values are
# kept raw, as every reader of the store expects. Never echoes a value.
_secrets_read_file() {
  local -n _into=$1
  local file=$2 line key n=0
  if [[ ! -r "$file" ]]; then
    err "Cannot read $file"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    # The sourcing shell accepts leading blanks and any blanks after export.
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^export[[:space:]]+ ]]; then
      line="${line#"${BASH_REMATCH[0]}"}"
    fi
    key="${line%%=*}"
    if [[ "$line" != *=* || ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "$file line $n is not KEY=value; ignored"
      continue
    fi
    _into["$key"]="${line#*=}"
  done < "$file"
}

# --- Secrets Management ---
# The example lists the keys a fresh machine is asked for. An existing store
# is never rebuilt: missing keys are appended, every other byte is kept, and
# the write is in place because containers bind this single file by inode.
load_or_prompt_secrets() {
  header "Secrets Management"
  mkdir -p "$SECRETS_DIR"

  local example_file="$SCRIPT_DIR/.secrets.env.example"
  if [[ ! -f "$example_file" ]]; then
    err "Missing .secrets.env.example in repo"
    exit 1
  fi

  local required_keys=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    required_keys+=("${line%%=*}")
  done < "$example_file"

  # Decide whether we can prompt (no tty, container mode, or env opt-out → no)
  local can_prompt=true
  [[ ! -t 0 ]] && can_prompt=false
  [[ "$ENV_TYPE" == "container" ]] && can_prompt=false
  [[ "${AICODINGSETUP_NONINTERACTIVE:-}" == "1" ]] && can_prompt=false

  # A run that may write reads the store under the lock, so two installs
  # cannot both append the same key or race a create. The write itself
  # refuses to run unlocked; a run with nothing to write needs no lock.
  local lock_fd=""
  if [[ ! -f "$SECRETS_FILE" || "$can_prompt" == "true" ]] \
      && command -v flock >/dev/null 2>&1 \
      && { exec {lock_fd}>>"$SECRETS_DIR/.secrets.lock"; } 2>/dev/null; then
    flock -w 30 "$lock_fd" || { exec {lock_fd}>&-; lock_fd=""; }
  fi

  local rc=0
  _secrets_load_prompt_write || rc=$?
  [[ -n "$lock_fd" ]] && exec {lock_fd}>&-
  return "$rc"
}

# Host stores are owner-only. chmod in place: containers bind the inode, and
# go-rwx never adds owner write to a 0400 store.
_secrets_tighten_mode() {
  [[ "$ENV_TYPE" == "container" || ! -O "$SECRETS_FILE" ]] && return 0
  local mode
  mode=$(stat -c %a "$SECRETS_FILE" 2>/dev/null) || return 0
  (( 8#$mode & 077 )) || return 0
  chmod go-rwx "$SECRETS_FILE" 2>/dev/null \
    || warn "Could not tighten permissions on $SECRETS_FILE"
}

_secrets_load_prompt_write() {
  declare -A secrets
  local existed=false
  if [[ -f "$SECRETS_FILE" ]]; then
    existed=true
    info "Found existing secrets file"
    _secrets_read_file secrets "$SECRETS_FILE" || return 1
    _secrets_tighten_mode
  else
    info "No secrets file found — will prompt for all keys"
  fi

  # Keys with empty values are "skipped", not missing, and are never asked again.
  local new_keys=() key value missing=()
  for key in "${required_keys[@]}"; do
    [[ -v "secrets[$key]" ]] || missing+=("$key")
  done

  # Fail before the first prompt if the write we are about to ask for cannot happen.
  if [[ "$existed" != "true" || ( ${#missing[@]} -gt 0 && "$can_prompt" == "true" ) ]]; then
    if [[ -z "$lock_fd" ]]; then
      err "Could not lock $SECRETS_DIR/.secrets.lock; not writing $SECRETS_FILE"
      return 1
    fi
    if [[ "$existed" == "true" && ! -w "$SECRETS_FILE" ]]; then
      err "Could not append ${missing[*]} to $SECRETS_FILE: not writable"
      return 1
    elif [[ "$existed" != "true" && ! -w "$SECRETS_DIR" ]]; then
      err "Could not create $SECRETS_FILE: $SECRETS_DIR is not writable"
      return 1
    fi
  fi
  for key in "${required_keys[@]}"; do
    if [[ -v "secrets[$key]" ]]; then
      if [[ -n "${secrets[$key]}" ]]; then
        ok "$key already set"
      else
        ok "$key skipped (empty)"
      fi
    elif [[ "$can_prompt" == "true" ]]; then
      while true; do
        value=""
        if ! IFS= read -rp "Enter $key [or press Enter to skip]: " value; then
          echo
          err "Input ended at the $key prompt; nothing written"
          return 1
        fi
        _secret_value_ok "$value" && break
        warn "$key: only letters, digits and . _ : / + = @ % , - are allowed; try again"
      done
      secrets["$key"]="$value"
      new_keys+=("$key")
    else
      info "$key not set (non-interactive — leaving empty)"
      secrets["$key"]=""
    fi
  done

  if [[ "$existed" != "true" ]]; then
    local buf=$'# AI Coding Base Setup — Secrets\n# Created by install.sh — do not commit\n\n'
    for key in "${required_keys[@]}"; do
      buf+="${key}=${secrets[$key]:-}"$'\n'
    done
    if ! ( umask 077 && printf '%s' "$buf" > "$SECRETS_FILE" ); then
      err "Could not create $SECRETS_FILE"
      return 1
    fi
    ok "Secrets saved to $SECRETS_FILE"
  elif (( ${#new_keys[@]} > 0 )); then
    local buf=$'\n'
    [[ -s "$SECRETS_FILE" && -n "$(tail -c1 "$SECRETS_FILE")" ]] && buf=$'\n\n'
    for key in "${new_keys[@]}"; do
      buf+="${key}=${secrets[$key]}"$'\n'
    done
    # One simple command: `if ! { ...; } >> f` does not see a failed redirect.
    if ! printf '%s' "$buf" >> "$SECRETS_FILE"; then
      err "Could not append ${new_keys[*]} to $SECRETS_FILE"
      return 1
    fi
    ok "Added ${new_keys[*]} to $SECRETS_FILE"
  fi

  # Only the example's keys reach install's child processes; helpers read the
  # store themselves.
  for key in "${required_keys[@]}"; do
    export "$key"="${secrets[$key]:-}"
  done
}
