#!/bin/bash
# Host-wide packages for shell commands agents run. Containers get them from
# the image; a host only got them from an opt-in install.sh run, so a package
# removed later (e.g. by `brew autoremove`) never came back. Codex and
# OpenCode bundle or fetch their own rg, but commands agents type still need
# `rg` on PATH, and Claude Code only shims it inside its own sessions.
set -euo pipefail
dpkg_query=${AICODING_ROOT_DPKG_QUERY:-dpkg-query}
apt_get=${AICODING_ROOT_APT_GET:-apt-get}

command -v "$apt_get" >/dev/null 2>&1 || { echo "  skip: no apt-get on this host"; exit 0; }
missing=()
for pkg in ripgrep; do
  # db:Status-Status is just the install state, so a held package counts.
  [ "$("$dpkg_query" -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" = installed ] || missing+=("$pkg")
done
if [ "${#missing[@]}" -eq 0 ]; then
  echo "  ok: host packages present"
  exit 0
fi
if [ "${AICODINGSETUP_SKIP_NETWORK:-0}" = 1 ]; then
  echo "  skip: would install ${missing[*]}, network disabled"
  exit 0
fi
echo "  installing: ${missing[*]}"
# One broken third-party source must not block an install the cached index
# can still satisfy (same as apt_install in lib/provision-system.sh).
# The dpkg lock timeout waits out unattended-upgrades on install, but update
# takes the lists lock without waiting, so it is retried by hand on contention.
updated=0
for try in 1 2 3; do
  if err=$(DEBIAN_FRONTEND=noninteractive "$apt_get" update -qq 2>&1); then updated=1; break; fi
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  case "$err" in *lists/lock*|*"Could not get lock"*) ;; *) break ;; esac
  [ "$try" -lt 3 ] && sleep "${AICODING_APT_LOCK_SLEEP:-10}"
done
[ "$updated" = 1 ] || echo "  warn: apt-get update failed; trying the install anyway" >&2
DEBIAN_FRONTEND=noninteractive "$apt_get" install -o DPkg::Lock::Timeout=60 -y -qq --no-install-recommends "${missing[@]}"
echo "  ok: installed ${missing[*]}"
