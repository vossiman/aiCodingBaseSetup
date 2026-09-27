# Terminal presentation for install/sync/update. Only active when stderr is an
# interactive terminal: logs, CI, timers and tests keep the plain text format.
# The UI writes to its own dup of the terminal (AICODING_UI_FD), so a spinner
# stays visible while a task's own stdout/stderr go to a capture file.

# An inherited descriptor number can be stale after sync re-execs itself.
if [ -n "${AICODING_UI_FD:-}" ] && ! [ -t "$AICODING_UI_FD" ] 2>/dev/null; then
  unset AICODING_UI_FD
fi
if [ -z "${AICODING_UI_FD:-}" ] && [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] \
    && [ -z "${NO_COLOR:-}" ] && [ "${AICODING_PLAIN:-0}" != 1 ]; then
  exec {AICODING_UI_FD}>&2
  export AICODING_UI_FD
fi

aicoding_ui_active() {
  [ -n "${AICODING_UI_FD:-}" ] && [ -t "$AICODING_UI_FD" ]
}

_aicoding_ui_now() { printf '%s' "${EPOCHREALTIME:-$SECONDS}" | tr , .; }

# Seconds since $1, formatted 0.4s / 12s / 2m05s.
aicoding_ui_elapsed() {
  LC_ALL=C awk -v a="$1" -v b="$(_aicoding_ui_now)" 'BEGIN {
    d = b - a; if (d < 0) d = 0
    if (d < 10) printf "%.1fs", d
    else if (d < 60) printf "%ds", d
    else printf "%dm%02ds", d / 60, d % 60 }'
}

_aicoding_ui_cols() {
  local c=${COLUMNS:-}
  [[ "$c" =~ ^[0-9]+$ ]] || c=$(tput cols 2>/dev/null) || c=
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 40 ] || c=100
  printf '%s' "$c"
}

# Shorten for display: ~ for $HOME, drop symlink targets (always a long
# release path), cap to the terminal width.
_aicoding_ui_fit() {
  local text=$1 width=$2
  text=${text//$HOME/\~}
  text=${text%% -> /*}
  [ "${#text}" -le "$width" ] || text="${text:0:width-1}…"
  printf '%s' "$text"
}

_aicoding_ui_tally() {
  [ -n "${AICODING_UI_TALLY:-}" ] && printf '%s\n' "$1" >>"$AICODING_UI_TALLY" 2>/dev/null
  return 0
}

# Section titles print lazily, right before their first line, so a section
# that turns out to have nothing to say leaves no empty heading behind.
# Repeating the title that is already on screen is a no-op.
aicoding_ui_section() {
  [ "$1" = "${AICODING_UI_SECTION_SHOWN:-}" ] && return 0
  AICODING_UI_PENDING_SECTION=$1
}

_aicoding_ui_flush_section() {
  [ -n "${AICODING_UI_PENDING_SECTION:-}" ] || return 0
  printf '\n\033[1m%s\033[0m\n' "$AICODING_UI_PENDING_SECTION" >&"$AICODING_UI_FD"
  AICODING_UI_SECTION_SHOWN=$AICODING_UI_PENDING_SECTION
  AICODING_UI_PENDING_SECTION=
}

# aicoding_ui_line ok|warn|fail|info|skip "label" ["note"] ["elapsed"]
aicoding_ui_line() {
  local state=$1 label=$2 note=${3:-} took=${4:-} mark color cols width
  case "$state" in
    ok)   mark='✔' color='32' ;;
    warn) mark='!' color='33' ;;
    fail) mark='✖' color='31' ;;
    skip) mark='·' color='2' ;;
    *)    mark='•' color='34' ;;
  esac
  _aicoding_ui_tally "$state"
  _aicoding_ui_flush_section
  cols=$(_aicoding_ui_cols)
  if [ -n "$note" ]; then
    width=$((cols - 38 - ${#took}))
    [ "$width" -ge 10 ] || width=10
    printf '\r\033[K  \033[%sm%s\033[0m %-28s %s \033[2m%s\033[0m\n' "$color" "$mark" \
      "$(_aicoding_ui_fit "$label" 28)" "$(_aicoding_ui_fit "$note" "$width")" "$took" >&"$AICODING_UI_FD"
  else
    width=$((cols - 6 - ${#took}))
    printf '\r\033[K  \033[%sm%s\033[0m %s \033[2m%s\033[0m\n' "$color" "$mark" \
      "$(_aicoding_ui_fit "$label" "$width")" "$took" >&"$AICODING_UI_FD"
  fi
}

# One spinner frame: aicoding_ui_spin <frame-index> <label> <verb> <start>
aicoding_ui_spin() {
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  printf '\r\033[K  \033[36m%s\033[0m %-28s \033[2m%s %s\033[0m' "${frames[$1 % 10]}" \
    "$(_aicoding_ui_fit "$2" 28)" "$3" "$(aicoding_ui_elapsed "$4")" >&"$AICODING_UI_FD"
}

aicoding_ui_clear() {
  printf '\r\033[K' >&"$AICODING_UI_FD"
}

# Put several small steps under one title: their own headers are ignored
# until aicoding_ui_group_end.
aicoding_ui_group() {
  aicoding_ui_active || return 0
  aicoding_ui_section "$1"
  AICODING_UI_GROUPED=1
}

aicoding_ui_group_end() {
  AICODING_UI_GROUPED=
}

# Start counting results for a closing summary line.
aicoding_ui_begin() {
  aicoding_ui_active || return 0
  # A sync that re-execs into a newer checkout keeps counting in the same file.
  [ -n "${AICODING_UI_TALLY:-}" ] && [ -f "$AICODING_UI_TALLY" ] && return 0
  AICODING_UI_TALLY=$(mktemp) || { AICODING_UI_TALLY=; return 0; }
  AICODING_UI_STARTED=$(_aicoding_ui_now)
  export AICODING_UI_TALLY AICODING_UI_STARTED
}

# aicoding_ui_summary [exit-code]
aicoding_ui_summary() {
  aicoding_ui_active && [ -n "${AICODING_UI_TALLY:-}" ] || return 0
  local ok warn fail skip rc=${1:-0} parts=()
  ok=$(grep -cx ok "$AICODING_UI_TALLY")
  warn=$(grep -cx warn "$AICODING_UI_TALLY")
  fail=$(grep -cx fail "$AICODING_UI_TALLY")
  skip=$(grep -cx skip "$AICODING_UI_TALLY")
  rm -f "$AICODING_UI_TALLY"; AICODING_UI_TALLY=
  [ $((ok + warn + fail + skip)) -gt 0 ] || [ "$rc" -ne 0 ] || return 0
  parts+=("$(printf '\033[32m✔ %s ok\033[0m' "$ok")")
  [ "$skip" -eq 0 ] || parts+=("$(printf '\033[2m· %s deferred\033[0m' "$skip")")
  [ "$warn" -eq 0 ] || parts+=("$(printf '\033[33m! %s warning%s\033[0m' "$warn" "$([ "$warn" -eq 1 ] || echo s)")")
  [ "$fail" -eq 0 ] || parts+=("$(printf '\033[31m✖ %s failed\033[0m' "$fail")")
  [ "$rc" -eq 0 ] || [ "$fail" -gt 0 ] || parts+=("$(printf '\033[31m✖ finished with errors (exit %s)\033[0m' "$rc")")
  printf '\n  %s' "${parts[0]}" >&"$AICODING_UI_FD"
  local p
  for p in "${parts[@]:1}"; do printf '  ·  %s' "$p" >&"$AICODING_UI_FD"; done
  printf '  \033[2min %s\033[0m\n' "$(aicoding_ui_elapsed "$AICODING_UI_STARTED")" >&"$AICODING_UI_FD"
}

# On a terminal, replace the plain loggers with the styled ones. Callers that
# define their own loggers (install.sh) source this afterwards via provision.sh.
if aicoding_ui_active; then
  info()   { aicoding_ui_line info "$*"; }
  ok()     { aicoding_ui_line ok "$*"; }
  warn()   { aicoding_ui_line warn "$*"; }
  err()    { aicoding_ui_line fail "$*"; }
  header() { _CURRENT_STEP="$*"; [ -n "${AICODING_UI_GROUPED:-}" ] || aicoding_ui_section "$*"; }
fi
