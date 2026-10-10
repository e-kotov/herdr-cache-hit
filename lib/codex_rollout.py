#!/usr/bin/env python3
"""Read Codex's current rollout pointer without modifying its database."""

from pathlib import Path
import re
import sqlite3
import sys


def current_rollout(sessions, session_id):
    sessions = Path(sessions).resolve()
    databases = []
    for path in sessions.parent.glob("state_*.sqlite"):
        match = re.fullmatch(r"state_(\d+)\.sqlite", path.name)
        if match:
            databases.append((int(match.group(1)), path))
    for _, path in sorted(databases, reverse=True):
        db = None
        try:
            db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=0.1)
            row = db.execute("SELECT rollout_path FROM threads WHERE id = ?", (session_id,)).fetchone()
            if row and isinstance(row[0], str):
                rollout = Path(row[0])
                if sessions in rollout.resolve().parents and rollout.is_file():
                    return rollout.as_posix()
        except (OSError, sqlite3.Error):
            continue
        finally:
            if db is not None:
                db.close()
    return None


if __name__ == "__main__":
    try:
        result = current_rollout(*sys.argv[1:])
        if result:
            print(result)
        sys.exit(0 if result else 1)
    except (OSError, ValueError):
        sys.exit(1)
