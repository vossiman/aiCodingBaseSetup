#!/usr/bin/env bash
# SessionStart: inject docs/REQUIREMENTS.md, the project's North Star.
# Fail-open: every path exits 0 and a missing file prints nothing.

main() {
  local dir="${CLAUDE_PROJECT_DIR:-$PWD}" f n
  f="$dir/docs/REQUIREMENTS.md"
  [[ -f "$f" ]] || return 0
  n=$(wc -l < "$f")
  printf '# North Star: docs/REQUIREMENTS.md (injected by the project SessionStart hook)\n'
  if (( n > 200 )); then
    printf 'docs/REQUIREMENTS.md has %s lines, over the 200-line injection limit. Read it directly and shorten it.\n' "$n"
  else
    cat "$f"
  fi
}

main 2>/dev/null
exit 0
