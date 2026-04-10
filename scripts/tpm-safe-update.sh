#!/usr/bin/env bash
set -euo pipefail

selection="${1:-}"
if [ -z "$selection" ]; then
  exit 0
fi

expand_path() {
  local path="$1"
  path="${path/#\~/$HOME}"
  path="${path/#\$HOME/$HOME}"
  printf '%s\n' "$path"
}

plugins_dir="$(tmux start-server\; show-environment -g TMUX_PLUGIN_MANAGER_PATH 2>/dev/null | cut -f2- -d= || true)"
if [ -z "$plugins_dir" ]; then
  plugins_dir="$HOME/.tmux/plugins"
fi
plugins_dir="$(expand_path "$plugins_dir")"

handler="${plugins_dir%/}/tpm/scripts/update_plugin_prompt_handler.sh"
if [ ! -x "$handler" ]; then
  tmux display-message "tmux-assistant-resurrect: TPM update handler not found"
  exit 1
fi

"$handler" "$selection"
