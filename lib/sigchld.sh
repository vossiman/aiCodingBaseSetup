# WSL's /init starts sessions with SIGCHLD ignored; bash cannot undo that
# (`trap - CHLD` is a no-op) and hands it to every child, whose waitpid then
# fails with ECHILD (git fsck: "waitpid for commit-graph failed"). Re-exec once.
aicoding_reset_inherited_sigchld() {
  local mask
  if [ -n "${AICODING_SIGCHLD_RESET:-}" ]; then
    unset AICODING_SIGCHLD_RESET
    return 0
  fi
  # sed, not awk: bash's own entry shows its handler, and awk ignores SIGPIPE itself.
  mask=$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status 2>/dev/null) || return 0
  [[ "$mask" =~ ^[0-9a-fA-F]{8,}$ ]] || return 0
  mask=${mask: -8}
  (( (16#$mask >> 16) & 1 )) || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  export AICODING_SIGCHLD_RESET=1
  # Python ignores SIGPIPE and SIGXFSZ at startup; hand back what bash inherited.
  exec python3 -c 'import os, signal, sys
mask = int(sys.argv[1], 16)
for sig in (signal.SIGPIPE, signal.SIGXFSZ):
    signal.signal(sig, signal.SIG_IGN if mask >> (sig - 1) & 1 else signal.SIG_DFL)
signal.signal(signal.SIGCHLD, signal.SIG_DFL)
os.execv(sys.argv[2], sys.argv[2:])' "$mask" "$@"
}
