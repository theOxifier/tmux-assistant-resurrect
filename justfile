# tmux-assistant-resurrect — session persistence for AI coding assistants
# Preserves Claude Code, OpenCode, and Codex CLI sessions across tmux restarts.

set shell := ["bash", "-euo", "pipefail", "-c"]

repo_dir := justfile_directory()

# Show available recipes
default:
    @just --list

# Install assistant hooks (Claude hook + OpenCode plugin)
install-hooks:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-hooks

# Install Claude Code hooks (SessionStart + SessionEnd) into ~/.claude/settings.json
install-claude-hook:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-claude-hook

# Install OpenCode session-tracker plugin
install-opencode-plugin:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" install-opencode-plugin

# Remove assistant hooks (Claude hook + OpenCode plugin)
uninstall-hooks:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" uninstall-hooks

# Remove Claude Code hooks (SessionStart + SessionEnd)
uninstall-claude-hook:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" uninstall-claude-hook

# Remove OpenCode session-tracker plugin
uninstall-opencode-plugin:
    @python3 "{{repo_dir}}/scripts/assistant_admin.py" uninstall-opencode-plugin

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

# Run the fast core test gate
test:
    python3 -m unittest test.test_runtime

# Run the full Docker-backed integration suite
test-extended:
    docker build -t tmux-assistant-resurrect-test -f test/Dockerfile .
    docker run --rm tmux-assistant-resurrect-test
