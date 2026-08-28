#!/usr/bin/env python3
"""clip-x11-bridge — X11 CLIPBOARD selection owner for the dvw clipboard bridge.

codex reads the clipboard via arboard (direct X11 protocol, no exec), so the
exec-level clip-shim never fires for it. This daemon owns the CLIPBOARD
selection on a virtual display (Xvfb) and answers every selection request
for image/png with FRESH bytes fetched from the bridge socket
(/tmp/dvw-clip.sock — the reverse ssh forward to the client's images-only
dvw-clipd). Fetch-at-paste-time, no cache, no polling — the same semantics
as the exec shims. Architecture per cc-clip's x11-bridge; spec:
dvw:docs/superpowers/specs/2026-08-27-clipboard-bridge-design.md.

Runs via `uv run --with python-xlib` (see bin/clip-x11-bridge). Serves only
image/png: the images-only trust boundary stays client-side in dvw-clipd;
this daemon merely re-exports what any container process could read from
the socket anyway. Disposable by design: delete wholesale if codex ever
ships CODEX_CLIPBOARD_READER (openai/codex#25465).
"""

import os
import subprocess
import sys
import time

from Xlib import X, display as xdisplay
from Xlib.protocol import event as xevent

MAX_IMAGE_BYTES = 8 * 1024 * 1024  # stay far below server max-request limits
FETCH_TIMEOUT = 3


def fetch_png(sock_path):
    """Bridge bytes or None. curl keeps HTTP-over-unix-socket out of here."""
    try:
        p = subprocess.run(
            ["curl", "-sf", "--max-time", str(FETCH_TIMEOUT),
             "--unix-socket", sock_path, "http://localhost/clip?type=image/png"],
            capture_output=True, timeout=FETCH_TIMEOUT + 2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0 or not p.stdout:
        return None
    if len(p.stdout) > MAX_IMAGE_BYTES:
        return None
    return p.stdout


def main():
    sock_path = os.environ.get("DVW_CLIP_SOCK", "/tmp/dvw-clip.sock")
    d = xdisplay.Display()
    root = d.screen().root
    win = root.create_window(0, 0, 1, 1, 0, 0)

    a_clipboard = d.intern_atom("CLIPBOARD")
    a_targets = d.intern_atom("TARGETS")
    a_timestamp = d.intern_atom("TIMESTAMP")
    a_png = d.intern_atom("image/png")
    a_atom = d.intern_atom("ATOM")
    a_integer = d.intern_atom("INTEGER")

    win.set_selection_owner(a_clipboard, X.CurrentTime)
    d.flush()
    if d.get_selection_owner(a_clipboard) != win:
        print("clip-x11-bridge: could not own CLIPBOARD", file=sys.stderr)
        return 1

    while True:
        ev = d.next_event()
        if ev.type == X.SelectionRequest:
            prop = ev.property if ev.property else ev.target
            ok = False
            if ev.target == a_targets:
                ev.requestor.change_property(
                    prop, a_atom, 32, [a_targets, a_timestamp, a_png])
                ok = True
            elif ev.target == a_timestamp:
                ev.requestor.change_property(prop, a_integer, 32, [X.CurrentTime])
                ok = True
            elif ev.target == a_png:
                data = fetch_png(sock_path)
                if data is not None:
                    # Chunked writes: one change_property call with a few
                    # hundred KB exceeds the X max-request size (BadLength,
                    # property never set). Replace-then-append in 64KB
                    # chunks keeps every request small; the requestor still
                    # reads one complete property.
                    chunk = 64 * 1024
                    ev.requestor.change_property(
                        prop, a_png, 8, data[:chunk])
                    for off in range(chunk, len(data), chunk):
                        ev.requestor.change_property(
                            prop, a_png, 8, data[off:off + chunk],
                            X.PropModeAppend)
                    ok = True
            notify = xevent.SelectionNotify(
                time=ev.time, requestor=ev.requestor, selection=ev.selection,
                target=ev.target, property=prop if ok else 0)
            ev.requestor.send_event(notify)
            d.flush()
        elif ev.type == X.SelectionClear:
            # Another container client copied something. Politeness pause,
            # then take the selection back — the in-container X clipboard has
            # no other legitimate long-term owner, and codex must keep
            # finding the bridge.
            time.sleep(1)
            win.set_selection_owner(a_clipboard, X.CurrentTime)
            d.flush()


if __name__ == "__main__":
    sys.exit(main())
