#!/usr/bin/env python3
"""Find a Claude transcript for a live pane without a Herdr session ID."""

import json
import os
from pathlib import Path
import re
import sys

from codex_session import process_started


SESSION_ID = re.compile(r"^[A-Za-z0-9._-]+$")


def is_claude_process(process):
    names = (process.get("name") or "", re.split(r"[/\\]", process.get("argv0") or "")[-1])
    return any(name.lower() in ("claude", "claude.exe") for name in names)


def resolve_session(root, cwd, pane_id, process, panes, started):
    processes = [p for p in process.get("foreground_processes", []) if is_claude_process(p)]
    if len(processes) != 1 or not cwd:
        return None

    project = Path(root) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", cwd)
    argv = processes[0].get("argv") or []
    claimed = {(p.get("agent_session") or {}).get("value") for p in panes
               if p.get("pane_id") != pane_id and p.get("agent") == "claude"
               and (p.get("agent_session") or {}).get("kind") == "id"}

    for i, arg in enumerate(argv[1:], 1):
        if arg in ("--resume", "-r") and i + 1 < len(argv):
            sid = argv[i + 1]
            if SESSION_ID.fullmatch(sid) and sid not in claimed and (project / f"{sid}.jsonl").is_file():
                return sid
            return None

    if not isinstance(started, (int, float)) or started <= 0:
        return None
    normalized_cwd = os.path.normcase(os.path.realpath(cwd))
    if any(p.get("agent") == "claude" and p.get("pane_id") != pane_id
           and os.path.normcase(os.path.realpath(p.get("cwd") or p.get("foreground_cwd") or ".")) == normalized_cwd
           for p in panes):
        return None

    candidates = []
    for path in project.glob("*.jsonl"):
        try:
            if SESSION_ID.fullmatch(path.stem) and path.stem not in claimed and path.stat().st_mtime >= started - 2:
                candidates.append(path.stem)
        except OSError:
            continue
    return candidates[0] if len(candidates) == 1 else None


def main():
    root, cwd, pane_id = sys.argv[1:]
    data = json.load(sys.stdin)
    process = data.get("process") or {}
    processes = [p for p in process.get("foreground_processes", []) if is_claude_process(p)]
    started = process_started(processes[0].get("pid")) if len(processes) == 1 else None
    sid = resolve_session(root, cwd, pane_id, process, data.get("panes") or [], started)
    if sid:
        print(sid)
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError):
        sys.exit(1)
