# tmux-assistant-resurrect

Persist and restore AI coding assistant sessions across tmux restarts and reboots.

This fork supports:

- [Claude Code](https://github.com/anthropics/claude-code)
- [OpenCode](https://github.com/opencode-ai/opencode)
- [Codex CLI](https://github.com/openai/codex)

It integrates with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
to save assistant session IDs, working directories, CLI flags, and selected
environment variables, then resume those sessions after restore. If you want
periodic autosave and restore-on-start, you can also add
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum).

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
set -g @plugin 'theOxifier/tmux-assistant-resurrect'

# Optional: capture extra env vars and replay them on restore
# set -g @assistant-resurrect-capture-env 'VIRTUAL_ENV NODE_ENV'

# Optional: add tmux-continuum if you want periodic autosave and restore-on-start
# set -g @plugin 'tmux-plugins/tmux-continuum'
# set -g @continuum-save-interval '5'
# set -g @continuum-restore 'on'

# Optional: disable the safe TPM update binding override
# set -g @assistant-resurrect-safe-tpm-update 'off'

run '~/.tmux/plugins/tpm/tpm'
```

Then inside tmux press `prefix + I`.

Then install the assistant-native integrations once:

```bash
python3 ~/.tmux/plugins/tmux-assistant-resurrect/scripts/assistant_admin.py install-hooks
```

That installs:

- Claude hooks into `~/.claude/settings.json`
- the OpenCode session tracker into `~/.config/opencode/plugins/`

## Use

Once installed, the normal tmux-resurrect flow is enough:

- `prefix + Ctrl-s` saves tmux state and assistant sessions
- `prefix + Ctrl-r` restores tmux state and resumes assistants

If you also use tmux-continuum, it can trigger the same hooks for periodic
save and restore-on-start.

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

### Safe TPM Update Binding

TPM's stock `prefix + U` update binding sends `C-c` into the active pane before
running the update prompt. That can exit Codex, Claude, or OpenCode if the
active pane is an assistant TUI. This plugin replaces that binding with the
same TPM update prompt without the injected `C-c`.

To keep TPM's stock behavior instead:

```tmux
set -g @assistant-resurrect-safe-tpm-update 'off'
```

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
| Codex | `~/.codex/session-tags.jsonl` | explicit UUID, named-thread metadata, time-correlated rollout metadata, `resume` args |

For deeper implementation details, see
[docs/design-principles.md](docs/design-principles.md).

## Troubleshooting

| Problem | What to check |
|---------|---------------|
| No sessions saved | Run `ps -eo pid=,ppid=,args= | grep -E 'claude|opencode|codex'` |
| Claude session missing | Check `~/.claude/settings.json` for `claude-session-track` |
| OpenCode session missing | Check `~/.config/opencode/plugins/session-tracker.js` |
| Claude or OpenCode was never tracked | Run `python3 ~/.tmux/plugins/tmux-assistant-resurrect/scripts/assistant_admin.py install-hooks` once |
| Restore says session not found | The assistant session itself may have expired; start a new one and save again |
| OpenCode session missing after save | Make sure the OpenCode plugin is installed; the live save path will not guess from cwd alone |
| Bare Codex session restored an old thread | Upgrade to a build that only trusts PID, named-thread, explicit `resume`, or rollout metadata close to the live process start |
| Assistants launch twice | Make sure assistants are not listed in `@resurrect-processes` |
| `prefix + U` exits an assistant | Make sure `@assistant-resurrect-safe-tpm-update` is not set to `off`, then reload tmux |

## Uninstall

Remove the plugin line from `~/.tmux.conf`:

```tmux
set -g @plugin 'theOxifier/tmux-assistant-resurrect'
```

Then press `prefix + Alt-u` to let TPM remove plugins no longer listed in your
tmux config.

If you also want to remove Claude/OpenCode integrations:

```bash
python3 ~/.tmux/plugins/tmux-assistant-resurrect/scripts/assistant_admin.py uninstall-hooks
```

## For Developers

The `justfile` is for development, not normal TPM usage.

Useful commands:

```bash
just install-hooks
just uninstall-hooks
just status
just save
just restore
just clean
just test
just test-extended
```

`just test` is the fast unit-test gate. `just test-extended` runs the full
Docker-backed integration suite. The integration scripts run tmux on isolated
sockets so they do not target a live tmux server.

## Limitations

- Running tool state is not preserved; conversation state is restored, but
  in-flight operations are lost.
- Claude CLI flags depend on `ps` visibility. If a future version hides args,
  restore falls back to a bare resume command.
- OpenCode save is accuracy-first: if the plugin state file is missing and
  there is no explicit `-s` / `--session` flag, the session is skipped instead
  of guessed from cwd metadata.
- Claude and OpenCode require their one-time native hook/plugin installation.
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
