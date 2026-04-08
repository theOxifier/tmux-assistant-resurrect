FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    jq \
    bash \
    git \
    procps \
    curl \
    ca-certificates \
    nodejs \
    npm \
    bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# Install assistant CLIs via npm
RUN npm install -g "@anthropic-ai/claude-code@^2" "@openai/codex@^0" "opencode-ai@^1"

# Install starship prompt
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- --yes

# Create demo user
RUN useradd -m -s /bin/bash demo
USER demo
WORKDIR /home/demo

# Configure starship — minimal prompt
RUN mkdir -p .config && printf '\
format = "$directory$character"\n\
[directory]\n\
truncation_length = 2\n\
style = "bold cyan"\n\
[character]\n\
success_symbol = "[>](bold green)"\n\
error_symbol = "[>](bold red)"\n\
' > .config/starship.toml

# Install Claude Code native build (suppresses "switched from npm" warning)
RUN claude install
ENV PATH="/home/demo/.local/bin:${PATH}"

RUN printf 'eval "$(starship init bash)"\n' > .bashrc

# Git config
RUN git config --global user.name "demo" && \
    git config --global user.email "demo@example.com" && \
    git config --global init.defaultBranch main

# Create fake project directories
RUN mkdir -p src/my-api && \
    cd src/my-api && git init && git commit --allow-empty -m "initial commit" && \
    mkdir -p src && touch src/server.ts src/db.ts && git add . && git commit -m "add stubs"

RUN mkdir -p src/web-app && \
    cd src/web-app && git init && git commit --allow-empty -m "initial commit" && \
    mkdir -p src && touch src/app.tsx && git add . && git commit -m "add stubs"

RUN mkdir -p src/infra && \
    cd src/infra && git init && git commit --allow-empty -m "initial commit" && \
    mkdir -p terraform && touch terraform/main.tf && git add . && git commit -m "add stubs"

# Copy the plugin
COPY --chown=demo:demo . /home/demo/tmux-assistant-resurrect

ENV TERM=xterm-256color

# Install TPM + plugins
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm && \
    git clone --depth 1 https://github.com/tmux-plugins/tmux-resurrect ~/.tmux/plugins/tmux-resurrect && \
    git clone --depth 1 https://github.com/tmux-plugins/tmux-continuum ~/.tmux/plugins/tmux-continuum

# Create resurrect dir
RUN mkdir -p ~/.tmux/resurrect

# Configure tmux
RUN printf '\
set -g default-terminal "xterm-256color"\n\
set -g status-style "bg=colour235,fg=colour248"\n\
set -g @plugin '\''tmux-plugins/tpm'\''\n\
set -g @plugin '\''tmux-plugins/tmux-resurrect'\''\n\
set -g @plugin '\''tmux-plugins/tmux-continuum'\''\n\
set -g @resurrect-hook-post-save-all "python3 ~/tmux-assistant-resurrect/scripts/assistant_resurrect.py save"\n\
set -g @resurrect-hook-post-restore-all "python3 ~/tmux-assistant-resurrect/scripts/assistant_resurrect.py restore"\n\
set -g @continuum-save-interval '\''5'\''\n\
set -g @continuum-restore '\''off'\''\n\
run '\''~/.tmux/plugins/tpm/tpm'\''\n\
' > .tmux.conf

# Install Claude Code hooks into ~/.claude/settings.json
RUN mkdir -p ~/.claude && printf '{\n\
  "hooks": {\n\
    "SessionStart": [{\n\
      "matcher": "",\n\
      "hooks": [{"type": "command", "command": "bash ~/tmux-assistant-resurrect/hooks/claude-session-track.sh"}]\n\
    }],\n\
    "SessionEnd": [{\n\
      "matcher": "",\n\
      "hooks": [{"type": "command", "command": "bash ~/tmux-assistant-resurrect/hooks/claude-session-cleanup.sh"}]\n\
    }]\n\
  }\n\
}\n' > ~/.claude/settings.json

# Configure OpenCode for Azure (env vars injected at runtime)
RUN mkdir -p ~/.config/opencode && printf '{\n\
  "$schema": "https://opencode.ai/config.json",\n\
  "provider": {\n\
    "anthropic": {\n\
      "options": {\n\
        "baseURL": "https://{env:AZURE_RESOURCE_NAME}.services.ai.azure.com/anthropic/v1",\n\
        "apiKey": "{env:AZURE_OPENAI_API_KEY}",\n\
        "headers": { "api-key": "{env:AZURE_OPENAI_API_KEY}" }\n\
      },\n\
      "models": {\n\
        "claude-sonnet-4-6": { "id": "claude-sonnet-4-6" }\n\
      }\n\
    }\n\
  },\n\
  "model": "anthropic/claude-sonnet-4-6"\n\
}\n' > ~/.config/opencode/opencode.json

# Codex config is generated at runtime (needs AZURE_RESOURCE_NAME env var).
# The entrypoint script writes it before starting bash.
COPY --chown=demo:demo docs/demo/entrypoint.sh /home/demo/entrypoint.sh
RUN chmod +x /home/demo/entrypoint.sh

# Install OpenCode session-tracker plugin
RUN mkdir -p ~/.config/opencode/plugins && \
    ln -sf ~/tmux-assistant-resurrect/hooks/opencode-session-track.js ~/.config/opencode/plugins/session-tracker.js

CMD ["/home/demo/entrypoint.sh"]
