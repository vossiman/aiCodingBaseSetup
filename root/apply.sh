#!/bin/bash
# Run as root by root/runner from its verified checkout of CI-qualified main.
# Everything aiCodingBaseSetup does as root on a host is defined here or in
# root/tasks.d/*.sh, so it only changes through merged PRs. Tasks run in name
# order, each in its own bash, with AICODING_BLUEPRINT_ROOT set to this
# checkout. A failing task fails the pass but does not stop the others.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
rc=0

# Self-update first, so a runner or unit fix still lands if a task is broken.
. "$here/lib.sh"
aicoding_root_install_files "$repo" || { echo "aicoding-root: refreshing runner/units failed"; rc=1; }

for task in "$here"/tasks.d/*.sh; do
  [ -f "$task" ] || continue
  echo "aicoding-root: task ${task##*/}"
  AICODING_BLUEPRINT_ROOT=$repo bash "$task" || { echo "aicoding-root: task ${task##*/} FAILED"; rc=1; }
done
exit "$rc"
