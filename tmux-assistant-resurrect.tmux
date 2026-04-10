#!/usr/bin/env bash
# TPM plugin entry point for tmux-assistant-resurrect.
# TPM executes this script when the plugin is installed or tmux starts.
#
# This only wires tmux save/restore hooks for the runtime.
# It does not install assistant-native hooks/plugins or set tmux-continuum
# policy defaults on the user's behalf.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_BIN="${TMUX_ASSISTANT_TMUX_BIN:-tmux}"
TMUX_SOCKET="${TMUX_ASSISTANT_TMUX_SOCKET:-}"
TMUX_CONFIG="${TMUX_ASSISTANT_TMUX_CONFIG:-}"

tmux_cmd=("$TMUX_BIN")
if [ -n "$TMUX_SOCKET" ]; then
  tmux_cmd+=(-L "$TMUX_SOCKET")
fi
if [ -n "$TMUX_CONFIG" ]; then
  tmux_cmd+=(-f "$TMUX_CONFIG")
fi

# Limitation: hook commands use single-quoted paths (bash '${CURRENT_DIR}/...').
# If the plugin install path contains a single quote, the quoting breaks.
# This is unlikely in practice (TPM installs to ~/.tmux/plugins/).

# --- tmux settings ---

# Do NOT add assistants to @resurrect-processes — that would launch bare
# binaries (without session IDs) and the post-restore hook would then type
# resume commands into the running TUI. The hook handles all resuming.
"${tmux_cmd[@]}" set-option -g @resurrect-hook-post-save-all "python3 '${CURRENT_DIR}/scripts/assistant_resurrect.py' save"
"${tmux_cmd[@]}" set-option -g @resurrect-hook-post-restore-all "python3 '${CURRENT_DIR}/scripts/assistant_resurrect.py' restore"

# TPM's stock prefix+U binding sends C-c into the active pane before running the
# update prompt. That is destructive in assistant TUIs, so replace the binding
# with an equivalent update prompt that never injects keys into the pane.
safe_tpm_update="$("${tmux_cmd[@]}" show-option -gqv @assistant-resurrect-safe-tpm-update 2>/dev/null || true)"
if [ "$safe_tpm_update" != "off" ] && [ "$safe_tpm_update" != "0" ]; then
  update_key="$("${tmux_cmd[@]}" show-option -gqv @tpm-update 2>/dev/null || true)"
  update_key="${update_key:-U}"
  "${tmux_cmd[@]}" bind-key "$update_key" command-prompt -p 'plugin update:' "run-shell 'bash \"${CURRENT_DIR}/scripts/tpm-safe-update.sh\" %1'"
fi
