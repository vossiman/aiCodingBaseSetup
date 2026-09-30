# blueprint_snapshot <dest>: a private copy of $BLUEPRINT_ROOT for tests that
# execute install-host.sh. Its durable-runtime step tars the whole source,
# .git included, under pipefail, so running it from the live checkout fails
# whenever a parallel test touches that .git. The clone keeps the real history
# (the deploy engine reads it) and the working tree carries uncommitted edits.
blueprint_snapshot() {
  local dest=$1
  git clone -q --no-local "$BLUEPRINT_ROOT" "$dest"
  rsync -a --delete --exclude=/.git --exclude=/.claude/worktrees --exclude=/out \
    "$BLUEPRINT_ROOT/" "$dest/"
}
