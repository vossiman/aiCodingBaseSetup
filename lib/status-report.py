#!/usr/bin/env python3
"""Read-only local status. Never import updater code or execute MCP servers."""
import concurrent.futures
import datetime
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


HOME = Path.home()
STATE = Path(os.environ.get("AICODING_STATE_DIR", HOME / ".local/state/aicoding"))
DATA = Path(os.environ.get("AICODING_DATA_DIR", HOME / ".local/share/aicoding"))
AUTO = STATE / "auto-update"
NOW = time.time()
LOCK_OBSERVATIONS = {}


def read(path):
    try:
        return path.read_text().strip()
    except (OSError, UnicodeError):
        return ""


def document(path):
    try:
        value = json.loads(read(path))
        return value if isinstance(value, dict) else {}
    except (ValueError, TypeError):
        return {}


def clean(value):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", str(value))[:240]


def epoch(value):
    try:
        if isinstance(value, (int, float)) or str(value).isdigit():
            result = float(value)
        else:
            result = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
        return result if math.isfinite(result) else None
    except (ValueError, TypeError, OverflowError):
        return None


def local_time(value):
    stamp = epoch(value)
    if stamp is None or stamp <= 0:
        return "unknown"
    try:
        return datetime.datetime.fromtimestamp(stamp).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    except (ValueError, OverflowError, OSError):
        return "unknown"


def freshness(value):
    stamp = epoch(value)
    if stamp is None:
        return "age unknown"
    age = NOW - stamp
    if age < -60:
        return "timestamp is in the future; check clock"
    age = max(0, int(age))
    if age < 60:
        return "less than a minute ago"
    if age < 3600:
        return f"{age // 60} minutes ago"
    if age < 86400:
        return f"{age // 3600} hours ago"
    return f"{age // 86400} days ago"


def command(args):
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=3, text=True)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return ""


def flock_matches(line, stat):
    # Waiting requests ("->") are not acquired locks. Linux uses hexadecimal
    # device numbers and a decimal inode in both /proc/locks and fdinfo.
    fields = line.split()
    if len(fields) < 8 or fields[1:3] != ["FLOCK", "ADVISORY"]:
        return False
    try:
        major, minor, inode = fields[5].split(":")
        return (int(major, 16), int(minor, 16), int(inode)) == (
            os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    except (ValueError, IndexError):
        return False


def lock_held(path):
    # Never probe by acquiring a lock: even a momentary exclusive flock could
    # make an actual updater's nonblocking acquisition skip its scheduled run.
    try:
        expected = path.stat()
    except OSError:
        return False
    key = (expected.st_dev, expected.st_ino)
    if key in LOCK_OBSERVATIONS:
        return LOCK_OBSERVATIONS[key]
    # Inspect all status lock inodes together, so free run/sync locks do not
    # each require another process walk. These are observations for this report.
    candidates = {key: expected}
    for candidate in (AUTO / "run.lock", AUTO / "worker.lock", STATE / "sync.lock"):
        try:
            stat = candidate.stat()
            candidates[(stat.st_dev, stat.st_ino)] = stat
        except OSError:
            continue
    entries = read(Path("/proc/locks")).splitlines()
    observed = {identity: any(flock_matches(line, stat) for line in entries)
                for identity, stat in candidates.items()}
    # A shell's `flock FD` utility exits while the shell retains its open file
    # description. Linux can omit this PID-0 lock from /proc/locks, but the
    # owning descriptor's fdinfo still exposes it. Only read fdinfo after its
    # descriptor inode matches one of our scheduler/update locks.
    try:
        processes = list(Path("/proc").iterdir())
    except OSError:
        processes = []
    for proc in processes:
        if not proc.name.isdigit():
            continue
        try:
            descriptors = list((proc / "fd").iterdir())
        except OSError:
            continue
        for fd in descriptors:
            try:
                stat = fd.stat()
            except OSError:
                continue
            identity = (stat.st_dev, stat.st_ino)
            if identity not in candidates or observed[identity]:
                continue
            info = read(proc / "fdinfo" / fd.name)
            observed[identity] = any(flock_matches(line[5:].strip(), stat)
                                     for line in info.splitlines() if line.startswith("lock:"))
    LOCK_OBSERVATIONS.update(observed)
    return observed[key]


def process(pid, ticks=None):
    if not str(pid).isdigit() or int(pid) <= 1:
        return False
    stat = read(Path(f"/proc/{pid}/stat"))
    fields = stat.rsplit(")", 1)[-1].split()
    return (len(fields) > 19 and fields[0] not in ("Z", "X")
            and (ticks is None or str(ticks) == fields[19]))


def owns_lock(pid, path):
    try:
        expected = path.stat()
        for fd in Path(f"/proc/{pid}/fd").iterdir():
            try:
                actual = fd.stat()
                if (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino):
                    # fdinfo associates the lock with this open file
                    # description, unlike merely having the same inode open.
                    info = read(Path(f"/proc/{pid}/fdinfo/{fd.name}"))
                    if any(flock_matches(line[5:].strip(), expected)
                           for line in info.splitlines() if line.startswith("lock:")):
                        return True
            except OSError:
                continue
    except OSError:
        pass
    return False


def within(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def systemd(unit):
    output = command(["systemctl", "--user", "show", unit, "--no-pager",
                      "--property=LoadState,ActiveState,SubState,NextElapseUSecRealtime,NextElapseUSecMonotonic"])
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def scheduler():
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        timer_future = pool.submit(systemd, "aicoding-auto-update.timer")
        service_future = pool.submit(systemd, "aicoding-auto-update.service")
        timer, service = timer_future.result(), service_future.result()
    pid = read(AUTO / "worker.pid")
    cmdline = read(Path(f"/proc/{pid}/cmdline")) if pid.isdigit() else ""
    worker = (process(pid) and "aicoding-auto-update" in cmdline
              and "--worker" in cmdline.split("\0") and owns_lock(pid, AUTO / "worker.lock"))
    timer_alive = timer.get("LoadState") == "loaded" and timer.get("ActiveState") == "active"
    timer_installed = timer.get("LoadState") == "loaded"
    if timer_alive:
        print("Scheduler: systemd user timer — alive")
        if worker:
            print("  Attention: a detached fallback worker is also alive")
    elif worker:
        print("Scheduler: detached fallback worker — alive")
    elif timer_installed:
        print(f"Scheduler: systemd user timer — not active ({clean(timer.get('ActiveState', 'unknown'))})")
    elif pid or (AUTO / "worker.lock").exists():
        print("Scheduler: detached fallback worker — not verified alive (dead or stale worker state)")
    else:
        print("Scheduler: not detected; systemd user timer unavailable or not installed")

    running = document(AUTO / "run.json")
    verified_run = (process(running.get("pid"), running.get("start_ticks"))
                    and running.get("start_ticks") is not None and owns_lock(running.get("pid"), AUTO / "run.lock"))
    service_running = (service.get("LoadState") == "loaded"
                       and service.get("ActiveState") in ("active", "activating")
                       and service.get("SubState") in ("running", "start", "start-pre", "start-post"))
    if verified_run or service_running:
        source = running.get("source", "source unknown") if verified_run else "systemd"
        print(f"Update: running ({clean(source)})")
    elif lock_held(AUTO / "run.lock"):
        print("Update: run lock is held; owner could not be verified")
    elif lock_held(STATE / "sync.lock"):
        print("Update: sync/install lock held; activity owner unknown")
    elif running:
        print("Update: not running; interrupted/stale run record remains")
    else:
        print("Update: not running")
    print(f"Last attempt: {local_time(read(AUTO / 'last-attempt'))}")
    completed = document(AUTO / "last-completed.json")
    if completed:
        outcome = {"success": "completed successfully", "deferred": "completed with deferred work",
                   "failed": "failed"}.get(str(completed.get("outcome")), "unknown outcome")
        print(f"Last completed outcome: {outcome} at {local_time(completed.get('completed_at'))} "
              f"({clean(completed.get('source', 'source unknown'))}; exit {clean(completed.get('exit_code', 'unknown'))})")
    else:
        print("Last completed outcome: not recorded")
        legacy = read(AUTO / "last-success")
        if legacy:
            print(f"  Last legacy fallback success: {local_time(legacy)} (later outcomes unknown)")

    due = None
    if timer_alive:
        realtime = timer.get("NextElapseUSecRealtime", "")
        if realtime and realtime != "n/a":
            converted = command(["date", "-d", realtime, "+%s"])
            due = epoch(converted)
        if not due:
            monotonic = timer.get("NextElapseUSecMonotonic", "")
            # systemctl formats monotonic usec values as durations, e.g. 3h 4min 2s.
            # Include systemd's fixed year/month units for long-lived hosts.
            units = {"us": 0.000001, "ms": 0.001, "s": 1, "min": 60,
                     "h": 3600, "d": 86400, "w": 604800,
                     "month": 2629800, "y": 31557600}
            span_part = r"([0-9]+(?:\.[0-9]+)?)(month|us|ms|min|s|h|d|w|y)\b"
            matches = re.findall(span_part, monotonic)
            try:
                if matches and re.sub(span_part, "", monotonic).strip():
                    raise ValueError("unrecognized timer span")
                seconds = (sum(float(n) * units[u] for n, u in matches) if matches
                           else float(monotonic) / 1_000_000)
                if seconds > 0:
                    # The timer uses CLOCK_MONOTONIC (no WakeSystem), which
                    # excludes suspend time; /proc/uptime includes suspension.
                    due = time.time() + seconds - time.monotonic()
            except (ValueError, IndexError):
                pass
    elif worker:
        due = epoch(read(AUTO / "next-due"))
    if due:
        suffix = " — overdue; running or retry/backoff may delay it" if due < NOW else ""
        print(f"Next scheduled run: {local_time(due)}{suffix}")
    else:
        print("Next scheduled run: unknown" if timer_alive or worker else "Next scheduled run: none verified")
        saved = read(AUTO / "next-due")
        if saved and not worker:
            print(f"  Saved fallback due time: {local_time(saved)} (does not prove scheduling)")


TOOLS = [
    ("aicoding", "Blueprint", (), None),
    ("claude", "Claude", ("claude",), None),
    ("codex", "Codex", ("codex",), None),
    ("opencode", "OpenCode", ("opencode",), None),
    ("cursor", "Cursor CLI", ("agent", "cursor-agent"), None),
    ("pi", "Pi", ("pi",), None),
    ("dvw", "dvw", ("dvw",), None),
    ("bw-AICode", "bw-AICode", ("bw", "claude-bw"), None),
    ("mcp-firecrawl", "Firecrawl MCP", ("firecrawl-mcp",), "firecrawl-mcp"),
    ("mcp-brave", "Brave MCP", ("brave-search-mcp-server",), "@brave/brave-search-mcp-server"),
    ("mcp-context7", "Context7 MCP", ("context7-mcp",), "@upstash/context7-mcp"),
    ("mcp-playwright", "Playwright MCP", ("playwright-mcp",), "@playwright/mcp"),
]


def installed(tool):
    key, label, commands, package = tool
    executable = None
    for name in commands:
        candidate = shutil.which(name)
        if candidate and not str(Path(candidate).resolve()).startswith(os.environ.get("AICODING_WSL_MOUNT_PREFIX", "/mnt/")):
            executable = candidate
            break
    probed = ""
    if executable and not package and key not in ("bw-AICode", "aicoding"):
        lines = command([executable, "--version"]).splitlines()
        probed = clean(lines[0]) if lines else ""
    active = DATA / "current" / key
    try:
        release = active.resolve(strict=True)
        managed = within(release, (DATA / "versions" / key).resolve()) and active.is_symlink()
    except (OSError, RuntimeError):
        managed = False
    if managed:
        version = (document(release / "node_modules" / package / "package.json").get("version")
                   if package else read(release / ".aicoding-version"))
        if not version:
            version = release.name
        if not package and key not in ("bw-AICode", "aicoding"):
            effective = f"{probed} (local version probe)" if probed else "effective CLI version unavailable"
            return f"{effective}; selected local release {clean(version)}"
        return f"{clean(version)} (selected local release)"
    if key == "aicoding":
        manifest = document(Path(os.environ.get("AICODING_MANIFEST", STATE / "manifest.json")))
        if manifest.get("blueprint_commit"):
            return f"{clean(manifest['blueprint_commit'])} (saved installation manifest; not freshly verified)"
    if key == "bw-AICode":
        vendor = Path(os.environ.get("AICODING_VENDOR_DIR", DATA / "vendor")) / "bw-AICode"
        marker = read(vendor / ".aicoding-version")
        if marker:
            return f"{clean(marker)} (local vendor marker)"
        if (vendor / ".git").is_dir():
            revision = command(["git", "-C", str(vendor), "rev-parse", "--verify", "HEAD"])
            if re.fullmatch(r"[0-9a-f]{40}", revision):
                return f"{revision} (local vendor checkout; working tree may differ)"
            return "installed vendor checkout; revision unavailable"
    if executable:
        if package:
            # Follow npm's executable symlink to metadata, never start an MCP server.
            for parent in list(Path(executable).resolve().parents)[:5]:
                metadata = document(parent / "package.json")
                if metadata.get("name") == package and metadata.get("version"):
                    return f"{clean(metadata['version'])} (local package metadata)"
        elif probed:
            return f"{probed} (local version probe)"
        return "installed; version unavailable"
    return "not detected locally"


def result_text(record):
    if not isinstance(record, dict) or not record:
        return "no update result recorded"
    reason = clean(record.get("reason", "reason unknown")).replace("_", " ")
    stamp = record.get("attempted_at")
    target = record.get("target_version")
    target_text = f"; target {clean(target)}" if target else ""
    success = record.get("successful_version")
    success_text = ""
    if success and record.get("state") in ("failed", "blocked", "conflict"):
        success_text = f"; last successful version {clean(success)} at {local_time(record.get('succeeded_at'))}"
    return (f"{clean(record.get('state', 'unknown'))} — {reason}; "
            f"{local_time(stamp)} ({freshness(stamp)}; recorded, not rechecked){target_text}{success_text}")


def main():
    print("Automatic aicoding updates")
    scheduler()
    records = document(Path(os.environ.get("AICODING_RESULTS_FILE", STATE / "update-results.json"))).get("components", {})
    if not isinstance(records, dict):
        records = {}
    print("\nTools — local installation evidence; update results are saved observations")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        versions = list(pool.map(installed, TOOLS))
    absent = []
    for tool, version in zip(TOOLS, versions):
        if version == "not detected locally" and not records.get(tool[0]):
            absent.append(tool[1])
            continue
        print(f"  {tool[1]}: {version}")
        print(f"    Last update: {result_text(records.get(tool[0]))}")
    if absent:
        print(f"  Not detected locally: {', '.join(absent)}")
    playwright = DATA / "current/mcp-playwright"
    browser = None
    try:
        if playwright.is_symlink() and playwright.exists():
            cache = DATA / "browser-cache/mcp-playwright" / playwright.resolve().name
            candidate = Path(read(cache / ".browser-bin"))
            if candidate.is_absolute() and within(candidate.resolve(), cache.resolve()) and candidate.is_file() and os.access(candidate, os.X_OK):
                browser = candidate
    except (OSError, RuntimeError):
        pass
    version = command([str(browser), "--version"]) if browser else ""
    print(f"  Playwright Chromium: {clean(version) if version else 'version unavailable' if browser else 'not detected in active managed browser cache'}")
    print(f"    Last browser update: {result_text(records.get('playwright-chromium'))}")
    print("\nManaged configuration, hooks and skills")
    managed_keys = {"config", "provision"} | {key for key in records if key.startswith(("config-", "mcp-registration-", "hooks", "skills"))}
    for key in sorted(managed_keys):
        print(f"  {clean(key)}: {result_text(records.get(key))}")
    blockers = [(key, record) for key, record in records.items() if isinstance(record, dict)
                and record.get("state") in ("blocked", "conflict", "failed")]
    print("\nUnresolved recorded blockers — last observation, not a fresh check")
    if blockers:
        for key, record in sorted(blockers):
            print(f"  {clean(key)}: {result_text(record)}")
    else:
        print("  None recorded. This does not establish that every tool is current.")
    print("\nTrigger an update: aicoding-auto-update --once")
    print("Scope: supported coding tools and managed blueprint provisioning; not an OS updater.")


if __name__ == "__main__":
    main()
