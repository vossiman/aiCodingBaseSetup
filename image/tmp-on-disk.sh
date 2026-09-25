#!/usr/bin/env bash
# The docker-in-docker feature copies moby's hack/dind, which mounts an
# unsized tmpfs on /tmp (only moby's own pkg/archive tests need it). Unsized
# means up to half of host RAM per container, evictable only to swap. Swap
# the mount for "empty /tmp once per container start" so /tmp stays on disk
# but keeps the fresh-on-restart behaviour everything was built against.
set -euo pipefail

INIT="${TMP_ON_DISK_INIT:-/usr/local/share/docker-init.sh}"
[ -f "$INIT" ] || { echo "tmp-on-disk: $INIT missing (run on the built image, after the docker-in-docker feature)" >&2; exit 1; }

python3 - "$INIT" <<'PY'
import sys

path = sys.argv[1]
old = """    # Mount /tmp (conditionally)
    if ! mountpoint -q /tmp; then
        mount -t tmpfs none /tmp
    fi
"""
# Runs as root inside dockerd_start, which the script retries up to 5 times
# and whose root path is eval'd under `set -e`: every command must succeed,
# and the boot marker keeps retries from emptying /tmp a second time.
new = """    # /tmp on disk (devbox-base image/tmp-on-disk.sh): empty it once per
    # container start. Marker = host boot id + PID 1 start time.
    tmp_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || :):$(cut -d' ' -f22 /proc/1/stat 2>/dev/null || :)"
    if [ "$(cat /var/lib/devbox-tmp-boot 2>/dev/null || :)" != "$tmp_boot" ]; then
        find /tmp -xdev -mindepth 1 -delete 2>/dev/null || :
        chmod 1777 /tmp || :
        echo "$tmp_boot" > /var/lib/devbox-tmp-boot || :
    fi
"""
src = open(path).read()
if src.count(old) != 1:
    sys.exit(f"tmp-on-disk: expected exactly one tmpfs mount block in {path}; upstream changed, re-check the patch")
open(path, "w").write(src.replace(old, new))
PY

grep -q 'mount -t tmpfs' "$INIT" && { echo "tmp-on-disk: tmpfs mount still present" >&2; exit 1; }
sh -n "$INIT"
echo "tmp-on-disk: patched $INIT"
