"""OpenCode session recovery when Herdr omits a native session ID."""

from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from opencode import get_usage  # noqa: E402
from opencode_session import resolve_session  # noqa: E402


class OpenCodeSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / "opencode.db"
        self.cwd = r"C:\work\project"
        self.started = time.time() - 10
        self.process = {"foreground_processes": [{
            "name": "opencode.exe", "argv": ["opencode.exe"], "pid": 123,
        }]}
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("""CREATE TABLE session (
                id TEXT PRIMARY KEY, directory TEXT, parent_id TEXT, title TEXT,
                time_created INTEGER, time_updated INTEGER, model TEXT,
                tokens_input INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER
            )""")
            con.execute("CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT)")
            con.commit()

    def session(self, sid, created, directory="C:/work/project", title="Greeting"):
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("INSERT INTO session VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)",
                        (sid, directory, title, int(created * 1000), int(created * 1000),
                         '{"id":"model","providerID":"provider"}', 100, 400, 20))
            con.commit()

    def resolve(self, process=None, panes=None, started=None, title="OC | Greeting"):
        return resolve_session(
            self.db, self.cwd, "p1", self.process if process is None else process,
            [] if panes is None else panes, self.started if started is None else started,
            title,
        )

    def test_unique_new_session_and_windows_directory(self):
        self.session("old", self.started - 100)
        self.session("current", self.started + 1)
        self.assertEqual(self.resolve(), "current")
        self.assertEqual(get_usage("", self.cwd, str(self.db))[1], "current")

    def test_ambiguous_sessions_and_peer_panes_are_rejected(self):
        self.session("first", self.started + 1)
        self.session("second", self.started + 2)
        self.assertIsNone(self.resolve())
        with closing(sqlite3.connect(self.db)) as con:
            con.execute("DELETE FROM session WHERE id = 'second'")
            con.commit()
        self.assertIsNone(self.resolve(panes=[{"agent": "opencode", "pane_id": "p2", "cwd": self.cwd}]))

    def test_explicit_session_id_is_verified(self):
        self.session("selected", self.started - 100)
        process = {"foreground_processes": [{
            "name": "opencode.exe", "argv": ["opencode.exe", "--session", "selected"], "pid": 123,
        }]}
        self.assertEqual(self.resolve(process=process), "selected")

    def test_new_session_in_same_process_replaces_bootstrap(self):
        self.started = time.time() - 120
        self.session("first", self.started + 1, title="First")
        self.session("second", self.started + 60, title="Second")
        self.assertEqual(self.resolve(title="OC | Second"), "second")

    def test_missing_process_or_start_time_is_rejected(self):
        self.session("current", self.started + 1)
        self.assertIsNone(self.resolve(process={"foreground_processes": []}))
        self.assertIsNone(self.resolve(started=0))


if __name__ == "__main__":
    unittest.main()
