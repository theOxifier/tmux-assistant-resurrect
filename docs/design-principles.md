# Design Principles

## Direct process detection

Agent detection uses direct process inspection rather than LLM-based
classification or screen content analysis. The Python save runtime:

1. Takes a single `ps -eo pid=,ppid=,args=` snapshot (efficient, no per-pane calls)
2. For each tmux pane, finds direct child processes of the pane's shell
3. Matches binary names in `detect_tool()` (`claude`, `opencode`, `codex`)
4. Excludes known false positives (e.g., `opencode run ...` LSP subprocesses)

This is simple, fast, and deterministic. No API calls, no LLM costs, no
latency per pane.

## What the runtime does

- Capture pane metadata from tmux (PIDs, working directories)
- Detect assistants by matching child process binary names
- Read session ID state files written by tool-native hooks/plugins
- Parse process arguments for session identifiers
- Query assistant-native metadata stores (JSONL, SQLite)
- Format and write JSON output
- Send commands to tmux panes via `tmux send-keys`
- Poll panes for readiness during restore instead of using fixed sleeps
- Confirm assistant launch after `send-keys` and retry panes that did not actually start

The TPM entrypoint only wires tmux save/restore hooks. Assistant-native
integrations are explicit one-time installs through
`scripts/assistant_admin.py install-hooks`, so tmux startup does not rewrite
`~/.claude/settings.json` or OpenCode plugin state on the user's behalf.
It also replaces TPM's stock `prefix + U` binding with a safe update prompt
because TPM normally sends `C-c` into the active pane before updating plugins.

## Session ID extraction

Session IDs are extracted through tool-native mechanisms -- infrastructure
plumbing, not interpretation. Each tool has a primary method and a fallback
to address the chicken-and-egg problem (session IDs may be in process args
before hooks/plugins have fired):

- **Claude Code**: `SessionStart` hook state file keyed by Claude's PID
  (primary); `~/.claude/sessions/<pid>.json` only when its `sessionId` also
  exists as a durable project transcript under `~/.claude/projects`
  (secondary); same-pane state file fallback via captured `TMUX_PANE` when the
  hook wrote a valid state file but the Claude PID changed inside that pane;
  `--resume <id>` in process args (last fallback -- note: Claude overwrites its
  process title, so this only works if args are still visible)
- **OpenCode**: plugin state file keyed by the OpenCode PID (primary for live
  saves); same-pane state file fallback via captured `TMUX_PANE` when the
  plugin state is valid but the visible PID changed inside the pane; `-s` /
  `--session` in process args (fallback when the state file is not available).
  The live save path intentionally does not trust cwd-based DB lookups, because
  accuracy matters more than recovering an ambiguous session.
- **Codex CLI**: PID lookup in `~/.codex/session-tags.jsonl` (primary when
  available); explicit UUID / named-thread / rollout / SQLite evidence
  (ordered fallback chain); `resume <id>` in process args (last resort)

## Adding a new assistant

To add support for a new tool:

1. Extend `detect_tool()` in `scripts/assistant_resurrect.py`
2. Add a `get_<tool>_session()` resolver for session ID extraction
3. Extend `build_resume_command()` for the tool's restore invocation
4. Optionally add a hook/plugin if the tool doesn't expose session IDs externally

## Process title behavior

- **Claude Code** is a Node.js script that overwrites its process title via
  `process.title = 'claude'`. This means `--resume <id>` is NOT visible in
  `ps` output -- the state file from the `SessionStart` hook is the only
  reliable source of session IDs for Claude.
- **Codex CLI** runs via Node.js and preserves its full command line in `ps`,
  so `codex resume <id>` is always visible.
- **OpenCode** is a native Go binary (distributed via npm as `opencode-ai`
  or installed via `opencode upgrade`). Like Claude, the Go binary overwrites
  its process title, so `-s <id>` is NOT visible in `ps`. The plugin state
  file is the reliable source of live session IDs; explicit `-s` / `--session`
  args are still usable when visible.

## macOS considerations

- `pgrep -P` is unreliable on macOS (silently misses children). Always use
  `ps -eo pid=,ppid=` with awk filtering instead.
- tmux 3.4 converts tab characters to underscores in `-F` format output. The
  save runtime uses pipe `|` as the delimiter instead.
