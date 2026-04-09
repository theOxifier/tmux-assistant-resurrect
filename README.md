# tmux-assistant-resurrect

Persist and restore AI coding assistant sessions across tmux restarts and reboots.

This fork supports:

- [Claude Code](https://github.com/anthropics/claude-code)
- [OpenCode](https://github.com/opencode-ai/opencode)
- [Codex CLI](https://github.com/openai/codex)

It integrates with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) to save
assistant session IDs, working directories, CLI flags, and selected environment
variables, then resume those sessions after restore.

This repository is a fork of
[`timvw/tmux-assistant-resurrect`](https://github.com/timvw/tmux-assistant-resurrect).
The runtime has been substantially rewritten around Python, but the fork
remains MIT-licensed and preserves upstream attribution.

![Save, kill, and restore — assistant sessions resume automatically](docs/images/demo-save-restore.gif)

## What It Restores

- The assistant session ID
- The original pane target
- The pane working directory
- CLI flags that should survive restore
- Environment variables listed in `@assistant-resurrect-capture-env`

Codex restore is evidence-based, so both named and unnamed Codex sessions are
supported.

## Install

Prerequisites:

- `tmux`
- `python3` 3.9+
- [TPM](https://github.com/tmux-plugins/tpm)
- At least one of `claude`, `opencode`, or `codex`

If you do not already have TPM:

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

Add this to `~/.tmux.conf`:

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'theOxifier/tmux-assistant-resurrect'

# Optional: capture extra env vars and replay them on restore
# set -g @assistant-resurrect-capture-env 'VIRTUAL_ENV NODE_ENV'

# Optional: restore scrollback for non-assistant panes
# set -g @resurrect-capture-pane-contents 'on'

run '~/.tmux/plugins/tpm/tpm'
```

Then inside tmux press `prefix + I`.

The plugin will:

- enable tmux-resurrect and tmux-continuum hooks for assistant save/restore
- install Claude hooks into `~/.claude/settings.json`
- link the OpenCode session tracker into `~/.config/opencode/plugins/`

## Use

Once installed, the normal tmux-resurrect flow is enough:

- `prefix + Ctrl-s` saves tmux state and assistant sessions
- `prefix + Ctrl-r` restores tmux state and resumes assistants

By default, tmux-continuum also saves every 5 minutes and restores on tmux
server start.

## Verify

Launch one or more assistants in tmux, then save:

```bash
python3 -m json.tool ~/.tmux/resurrect/assistant-sessions.json
```

You should see entries like:

```json
{
  "pane": "my-project:0.0",
  "tool": "claude",
  "session_id": "01abc...",
  "cwd": "/home/user/src/my-project",
  "cli_args": "--dangerously-skip-permissions --model claude-opus-4-6",
  "env": {
    "tmux_pane": "%1",
    "shell": "/bin/zsh",
    "ANTHROPIC_BASE_URL": "https://proxy.internal"
  }
}
```

After a restore, check:

```bash
cat ~/.tmux/resurrect/assistant-restore.log
```

and:

```bash
cat ~/.tmux/resurrect/assistant-save.log
```

The restore log should show which panes were resumed and whether launch was
confirmed.

## Configuration

### Capture Extra Environment Variables

To replay extra env vars on restore:

```tmux
set -g @assistant-resurrect-capture-env 'VIRTUAL_ENV NODE_ENV CONDA_DEFAULT_ENV'
```

Only variables listed there are restored. Built-in tracking values like
`TMUX_PANE` and `SHELL` are captured for state, but are not replayed.

### Pane Contents

If you want tmux-resurrect to restore scrollback for normal panes:

```tmux
set -g @resurrect-capture-pane-contents 'on'
```

When this is enabled, assistant pane contents are stripped from the pane
archive so stale TUI output does not flash before the assistant resumes.

## How It Works

Save:

- one tmux pane snapshot
- one `ps` snapshot
- assistant detection by binary name
- session ID resolution using tool-native state
- write `~/.tmux/resurrect/assistant-sessions.json`

Restore:

- wait for a target pane to be ready
- `cd` back to the saved working directory
- replay env vars and CLI flags
- retry panes that swallow the first restore command
- only count success after the assistant process stays up through a short
  confirmation window

Session ID sources:

| Tool | Primary source | Fallbacks |
|------|----------------|-----------|
| Claude | SessionStart hook state file | `--resume` in process args |
| OpenCode | Plugin state file | `-s` / `--session` args |
| Codex | `~/.codex/session-tags.jsonl` | explicit UUID, thread metadata, rollout metadata, SQLite, `resume` args |

For deeper implementation details, see
[docs/design-principles.md](docs/design-principles.md).

## Troubleshooting

| Problem | What to check |
|---------|---------------|
| No sessions saved | Run `ps -eo pid=,ppid=,args= | grep -E 'claude|opencode|codex'` |
| Claude session missing | Check `~/.claude/settings.json` for `claude-session-track` |
| OpenCode session missing | Check `~/.config/opencode/plugins/session-tracker.js` |
| Restore says session not found | The assistant session itself may have expired; start a new one and save again |
| OpenCode session missing after save | Make sure the OpenCode plugin is installed; the live save path will not guess from cwd alone |
| Assistants launch twice | Make sure assistants are not listed in `@resurrect-processes` |

## Uninstall

Remove the plugin line from `~/.tmux.conf`:

```tmux
set -g @plugin 'theOxifier/tmux-assistant-resurrect'
```

Then press `prefix + Alt-u` to let TPM remove plugins no longer listed in your
tmux config.

## Performance

This fork's biggest measured gain is on the save path. On April 9, 2026, a
local isolated benchmark compared the current Python runtime against upstream
commit `6be6d82` using mock Claude processes, 5 timed runs per scenario, and an
isolated tmux socket:

| Scenario | Upstream avg | Fork avg | Speedup | Reduction |
|----------|-------------:|---------:|--------:|----------:|
| 116 panes / 40 assistants | 0.169s | 0.139s | 1.22x | 17.8% |
| 124 panes / 60 assistants | 0.164s | 0.130s | 1.26x | 20.7% |
| 124 panes / 100 assistants | 0.154s | 0.132s | 1.17x | 14.3% |

Across those scenarios, the save-hook average improved from `0.162s` to
`0.134s`, about `17.7%` faster overall.

Restore improvements in this fork are more about correctness than raw wall
clock time: no blind sleeps, launch retries, pane safety guards, and durable
launch confirmation.

## For Developers

The `justfile` is for development, not normal TPM usage.

Useful commands:

```bash
just status
just save
just restore
just clean
just test
just benchmark
```

The test and benchmark scripts run tmux on isolated sockets so they do not
target a live tmux server.

## Limitations

- Running tool state is not preserved; conversation state is restored, but
  in-flight operations are lost.
- Claude CLI flags depend on `ps` visibility. If a future version hides args,
  restore falls back to a bare resume command.
- OpenCode save is accuracy-first: if the plugin state file is missing and
  there is no explicit `-s` / `--session` flag, the session is skipped instead
  of guessed from cwd metadata.
- Pane targeting assumes tmux-resurrect restores the same pane layout. If you
  manually change the layout between save and restore, the mapping can be wrong.

## License

This fork remains under the MIT License.

- Original project: `timvw/tmux-assistant-resurrect`
- Upstream copyright notice and permission notice are preserved in `LICENSE`
- Fork modifications are additionally marked `Copyright (c) 2026 Sean Hunter Rea`
- New modifications in this fork are distributed under the same MIT terms

That means you can use, modify, and redistribute this fork, but the MIT notice
must stay with copies or substantial portions of the software.
