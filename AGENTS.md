# Guidelines for AI Coding Agents

## Project overview

tmux-assistant-resurrect persists AI coding assistant sessions (Claude Code,
OpenCode, Codex CLI) across tmux restarts. It hooks into tmux-resurrect to save
session IDs and restore them automatically.

## Architecture

- `tmux-assistant-resurrect.tmux` -- TPM plugin entry point (wires tmux save/restore hooks only)
- `hooks/` -- Native hooks/plugins for each assistant tool (write session IDs to state files)
- `scripts/assistant_resurrect.py` -- Core Python runtime for save/restore and Claude hook handling
- `scripts/assistant_admin.py` -- Explicit assistant hook/plugin installation plus status/clean helpers
- `docs/design-principles.md` -- Detection approach, session ID extraction, process title behavior
- `justfile` -- Developer recipes (hooks, status, save/restore, tests)
- `test/` -- Python unit tests plus an opt-in Docker-based integration suite with real CLI binaries

## Design constraints

- **No wrapper scripts**: Do not create wrapper functions/aliases around `claude`,
  `opencode`, or `codex`. Use native hook/plugin systems instead.
- **Restore hook is the sole launcher**: Assistants must NOT be listed in
  `@resurrect-processes`. The post-restore hook handles all resuming with correct
  session IDs. Adding them to `@resurrect-processes` causes double-launch.
- **TPM wires tmux, assistant-native hooks are explicit**: Users install via TPM
  (`set -g @plugin 'theOxifier/tmux-assistant-resurrect'` + `prefix + I`), then
  run `assistant_admin.py install-hooks` once for Claude/OpenCode. The tmux
  entry point must not rewrite assistant config on every startup.
- **Safe TPM update binding**: TPM's stock `prefix + U` binding sends `C-c`
  into the active pane before running the update prompt. The plugin overrides
  that binding by default with `scripts/tpm-safe-update.sh` so updating TPM
  plugins from an assistant pane does not interrupt the assistant. Respect
  `@assistant-resurrect-safe-tpm-update 'off'` if users want stock TPM behavior.
- **Python owns runtime behavior**: Save/restore/session-resolution logic lives
  in `scripts/assistant_resurrect.py`. Do not reintroduce sourced-shell helper APIs.
- **Pipe delimiter in tmux format output**: tmux 3.4 converts tabs and control
  characters in `-F` output. Use `|` as delimiter (documented limitation: paths
  containing `|` will break, but `|` is extremely rare in directory names).
- **Two-guard restore**: The restore script has two independent guards before
  injecting a resume command into a pane: (1) the pane's foreground process must
  be a known shell, and (2) the pane must not already have a running assistant
  in its process tree. Both must pass. This prevents typing into TUIs or
  double-launching. After a command is injected, restore does not assume success:
  it confirms that the assistant process actually appears in the pane tree and
  retries panes whose first restore attempt was swallowed.
- **Restore shell whitelist**: Guard 1 strips a leading `-` (login shells report
  as `-bash`, `-zsh`, etc.) then checks against a hardcoded whitelist: `bash`,
  `zsh`, `fish`, `sh`, `dash`, `ksh`, `tcsh`, `csh`, `nu`. If a user's shell
  isn't in this list, restore silently skips the pane. Update the whitelist in
  `scripts/assistant_resurrect.py` if needed.

## Detection approach

Agent detection uses direct process inspection: the save script takes a single
`ps -eo pid=,ppid=,args=` snapshot and matches child processes of tmux pane
shells against known assistant binary names via `detect_tool()` in
`scripts/assistant_resurrect.py`.

Session ID extraction uses explicit tool-native mechanisms: Claude/OpenCode
state files, process args, and Codex JSONL/SQLite metadata. This is
infrastructure plumbing, not heuristic classification. Both Claude and OpenCode
overwrite their process titles, but on macOS arm64 (v2.1.44+) process args may
still be visible via `ps -eo args=`. State files and Codex metadata remain the
primary extraction methods, with process args as a last fallback.

## Key conventions

- Hooks use `set -euo pipefail`; the main runtime is Python
- State files go to `$TMUX_ASSISTANT_RESURRECT_DIR` (default: `$XDG_RUNTIME_DIR` or `$TMPDIR` + `/tmux-assistant-resurrect`)
- State files contain the full tool-provided context (merged from hook stdin /
  plugin events) plus plugin metadata (`tool`, `ppid`/`pid`, `timestamp`, `env`).
  The Claude hook merges Claude's entire SessionStart JSON; the OpenCode plugin
  captures the full Session object. The save script reads `session_id` and `env`
  from state files and `cli_args` from `ps` process args. The restore
  script uses `cli_args` to reconstruct the original CLI invocation and restores
  user-configured env vars (from `@assistant-resurrect-capture-env`) as a command
  prefix.
- The `env` object in state files captures `TMUX_PANE` and `SHELL` by default,
  plus user-configured vars via `@assistant-resurrect-capture-env` tmux option
  (space-separated list, set in tmux.conf)
- Log files go to `~/.tmux/resurrect/assistant-{save,restore}.log` (truncated to 500 lines per run)
- Process inspection uses `ps -eo pid=,ppid=` (not `pgrep -P` -- unreliable on macOS)
- Agent detection matches binary names in `detect_tool()`
- Hook matching should tolerate malformed entries that lack `.command`
- Use the Python runtime's single-quote `posix_quote()` semantics for any values
  sent to tmux panes via `send-keys` (safe for bash, zsh, fish, and other
  POSIX-ish shells)
- Hook command paths use single quotes (`bash '${CURRENT_DIR}/hooks/...'`);
  this breaks if the install path contains a single quote (unlikely with TPM)
- The sidecar JSON (`assistant-sessions.json`) entries keep only replayable
  fields: `pane`, `tool`, `session_id`, optional `cwd`, optional `cli_args`,
  and optional `env`.
- `extract_cli_args()` in `scripts/assistant_resurrect.py` strips per-tool session
  args: Claude `--resume[= ]<id>`, OpenCode `--session[= ]<id>` and `-s <id>`,
  Codex `resume <id>`. Returns normalized whitespace-trimmed string.
- The restore script only restores env vars listed in
  `@assistant-resurrect-capture-env` (not `tmux_pane` or `shell`), prepended
  as `VAR='val'` prefix to the resume command

## Upstream assumptions to verify

These assumptions were derived from reading upstream source code. If behavior
changes after an upgrade, check the relevant source to confirm.

| Assumption | Why it matters | Where to verify |
|-----------|---------------|----------------|
| **Claude sets `process.title = 'claude'`** | Node.js sets the process title, but on macOS arm64 (v2.1.44) `ps -eo args=` still shows full args (e.g., `claude --dangerously-skip-permissions`). The save script's `extract_cli_args()` relies on this. If a future version hides args, `cli_args` will be empty and restore falls back to bare `<binary> <resume_arg>`. | Run `ps -eo args=` on a running Claude process; Claude Code source: search for `process.title` |
| **Claude hook spawns intermediate `sh -c`** | `$PPID` in the hook is NOT Claude's PID; hooks walk the process tree via `find_claude_pid()` (max 5 levels) | Run `ps -eo pid=,ppid=,args=` while a hook is executing |
| **OpenCode plugins run in-process** | `process.pid` in the plugin IS the opencode binary's PID; state file is keyed by this PID | OpenCode source: search for `await import(` in the plugin loader (approx. `packages/opencode/src/plugin/index.ts` -- path may move) |
| **OpenCode Go binary overwrites process title** | `-s <id>` is often NOT visible in `ps`; the plugin state file is the reliable source for live saves, with explicit `-s` / `--session` args as a secondary path when visible | Run `ps -eo args=` on a running `opencode -s <id>` process |
| **Codex writes `~/.codex/session-tags.jsonl`** | Primary session ID source for Codex (PID → session mapping) | Run Codex and check `cat ~/.codex/session-tags.jsonl` |
| **Codex rollout metadata must be close to process start** | Cwd-only rollout history is only trustworthy when its timestamp is near the live Codex process start. Bare `codex` with no history should be skipped, not rebound to an older thread. | Compare rollout `session_meta.timestamp` with `ps -o etimes=` for the live Codex PID |
## Platform gotchas

These are hard-won lessons. Do not "simplify" them away.

| Gotcha | Details |
|--------|---------|
| **macOS `pgrep -P` is unreliable** | Silently misses child processes. Always use `ps -eo pid=,ppid=` with awk |
| **tmux 3.4 mangles delimiters** | Converts tabs to underscores, control characters to octal escapes in `-F` output. Use `|` (plain pipe) as delimiter |
| **`printf %q` breaks fish shell** | Not POSIX. Use `posix_quote()` (single-quote wrapping with `'\''` escaping) instead |
| **`\|\| continue` inside `$()` runs in the subshell** | `continue` executes but only affects the subshell, not the outer loop. Place `\|\| continue` outside the `$()` |
| **`kill -0 0` succeeds** | Checks current process group, not PID 0. Always validate PIDs are numeric and > 1 before `kill -0` |
| **npx wrapper chains** | `npx opencode` spawns npm → sh → node → opencode (4+ levels). Use `wait_for_descendant()` (full tree walk) not `wait_for_child()` (direct children only) |
| **`tmux-resurrect execute_hook()` uses `eval`** | Hook stdout goes to the active pane. Log to stderr only |
| **`process.title` vs `ps` args** | Claude Code sets `process.title = 'claude'` (Node.js), but `ps -eo args=` still shows full command line on macOS arm64 v2.1.44. This may not hold on Linux or future versions. `extract_cli_args()` degrades gracefully to empty string |
| **Claude `permission_mode` not in SessionStart hooks** | Claude Code v2.1.44 passes `undefined` for `permission_mode` in `executeSessionStartHooks`. The save script works around this by extracting `--dangerously-skip-permissions` from `ps` args via `extract_cli_args()` |

## Testing

The default test gate is Python unit tests. The full integration suite runs in
Docker with real CLI binaries (`@anthropic-ai/claude-code`, `opencode-ai`,
`@openai/codex`). No mocks, no API keys needed.

```bash
# Run the fast default test gate
just test

# Run the full Docker-backed integration suite
just test-extended

# Manual debugging on a live system
just save                          # trigger a save manually
just status                        # check installation status
just clean                         # remove stale state files
python3 -m json.tool ~/.tmux/resurrect/assistant-sessions.json
cat ~/.tmux/resurrect/assistant-save.log
cat ~/.tmux/resurrect/assistant-restore.log
```

### Test infrastructure notes

- Runtime internals are tested from Python unit tests, not by sourcing shell files.
- Keep `just test` fast; reserve `just test-extended` for broad end-to-end coverage.
- Tests use polling helpers (`wait_for_child`, `wait_for_descendant`,
  `wait_for_death`) instead of fixed `sleep` -- fast on fast machines,
  tolerant on slow CI.
- `kill_pane_children()` does tree-walk cleanup instead of inline kill patterns.
- npm packages are pinned to major versions: `claude-code@^2`, `codex@^0`,
  `opencode-ai@^1`.

## Adding a new assistant

1. Extend `detect_tool()` in `scripts/assistant_resurrect.py`
2. Add a `get_<tool>_session()` resolver in `scripts/assistant_resurrect.py`
3. Extend `build_resume_command()` in `scripts/assistant_resurrect.py`
4. Optionally add a hook/plugin in `hooks/` if the tool doesn't expose session IDs externally
5. Update install/uninstall recipes in `justfile` and `tmux-assistant-resurrect.tmux` if a new hook was added
6. Add tests in `test/run-tests.sh`

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
- `feat: add support for <tool>`
- `fix: handle <edge case>`
- `docs: update README`
