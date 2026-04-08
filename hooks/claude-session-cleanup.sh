#!/usr/bin/env bash
# Claude Code SessionEnd hook — removes the session tracking state file.
# Receives JSON on stdin with session_id, cwd, etc.
#
# Install: add to ~/.claude/settings.json under hooks.SessionEnd

set -euo pipefail

# Source shared find_claude_pid() helper
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-claude-pid.sh
source "$HOOK_DIR/lib-claude-pid.sh"

PYTHON_BIN="${PYTHON_BIN:-python3}"
RUNTIME="$HOOK_DIR/../scripts/assistant_resurrect.py"

CLAUDE_PID=$(find_claude_pid)
exec "$PYTHON_BIN" "$RUNTIME" claude-hook-end "$CLAUDE_PID"
