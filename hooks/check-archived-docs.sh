#!/usr/bin/env bash
# SessionStart hook: if the current project has docs/*/active/*.md files whose
# YAML frontmatter says `status: done`, print a one-line banner reminding the
# user to run `/housekeep`.
#
# FAIL-OPEN contract: this hook never blocks Claude. All branches return 0.
# A deliberate `exit 1` at the top should still let Claude start cleanly —
# Claude Code SessionStart hook failures are non-fatal, but we enforce the
# behavior here regardless so operator mistakes don't cascade.

# Intentionally no `set -e`, `set -u`, `set -o pipefail`.

main() {
  # Claude Code sets CLAUDE_PROJECT_DIR for hooks. Fall back to cwd if absent
  # (e.g., running the hook by hand for testing).
  local project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

  # Opt-in signal: the user scaffolded the project layout.
  if [[ ! -d "$project_dir/docs/specs" ]] \
      && [[ ! -d "$project_dir/docs/plans" ]] \
      && [[ ! -d "$project_dir/docs/notes" ]]; then
    return 0
  fi

  # Count files whose first ~15 lines contain a literal `status: done` line
  # inside YAML frontmatter. Fast path with grep; no YAML parser required.
  local count=0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if head -n 20 "$f" 2>/dev/null | grep -qE '^status:[[:space:]]+done[[:space:]]*$'; then
      count=$((count + 1))
    fi
  done < <(find "$project_dir/docs" \
              -mindepth 3 -maxdepth 3 \
              -type f -name '*.md' \
              -path '*/active/*' \
              2>/dev/null)

  if (( count > 0 )); then
    if (( count == 1 )); then
      echo "📦 1 doc ready to archive — run /housekeep to sweep."
    else
      echo "📦 ${count} docs ready to archive — run /housekeep to sweep."
    fi
  fi

  return 0
}

# Always exit 0. Wrap main so a syntax error or unexpected failure still exits 0.
main "$@" || true
exit 0
