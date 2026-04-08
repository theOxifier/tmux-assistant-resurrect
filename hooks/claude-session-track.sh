#!/usr/bin/env bash
# Claude Code SessionStart hook — writes session context to a trackable file.
# Receives JSON on stdin with session_id, cwd, model, source, permission_mode,
# transcript_path, hook_event_name, and optionally agent_type.
#
# The full stdin JSON is merged with our added fields (tool, ppid, timestamp,
# env) so any new fields Claude adds in future versions are captured
# automatically without code changes.
#
# Install: add to ~/.claude/settings.json under hooks.SessionStart

set -euo pipefail

# Source shared find_claude_pid() helper
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-claude-pid.sh
source "$HOOK_DIR/lib-claude-pid.sh"

PYTHON_BIN="${PYTHON_BIN:-python3}"
RUNTIME="$HOOK_DIR/../scripts/assistant_resurrect.py"

CLAUDE_PID="$(find_claude_pid)"
CAPTURE_ENV=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)

export TMUX_PANE SHELL
for var in $CAPTURE_ENV; do
	export "$var"
done

exec "$PYTHON_BIN" "$RUNTIME" claude-hook-start "$CLAUDE_PID"
