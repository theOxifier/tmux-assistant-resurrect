# tmux-assistant-resurrect — session persistence for AI coding assistants
# Preserves Claude Code, OpenCode, and Codex CLI sessions across tmux restarts.

set shell := ["bash", "-euo", "pipefail", "-c"]

repo_dir := justfile_directory()
# State directory: uses TMUX_ASSISTANT_RESURRECT_DIR if set, else XDG_RUNTIME_DIR/TMPDIR/tmp.
# The just env() function can't do nested expansion, so recipes compute the
# default via shell. This variable is only used when the env var IS set.
state_dir_override := env("TMUX_ASSISTANT_RESURRECT_DIR", "")
_state_dir_expr := 'STATE_DIR="${TMUX_ASSISTANT_RESURRECT_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect}"'

# Show available recipes
default:
    @just --list

# Install everything: TPM, hooks, and tmux config
install: install-tpm install-hooks configure-tmux
    @echo ""
    @echo "Installation complete!"
    @echo ""
    @echo "Next steps:"
    @echo "  1. Reload tmux config:  tmux source-file ~/.tmux.conf"
    @echo "  2. Install TPM plugins: press prefix + I (capital I) inside tmux"
    @echo "  3. Verify:              just status"

# Install TPM (Tmux Plugin Manager)
install-tpm:
    @if [ -d ~/.tmux/plugins/tpm ]; then \
        echo "TPM already installed"; \
    else \
        echo "Installing TPM..."; \
        git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm; \
        echo "TPM installed at ~/.tmux/plugins/tpm"; \
    fi

# Install TPM plugins (resurrect + continuum)
install-plugins:
    @if [ -x ~/.tmux/plugins/tpm/bin/install_plugins ]; then \
        ~/.tmux/plugins/tpm/bin/install_plugins; \
    else \
        echo "TPM not found — run 'just install-tpm' first, then press prefix+I in tmux"; \
    fi

# Install assistant hooks (Claude hook + OpenCode plugin)
install-hooks:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-hooks

# Install Claude Code hooks (SessionStart + SessionEnd) into ~/.claude/settings.json
install-claude-hook:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-claude-hook

# Install OpenCode session-tracker plugin
install-opencode-plugin:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-opencode-plugin

# Add resurrect config to ~/.tmux.conf
configure-tmux:
    #!/usr/bin/env bash
    set -euo pipefail
    conf="$HOME/.tmux.conf"
    tpm_line="run '~/.tmux/plugins/tpm/tpm'"
    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    touch "$conf"

    # Remove any existing marker block (handles re-runs and repo_dir changes).
    if grep -qF "$begin_marker" "$conf"; then
        tmp=$(mktemp)
        sed "/$begin_marker/,/$end_marker/d" "$conf" > "$tmp"
        mv "$tmp" "$conf"
    fi

    # Remove legacy source-file line from pre-marker installs
    if grep -qF "resurrect-assistants.conf" "$conf"; then
        tmp=$(mktemp)
        grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    # Capture and remove the TPM init line so we can re-add it at the very
    # end. TPM's run line must be the last line in tmux.conf — anything
    # after it won't be processed. We preserve the user's original line
    # verbatim (custom path, if-shell wrapper, etc.) instead of replacing
    # it with a hardcoded default.
    # Filter out comment lines when capturing — a commented example like
    # "# run '/old/tpm/tpm'" must not be mistaken for the real init line.
    existing_tpm_line=""
    if grep -F "tpm/tpm" "$conf" | grep -qv '^[[:space:]]*#' 2>/dev/null; then
        existing_tpm_line=$(grep -F "tpm/tpm" "$conf" | grep -v '^[[:space:]]*#' | tail -1)
        tmp=$(mktemp)
        # Only remove non-comment lines containing tpm/tpm (preserve comments)
        grep -v '^[^#]*tpm/tpm' "$conf" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    # Write the new block with begin/end markers. The markers allow
    # unconfigure-tmux to remove exactly what we added (including plugin
    # lines) without affecting user settings outside the block.
    # NOTE: The sed patterns in this recipe work because the marker
    # strings contain no sed-special characters (no /, *, ., etc.).
    # If the markers ever change, the sed commands may need escaping.
    {
        echo ""
        echo "$begin_marker"
        echo "set -g @plugin 'tmux-plugins/tpm'"
        echo "set -g @plugin 'tmux-plugins/tmux-resurrect'"
        echo "set -g @plugin 'tmux-plugins/tmux-continuum'"
        echo "# Optional: restore terminal text in non-assistant panes after tmux restart."
        echo "# Assistant pane contents are stripped automatically by the save hook."
        echo "# set -g @resurrect-capture-pane-contents 'on'"
        echo "set -g @resurrect-hook-post-save-all \"python3 '{{repo_dir}}/scripts/assistant_resurrect.py' save\""
        echo "set -g @resurrect-hook-post-restore-all \"python3 '{{repo_dir}}/scripts/assistant_resurrect.py' restore\""
        echo "set -g @continuum-save-interval '5'"
        echo "set -g @continuum-restore 'on'"
        echo "$end_marker"
    } >> "$conf"
    echo "Added tmux-assistant-resurrect settings to $conf"

    # Re-add TPM init as the very last line (required by TPM).
    # Use the user's original line if we captured one, otherwise the default.
    if [ -n "$existing_tpm_line" ]; then
        echo "$existing_tpm_line" >> "$conf"
        echo "TPM init moved to end of $conf"
    else
        echo "$tpm_line" >> "$conf"
        echo "Added TPM init to $conf"
    fi

# Remove all installed hooks and config
uninstall: uninstall-claude-hook uninstall-opencode-plugin unconfigure-tmux
    @echo ""
    @echo "Uninstalled. You may also want to:"
    @echo "  - Remove TPM: rm -rf ~/.tmux/plugins/"
    @echo "  - Reload tmux: tmux source-file ~/.tmux.conf"

# Remove Claude Code hooks (SessionStart + SessionEnd)
uninstall-claude-hook:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" uninstall-claude-hook

# Remove OpenCode session-tracker plugin
uninstall-opencode-plugin:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" uninstall-opencode-plugin

# Remove resurrect config from ~/.tmux.conf
unconfigure-tmux:
    #!/usr/bin/env bash
    set -euo pipefail
    conf="$HOME/.tmux.conf"
    if [ ! -f "$conf" ]; then
        exit 0
    fi

    begin_marker="# --- begin tmux-assistant-resurrect ---"
    end_marker="# --- end tmux-assistant-resurrect ---"

    # Remove the marker block (current format).
    # NOTE: sed range pattern works because markers contain no sed-special
    # characters. If markers ever change, escaping may be needed.
    if grep -qF "$begin_marker" "$conf"; then
        tmp=$(mktemp)
        sed "/$begin_marker/,/$end_marker/d" "$conf" > "$tmp"
        mv "$tmp" "$conf"
    fi

    # Also remove legacy format (source-file + comment, pre-marker installs)
    if grep -qF "resurrect-assistants.conf" "$conf"; then
        tmp=$(mktemp)
        grep -v "resurrect-assistants.conf" "$conf" | grep -v "# tmux-assistant-resurrect" > "$tmp" || true
        mv "$tmp" "$conf"
    fi

    echo "Removed tmux-assistant-resurrect settings from $conf"

# Show current status: installed hooks, tracked sessions, state files
status:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" status

# Manually trigger a save of current assistant sessions
save:
    @python3 "{{repo_dir}}/scripts/assistant_resurrect.py" save

# Manually trigger a restore of saved assistant sessions
restore:
    @python3 "{{repo_dir}}/scripts/assistant_resurrect.py" restore

# Clean up stale state files (from dead processes)
clean:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" clean

# Run integration tests in Docker
test:
    docker build -t tmux-assistant-resurrect-test -f test/Dockerfile .
    docker run --rm tmux-assistant-resurrect-test

# Run save-hook benchmark matrix in Docker (writes CSV + Markdown summary)
benchmark runs='7' base_repo='':
    #!/usr/bin/env bash
    set -euo pipefail
    docker build -t tmux-assistant-resurrect-test -f "{{repo_dir}}/test/Dockerfile" "{{repo_dir}}"
    mkdir -p "{{repo_dir}}/test-results"
    cmd=(bash "{{repo_dir}}/test/bench-matrix.sh" --head-repo "{{repo_dir}}" --runs "{{runs}}" --output-csv "{{repo_dir}}/test-results/benchmark.csv" --output-md "{{repo_dir}}/test-results/benchmark.md")
    if [ -n "{{base_repo}}" ]; then
        cmd+=(--base-repo "{{base_repo}}")
    fi
    "${cmd[@]}"
    cat "{{repo_dir}}/test-results/benchmark.md"
