#!/usr/bin/env python3
"""tmux-assistant-resurrect runtime.

Python runtime for save/restore orchestration, hook installation, and
assistant-native hook handling.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


LOG_LINE_LIMIT = 500
SHELL_WHITELIST = {"bash", "zsh", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu"}
RESTORE_TIMEOUT_SECONDS = float(os.environ.get("TMUX_ASSISTANT_RESTORE_TIMEOUT_SECONDS", "10.0"))
RESTORE_POLL_INTERVAL_SECONDS = float(os.environ.get("TMUX_ASSISTANT_RESTORE_POLL_INTERVAL_SECONDS", "0.1"))
RESTORE_RETRY_INTERVAL_SECONDS = float(os.environ.get("TMUX_ASSISTANT_RESTORE_RETRY_INTERVAL_SECONDS", "1.5"))


@dataclass
class ProcessInfo:
    pid: int
    ppid: int
    args: str
    tool: str | None


@dataclass
class PaneInfo:
    target: str
    pane_pid: int
    cwd: str = ""
    window_name: str = ""
    current_command: str = ""


@dataclass
class SessionEntry:
    pane: str
    tool: str
    session_id: str
    cwd: str
    pid: str
    model: str = ""
    cli_args: str = ""
    env: Any = None


@dataclass
class RolloutCandidate:
    session_id: str
    timestamp: float | None
    mtime: float


@dataclass
class CodexMetadata:
    pid_to_session: dict[int, str]
    thread_name_to_session: dict[str, str]
    rollout_by_cwd: dict[str, list[RolloutCandidate]]
    sid_to_cwds: dict[str, set[str]]
    latest_by_cwd: dict[str, tuple[int, str]]


def state_dir() -> Path:
    base = os.environ.get("STATE_DIR") or os.environ.get("TMUX_ASSISTANT_RESURRECT_DIR")
    if base:
        return Path(base)
    runtime = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    return Path(runtime) / "tmux-assistant-resurrect"


def resurrect_dir() -> Path:
    return Path.home() / ".tmux" / "resurrect"


def output_file() -> Path:
    return Path(os.environ.get("OUTPUT_FILE", resurrect_dir() / "assistant-sessions.json"))


def save_log_file() -> Path:
    return Path(os.environ.get("LOG_FILE", resurrect_dir() / "assistant-save.log"))


def restore_log_file() -> Path:
    return resurrect_dir() / "assistant-restore.log"


def rotate_log(path: Path) -> None:
    if not path.exists():
        return
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        if len(lines) > LOG_LINE_LIMIT:
            path.write_text("\n".join(lines[-LOG_LINE_LIMIT:]) + "\n", encoding="utf-8")
    except OSError:
        pass


def log(path: Path, message: str) -> None:
    timestamp = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{timestamp}] {message}"
    print(line, file=sys.stderr)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def run_command(
    argv: list[str],
    *,
    check: bool = False,
    text: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        check=check,
        text=text,
        capture_output=capture_output,
    )


def tmux_base_argv() -> list[str]:
    argv = [os.environ.get("TMUX_ASSISTANT_TMUX_BIN", "tmux")]
    socket_name = os.environ.get("TMUX_ASSISTANT_TMUX_SOCKET", "")
    config_path = os.environ.get("TMUX_ASSISTANT_TMUX_CONFIG", "")
    if socket_name:
        argv.extend(["-L", socket_name])
    if config_path:
        argv.extend(["-f", config_path])
    return argv


def run_tmux(argv: list[str], *, capture_output: bool = True) -> subprocess.CompletedProcess[str]:
    return run_command(tmux_base_argv() + argv, capture_output=capture_output)


def tmux_capture(format_str: str) -> str:
    proc = run_tmux(["list-panes", "-a", "-F", format_str])
    if proc.returncode != 0:
        return ""
    return proc.stdout


def normalize_args(args: str) -> list[str]:
    try:
        return shlex.split(args)
    except ValueError:
        return args.split()


def detect_tool(args: str) -> str | None:
    tokens = normalize_args(args)
    if not tokens:
        return None

    def token_is_tool(token: str, tool: str) -> bool:
        basename = os.path.basename(token)
        return basename == tool and "/" in token

    first = os.path.basename(tokens[0])
    if first == "claude":
        return "claude"
    if first == "opencode":
        return None if len(tokens) > 1 and tokens[1] == "run" else "opencode"
    if first == "codex":
        return "codex"

    for idx, token in enumerate(tokens[1:], start=1):
        if token_is_tool(token, "claude"):
            return "claude"
        if token_is_tool(token, "opencode"):
            return None if len(tokens) > idx + 1 and tokens[idx + 1] == "run" else "opencode"
        if token_is_tool(token, "codex"):
            return "codex"
    return None


def posix_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def parse_ps_snapshot(snapshot: str) -> tuple[dict[int, ProcessInfo], dict[int, list[int]]]:
    processes: dict[int, ProcessInfo] = {}
    children: dict[int, list[int]] = defaultdict(list)
    for raw_line in snapshot.splitlines():
        line = raw_line.rstrip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        args = parts[2] if len(parts) > 2 else ""
        tool = detect_tool(args)
        processes[pid] = ProcessInfo(pid=pid, ppid=ppid, args=args, tool=tool)
        children[ppid].append(pid)
    return processes, children


def parse_pane_snapshot(snapshot: str, *, include_command: bool = False) -> dict[str, PaneInfo]:
    panes: dict[str, PaneInfo] = {}
    for raw_line in snapshot.splitlines():
        if not raw_line:
            continue
        parts = raw_line.split("|")
        if include_command:
            if len(parts) < 3:
                continue
            target, pane_pid_raw, current_command = parts[:3]
            try:
                pane_pid = int(pane_pid_raw)
            except ValueError:
                continue
            panes[target] = PaneInfo(target=target, pane_pid=pane_pid, current_command=current_command)
        else:
            if len(parts) < 4:
                continue
            target, pane_pid_raw, cwd, window_name = parts[:4]
            try:
                pane_pid = int(pane_pid_raw)
            except ValueError:
                continue
            panes[target] = PaneInfo(target=target, pane_pid=pane_pid, cwd=cwd, window_name=window_name)
    return panes


def pane_assistant_pid(root_pid: int, processes: dict[int, ProcessInfo], children: dict[int, list[int]]) -> int | None:
    root = processes.get(root_pid)
    if root and root.tool:
        return root.pid
    queue: deque[int] = deque(children.get(root_pid, []))
    while queue:
        pid = queue.popleft()
        proc = processes.get(pid)
        if proc and proc.tool:
            return proc.pid
        queue.extend(children.get(pid, []))
    return None


def assistant_candidates(root_pid: int, processes: dict[int, ProcessInfo], children: dict[int, list[int]]) -> list[ProcessInfo]:
    found: list[ProcessInfo] = []
    seen: set[int] = set()
    root = processes.get(root_pid)
    if root and root.tool:
        found.append(root)
        seen.add(root.pid)
    queue: deque[int] = deque(children.get(root_pid, []))
    while queue:
        pid = queue.popleft()
        if pid in seen:
            continue
        seen.add(pid)
        proc = processes.get(pid)
        if proc and proc.tool:
            found.append(proc)
        queue.extend(children.get(pid, []))
    return found


def read_json_file(path: Path) -> Any | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def read_json_object_for_update(path: Path, label: str) -> dict[str, Any] | None:
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        print(f"Failed to read {label} at {path}: {exc}", file=sys.stderr)
        return None
    except json.JSONDecodeError as exc:
        print(f"Refusing to modify invalid {label} at {path}: {exc}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(f"Refusing to modify {label} at {path}: expected a JSON object", file=sys.stderr)
        return None
    return data


def read_json_lines(path: Path) -> list[Any]:
    if not path.exists():
        return []
    rows: list[Any] = []
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    rows.append(json.loads(stripped))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return rows


def state_file_cache() -> dict[str, dict[str, Any]]:
    cache: dict[str, dict[str, Any]] = {}
    directory = state_dir()
    if not directory.exists():
        return cache
    for path in sorted(directory.glob("claude-*.json")) + sorted(directory.glob("opencode-*.json")):
        data = read_json_file(path)
        if not isinstance(data, dict):
            continue
        pid = path.stem.split("-", 1)[1] if "-" in path.stem else ""
        if pid:
            cache[pid] = data
    return cache


def read_etimes(pid: int) -> int | None:
    proc = run_command(["ps", "-o", "etimes=", "-p", str(pid)])
    if proc.returncode != 0:
        return None
    value = proc.stdout.strip()
    return int(value) if value.isdigit() else None


def load_opencode_db() -> dict[str, list[str]]:
    db_path = Path.home() / ".local" / "share" / "opencode" / "opencode.db"
    sessions_by_dir: dict[str, list[str]] = defaultdict(list)
    if not db_path.exists():
        return sessions_by_dir
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, directory, time_updated FROM session ORDER BY time_updated DESC"
        ).fetchall()
        conn.close()
    except sqlite3.DatabaseError:
        return sessions_by_dir
    for row in rows:
        directory = row["directory"]
        session_id = row["id"]
        if directory and session_id:
            sessions_by_dir[directory].append(session_id)
    return sessions_by_dir


def load_codex_metadata() -> CodexMetadata:
    codex_home = Path.home() / ".codex"
    pid_to_session: dict[int, str] = {}
    thread_name_to_session: dict[str, str] = {}
    rollout_by_cwd: dict[str, list[RolloutCandidate]] = defaultdict(list)
    sid_to_cwds: dict[str, set[str]] = defaultdict(set)
    latest_by_cwd: dict[str, tuple[int, str]] = {}

    for row in read_json_lines(codex_home / "session-tags.jsonl"):
        try:
            pid = int(row.get("pid"))
        except (TypeError, ValueError):
            continue
        session_id = row.get("session")
        if isinstance(session_id, str) and session_id:
            pid_to_session[pid] = session_id

    for row in read_json_lines(codex_home / "session_index.jsonl"):
        thread_name = row.get("thread_name")
        session_id = row.get("id")
        if isinstance(thread_name, str) and isinstance(session_id, str) and thread_name and session_id:
            thread_name_to_session[thread_name] = session_id

    sessions_root = codex_home / "sessions"
    if sessions_root.exists():
        for path in sessions_root.rglob("*.jsonl"):
            try:
                with path.open("r", encoding="utf-8") as handle:
                    first_line = handle.readline().strip()
                if not first_line:
                    continue
                row = json.loads(first_line)
            except (OSError, json.JSONDecodeError):
                continue
            if row.get("type") != "session_meta":
                continue
            payload = row.get("payload") or {}
            cwd = payload.get("cwd")
            session_id = payload.get("id")
            if not isinstance(cwd, str) or not isinstance(session_id, str) or not cwd or not session_id:
                continue
            timestamp = parse_timestamp(payload.get("timestamp"))
            try:
                mtime = path.stat().st_mtime
            except OSError:
                mtime = 0
            rollout_by_cwd[cwd].append(RolloutCandidate(session_id=session_id, timestamp=timestamp, mtime=mtime))

    for db_file in sorted(glob.glob(str(codex_home / "state_*.sqlite"))):
        try:
            conn = sqlite3.connect(f"file:{db_file}?mode=ro", uri=True)
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT id, cwd, updated_at, archived FROM threads"
            ).fetchall()
            conn.close()
        except sqlite3.DatabaseError:
            continue
        for row in rows:
            if row["archived"]:
                continue
            session_id = row["id"]
            cwd = row["cwd"]
            if not isinstance(session_id, str) or not isinstance(cwd, str):
                continue
            sid_to_cwds[session_id].add(cwd)
            updated_at = normalize_int(row["updated_at"])
            current = latest_by_cwd.get(cwd)
            if current is None or updated_at > current[0]:
                latest_by_cwd[cwd] = (updated_at, session_id)

    return CodexMetadata(
        pid_to_session=pid_to_session,
        thread_name_to_session=thread_name_to_session,
        rollout_by_cwd=rollout_by_cwd,
        sid_to_cwds=sid_to_cwds,
        latest_by_cwd=latest_by_cwd,
    )


def parse_timestamp(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def normalize_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def get_claude_session(child_pid: int, args: str, cache: dict[str, dict[str, Any]] | None = None) -> str:
    cache = cache or state_file_cache()
    data = cache.get(str(child_pid))
    if isinstance(data, dict):
        session_id = data.get("session_id")
        if isinstance(session_id, str) and session_id:
            return session_id
    match = re.search(r"--resume(?:=|\s+)(\S+)", args)
    return match.group(1) if match else ""


def get_opencode_session(
    child_pid: int,
    args: str,
    cwd: str,
    allow_db: bool = True,
    cache: dict[str, dict[str, Any]] | None = None,
    db_sessions: dict[str, list[str]] | None = None,
) -> str:
    cache = cache or state_file_cache()
    data = cache.get(str(child_pid))
    if isinstance(data, dict):
        session_id = data.get("session_id")
        if isinstance(session_id, str) and session_id:
            return session_id

    match = re.search(r"--session(?:=|\s+)(\S+)", args)
    if match:
        return match.group(1)
    match = re.search(r"(?:^|\s)-s\s+(\S+)", args)
    if match:
        return match.group(1)

    if allow_db and cwd:
        db_sessions = db_sessions or load_opencode_db()
        matches = db_sessions.get(cwd) or []
        if matches:
            return matches[0]
    return ""


def _named_codex_target(args: str) -> str:
    match = re.search(r"\bresume\s+(.+)$", args)
    if not match:
        return ""
    target = match.group(1).strip()
    if not target or target.startswith("-"):
        return ""
    return target


def _rollout_candidate_for_cwd(
    cwd: str,
    child_pid: int,
    used_ids: set[str],
    metadata: CodexMetadata,
) -> str:
    candidates = metadata.rollout_by_cwd.get(cwd) or []
    if not candidates:
        return ""
    etimes = read_etimes(child_pid)
    process_start = time.time() - etimes if etimes is not None else None

    def score(candidate: RolloutCandidate) -> tuple[int, int, float, float]:
        reused = candidate.session_id in used_ids
        if process_start is None or candidate.timestamp is None:
            prior = 0
            distance = float("inf")
        else:
            prior = 1 if candidate.timestamp <= process_start + 120 else 0
            distance = abs(process_start - candidate.timestamp)
        return (0 if reused else 1, prior, -distance, candidate.mtime)

    best = max(candidates, key=score)
    return best.session_id


def get_codex_session(
    child_pid: int,
    args: str,
    cwd: str = "",
    window_name: str = "",
    *,
    metadata: CodexMetadata | None = None,
    used_ids: set[str] | None = None,
) -> str:
    metadata = metadata or load_codex_metadata()
    used_ids = used_ids or set()

    pid_match = metadata.pid_to_session.get(child_pid)
    if pid_match:
        return pid_match

    explicit_uuid = re.search(r"\bresume\s+([A-Fa-f0-9-]{36})\b", args)
    if explicit_uuid:
        return explicit_uuid.group(1)

    named_target = _named_codex_target(args) or window_name
    if named_target:
        candidate = metadata.thread_name_to_session.get(named_target)
        if candidate:
            if not cwd or cwd in metadata.sid_to_cwds.get(candidate, set()):
                return candidate

    if cwd:
        rollout_sid = _rollout_candidate_for_cwd(cwd, child_pid, used_ids, metadata)
        if rollout_sid:
            return rollout_sid

        latest = metadata.latest_by_cwd.get(cwd)
        if latest:
            return latest[1]

    fallback = re.search(r"\bresume\s+([A-Za-z0-9_.:/-]+)", args)
    if fallback:
        return fallback.group(1)
    return ""


def register_codex_session_id(session_id: str) -> None:
    current = os.environ.get("USED_CODEX_SESSION_IDS", "")
    used = {value for value in current.split("\t") if value}
    if session_id and session_id not in used:
        used.add(session_id)
        os.environ["USED_CODEX_SESSION_IDS"] = "\t".join(sorted(used))


def extract_cli_args(tool: str, raw_args: str) -> str:
    tokens = normalize_args(raw_args)
    if len(tokens) <= 1:
        return ""
    tokens = tokens[1:]
    if tokens and "/" in tokens[0] and os.path.basename(tokens[0]) == tool:
        tokens = tokens[1:]

    result: list[str] = []
    idx = 0
    while idx < len(tokens):
        token = tokens[idx]
        if tool == "claude":
            if token == "--resume":
                idx += 2
                continue
            if token.startswith("--resume="):
                idx += 1
                continue
        elif tool == "opencode":
            if token in {"-s", "--session"}:
                idx += 2
                continue
            if token.startswith("--session="):
                idx += 1
                continue
        elif tool == "codex":
            if token == "resume":
                break
        result.append(token)
        idx += 1
    return " ".join(result).strip()


def build_env_prefix(env_json: Any) -> str:
    capture_env = get_tmux_option("@assistant-resurrect-capture-env").split()
    if not isinstance(env_json, dict) or not capture_env:
        return ""
    pieces: list[str] = []
    for var in capture_env:
        value = env_json.get(var)
        if isinstance(value, str) and value:
            pieces.append(f"{var}={posix_quote(value)}")
    return " ".join(pieces) + (" " if pieces else "")


def get_tmux_option(name: str) -> str:
    proc = run_tmux(["show-option", "-gqv", name])
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def build_captured_env() -> dict[str, str]:
    env = {
        "tmux_pane": os.environ.get("TMUX_PANE", ""),
        "shell": os.environ.get("SHELL", ""),
    }
    for var in get_tmux_option("@assistant-resurrect-capture-env").split():
        env[var] = os.environ.get(var, "")
    return env


def build_resume_command(tool: str, session_id: str, cli_args: str, env_json: Any) -> str:
    safe_sid = posix_quote(session_id)
    if tool == "codex":
        cli_args = re.sub(r"^resume(?:\s+\S+)?", "", cli_args).strip()

    safe_tokens: list[str] = []
    if cli_args:
        for token in normalize_args(cli_args):
            safe_tokens.append(posix_quote(token))

    if tool == "claude":
        command = "command claude"
        if safe_tokens:
            command += " " + " ".join(safe_tokens)
        command += f" --resume {safe_sid}"
    elif tool == "opencode":
        command = "command opencode"
        if safe_tokens:
            command += " " + " ".join(safe_tokens)
        command += f" -s {safe_sid}"
    elif tool == "codex":
        command = "command codex"
        if safe_tokens:
            command += " " + " ".join(safe_tokens)
        command += f" resume {safe_sid}"
    else:
        raise ValueError(f"unknown tool: {tool}")

    return build_env_prefix(env_json) + command


def read_saved_sessions() -> tuple[list[dict[str, Any]], str]:
    path = output_file()
    data = read_json_file(path)
    if not isinstance(data, dict):
        return [], ""
    sessions = data.get("sessions")
    timestamp = data.get("timestamp") if isinstance(data.get("timestamp"), str) else ""
    return list(sessions or []), timestamp


def strip_assistant_pane_contents_runtime(
    *,
    sessions: list[dict[str, Any]] | None = None,
    output_path: Path | None = None,
    resurrect_path: Path | None = None,
    log_path: Path | None = None,
) -> int:
    output_path = output_path or output_file()
    resurrect_path = resurrect_path or resurrect_dir()
    log_path = log_path or save_log_file()

    if sessions is None:
        data = read_json_file(output_path)
        sessions = list((data or {}).get("sessions") or [])

    archive_path = resurrect_path / "pane_contents.tar.gz"
    if not archive_path.exists():
        return 0

    pane_targets = [
        entry.get("pane")
        for entry in sessions
        if isinstance(entry, dict) and isinstance(entry.get("pane"), str)
    ]
    if not pane_targets:
        return 0

    tmpdir = Path(tempfile.mkdtemp())
    removed = 0
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            archive.extractall(tmpdir)

        for pane_target in pane_targets:
            content_file = tmpdir / "pane_contents" / f"pane-{pane_target}"
            if content_file.exists():
                content_file.unlink()
                removed += 1

        if removed:
            tmp_archive = archive_path.with_suffix(".tar.gz.tmp")
            with tarfile.open(tmp_archive, "w:gz") as archive:
                archive.add(tmpdir / "pane_contents", arcname="./pane_contents")
            tmp_archive.replace(archive_path)
            log(log_path, f"stripped pane contents for {removed} assistant pane(s)")
        return 0
    except (OSError, tarfile.TarError):
        log(log_path, "warning: failed to repack pane_contents archive")
        return 0
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def session_entry_to_dict(entry: SessionEntry) -> dict[str, Any]:
    return {
        "pane": entry.pane,
        "tool": entry.tool,
        "session_id": entry.session_id,
        "cwd": entry.cwd,
        "pid": entry.pid,
        "model": entry.model,
        "cli_args": entry.cli_args,
        "env": entry.env,
    }


def save_runtime() -> int:
    log_path = save_log_file()
    rotate_log(log_path)
    output_path = output_file()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    state_dir().mkdir(parents=True, exist_ok=True, mode=0o700)

    ps_proc = run_command(["ps", "-eo", "pid=,ppid=,args="])
    if ps_proc.returncode != 0 or not ps_proc.stdout.strip():
        log(log_path, "ps snapshot failed or empty, skipping save")
        return 1

    pane_snapshot = tmux_capture("#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}|#{window_name}")
    panes = parse_pane_snapshot(pane_snapshot)
    processes, children = parse_ps_snapshot(ps_proc.stdout)
    state_cache = state_file_cache()
    opencode_db = load_opencode_db()
    codex_meta = load_codex_metadata()
    used_codex_ids: set[str] = set()
    sessions: list[dict[str, Any]] = []

    for pane in panes.values():
        candidates = assistant_candidates(pane.pane_pid, processes, children)
        if not candidates:
            continue

        first_tool = candidates[0].tool or ""
        first_pid = candidates[0].pid
        resolved: SessionEntry | None = None

        for allow_opencode_db in (False, True):
            if resolved is not None:
                break
            for process in candidates:
                if process.tool is None:
                    continue
                if allow_opencode_db and process.tool != "opencode":
                    continue

                session_id = ""
                if process.tool == "claude":
                    session_id = get_claude_session(process.pid, process.args, state_cache)
                elif process.tool == "opencode":
                    session_id = get_opencode_session(
                        process.pid,
                        process.args,
                        pane.cwd,
                        allow_db=allow_opencode_db,
                        cache=state_cache,
                        db_sessions=opencode_db,
                    )
                elif process.tool == "codex":
                    session_id = get_codex_session(
                        process.pid,
                        process.args,
                        pane.cwd,
                        pane.window_name,
                        metadata=codex_meta,
                        used_ids=used_codex_ids,
                    )

                if not session_id:
                    continue

                state_data = state_cache.get(str(process.pid), {})
                model = state_data.get("model", "") if isinstance(state_data, dict) else ""
                env_json = state_data.get("env") if isinstance(state_data, dict) else None
                if not isinstance(model, str):
                    model = ""
                if not model:
                    model = extract_model(process.args)

                resolved = SessionEntry(
                    pane=pane.target,
                    tool=process.tool,
                    session_id=session_id,
                    cwd=pane.cwd,
                    pid=str(process.pid),
                    model=model,
                    cli_args=extract_cli_args(process.tool, process.args),
                    env=env_json,
                )
                if process.tool == "codex":
                    used_codex_ids.add(session_id)
                break

        if resolved:
            sessions.append(session_entry_to_dict(resolved))
        elif first_tool:
            log(log_path, f"detected {first_tool} in {pane.target} (pid {first_pid}) but no session ID available")

    payload = {
        "timestamp": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sessions": sessions,
    }
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    log(log_path, f"saved {len(sessions)} assistant session(s) to {output_path}")
    if sessions:
        strip_assistant_pane_contents_runtime(sessions=sessions, output_path=output_path, log_path=log_path)
    return 0


def extract_model(args: str) -> str:
    tokens = normalize_args(args)
    for idx, token in enumerate(tokens):
        if token == "--model" and idx + 1 < len(tokens):
            return tokens[idx + 1]
        if token.startswith("--model="):
            return token.split("=", 1)[1]
    return ""


def restore_runtime() -> int:
    log_path = restore_log_file()
    rotate_log(log_path)
    sessions, _ = read_saved_sessions()
    if not sessions:
        log(log_path, f"no saved sessions found at {output_file()}" if not output_file().exists() else "no assistant sessions to restore")
        return 0

    pending = [entry for entry in sessions if isinstance(entry, dict)]
    log(log_path, f"restoring {len(pending)} assistant session(s)...")
    restored = 0
    deadline = time.monotonic() + RESTORE_TIMEOUT_SECONDS
    last_panes: dict[str, PaneInfo] = {}
    last_processes: dict[int, ProcessInfo] = {}
    last_children: dict[int, list[int]] = {}
    dispatch_times: dict[str, float] = {}
    dispatch_attempts: dict[str, int] = defaultdict(int)

    while pending and time.monotonic() <= deadline:
        now = time.monotonic()
        pane_snapshot = tmux_capture("#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_command}")
        ps_proc = run_command(["ps", "-eo", "pid=,ppid=,args="])
        last_panes = parse_pane_snapshot(pane_snapshot, include_command=True)
        if ps_proc.returncode == 0:
            last_processes, last_children = parse_ps_snapshot(ps_proc.stdout)

        remaining: list[dict[str, Any]] = []
        progress = False
        for entry in pending:
            pane = entry.get("pane")
            tool = entry.get("tool")
            session_id = entry.get("session_id")
            cwd = entry.get("cwd") if isinstance(entry.get("cwd"), str) else ""
            cli_args = entry.get("cli_args") if isinstance(entry.get("cli_args"), str) else ""
            env_json = entry.get("env")

            if not isinstance(pane, str) or not isinstance(tool, str) or not isinstance(session_id, str):
                continue

            pane_info = last_panes.get(pane)
            if not pane_info:
                remaining.append(entry)
                continue

            existing = pane_assistant_pid(pane_info.pane_pid, last_processes, last_children)
            if existing is not None:
                if pane in dispatch_times:
                    restored += 1
                    progress = True
                    log(log_path, f"confirmed {tool} running in {pane} after restore attempt")
                    dispatch_times.pop(pane, None)
                    dispatch_attempts.pop(pane, None)
                    continue
                remaining.append(entry)
                continue

            pane_cmd = pane_info.current_command.lstrip("-")
            if pane_cmd not in SHELL_WHITELIST:
                remaining.append(entry)
                continue

            last_dispatch = dispatch_times.get(pane)
            if last_dispatch is not None and (now - last_dispatch) < RESTORE_RETRY_INTERVAL_SECONDS:
                remaining.append(entry)
                continue

            try:
                resume_cmd = build_resume_command(tool, session_id, cli_args, env_json)
            except ValueError:
                log(log_path, f"unknown tool '{tool}' for pane {pane}, skipping")
                continue

            full_cmd = f"clear; {resume_cmd}"
            if cwd and cwd != "null":
                full_cmd = f"clear; cd {posix_quote(cwd)} 2>/dev/null; {resume_cmd}"

            attempt = dispatch_attempts[pane] + 1
            if attempt > 1:
                run_tmux(["send-keys", "-t", pane, "C-c"], capture_output=True)
            run_tmux(["clear-history", "-t", pane], capture_output=True)
            run_tmux(["send-keys", "-t", pane, full_cmd, "Enter"], capture_output=True)
            dispatch_attempts[pane] = attempt
            dispatch_times[pane] = now
            if attempt == 1:
                log(log_path, f"restoring {tool} in {pane} (session: {session_id}, cmd: {resume_cmd})")
            else:
                log(log_path, f"retrying {tool} in {pane} (attempt {attempt}, session: {session_id})")
            remaining.append(entry)

        if restored == len(sessions):
            pending = []
            break
        if len(remaining) == len(pending) and not progress:
            time.sleep(RESTORE_POLL_INTERVAL_SECONDS)
        pending = remaining

    if pending:
        pane_snapshot = tmux_capture("#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_command}")
        ps_proc = run_command(["ps", "-eo", "pid=,ppid=,args="])
        panes = parse_pane_snapshot(pane_snapshot, include_command=True)
        processes, children = parse_ps_snapshot(ps_proc.stdout if ps_proc.returncode == 0 else "")
        for entry in pending:
            pane = entry.get("pane")
            tool = entry.get("tool")
            if not isinstance(pane, str):
                continue
            pane_info = panes.get(pane)
            if pane_info is None:
                session_name = pane.split(":", 1)[0]
                has_session = run_tmux(["has-session", "-t", session_name], capture_output=True)
                if has_session.returncode != 0:
                    log(log_path, f"session '{session_name}' does not exist, skipping pane {pane}")
                else:
                    log(log_path, f"pane {pane} does not exist, skipping")
                continue

            pane_cmd = pane_info.current_command.lstrip("-")
            if pane_cmd not in SHELL_WHITELIST:
                log(log_path, f"pane {pane} is running '{pane_cmd}' (not a shell), skipping")
                continue

            existing = pane_assistant_pid(pane_info.pane_pid, processes, children)
            if existing is not None:
                if pane in dispatch_times:
                    restored += 1
                    log(log_path, f"confirmed {tool} running in {pane} after restore attempt")
                else:
                    log(log_path, f"pane {pane} already has a running assistant (pid {existing}), skipping")
                continue

            if isinstance(tool, str):
                attempts = dispatch_attempts.get(pane, 0)
                if attempts > 0:
                    log(log_path, f"pane {pane} did not launch {tool} after {attempts} restore attempt(s), skipping")
                else:
                    log(log_path, f"pane {pane} did not become ready before timeout, skipping {tool}")

    log(log_path, f"restored {restored} of {len(sessions)} assistant session(s)")
    return 0


def clean_runtime() -> int:
    directory = state_dir()
    if not directory.exists():
        print("Nothing to clean")
        return 0
    removed = 0
    for path in directory.glob("*.json"):
        data = read_json_file(path)
        if not isinstance(data, dict):
            path.unlink(missing_ok=True)
            removed += 1
            continue
        tool = data.get("tool")
        pid_value = data.get("ppid") if tool == "claude" else data.get("pid") if tool == "opencode" else None
        try:
            pid = int(pid_value)
        except (TypeError, ValueError):
            path.unlink(missing_ok=True)
            removed += 1
            continue
        if pid <= 1:
            path.unlink(missing_ok=True)
            removed += 1
            continue
        try:
            os.kill(pid, 0)
        except OSError:
            path.unlink(missing_ok=True)
            removed += 1
    print(f"Cleaned {removed} stale state file(s)")
    return 0


def status_runtime() -> int:
    print("=== tmux-assistant-resurrect status ===")
    print("")

    def marker(ok: bool) -> str:
        return "[ok]" if ok else "[--]"

    print(f"{marker((Path.home() / '.tmux' / 'plugins' / 'tpm').exists())} TPM installed")
    print(f"{marker((Path.home() / '.tmux' / 'plugins' / 'tmux-resurrect').exists())} tmux-resurrect installed")
    print(f"{marker((Path.home() / '.tmux' / 'plugins' / 'tmux-continuum').exists())} tmux-continuum installed")

    tmux_conf = Path.home() / ".tmux.conf"
    configured = False
    if tmux_conf.exists():
        conf_text = tmux_conf.read_text(encoding="utf-8", errors="ignore")
        configured = "begin tmux-assistant-resurrect" in conf_text or "resurrect-assistants.conf" in conf_text
    print(f"{marker(configured)} tmux.conf configured")

    settings_path = Path.home() / ".claude" / "settings.json"
    settings = read_json_file(settings_path)
    start_installed = claude_hook_present(settings, "claude-session-track")
    end_installed = claude_hook_present(settings, "claude-session-cleanup")
    print(f"{marker(start_installed)} Claude SessionStart hook installed")
    print(f"{marker(end_installed)} Claude SessionEnd hook installed")

    plugin_file = Path.home() / ".config" / "opencode" / "plugins" / "session-tracker.js"
    print(f"{marker(plugin_file.is_symlink())} OpenCode session-tracker plugin linked")
    print("")

    directory = state_dir()
    if directory.exists():
        files = sorted(directory.glob("*.json"))
        print(f"State directory: {directory} ({len(files)} active tracking file(s))")
        if files:
            print("")
            for path in files:
                data = read_json_file(path) or {}
                tool = data.get("tool", "?")
                session_id = data.get("session_id", "?")
                timestamp = data.get("timestamp", "?")
                print(f"  {tool}: {session_id} (tracked at {timestamp})")
    else:
        print(f"State directory: {directory} (not created yet)")

    print("")
    saved_path = output_file()
    if saved_path.exists():
        data = read_json_file(saved_path) or {}
        sessions = data.get("sessions") or []
        timestamp = data.get("timestamp", "?")
        print(f"Last save: {timestamp} ({len(sessions)} session(s))")
        for entry in sessions:
            if isinstance(entry, dict):
                print(f"  {entry.get('tool')} in {entry.get('pane')}: {entry.get('session_id')}")
    else:
        print("No saved assistant sessions yet")
    return 0


def claude_hook_present(settings: Any, needle: str) -> bool:
    if not isinstance(settings, dict):
        return False
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    for phase in ("SessionStart", "SessionEnd"):
        for group in hooks.get(phase, []) or []:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []) or []:
                if isinstance(hook, dict) and needle in str(hook.get("command") or ""):
                    return True
    return False


def ensure_claude_hooks(repo_dir: Path) -> bool:
    settings_path = Path.home() / ".claude" / "settings.json"
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings = read_json_object_for_update(settings_path, "Claude settings.json")
    if settings is None:
        return False

    track_cmd = f"bash '{repo_dir}/hooks/claude-session-track.sh'"
    cleanup_cmd = f"bash '{repo_dir}/hooks/claude-session-cleanup.sh'"

    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        settings["hooks"] = hooks

    start_changed = ensure_claude_hook_group(hooks, "SessionStart", "claude-session-track", track_cmd)
    end_changed = ensure_claude_hook_group(hooks, "SessionEnd", "claude-session-cleanup", cleanup_cmd)

    settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    if start_changed:
        print(f"Claude SessionStart hook installed in {settings_path}")
    else:
        print("Claude SessionStart hook already configured")
    if end_changed:
        print(f"Claude SessionEnd hook installed in {settings_path}")
    else:
        print("Claude SessionEnd hook already configured")
    return True


def ensure_claude_hook_group(hooks: dict[str, Any], phase: str, needle: str, command: str) -> bool:
    groups = hooks.setdefault(phase, [])
    if not isinstance(groups, list):
        groups = []
        hooks[phase] = groups
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []) or []:
            if isinstance(hook, dict) and needle in str(hook.get("command") or ""):
                return False
    groups.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
    return True


def remove_claude_hooks() -> None:
    settings_path = Path.home() / ".claude" / "settings.json"
    if not settings_path.exists():
        print("No Claude settings to modify")
        return
    settings = read_json_object_for_update(settings_path, "Claude settings.json")
    if settings is None:
        return
    if not settings:
        print("No Claude settings to modify")
        return
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        print("Claude hooks removed")
        return
    for phase, needle in (("SessionStart", "claude-session-track"), ("SessionEnd", "claude-session-cleanup")):
        groups = hooks.get(phase)
        if not isinstance(groups, list):
            continue
        new_groups = []
        for group in groups:
            if not isinstance(group, dict):
                new_groups.append(group)
                continue
            group_hooks = []
            for hook in group.get("hooks", []) or []:
                if isinstance(hook, dict) and needle in str(hook.get("command") or ""):
                    continue
                group_hooks.append(hook)
            if group_hooks:
                updated = dict(group)
                updated["hooks"] = group_hooks
                new_groups.append(updated)
        if new_groups:
            hooks[phase] = new_groups
        else:
            hooks.pop(phase, None)
    if not hooks:
        settings.pop("hooks", None)
    settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    print("Claude hooks removed")


def install_opencode_plugin(repo_dir: Path) -> None:
    plugin_dir = Path.home() / ".config" / "opencode" / "plugins"
    plugin_dir.mkdir(parents=True, exist_ok=True)
    plugin_file = plugin_dir / "session-tracker.js"
    source_file = repo_dir / "hooks" / "opencode-session-track.js"
    if plugin_file.is_symlink() and os.readlink(plugin_file) == str(source_file):
        print("OpenCode session-tracker plugin already linked")
        return
    if plugin_file.exists() or plugin_file.is_symlink():
        plugin_file.unlink()
    plugin_file.symlink_to(source_file)
    print(f"OpenCode session-tracker plugin linked at {plugin_file}")


def uninstall_opencode_plugin() -> None:
    plugin_file = Path.home() / ".config" / "opencode" / "plugins" / "session-tracker.js"
    if plugin_file.exists() or plugin_file.is_symlink():
        plugin_file.unlink(missing_ok=True)
        print("OpenCode session-tracker plugin removed")
    else:
        print("OpenCode plugin not found, nothing to remove")


def claude_hook_start_runtime(claude_pid: int) -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    if not isinstance(payload, dict):
        return 0

    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id:
        return 0

    state = dict(payload)
    state["tool"] = "claude"
    state["ppid"] = claude_pid
    state["timestamp"] = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    state["env"] = build_captured_env()

    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_file = directory / f"claude-{claude_pid}.json"
    try:
        state_file.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    except OSError:
        print(
            f"tmux-assistant-resurrect: failed to write state file {state_file} (permission denied?)",
            file=sys.stderr,
        )
    return 0


def claude_hook_end_runtime(claude_pid: int) -> int:
    state_dir().joinpath(f"claude-{claude_pid}.json").unlink(missing_ok=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("save")
    subparsers.add_parser("restore")
    subparsers.add_parser("clean")
    subparsers.add_parser("status")
    subparsers.add_parser("install-hooks")
    subparsers.add_parser("uninstall-hooks")
    subparsers.add_parser("install-claude-hook")
    subparsers.add_parser("uninstall-claude-hook")
    subparsers.add_parser("install-opencode-plugin")
    subparsers.add_parser("uninstall-opencode-plugin")

    claude_hook_start = subparsers.add_parser("claude-hook-start")
    claude_hook_start.add_argument("claude_pid", type=int)

    claude_hook_end = subparsers.add_parser("claude-hook-end")
    claude_hook_end.add_argument("claude_pid", type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    repo_dir = Path(__file__).resolve().parent.parent

    if args.command == "save":
        return save_runtime()
    if args.command == "restore":
        return restore_runtime()
    if args.command == "clean":
        return clean_runtime()
    if args.command == "status":
        return status_runtime()
    if args.command == "install-hooks":
        claude_ok = ensure_claude_hooks(repo_dir)
        install_opencode_plugin(repo_dir)
        if claude_ok:
            print("All assistant hooks installed")
            return 0
        return 1
    if args.command == "uninstall-hooks":
        remove_claude_hooks()
        uninstall_opencode_plugin()
        return 0
    if args.command == "install-claude-hook":
        return 0 if ensure_claude_hooks(repo_dir) else 1
    if args.command == "uninstall-claude-hook":
        remove_claude_hooks()
        return 0
    if args.command == "install-opencode-plugin":
        install_opencode_plugin(repo_dir)
        return 0
    if args.command == "uninstall-opencode-plugin":
        uninstall_opencode_plugin()
        return 0
    if args.command == "claude-hook-start":
        return claude_hook_start_runtime(args.claude_pid)
    if args.command == "claude-hook-end":
        return claude_hook_end_runtime(args.claude_pid)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
