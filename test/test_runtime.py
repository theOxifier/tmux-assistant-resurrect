#!/usr/bin/env python3
"""Unit tests for the Python runtime."""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "assistant_resurrect.py"
SPEC = importlib.util.spec_from_file_location("assistant_resurrect", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime from {MODULE_PATH}")
runtime = importlib.util.module_from_spec(SPEC)
sys.modules["assistant_resurrect"] = runtime
SPEC.loader.exec_module(runtime)


class TempEnvMixin:
    def setUp(self) -> None:
        super().setUp()
        self._tmpdir = tempfile.TemporaryDirectory()
        self._old_env = os.environ.copy()
        os.environ["HOME"] = self._tmpdir.name
        os.environ["TMUX_ASSISTANT_RESURRECT_DIR"] = str(Path(self._tmpdir.name) / "state")

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._old_env)
        self._tmpdir.cleanup()
        super().tearDown()

    @property
    def home(self) -> Path:
        return Path(self._tmpdir.name)

    @property
    def state_dir(self) -> Path:
        return Path(os.environ["TMUX_ASSISTANT_RESURRECT_DIR"])


class DetectToolTests(unittest.TestCase):
    def test_detect_tool_cases(self) -> None:
        cases = [
            ("claude", "claude"),
            ("claude --resume ses_123", "claude"),
            ("/usr/local/bin/claude --resume ses_123", "claude"),
            ("opencode -s ses_456", "opencode"),
            ("bash /usr/local/bin/opencode -s ses_456", "opencode"),
            ("opencode run pyright-langserver.js", None),
            ("codex resume ses_789", "codex"),
            ("/usr/bin/codex resume ses_789", "codex"),
            ("python3 -c 'import time; time.sleep(300)' --profile codex", None),
            ("/tmp/tools/codex-helper --foo", None),
        ]
        for command, expected in cases:
            with self.subTest(command=command):
                self.assertEqual(runtime.detect_tool(command), expected)


class PosixQuoteTests(unittest.TestCase):
    def test_posix_quote_cases(self) -> None:
        self.assertEqual(runtime.posix_quote("/tmp/project"), "'/tmp/project'")
        self.assertEqual(runtime.posix_quote("/tmp/my project"), "'/tmp/my project'")
        self.assertEqual(runtime.posix_quote("/tmp/project's dir"), "'/tmp/project'\"'\"'s dir'")
        self.assertEqual(runtime.posix_quote('/tmp/project"dir'), '\'/tmp/project"dir\'')
        self.assertEqual(runtime.posix_quote("/tmp/$HOME/project"), "'/tmp/$HOME/project'")
        self.assertEqual(runtime.posix_quote(""), "''")


class ExtractCliArgsTests(unittest.TestCase):
    def test_extract_cli_args_cases(self) -> None:
        cases = [
            ("claude", "claude --dangerously-skip-permissions --model opus --resume ses_abc123", "--dangerously-skip-permissions --model opus"),
            ("claude", "claude --dangerously-skip-permissions --resume=ses_abc123", "--dangerously-skip-permissions"),
            ("claude", "/usr/local/bin/claude --dangerously-skip-permissions --resume ses_abc", "--dangerously-skip-permissions"),
            ("claude", "claude --resume ses_abc", ""),
            ("opencode", "opencode --verbose -s ses_abc", "--verbose"),
            ("opencode", "opencode --verbose --session=ses_abc", "--verbose"),
            ("codex", "codex --full-auto resume ses_abc", "--full-auto"),
            ("codex", "codex resume", ""),
            ("codex", "codex --full-auto resume --all old-session-name", "--full-auto"),
            ("codex", "codex /usr/local/bin/codex", ""),
        ]
        for tool, raw_args, expected in cases:
            with self.subTest(tool=tool, raw_args=raw_args):
                self.assertEqual(runtime.extract_cli_args(tool, raw_args), expected)


class ClaudeSessionTests(TempEnvMixin, unittest.TestCase):
    def test_state_file_beats_args(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "claude-12345.json").write_text(
            json.dumps({"tool": "claude", "session_id": "ses_from_hook", "ppid": 12345}) + "\n",
            encoding="utf-8",
        )
        self.assertEqual(
            runtime.get_claude_session(12345, "claude --resume ses_from_args"),
            "ses_from_hook",
        )

    def test_corrupt_state_file_falls_through(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "claude-12345.json").write_text("NOT JSON\n", encoding="utf-8")
        self.assertEqual(
            runtime.get_claude_session(12345, "claude --resume ses_fallback"),
            "ses_fallback",
        )

    def test_pane_state_fallback(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "claude-11111.json").write_text(
            json.dumps(
                {
                    "tool": "claude",
                    "session_id": "ses_from_pane",
                    "ppid": 11111,
                    "timestamp": "2026-04-09T16:14:38Z",
                    "env": {"tmux_pane": "%5"},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(
            runtime.get_claude_session(22222, "claude", pane_id="%5", live_pids={11111, 22222}),
            "ses_from_pane",
        )

    def test_pane_state_fallback_rejects_stale_process(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "claude-11111.json").write_text(
            json.dumps(
                {
                    "tool": "claude",
                    "session_id": "ses_stale",
                    "ppid": 11111,
                    "timestamp": "2026-04-09T16:14:38Z",
                    "env": {"tmux_pane": "%5"},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(
            runtime.get_claude_session(22222, "claude", pane_id="%5", live_pids={22222}),
            "",
        )


class OpenCodeSessionTests(TempEnvMixin, unittest.TestCase):
    def test_arg_extraction(self) -> None:
        self.assertEqual(runtime.get_opencode_session(99999, "opencode -s ses_oc_456"), "ses_oc_456")
        self.assertEqual(runtime.get_opencode_session(99999, "opencode --session=ses_oc_789"), "ses_oc_789")

    def test_pane_state_fallback(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "opencode-11111.json").write_text(
            json.dumps(
                {
                    "tool": "opencode",
                    "session_id": "ses_from_pane",
                    "pid": 11111,
                    "timestamp": "2026-04-09T16:14:38Z",
                    "env": {"tmux_pane": "%4"},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(
            runtime.get_opencode_session(22222, "opencode", pane_id="%4", live_pids={11111, 22222}),
            "ses_from_pane",
        )

    def test_pane_state_fallback_rejects_stale_process(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "opencode-11111.json").write_text(
            json.dumps(
                {
                    "tool": "opencode",
                    "session_id": "ses_stale",
                    "pid": 11111,
                    "timestamp": "2026-04-09T16:14:38Z",
                    "env": {"tmux_pane": "%4"},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(
            runtime.get_opencode_session(22222, "opencode", pane_id="%4", live_pids={22222}),
            "",
        )


class StateBackedDetectionTests(TempEnvMixin, unittest.TestCase):
    def test_assistant_candidates_uses_state_file_when_args_hide_tool_name(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "opencode-4242.json").write_text(
            json.dumps({"tool": "opencode", "session_id": "ses_hidden", "pid": 4242}) + "\n",
            encoding="utf-8",
        )
        processes, children = runtime.parse_ps_snapshot(
            "10 1 -zsh\n4242 10 /tmp/.tmpXYZ/runner --hidden-title\n"
        )
        candidates = runtime.assistant_candidates(
            10,
            processes,
            children,
            state_cache=runtime.state_file_cache(),
        )
        self.assertEqual([(candidate.pid, candidate.tool) for candidate in candidates], [(4242, "opencode")])

    def test_pane_assistant_pid_uses_state_file_when_args_hide_tool_name(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / "opencode-4242.json").write_text(
            json.dumps({"tool": "opencode", "session_id": "ses_hidden", "pid": 4242}) + "\n",
            encoding="utf-8",
        )
        processes, children = runtime.parse_ps_snapshot(
            "10 1 -zsh\n4242 10 /tmp/.tmpXYZ/runner --hidden-title\n"
        )
        self.assertEqual(
            runtime.pane_assistant_pid(10, processes, children, state_cache=runtime.state_file_cache()),
            4242,
        )


class CodexSessionTests(TempEnvMixin, unittest.TestCase):
    def test_resume_arg_extraction(self) -> None:
        self.assertEqual(runtime.get_codex_session(99999, "codex resume ses_codex_789"), "ses_codex_789")

    def test_rollout_lookup_and_dedup(self) -> None:
        sessions_dir = self.home / ".codex" / "sessions" / "2026" / "03" / "24"
        sessions_dir.mkdir(parents=True, exist_ok=True)
        rollout_a = sessions_dir / "rollout-a.jsonl"
        rollout_b = sessions_dir / "rollout-b.jsonl"
        rollout_a.write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {
                        "id": "ses_rollout_aaa",
                        "cwd": "/tmp/test-project",
                        "timestamp": "2026-03-24T10:00:00.000Z",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        time.sleep(0.01)
        rollout_b.write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {
                        "id": "ses_rollout_bbb",
                        "cwd": "/tmp/test-project",
                        "timestamp": "2026-03-24T10:01:00.000Z",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        metadata = runtime.load_codex_metadata()
        now = runtime.parse_timestamp("2026-03-24T10:01:15.000Z")
        self.assertIsNotNone(now)
        with (
            mock.patch.object(runtime, "read_etimes", return_value=15),
            mock.patch.object(runtime.time, "time", return_value=now),
        ):
            first = runtime.get_codex_session(99999, "codex", "/tmp/test-project", metadata=metadata, used_ids=set())
            second = runtime.get_codex_session(99999, "codex", "/tmp/test-project", metadata=metadata, used_ids={first})
        self.assertIn(first, {"ses_rollout_aaa", "ses_rollout_bbb"})
        self.assertIn(second, {"ses_rollout_aaa", "ses_rollout_bbb"})
        self.assertNotEqual(first, second)

    def test_rollout_lookup_rejects_stale_history_for_bare_session(self) -> None:
        sessions_dir = self.home / ".codex" / "sessions" / "2026" / "03" / "24"
        sessions_dir.mkdir(parents=True, exist_ok=True)
        (sessions_dir / "stale-rollout.jsonl").write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {
                        "id": "ses_stale_rollout",
                        "cwd": "/tmp/test-project",
                        "timestamp": "2026-03-24T10:00:00.000Z",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        metadata = runtime.load_codex_metadata()
        now = runtime.parse_timestamp("2026-04-10T10:01:15.000Z")
        self.assertIsNotNone(now)
        with (
            mock.patch.object(runtime, "read_etimes", return_value=15),
            mock.patch.object(runtime.time, "time", return_value=now),
        ):
            self.assertEqual(
                runtime.get_codex_session(99999, "codex", "/tmp/test-project", metadata=metadata, used_ids=set()),
                "",
            )

    def test_named_thread_lookup_uses_window_name_and_cwd(self) -> None:
        codex_dir = self.home / ".codex"
        codex_dir.mkdir(parents=True, exist_ok=True)
        db_path = codex_dir / "state_5.sqlite"
        conn = sqlite3.connect(db_path)
        conn.execute(
            """CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                source TEXT NOT NULL,
                model_provider TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                sandbox_policy TEXT NOT NULL,
                approval_mode TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                has_user_event INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                archived_at INTEGER
            )"""
        )
        conn.execute(
            """INSERT INTO threads (
                id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
                sandbox_policy, approval_mode, archived
            ) VALUES (
                '019renamewinner00000000000000000000',
                '/tmp/rollout-a.jsonl',
                1000, 3000, 'interactive', 'openai', '/tmp/codex-project', 'renamed session',
                'workspace-write', 'on-request', 0
            )"""
        )
        conn.execute(
            """INSERT INTO threads (
                id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
                sandbox_policy, approval_mode, archived
            ) VALUES (
                '019olderthread000000000000000000000',
                '/tmp/rollout-b.jsonl',
                1000, 2000, 'interactive', 'openai', '/tmp/codex-project', 'older session',
                'workspace-write', 'on-request', 0
            )"""
        )
        conn.commit()
        conn.close()
        (codex_dir / "session_index.jsonl").write_text(
            json.dumps(
                {
                    "id": "019renamewinner00000000000000000000",
                    "thread_name": "renamed session",
                    "updated_at": "2026-01-01T00:00:03Z",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        metadata = runtime.load_codex_metadata()
        self.assertEqual(
            runtime.get_codex_session(99999, "codex", "/tmp/codex-project", "renamed session", metadata=metadata),
            "019renamewinner00000000000000000000",
        )
        self.assertEqual(
            runtime.get_codex_session(99999, "codex resume --all", "/tmp/codex-project", "renamed session", metadata=metadata),
            "019renamewinner00000000000000000000",
        )
        self.assertEqual(
            runtime.get_codex_session(99999, "codex", "/tmp/codex-project", "bad-window", metadata=metadata),
            "",
        )

    def test_named_thread_lookup_does_not_reuse_same_session_across_panes(self) -> None:
        codex_dir = self.home / ".codex"
        codex_dir.mkdir(parents=True, exist_ok=True)
        db_path = codex_dir / "state_5.sqlite"
        conn = sqlite3.connect(db_path)
        conn.execute(
            """CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                source TEXT NOT NULL,
                model_provider TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                sandbox_policy TEXT NOT NULL,
                approval_mode TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                has_user_event INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                archived_at INTEGER
            )"""
        )
        conn.execute(
            """INSERT INTO threads (
                id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
                sandbox_policy, approval_mode, archived
            ) VALUES (
                '019namedpane1000000000000000000000',
                '/tmp/rollout-named.jsonl',
                1000, 3000, 'interactive', 'openai', '/tmp/codex-project', 'shared-window',
                'workspace-write', 'on-request', 0
            )"""
        )
        conn.execute(
            """INSERT INTO threads (
                id, rollout_path, created_at, updated_at, source, model_provider, cwd, title,
                sandbox_policy, approval_mode, archived
            ) VALUES (
                '019rolloutpane200000000000000000000',
                '/tmp/rollout-pane-2.jsonl',
                1000, 2000, 'interactive', 'openai', '/tmp/codex-project', 'another title',
                'workspace-write', 'on-request', 0
            )"""
        )
        conn.commit()
        conn.close()
        (codex_dir / "session_index.jsonl").write_text(
            json.dumps(
                {
                    "id": "019namedpane1000000000000000000000",
                    "thread_name": "shared-window",
                    "updated_at": "2026-01-01T00:00:03Z",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        sessions_dir = codex_dir / "sessions" / "2026" / "03" / "24"
        sessions_dir.mkdir(parents=True, exist_ok=True)
        (sessions_dir / "rollout-pane-1.jsonl").write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {
                        "id": "019namedpane1000000000000000000000",
                        "cwd": "/tmp/codex-project",
                        "timestamp": "2026-03-24T10:00:00.000Z",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (sessions_dir / "rollout-pane-2.jsonl").write_text(
            json.dumps(
                {
                    "type": "session_meta",
                    "payload": {
                        "id": "019rolloutpane200000000000000000000",
                        "cwd": "/tmp/codex-project",
                        "timestamp": "2026-03-24T10:00:10.000Z",
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        metadata = runtime.load_codex_metadata()
        now = runtime.parse_timestamp("2026-03-24T10:00:15.000Z")
        self.assertIsNotNone(now)
        with (
            mock.patch.object(runtime, "read_etimes", return_value=15),
            mock.patch.object(runtime.time, "time", return_value=now),
        ):
            first = runtime.get_codex_session(
                99999,
                "codex",
                "/tmp/codex-project",
                "shared-window",
                metadata=metadata,
                used_ids=set(),
            )
            second = runtime.get_codex_session(
                99998,
                "codex",
                "/tmp/codex-project",
                "shared-window",
                metadata=metadata,
                used_ids={first},
            )
        self.assertEqual(first, "019namedpane1000000000000000000000")
        self.assertEqual(second, "019rolloutpane200000000000000000000")


class ConfigSafetyTests(TempEnvMixin, unittest.TestCase):
    def test_invalid_config_fails_closed(self) -> None:
        settings_path = self.home / ".claude" / "settings.json"
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        settings_path.write_text("{ invalid\n", encoding="utf-8")
        self.assertIsNone(runtime.read_json_object_for_update(settings_path, "Claude settings.json"))
        self.assertEqual(settings_path.read_text(encoding="utf-8"), "{ invalid\n")


class SaveRuntimeTests(TempEnvMixin, unittest.TestCase):
    def test_save_runtime_preserves_env_from_pane_fallback(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        output_path = self.home / "assistant-sessions.json"
        os.environ["OUTPUT_FILE"] = str(output_path)
        (self.state_dir / "opencode-33333.json").write_text(
            json.dumps(
                {
                    "tool": "opencode",
                    "session_id": "ses_from_pane",
                    "pid": 33333,
                    "timestamp": "2026-04-09T16:14:38Z",
                    "env": {"tmux_pane": "%4", "OPENCODE_DEBUG": "1"},
                }
            )
            + "\n",
            encoding="utf-8",
        )

        original_run_command = runtime.run_command
        original_tmux_capture = runtime.tmux_capture
        def fake_run_command(argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
            if argv == ["ps", "-eo", "pid=,ppid=,args="]:
                stdout = "\n".join(
                    [
                        "100 1 -zsh",
                        "22222 100 opencode --profile test",
                        "33333 22222 node plugin-host.js",
                    ]
                )
                return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")
            raise AssertionError(f"unexpected command: {argv}")

        def fake_tmux_capture(format_str: str) -> str:
            self.assertEqual(
                format_str,
                "#{session_name}:#{window_index}.#{pane_index}|#{pane_id}|#{pane_pid}|#{pane_current_path}|#{window_name}",
            )
            return "work:0.0|%4|100|/tmp/project|project\n"

        runtime.run_command = fake_run_command
        runtime.tmux_capture = fake_tmux_capture
        try:
            self.assertEqual(runtime.save_runtime(), 0)
        finally:
            runtime.run_command = original_run_command
            runtime.tmux_capture = original_tmux_capture

        payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(
            payload["sessions"],
            [
                {
                    "pane": "work:0.0",
                    "tool": "opencode",
                    "session_id": "ses_from_pane",
                    "cwd": "/tmp/project",
                    "cli_args": "--profile test",
                    "env": {"tmux_pane": "%4", "OPENCODE_DEBUG": "1"},
                }
            ],
        )


class SessionDiffTests(unittest.TestCase):
    def test_summarize_session_changes_reports_added_dropped_and_updated_panes(self) -> None:
        previous = [
            {
                "pane": "codex:1.1",
                "tool": "codex",
                "session_id": "ses_old",
                "cwd": "/tmp/old",
                "cli_args": "",
            },
            {
                "pane": "codex:2.1",
                "tool": "codex",
                "session_id": "ses_drop",
                "cwd": "/tmp/drop",
                "cli_args": "",
            },
        ]
        current = [
            {
                "pane": "codex:1.1",
                "tool": "codex",
                "session_id": "ses_new",
                "cwd": "/tmp/new",
                "cli_args": "--full-auto",
            },
            {
                "pane": "codex:3.1",
                "tool": "codex",
                "session_id": "ses_add",
                "cwd": "/tmp/add",
                "cli_args": "",
            },
        ]

        changes = runtime.summarize_session_changes(previous, current)

        self.assertEqual(
            changes,
            [
                "added pane codex:3.1 (codex ses_add cwd /tmp/add)",
                "dropped pane codex:2.1 (codex ses_drop cwd /tmp/drop)",
                "updated pane codex:1.1 (codex ses_old cwd /tmp/old -> codex ses_new cwd /tmp/new)",
            ],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
