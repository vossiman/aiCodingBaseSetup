#!/usr/bin/env python3
"""Reproduction harness for tmux rendering artifacts.

Starts an isolated tmux server with a given config, attaches a fake outer
terminal (pty -> pyte screen emulator), replays a recorded byte stream inside
the pane (see replay.py), then compares:

  A) tmux's internal pane model    (capture-pane)
  B) what the outer terminal shows (pyte screen, incremental updates only)

If A != B in the pane region, tmux's incremental output diverged from its own
model -- the machine-checkable equivalent of "artifacts that a forced redraw
cleans". See README.md for how to record a workload and build a test config.

Usage: harness.py --config CFG --recording RAW [--width 165] [--client-height 45]
                  [--label NAME] [--chunk 2048] [--delay-ms 20] [--term TERM]
                  [--responder none|kitty|wt] [--slow-reader] [--ambiguous-wide]
Exit code: 0 = clean, 1 = divergence detected.
Requires: pip install --user pyte
"""
import argparse, fcntl, os, pathlib, pty, re, select, struct, subprocess, sys, termios, time

import pyte

HERE = pathlib.Path(__file__).parent


def sh(sock, *args, check=True):
    return subprocess.run(["tmux", "-L", sock, *args], check=check,
                          capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--recording", required=True)
    ap.add_argument("--width", type=int, default=165)
    ap.add_argument("--client-height", type=int, default=45)
    ap.add_argument("--label", default="run")
    ap.add_argument("--chunk", type=int, default=2048)
    ap.add_argument("--delay-ms", type=int, default=20)
    ap.add_argument("--term", default="xterm-256color")
    ap.add_argument("--responder", choices=["none", "kitty", "wt"], default="none",
                    help="answer tmux's DA1/DA2/XTVERSION queries like this terminal")
    ap.add_argument("--slow-reader", action="store_true",
                    help="read client output slowly (simulates laggy ssh client)")
    ap.add_argument("--ambiguous-wide", action="store_true",
                    help="outer terminal renders East-Asian-Ambiguous chars as width 2")
    ap.add_argument("--keep", action="store_true", help="keep tmux server running")
    args = ap.parse_args()

    RESPONSES = {
        "none": {b"\x1b[c": b"\x1b[?62;22c"},
        "kitty": {
            b"\x1b[c": b"\x1b[?62;c",
            b"\x1b[>c": b"\x1b[>1;4000;33c",
            b"\x1b[>q": b"\x1bP>|kitty(0.40.0)\x1b\\",
        },
        "wt": {
            b"\x1b[c": b"\x1b[?61;4;6;7;14;21;22;23;24;28;32;42c",
            b"\x1b[>c": b"\x1b[>0;10;1c",
            b"\x1b[>q": b"\x1bP>|Windows Terminal 1.22.10352\x1b\\",
        },
    }[args.responder]

    if args.ambiguous_wide:
        import unicodedata
        import pyte.screens as _ps
        _orig_wcwidth = _ps.wcwidth
        _ps.wcwidth = lambda ch: (2 if unicodedata.east_asian_width(ch) == "A"
                                  else _orig_wcwidth(ch))

    sock = f"ccrepro-{args.label}-{os.getpid()}"
    outdir = HERE / "out" / args.label
    outdir.mkdir(parents=True, exist_ok=True)
    donefile = outdir / "replay.done"
    if donefile.exists():
        donefile.unlink()

    env = dict(os.environ)
    env.pop("TMUX", None)
    env["TERM"] = args.term

    # Start server + detached session.
    subprocess.run(["tmux", "-L", sock, "-f", args.config, "new-session",
                    "-d", "-s", "repro", "-x", str(args.width),
                    "-y", str(args.client_height)], check=True, env=env)

    try:
        # Attach a client inside a pty of fixed size.
        master, slave = pty.openpty()
        winsz = struct.pack("HHHH", args.client_height, args.width, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, winsz)
        client = subprocess.Popen(
            ["tmux", "-L", sock, "attach-session", "-t", "repro"],
            stdin=slave, stdout=slave, stderr=slave, env=env,
            start_new_session=True)
        os.close(slave)

        screen = pyte.Screen(args.width, args.client_height)
        stream = pyte.ByteStream(screen)
        rawlog = open(outdir / "outer-terminal.raw", "wb")

        # pyte can't parse colon-form SGR (38:2::r:g:b, 4:3, 58:...) or
        # private DSR queries (e.g. tmux master's theme probe CSI ?996n).
        # Sanitize so pyte doesn't spill them as literal text (false-positive
        # artifacts). Color fidelity is irrelevant; we compare text only.
        SGR_COLON = re.compile(rb"\x1b\[([0-9;:]*?):([0-9;:]*)m")
        PRIV_DSR = re.compile(rb"\x1b\[\?[0-9;]*n")

        def sanitize(data):
            data = PRIV_DSR.sub(b"", data)
            prev = None
            while prev != data:
                prev = data
                data = SGR_COLON.sub(lambda m: b"\x1b[" + m.group(1) + b";" + m.group(2) + b"m", data)
            return data

        last_data = [time.time()]

        def pump(timeout):
            """Read pty output for `timeout` seconds, feed pyte, answer queries."""
            end = time.time() + timeout
            while time.time() < end:
                r, _, _ = select.select([master], [], [], 0.05)
                if master in r:
                    try:
                        data = os.read(master, 512 if args.slow_reader else 65536)
                    except OSError:
                        return False
                    if not data:
                        return False
                    last_data[0] = time.time()
                    rawlog.write(data)
                    stream.feed(sanitize(data))
                    for query, resp in RESPONSES.items():
                        if query in data:
                            os.write(master, resp)
                    if args.slow_reader:
                        time.sleep(0.02)
            return True

        def render_screen():
            """Robust replacement for screen.display (handles wide-char stubs)."""
            lines = []
            for y in range(screen.lines):
                row = screen.buffer[y]
                lines.append("".join((row[x].data or " ") for x in range(screen.columns)))
            return lines

        pump(2.0)  # let tmux draw the initial screen

        # Kick off the replay inside the pane.
        cmd = (f"python3 {HERE}/replay.py {args.recording} {donefile} "
               f"{args.chunk} {args.delay_ms}\n")
        sh(sock, "send-keys", "-t", "repro", cmd.rstrip("\n"), "Enter")

        # Pump until replay signals completion (cap at 300s).
        deadline = time.time() + 300
        while not donefile.exists() and time.time() < deadline:
            if not pump(0.5):
                break
        # Drain until the client has been quiet for 2s (slow readers lag far
        # behind the replay finishing).
        while time.time() < deadline:
            pump(0.5)
            if time.time() - last_data[0] > 2.0:
                break

        # Snapshot A: tmux's internal model of the pane.
        model = sh(sock, "capture-pane", "-p", "-t", "repro").stdout.split("\n")
        # Snapshot B: what the fake outer terminal displays.
        display = render_screen()

        # Locate the pane region in the client display (pane-border-status /
        # status bar shift it). Derive from tmux.
        info = sh(sock, "display", "-p", "-t", "repro",
                  "#{pane_top} #{pane_height}").stdout.split()
        pane_top, pane_h = int(info[0]), int(info[1])

        diffs = []
        for i in range(pane_h):
            m = (model[i] if i < len(model) else "").rstrip()
            d = display[pane_top + i].rstrip()
            if m != d:
                diffs.append((pane_top + i, m, d))

        report = outdir / "report.txt"
        with open(report, "w") as f:
            f.write(f"label={args.label} config={args.config}\n")
            f.write(f"recording={args.recording} bytes={os.path.getsize(args.recording)}\n")
            f.write(f"pane_top={pane_top} pane_h={pane_h}\n")
            f.write(f"diff_rows={len(diffs)}\n\n")
            col01 = 0
            for row, m, d in diffs:
                j = 0
                while j < min(len(m), len(d)) and m[j] == d[j]:
                    j += 1
                if j <= 1:
                    col01 += 1
                f.write(f"--- row {row} (first diff col {j})\n")
                f.write(f"model  |{m}|\n")
                f.write(f"outer  |{d}|\n")
            f.write(f"\nrows_with_diff_at_col0or1={col01}\n")
        (outdir / "model.txt").write_text("\n".join(model))
        (outdir / "outer.txt").write_text("\n".join(display))

        print(f"[{args.label}] diff_rows={len(diffs)} "
              f"col01_rows={col01} report={report}")

        # Signature check: does a forced redraw converge the outer terminal?
        if diffs:
            sh(sock, "refresh-client", check=False)
            pump(2.0)
            display2 = render_screen()
            model2 = sh(sock, "capture-pane", "-p", "-t", "repro").stdout.split("\n")
            still = sum(1 for i in range(pane_h)
                        if (model2[i] if i < len(model2) else "").rstrip()
                        != display2[pane_top + i].rstrip())
            print(f"[{args.label}] after refresh-client: diff_rows={still} "
                  f"(0 => matches the 'forced redraw cleans it' signature)")

        rawlog.close()
        return 1 if diffs else 0
    finally:
        if not args.keep:
            sh(sock, "kill-server", check=False)
            try:
                client.terminate()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
