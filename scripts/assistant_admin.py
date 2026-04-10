#!/usr/bin/env python3
"""Administrative commands for tmux-assistant-resurrect."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from assistant_resurrect import output_file, read_json_file, read_json_object_for_update, state_dir


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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("clean")
    subparsers.add_parser("status")
    subparsers.add_parser("install-hooks")
    subparsers.add_parser("uninstall-hooks")
    subparsers.add_parser("install-claude-hook")
    subparsers.add_parser("uninstall-claude-hook")
    subparsers.add_parser("install-opencode-plugin")
    subparsers.add_parser("uninstall-opencode-plugin")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    repo_dir = Path(__file__).resolve().parent.parent

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
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
