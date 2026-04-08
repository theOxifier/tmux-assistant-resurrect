#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This sets up:
# 1. tmux-resurrect + tmux-continuum settings
# 2. Post-save/restore hooks for assistant session tracking
# 3. Claude Code hooks in ~/.claude/settings.json
# 4. OpenCode session-tracker plugin in ~/.config/opencode/plugins/

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Limitation: hook commands use single-quoted paths (bash '${CURRENT_DIR}/...').
# If the plugin install path contains a single quote, the quoting breaks.
# This is unlikely in practice (TPM installs to ~/.tmux/plugins/).

# --- tmux settings ---

# Do NOT set @resurrect-capture-pane-contents here — that is the user's choice.
# If it is enabled, the post-save hook strips captured content for assistant panes
# inside the Python runtime so restore
# won't briefly flash stale TUI output before the assistant is resumed.
#
# Do NOT add assistants to @resurrect-processes — that would launch bare
# binaries (without session IDs) and the post-restore hook would then type
# resume commands into the running TUI. The hook handles all resuming.
tmux set-option -g @resurrect-hook-post-save-all "python3 '${CURRENT_DIR}/scripts/assistant_resurrect.py' save"
tmux set-option -g @resurrect-hook-post-restore-all "python3 '${CURRENT_DIR}/scripts/assistant_resurrect.py' restore"
tmux set-option -g @continuum-save-interval '5'
tmux set-option -g @continuum-restore 'on'

# Install assistant-native hooks/plugins through the admin runtime.
python3 "${CURRENT_DIR}/scripts/assistant_admin.py" install-hooks >/dev/null 2>&1 || true
