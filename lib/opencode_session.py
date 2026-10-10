#!/usr/bin/env python3
"""Resolve an OpenCode pane without a native Herdr session ID."""

import json
from contextlib import closing
import re
import sqlite3
import sys
from urllib.parse import quote

from codex_session import process_started
from opencode import directory_key, find_db_path


def is_opencode_process(process):
    names = (process.get("name") or "", re.split(r"[/\\]", process.get("argv0") or "")[-1])
    return any(name.lower() in ("opencode", "opencode.exe") for name in names)


def resolve_session(db_path, cwd, pane_id, process, panes, started, title=""):
    processes = [p for p in process.get("foreground_processes", []) if is_opencode_process(p)]
    if len(processes) != 1 or not cwd:
        return None

    with closing(sqlite3.connect("file:{}?mode=ro".format(quote(str(db_path), safe="/")),
                                 uri=True, timeout=1.0)) as con:
        rows = con.execute("SELECT id, directory, parent_id, title, time_created, time_updated FROM session").fetchall()
    claimed = {(p.get("agent_session") or {}).get("value") for p in panes
               if p.get("pane_id") != pane_id and p.get("agent") == "opencode"
               and (p.get("agent_session") or {}).get("kind") == "id"}
    candidates = [(sid, session_title, created, updated) for sid, directory, parent, session_title, created, updated in rows
                  if not parent and sid not in claimed and directory_key(directory) == directory_key(cwd)]

    argv = processes[0].get("argv") or []
    for i, arg in enumerate(argv[1:], 1):
        if arg in ("--session", "-s") and i + 1 < len(argv):
            sid = argv[i + 1]
            return sid if any(row[0] == sid for row in candidates) else None
        if arg.startswith("--session="):
            sid = arg.split("=", 1)[1]
            return sid if any(row[0] == sid for row in candidates) else None

    if not isinstance(started, (int, float)) or started <= 0:
        return None
    if any(p.get("agent") == "opencode" and p.get("pane_id") != pane_id
           and directory_key(p.get("cwd") or p.get("foreground_cwd") or "") == directory_key(cwd)
           for p in panes):
        return None

    created_since_start = [(sid, session_title) for sid, session_title, created, _ in candidates
                           if isinstance(created, (int, float)) and created / 1000 >= started - 2]
    if len(created_since_start) == 1:
        return created_since_start[0][0]
    if len(created_since_start) > 1:
        titled = [sid for sid, session_title in created_since_start
                  if session_title and title.endswith(session_title)]
        return titled[0] if len(titled) == 1 else None

    active = [(sid, session_title) for sid, session_title, _, updated in candidates
              if isinstance(updated, (int, float)) and updated / 1000 >= started - 2]
    if len(active) == 1:
        return active[0][0]
    titled = [sid for sid, session_title in active if session_title and title.endswith(session_title)]
    return titled[0] if len(titled) == 1 else None


def main():
    cwd, pane_id, title = sys.argv[1:]
    db_path = find_db_path()
    if not db_path:
        return 1
    data = json.load(sys.stdin)
    process = data.get("process") or {}
    processes = [p for p in process.get("foreground_processes", []) if is_opencode_process(p)]
    started = process_started(processes[0].get("pid")) if len(processes) == 1 else None
    sid = resolve_session(db_path, cwd, pane_id, process, data.get("panes") or [], started, title)
    if sid:
        print(sid)
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, sqlite3.Error):
        sys.exit(1)
