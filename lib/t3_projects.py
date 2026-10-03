#!/usr/bin/env python3
"""Print the workspace folder of every live t3 project, one per line.

usage: t3_projects.py DB
Reads projection_projects read-only. Exits 1 on any error, printing nothing.
"""
import sqlite3
import sys


def main():
    try:
        db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=5)
        rows = db.execute(
            "SELECT DISTINCT workspace_root FROM projection_projects"
            " WHERE deleted_at IS NULL ORDER BY workspace_root").fetchall()
    except (sqlite3.Error, IndexError):
        return 1
    for (root,) in rows:
        if root.startswith("/") and "\n" not in root and "\t" not in root:
            print(root)
    return 0


sys.exit(main())
