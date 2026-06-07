#!/bin/bash
# Back-compat shim: update.sh -> on-start.sh. Remove after one release.
# Guard each candidate with -f before exec: `exec bash <missing>` would still
# replace the process with bash (then exit 127), so the `||` fallback never runs.
# Prefer the adjacent file (submodule checkout), then the curl-stashed copy.
for _cand in "$(dirname "$(readlink -f "$0")")/on-start.sh" "$HOME/.aicodingsetup/on-start.sh"; do
  [ -f "$_cand" ] && exec bash "$_cand" "$@"
done
exit 0
