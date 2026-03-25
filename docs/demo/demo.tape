Output "docs/images/demo-save-restore.gif"

Set Theme "Dracula"
Set FontSize 16
Set Width 1200
Set Height 700
Set TypingSpeed 10ms
Set Padding 20

# Hidden: Docker + Claude first-run prompts
Hide
Type "docker run --rm -it -e ANTHROPIC_FOUNDRY_API_KEY -e ANTHROPIC_FOUNDRY_RESOURCE -e CLAUDE_CODE_USE_FOUNDRY -e AZURE_OPENAI_API_KEY -e AZURE_OPENAI_API_VERSION -e AZURE_OPENAI_ENDPOINT -e AZURE_RESOURCE_NAME -e OPENAI_API_VERSION tmux-resurrect-demo"
Enter
Sleep 4s

# Claude first-run: theme + security + trust
Type "tmux new-session -s setup-claude -c ~/src/my-api"
Enter
Sleep 2s
Type "claude"
Enter
Sleep 12s
Enter
Sleep 5s
Enter
Sleep 5s
Enter
Sleep 8s
Type "/exit"
Enter
Sleep 2s
Type "exit"
Enter
Sleep 1s
Type "tmux kill-server"
Enter
Sleep 1s
Type "clear"
Enter
Sleep 1s
Show

# === Visible: Claude-only flow ===

# 1. Start tmux session
Type "tmux new-session -s claude-dev -c ~/src/my-api"
Enter
Sleep 1s

# 2. Launch Claude
Type "claude"
Enter
Sleep 1s
Hide
Sleep 4s
Show

# 3. Ask Claude something
Type "which model are you?"
Enter
Sleep 1s
Hide
Sleep 8s
Show
Sleep 1s

# 4. Save sessions
Ctrl+B
Ctrl+S
Sleep 2s

# 5. Detach and kill tmux
Ctrl+B
Type "d"
Sleep 0.3s
Type "tmux kill-server"
Enter
Sleep 1s

# 6. Start fresh tmux
Type "tmux"
Enter
Sleep 0.5s

# 7. Restore
Ctrl+B
Ctrl+R
Sleep 5s

# 8. Claude is back
Sleep 2s
