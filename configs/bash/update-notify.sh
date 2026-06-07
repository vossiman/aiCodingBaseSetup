# Update notifier — print a CTA banner for managed tools behind main. Reads a
# cached status (refreshed in the background, throttled); interactive shells
# only; fail-open.
case $- in
  *i*)
    command -v aicoding-status >/dev/null 2>&1 && aicoding-status --banner 2>/dev/null || true
    ;;
esac
