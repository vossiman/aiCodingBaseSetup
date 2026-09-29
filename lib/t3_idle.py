#!/usr/bin/env python3
"""Idle checks 1 and 2 against t3's projection tables (read-only).

usage: t3_idle.py DB QUIET_SECONDS NOW_EPOCH CHECKS
CHECKS is "1" (nothing running or waiting) or "12" (also: nothing happened
for QUIET_SECONDS). Prints "idle" and exits 0, or prints "busy:<reason>" and
exits 1. Any error, missing table or column, or unknown value means busy.
Enums: packages/contracts/src/orchestration.ts:608 (session status),
persistence/Services/ProjectionTurns.ts:27 (turn state),
persistence/Layers/ProjectionPendingApprovals.ts:76 (pending predicate).
"""
import datetime as dt
import sqlite3
import sys

SESSION_SETTLED = {"idle", "ready", "interrupted", "stopped", "error"}
SESSION_ALL = SESSION_SETTLED | {"starting", "running"}
TURN_ALL = {"pending", "running", "interrupted", "completed", "error"}
TURN_BUSY = {"pending", "running"}
APPROVAL_ALL = {"pending", "resolved"}
TIMESTAMPS = [
    ("projection_thread_messages", "created_at"),
    ("projection_thread_messages", "updated_at"),
    ("projection_thread_activities", "created_at"),
    ("projection_turns", "requested_at"),
    ("projection_turns", "started_at"),
    ("projection_turns", "completed_at"),
    ("projection_pending_approvals", "created_at"),
    ("projection_pending_approvals", "resolved_at"),
    ("projection_thread_sessions", "updated_at"),
]
FUTURE_SLACK = dt.timedelta(minutes=5)


def parse(value):
    t = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if t.tzinfo is None:
        raise ValueError("timestamp without a zone")
    return t


def check_now(con):
    for status, active in con.execute("SELECT status, active_turn_id FROM projection_thread_sessions"):
        if status not in SESSION_ALL:
            return "session_unknown"
        if status not in SESSION_SETTLED:
            return "session_running"
        if active is not None:
            return "active_turn"
    for (state,) in con.execute("SELECT DISTINCT state FROM projection_turns"):
        if state not in TURN_ALL:
            return "turn_unknown"
        if state in TURN_BUSY:
            return "turn_running"
    for (status,) in con.execute("SELECT DISTINCT status FROM projection_pending_approvals"):
        if status not in APPROVAL_ALL:
            return "approval_unknown"
        if status == "pending":
            return "approval_pending"
    return None


def check_quiet(con, quiet, now):
    newest = None
    for table, col in TIMESTAMPS:
        for (value,) in con.execute(f"SELECT {col} FROM {table} WHERE {col} IS NOT NULL"):
            try:
                t = parse(value)
            except (TypeError, ValueError, AttributeError):
                return "bad_timestamp"
            if t > now + FUTURE_SLACK:
                return "future_timestamp"
            if newest is None or t > newest:
                newest = t
    if newest is not None and (now - newest).total_seconds() < quiet:
        return "recent_activity"
    return None


def main(argv):
    db, quiet, now_s, checks = argv[1], float(argv[2]), float(argv[3]), argv[4]
    now = dt.datetime.fromtimestamp(now_s, dt.timezone.utc)
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        reason = check_now(con)
        if reason is None and "2" in checks:
            reason = check_quiet(con, quiet, now)
    except sqlite3.Error:
        reason = "db_error"
    if reason:
        print(f"busy:{reason}")
        return 1
    print("idle")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
