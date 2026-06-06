#!/bin/bash
# Back-compat shim: update.sh -> on-start.sh. Remove after one release.
exec bash "$HOME/.aicodingsetup/on-start.sh" "$@" 2>/dev/null \
  || exec bash "$(dirname "$(readlink -f "$0")")/on-start.sh" "$@"
