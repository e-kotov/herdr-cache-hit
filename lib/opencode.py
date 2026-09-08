#!/usr/bin/env python3
"""OpenCode session and message cache usage extractor for Herdr Cache HUD."""
import datetime
import json
import os
import sqlite3
import sys

def find_db_path(supplied=None):
    if supplied and os.path.isfile(supplied):
        return supplied
    env_path = os.environ.get("OPENCODE_DB_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path
    xdg_data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    candidates = [
        os.path.join(xdg_data, "opencode", "opencode.db"),
        os.path.expanduser("~/.local/share/opencode/opencode.db"),
        os.path.expanduser("~/Library/Application Support/opencode/opencode.db"),
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return cand
    return None

def parse_model_info(model_raw):
    model = ""
    provider = ""
    if not model_raw:
        return model, provider
    if isinstance(model_raw, dict):
        model = model_raw.get("id") or model_raw.get("modelID") or ""
        provider = model_raw.get("providerID") or ""
    elif isinstance(model_raw, str):
        try:
            m = json.loads(model_raw)
            if isinstance(m, dict):
                model = m.get("id") or m.get("modelID") or ""
                provider = m.get("providerID") or ""
            else:
                model = str(m)
        except Exception:
            model = model_raw
    return model, provider

def get_usage(session_id, cwd="", supplied=""):
    db_path = find_db_path(supplied)
    if not db_path:
        return None
    try:
        con = sqlite3.connect("file:{}?mode=ro".format(
            __import__('urllib.parse', fromlist=['quote']).quote(db_path, safe="/")
        ), uri=True, timeout=1.0)
        con.execute("PRAGMA busy_timeout = 1000;")
        cur = con.cursor()

        # If session_id not given or doesn't match, attempt resolution by directory
        if not session_id and cwd:
            cur.execute(
                "SELECT id FROM session WHERE directory = ? ORDER BY time_updated DESC LIMIT 1",
                (cwd,)
            )
            row = cur.fetchone()
            if row:
                session_id = row[0]

        if not session_id:
            return None

        # 1. Try latest completed assistant message
        cur.execute(
            """SELECT data FROM message 
               WHERE session_id = ? 
                 AND json_extract(data, '$.role') = 'assistant' 
                 AND json_extract(data, '$.time.completed') IS NOT NULL 
               ORDER BY time_created DESC LIMIT 1""",
            (session_id,)
        )
        row = cur.fetchone()
        if row:
            try:
                d = json.loads(row[0])
                tokens = d.get("tokens") or {}
                cache = tokens.get("cache") or {}
                ts_ms = d.get("time", {}).get("completed") or d.get("time", {}).get("created") or 0
                dt = datetime.datetime.fromtimestamp(ts_ms / 1000.0, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                inp = int(tokens.get("input") or 0)
                read = int(cache.get("read") or 0)
                write = int(cache.get("write") or 0)
                model = d.get("modelID") or ""
                provider = d.get("providerID") or ""
                return ["opencode", session_id, dt, inp, read, write, 0, 0, model, provider, db_path, 0]
            except Exception:
                pass

        # 2. Fall back to session table
        cur.execute(
            "SELECT tokens_input, tokens_cache_read, tokens_cache_write, time_updated, model FROM session WHERE id = ?",
            (session_id,)
        )
        s_row = cur.fetchone()
        if s_row:
            inp, read, write, ts_ms, model_raw = s_row
            dt = datetime.datetime.fromtimestamp((ts_ms or 0) / 1000.0, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            model, provider = parse_model_info(model_raw)
            return ["opencode", session_id, dt, int(inp or 0), int(read or 0), int(write or 0), 0, 0, model, provider, db_path, 0]

    except Exception:
        return None
    return None

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    session_id = sys.argv[1]
    cwd = sys.argv[2] if len(sys.argv) > 2 else ""
    supplied = sys.argv[3] if len(sys.argv) > 3 else ""
    res = get_usage(session_id, cwd, supplied)
    if res:
        print("\t".join(map(str, res)))
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()
