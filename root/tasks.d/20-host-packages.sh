#!/bin/bash
# Host packages the agent CLIs need from the system. Containers get them from
# the image; a host only got them from an opt-in install.sh run, so a package
# removed later (e.g. by `brew autoremove`) never came back. Codex and
# OpenCode need a real ripgrep binary; Claude Code only shims `rg` itself.
set -euo pipefail
dpkg_query=${AICODING_ROOT_DPKG_QUERY:-dpkg-query}
apt_get=${AICODING_ROOT_APT_GET:-apt-get}

command -v "$apt_get" >/dev/null 2>&1 || { echo "  skip: no apt-get on this host"; exit 0; }
missing=()
for pkg in ripgrep; do
  "$dpkg_query" -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
done
if [ "${#missing[@]}" -eq 0 ]; then
  echo "  ok: host packages present"
  exit 0
fi
echo "  installing: ${missing[*]}"
DEBIAN_FRONTEND=noninteractive "$apt_get" update -qq
DEBIAN_FRONTEND=noninteractive "$apt_get" install -y -qq --no-install-recommends "${missing[@]}"
echo "  ok: installed ${missing[*]}"
