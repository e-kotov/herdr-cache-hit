"""Focused checks for recovering a Claude session when Herdr has no ID."""

import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from claude_session import resolve_session  # noqa: E402


class ClaudeSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = str(self.root / "work")
        self.started = time.time() - 10
        self.process = {"foreground_processes": [{
            "name": "claude.exe", "argv": ["claude.exe", "-c"], "pid": 123,
        }]}
        self.project = self.root / "projects" / "".join(
            ch if ch.isalnum() and ch.isascii() else "-" for ch in self.cwd
        )
        self.project.mkdir(parents=True)

    def transcript(self, sid, modified):
        path = self.project / f"{sid}.jsonl"
        path.write_text("{}\n", encoding="utf-8")
        os.utime(path, (modified, modified))
        return path

    def resolve(self, panes=None, process=None, started=None):
        return resolve_session(
            self.root, self.cwd, "p1", self.process if process is None else process,
            panes or [], self.started if started is None else started,
        )

    def test_unique_live_transcript_for_continue(self):
        self.transcript("old", self.started - 100)
        self.transcript("current", self.started + 5)
        self.assertEqual(self.resolve(), "current")

    def test_ambiguous_transcripts_or_panes_are_rejected(self):
        self.transcript("first", self.started + 5)
        self.transcript("second", self.started + 6)
        self.assertIsNone(self.resolve())
        (self.project / "second.jsonl").unlink()
        self.assertIsNone(self.resolve([{"agent": "claude", "pane_id": "p2", "cwd": self.cwd}]))

    def test_explicit_resume_id_is_used(self):
        self.transcript("selected", self.started - 100)
        process = {"foreground_processes": [{
            "name": "claude.exe", "argv": ["claude.exe", "--resume", "selected"], "pid": 123,
        }]}
        self.assertEqual(self.resolve(process=process), "selected")

    def test_missing_process_or_start_time_is_rejected(self):
        self.transcript("current", self.started + 5)
        self.assertIsNone(self.resolve(process={"foreground_processes": []}))
        self.assertIsNone(self.resolve(started=0))


if __name__ == "__main__":
    unittest.main()
