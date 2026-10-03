#!/usr/bin/env bash
# Prints "project <path>" when this repo has its own docs/DEV_PROCESS.md,
# otherwise "lite". Fail-open: always exits 0.
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo lite; exit 0; }
if [ -f "$root/docs/DEV_PROCESS.md" ]; then
  echo "project $root/docs/DEV_PROCESS.md"
else
  echo lite
fi
exit 0
