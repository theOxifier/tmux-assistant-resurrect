#!/usr/bin/env bash
# Integration tests for tmux-assistant-resurrect.
# Runs inside Docker with real assistant CLI binaries.
set -euo pipefail

REPO_DIR="$HOME/tmux-assistant-resurrect"
JUNIT_FILE="${JUNIT_FILE:-/tmp/test-results/junit.xml}"
PASS=0
FAIL=0
ERRORS=""
TMUX_SOCKET="assistant-resurrect-test-$$"
export TMUX_ASSISTANT_TMUX_SOCKET="$TMUX_SOCKET"
export TMUX_ASSISTANT_TMUX_CONFIG="/dev/null"
TMUX_REAL_BIN="$(command -v tmux)"

tmux() {
	env -u TMUX "$TMUX_REAL_BIN" -L "$TMUX_SOCKET" -f /dev/null "$@"
}

cleanup_tmux() {
	tmux kill-server >/dev/null 2>&1 || true
}
trap cleanup_tmux EXIT

# Pin state directory to a known path for tests (overrides the per-user default)
export TMUX_ASSISTANT_RESURRECT_DIR="/tmp/tmux-assistant-resurrect-test"
TEST_STATE_DIR="$TMUX_ASSISTANT_RESURRECT_DIR"

# --- JUnit XML tracking ---

CURRENT_SUITE=""
JUNIT_CASES=""

# XML-escape special characters in text
xml_escape() {
	printf '%s' "$1" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g; s/'/\&apos;/g"
}

suite() {
	CURRENT_SUITE="$1"
}

junit_pass() {
	local name
	name=$(xml_escape "$1")
	local suite
	suite=$(xml_escape "$CURRENT_SUITE")
	JUNIT_CASES="${JUNIT_CASES}<testcase classname=\"${suite}\" name=\"${name}\"/>"
}

junit_fail() {
	local name
	name=$(xml_escape "$1")
	local message
	message=$(xml_escape "$2")
	local suite
	suite=$(xml_escape "$CURRENT_SUITE")
	JUNIT_CASES="${JUNIT_CASES}<testcase classname=\"${suite}\" name=\"${name}\"><failure message=\"${message}\"/></testcase>"
}

write_junit() {
	local total=$((PASS + FAIL))
	mkdir -p "$(dirname "$JUNIT_FILE")"
	cat >"$JUNIT_FILE" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="${total}" failures="${FAIL}">
  <testsuite name="tmux-assistant-resurrect" tests="${total}" failures="${FAIL}">
    ${JUNIT_CASES}
  </testsuite>
</testsuites>
JEOF
	echo "JUnit XML written to $JUNIT_FILE"
}

# --- Helpers ---

pass() {
	PASS=$((PASS + 1))
	echo "  PASS: $1"
	junit_pass "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  FAIL: $1"
	echo "  FAIL: $1"
	junit_fail "$1" "$1"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		fail "$desc (expected '$expected', got '$actual')"
	fi
}

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF -- "$needle"; then
		pass "$desc"
	else
		fail "$desc (expected to contain '$needle')"
	fi
}

assert_file_exists() {
	local desc="$1" path="$2"
	if [ -f "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file not found: $path)"
	fi
}

assert_file_not_exists() {
	local desc="$1" path="$2"
	if [ ! -f "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file should not exist: $path)"
	fi
}

# --- Process lifecycle helpers ---

# Poll for a child process matching a pattern under a given parent PID.
# Replaces fixed `sleep N` after `tmux send-keys` — fast on quick machines,
# tolerant on slow CI runners.
#
# Usage: wait_for_child <parent_pid> <grep_pattern> [timeout_secs]
# Returns 0 and prints child PID on success, 1 on timeout.
wait_for_child() {
	local ppid="$1" pattern="$2" timeout="${3:-10}"
	local deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ]; do
		local cpid
		cpid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$ppid" -v pat="$pattern" \
			'$2 == ppid && $0 ~ pat {print $1; exit}')
		if [ -n "$cpid" ]; then
			echo "$cpid"
			return 0
		fi
		sleep 0.5
	done
	return 1
}

# Poll for a descendant process anywhere in the tree under a given root PID
# whose args match detect_tool(). Handles wrapper chains like npx → node → opencode.
# Unlike wait_for_child (direct children only), this walks the full tree.
#
# Usage: wait_for_descendant <root_pid> [timeout_secs]
# Returns 0 and prints descendant PID on success, 1 on timeout.
wait_for_descendant() {
	local root="$1" timeout="${2:-15}"
	local deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ]; do
		local dpid
		dpid=$(ps -eo pid=,ppid=,args= | awk -v root="$root" '
			BEGIN { pids[root]=1 }
			{ if ($2 in pids) { pids[$1]=1; print $1, substr($0, index($0,$3)) } }
		' | while read -r cpid cargs; do
			case "$cargs" in
			claude | claude\ * | */claude | */claude\ * | \
				opencode | opencode\ * | */opencode | */opencode\ * | \
				codex | codex\ * | */codex | */codex\ *)
				case "$cargs" in
				*"opencode run "*) ;;
				*)
					echo "$cpid"
					break
					;;
				esac
				;;
			esac
		done)
		if [ -n "$dpid" ]; then
			echo "$dpid"
			return 0
		fi
		sleep 0.5
	done
	return 1
}

# Wait until a specific PID no longer exists.
# Usage: wait_for_death <pid> [timeout_secs]
wait_for_death() {
	local pid="$1" timeout="${2:-10}"
	local deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ]; do
		if ! kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

# Kill all descendant processes of a tmux pane, then optionally kill the session.
# Sends C-c first to allow graceful exit, then force-kills remaining children.
#
# Usage: kill_pane_children <tmux_target> [kill_session]
#   kill_session: "true" to also kill the tmux session (default: "false")
kill_pane_children() {
	local target="$1" kill_session="${2:-false}"
	tmux send-keys -t "$target" C-c 2>/dev/null || true
	local spid
	spid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$spid" ]; then
		# Give the C-c a moment to propagate
		sleep 0.5
		# Force-kill all descendants via full tree walk
		ps -eo pid=,ppid= | awk -v root="$spid" '
			BEGIN { pids[root]=1 }
			{ if ($2 in pids) { pids[$1]=1; print $1 } }
		' | while read -r cpid; do kill -9 "$cpid" 2>/dev/null || true; done
	fi
	if [ "$kill_session" = "true" ]; then
		sleep 0.3
		tmux kill-session -t "$target" 2>/dev/null || true
	fi
}

# --- Test 1: Installation ---

suite "install"
echo ""
echo "=== Test 1: just install ==="
echo ""

cd "$REPO_DIR"
just install 2>&1

# Verify TPM installed
if [ -d "$HOME/.tmux/plugins/tpm" ]; then
	pass "TPM installed"
else
	fail "TPM not installed"
fi

# Verify Claude hooks in settings.json
assert_file_exists "Claude settings.json created" "$HOME/.claude/settings.json"

hook_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Claude SessionStart hook present" "1" "$hook_count"

cleanup_count=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json")
assert_eq "Claude SessionEnd hook present" "1" "$cleanup_count"

# Verify OpenCode plugin symlinked
if [ -L "$HOME/.config/opencode/plugins/session-tracker.js" ]; then
	pass "OpenCode plugin symlinked"
else
	fail "OpenCode plugin not symlinked"
fi

# Verify tmux.conf configured
assert_file_exists "tmux.conf exists" "$HOME/.tmux.conf"
assert_contains "tmux.conf has marker block" "$(cat "$HOME/.tmux.conf")" "begin tmux-assistant-resurrect"
assert_contains "tmux.conf has Python hook paths" "$(cat "$HOME/.tmux.conf")" "assistant_resurrect.py' save"

# Verify idempotent install (run again, should not duplicate)
just install 2>&1 >/dev/null

hook_count_after=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Install is idempotent (no duplicate hooks)" "1" "$hook_count_after"

# --- Test 2: Save — detect assistants in tmux panes ---

suite "save"
echo ""
echo "=== Test 2: save (process detection + session IDs) ==="
echo ""

# Start a tmux server
tmux new-session -d -s test-claude -c /tmp
tmux new-session -d -s test-opencode -c /tmp
tmux new-session -d -s test-codex -c /tmp
tmux new-session -d -s test-opencode-nosid -c /tmp
tmux new-session -d -s test-lsp -c /tmp
tmux new-session -d -s test-false-positive -c /tmp

# Launch mock assistants inside tmux panes
# Claude: just a bare claude process (session ID comes from hook state file)
tmux send-keys -t test-claude "claude --resume ses_claude_test_123" Enter
# OpenCode: with -s flag (session ID comes from plugin state file — the Go
# binary overwrites its process title so -s is NOT visible in ps)
tmux send-keys -t test-opencode "opencode -s ses_opencode_test_456" Enter
# Codex: bare process (session ID comes from session-tags.jsonl)
tmux send-keys -t test-codex "codex resume ses_codex_test_789" Enter
# OpenCode without -s flag (no session ID available — should log warning)
tmux send-keys -t test-opencode-nosid "opencode" Enter
# OpenCode LSP subprocess (should be excluded from detection)
tmux send-keys -t test-lsp "opencode run pyright-langserver.js" Enter
# Command line mentioning "codex" as a value (must NOT be detected as Codex)
tmux send-keys -t test-false-positive "python3 -c 'import time; time.sleep(300)' --profile codex" Enter

# Wait for each assistant to appear as a child process (replaces fixed sleep 4).
# OpenCode spawns node → native binary chain, so it takes longer than claude/codex.
claude_pane_shell_pid=$(tmux display-message -t test-claude -p '#{pane_pid}')
opencode_pane_shell_pid=$(tmux display-message -t test-opencode -p '#{pane_pid}')
codex_pane_shell_pid=$(tmux display-message -t test-codex -p '#{pane_pid}')
nosid_pane_shell_pid=$(tmux display-message -t test-opencode-nosid -p '#{pane_pid}')

wait_for_child "$claude_pane_shell_pid" "claude" 10 >/dev/null || echo "WARN: claude child not found (may still work via tree walk)"
wait_for_child "$opencode_pane_shell_pid" "opencode" 10 >/dev/null || echo "WARN: opencode child not found"
wait_for_child "$codex_pane_shell_pid" "codex" 10 >/dev/null || echo "WARN: codex child not found"
wait_for_child "$nosid_pane_shell_pid" "opencode" 10 >/dev/null || echo "WARN: opencode-nosid child not found"

# Create a Claude hook state file keyed by the Claude child PID
# (When Claude runs the hook, hook's $PPID = Claude PID, so the save script
#  looks for claude-{child_pid}.json where child_pid = the claude process PID)
claude_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$claude_pane_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')
mkdir -p "$TEST_STATE_DIR"
cat >"$TEST_STATE_DIR/claude-${claude_child_pid}.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_claude_test_123",
  "ppid": $claude_child_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
EOF

# Create an OpenCode plugin state file keyed by the OpenCode child PID
# (The Go binary overwrites its process title, so -s flag is NOT visible
#  in `ps` output. The plugin writes a state file instead — same mechanism
#  as Claude's hook.)
opencode_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$opencode_pane_shell_pid" '$2 == ppid && /opencode/ {print $1; exit}')
cat >"$TEST_STATE_DIR/opencode-${opencode_child_pid}.json" <<EOF
{
  "tool": "opencode",
  "session_id": "ses_opencode_test_456",
  "pid": $opencode_child_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
EOF

# Create a Codex session-tags.jsonl entry
codex_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$codex_pane_shell_pid" '$2 == ppid && /codex/ {print $1; exit}')
mkdir -p "$HOME/.codex"
echo "{\"pid\": ${codex_child_pid}, \"session\": \"ses_codex_test_789\", \"host\": \"test\", \"started_at\": \"2026-01-01T00:00:00Z\"}" >"$HOME/.codex/session-tags.jsonl"

# Run save
just save 2>&1

# Verify output file
SAVED="$HOME/.tmux/resurrect/assistant-sessions.json"
RESTORE_FIXTURE="/tmp/assistant-restore-fixture.json"
assert_file_exists "assistant-sessions.json created" "$SAVED"
cp "$SAVED" "$RESTORE_FIXTURE"

session_count=$(jq '.sessions | length' "$SAVED")
# We expect: claude (1) + opencode with -s (1) + codex (1) = 3 with session IDs
# opencode-nosid must be excluded instead of guessed from cwd metadata
# lsp subprocess should be excluded entirely
if [ "$session_count" -ge 3 ]; then
	pass "Detected at least 3 assistant sessions (got $session_count)"
else
	fail "Expected at least 3 sessions, got $session_count"
fi

# Verify Claude was detected with correct session ID
claude_sid=$(jq -r '.sessions[] | select(.tool == "claude") | .session_id' "$SAVED")
assert_eq "Claude session ID extracted" "ses_claude_test_123" "$claude_sid"

# Verify OpenCode was detected with correct session ID (from plugin state file)
opencode_sid=$(jq -r '[.sessions[] | select(.tool == "opencode" and .session_id != "")] | first | .session_id' "$SAVED")
assert_eq "OpenCode session ID extracted from plugin state file" "ses_opencode_test_456" "$opencode_sid"

# Verify OpenCode without a trusted session source is excluded rather than
# guessed from the newest SQLite row for the cwd.
nosid_count=$(jq '[.sessions[] | select(.pane | contains("test-opencode-nosid"))] | length' "$SAVED")
assert_eq "OpenCode without a session ID is excluded" "0" "$nosid_count"

# Verify Codex was detected with correct session ID (from session-tags.jsonl)
codex_sid=$(jq -r '.sessions[] | select(.tool == "codex") | .session_id' "$SAVED")
assert_eq "Codex session ID extracted from session-tags.jsonl" "ses_codex_test_789" "$codex_sid"

# Verify LSP subprocess was excluded
lsp_count=$(jq '[.sessions[] | select(.pane | contains("test-lsp"))] | length' "$SAVED")
assert_eq "LSP subprocess excluded from detection" "0" "$lsp_count"

# Verify non-tool arg value "codex" does not trigger false-positive detection
false_positive_count=$(jq '[.sessions[] | select(.pane | contains("test-false-positive"))] | length' "$SAVED")
assert_eq "Argument value 'codex' does not trigger false-positive detection" "0" "$false_positive_count"

# Verify the log mentions the opencode without session ID
LOG="$HOME/.tmux/resurrect/assistant-save.log"
if grep -q "no session ID available" "$LOG"; then
	pass "Log warns about opencode without session ID"
else
	fail "Expected log warning about missing session ID"
fi

# --- Test 2b: Save detects assistants launched via wrappers (npx) ---

echo ""
echo "=== Test 2b: save detects assistants via wrappers (npx) ==="
echo ""

tmux new-session -d -s test-npx -c /tmp
tmux send-keys -t test-npx "npx opencode -s ses_npx_wrapper" Enter
npx_shell_pid=$(tmux display-message -t test-npx -p '#{pane_pid}')
# npx spawns: npm → sh → node → opencode (4 levels deep)
npx_oc_pid=$(wait_for_descendant "$npx_shell_pid" 15) || echo "WARN: npx opencode descendant not found"

# Create a plugin state file for the npx-launched opencode (same mechanism
# as the OpenCode plugin in production — the Go binary overwrites its title
# so -s flag is NOT visible in `ps`)
if [ -n "$npx_oc_pid" ]; then
	cat >"$TEST_STATE_DIR/opencode-${npx_oc_pid}.json" <<NPXEOF
{
  "tool": "opencode",
  "session_id": "ses_npx_wrapper",
  "pid": $npx_oc_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
NPXEOF
fi

# Seed DB fallback with a competing session for the same cwd. Save pass 1 should
# still pick the PID-specific state-file session and never need this fallback.
mkdir -p "$HOME/.local/share/opencode"
rm -f "$HOME/.local/share/opencode/opencode.db"
python3 - <<'PY'
import os
import sqlite3
db = os.path.expanduser('~/.local/share/opencode/opencode.db')
conn = sqlite3.connect(db)
conn.execute('''CREATE TABLE session (
    id TEXT PRIMARY KEY,
    slug TEXT,
    project_id TEXT,
    directory TEXT,
    title TEXT,
    version TEXT,
    time_created INTEGER,
    time_updated INTEGER
)''')
conn.execute('''INSERT INTO session (id, slug, project_id, directory, title, version, time_created, time_updated)
    VALUES ('ses_db_wrong_npx', 'wrong', 'global', '/tmp', 'wrong winner', '1.2.5', 1000000, 999999999999)''')
conn.commit()
conn.close()
PY

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

npx_sid=$(jq -r '.sessions[] | select(.pane | contains("test-npx")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Save detects opencode launched via npx" "ses_npx_wrapper" "$npx_sid"

kill_pane_children test-npx true

# --- Test 3: Restore — sends correct resume commands ---

suite "restore"
echo ""
echo "=== Test 3: restore (resume commands) ==="
echo ""

# Kill all assistants first (so panes are empty shells)
for sess in test-claude test-opencode test-codex test-opencode-nosid test-lsp test-false-positive; do
	kill_pane_children "$sess"
done
sleep 1

# Use the first save as the restore fixture. Real OpenCode exits quickly in the
# test environment, so restore verification should not depend on a later live
# save still seeing the original pane.
cp "$RESTORE_FIXTURE" "$HOME/.tmux/resurrect/assistant-sessions.json"

# Run restore
just restore 2>&1

# Give restore time to send commands (it has sleep 1 between each + sleep 2 at start)
sleep $((session_count * 2 + 3))

# Verify restore log
RESTORE_LOG="$HOME/.tmux/resurrect/assistant-restore.log"
assert_file_exists "Restore log created" "$RESTORE_LOG"

restore_log_content=$(cat "$RESTORE_LOG")
assert_contains "Restore log mentions claude" "$restore_log_content" "restoring claude"
assert_contains "Restore log mentions opencode" "$restore_log_content" "restoring opencode"
assert_contains "Restore log mentions codex" "$restore_log_content" "restoring codex"

# Verify the restore log contains the correct resume commands
# (pane content is unreliable — real CLIs take over the terminal and clear it)
assert_contains "Restore sent claude --resume" "$restore_log_content" "ses_claude_test_123"
assert_contains "Restore sent opencode -s" "$restore_log_content" "ses_opencode_test_456"
assert_contains "Restore sent codex resume" "$restore_log_content" "ses_codex_test_789"

# Verify restore uses 'command' prefix to bypass shell aliases
assert_contains "Restore uses 'command claude' prefix" "$restore_log_content" "command claude"
assert_contains "Restore uses 'command opencode' prefix" "$restore_log_content" "command opencode"
assert_contains "Restore uses 'command codex' prefix" "$restore_log_content" "command codex"

# --- Test 3b: Restore skips panes with already-running assistants ---

echo ""
echo "=== Test 3b: restore Guard 1 — skips non-shell foreground process ==="
echo ""

# The restore above launched assistants in the panes. The TUI tool (claude/node)
# becomes the foreground process, so pane_current_command != shell. Guard 1
# (the shell whitelist) should fire and skip these panes.
sleep 2
>"$RESTORE_LOG"
just restore 2>&1
sleep $((session_count * 2 + 3))

restore_log_2=$(cat "$RESTORE_LOG")
if echo "$restore_log_2" | grep -q "not a shell"; then
	pass "Guard 1: restore skips panes with non-shell foreground process"
else
	fail "Guard 1: expected 'not a shell' in restore log"
fi

# --- Test 3b2: Guard 2 — skips panes with background assistant process ---
#
# Guard 2 (pane_has_assistant tree walk) must also work independently of Guard 1.
# To test it, we need a pane where the foreground process IS a shell (so Guard 1
# passes) but an assistant is running as a descendant. We achieve this by
# launching an assistant in the background.

echo ""
echo "=== Test 3b2: restore Guard 2 — skips panes with background assistant ==="
echo ""

# Kill existing assistants so panes return to shells
for sess in test-claude test-opencode test-codex test-opencode-nosid test-lsp; do
	kill_pane_children "$sess"
done
sleep 1

# Launch claude in the background — the shell remains the foreground process
tmux send-keys -t test-claude "claude --resume ses_bg_test &" Enter
sleep 2

# Verify the shell is still the foreground command (Guard 1 should pass)
bg_pane_cmd=$(tmux display-message -t test-claude -p '#{pane_current_command}' 2>/dev/null || true)
echo "  (test-claude foreground command: $bg_pane_cmd)"

# Create a sidecar entry pointing at this pane
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'BG_EOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "test-claude:0.0", "tool": "claude", "session_id": "ses_bg_guard2_test", "cwd": "/tmp", "pid": "99999"}
  ]
}
BG_EOF

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

restore_log_bg=$(cat "$RESTORE_LOG")
if echo "$restore_log_bg" | grep -q "already has a running assistant"; then
	pass "Guard 2: restore skips panes with background assistant"
else
	# If the shell isn't foreground (Claude took over), Guard 1 fired instead
	if echo "$restore_log_bg" | grep -q "not a shell"; then
		pass "Guard 2: skipped (Guard 1 fired — Claude took foreground; acceptable)"
	else
		fail "Guard 2: expected 'already has a running assistant' in restore log"
	fi
fi

# Clean up the background assistant
kill_pane_children test-claude

# --- Test 3c: Restore handles cwd with single quotes and missing dirs ---

echo ""
echo "=== Test 3c: restore handles tricky cwd values ==="
echo ""

# Kill assistants so panes are clean shells
for sess in test-claude test-opencode test-codex test-opencode-nosid test-lsp; do
	kill_pane_children "$sess"
done
sleep 1

# Create a sidecar JSON with a cwd containing a single quote
mkdir -p "/tmp/project's dir"
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'CWDEOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "test-claude:0.0", "tool": "claude", "session_id": "ses_cwd_test", "cwd": "/tmp/project's dir", "pid": "99999"}
  ]
}
CWDEOF

>"$RESTORE_LOG"
restore_exit=0
just restore 2>&1 || restore_exit=$?
sleep 5

assert_eq "Restore doesn't crash on cwd with single quote" "0" "$restore_exit"
assert_contains "Restore attempted resume with tricky cwd" "$(cat "$RESTORE_LOG")" "ses_cwd_test"

# Kill any assistant that was just launched so the next restore can proceed
kill_pane_children test-claude

# Test with a missing cwd
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'CWDEOF2'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "test-claude:0.0", "tool": "claude", "session_id": "ses_nocwd_test", "cwd": "/nonexistent/path/that/does/not/exist", "pid": "99999"}
  ]
}
CWDEOF2

>"$RESTORE_LOG"
restore_exit2=0
just restore 2>&1 || restore_exit2=$?
sleep 5

assert_eq "Restore doesn't crash on missing cwd" "0" "$restore_exit2"
assert_contains "Restore attempted resume with missing cwd" "$(cat "$RESTORE_LOG")" "ses_nocwd_test"

# --- Test 3d: @resurrect-processes does not include assistants ---
#
# Verify that the plugin entry point does NOT set @resurrect-processes to
# include assistants, preventing the double-launch scenario.

echo ""
echo "=== Test 3d: @resurrect-processes excludes assistants ==="
echo ""

# Run the plugin entry point (this sets tmux options)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"

resurrect_procs=$(tmux show-option -gv @resurrect-processes 2>/dev/null || echo "")
if echo "$resurrect_procs" | grep -qiE "claude|opencode|codex"; then
	fail "@resurrect-processes still contains assistants (double-launch risk!)"
else
	pass "@resurrect-processes does not include assistants"
fi

# --- Test 3e: Restore logs unknown tool name ---
#
# Verify the `*` default branch in the restore script's case statement
# correctly logs unknown tool names and skips the pane.

echo ""
echo "=== Test 3e: restore logs unknown tool ==="
echo ""

# Kill any assistants so panes are clean shells
kill_pane_children test-claude

# Create a sidecar JSON with an unknown tool name
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'UNKNEOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "test-claude:0.0", "tool": "unknowntool", "session_id": "ses_unknown_test", "cwd": "/tmp", "pid": "99999"}
  ]
}
UNKNEOF

>"$RESTORE_LOG"
restore_exit_unknown=0
just restore 2>&1 || restore_exit_unknown=$?
sleep 3

assert_eq "Restore doesn't crash on unknown tool" "0" "$restore_exit_unknown"
assert_contains "Restore logs unknown tool" "$(cat "$RESTORE_LOG")" "unknown tool"

# --- Test 3f: Restore skips panes running non-shell programs ---
#
# If a pane is running something other than a shell (e.g., vim, sleep, top),
# the restore script should NOT inject send-keys into it.

echo ""
echo "=== Test 3f: restore skips non-shell panes ==="
echo ""

# Launch a non-shell program in test-claude pane (which has a sidecar entry)
kill_pane_children test-claude
sleep 0.5
tmux send-keys -t test-claude "sleep 9999" Enter
sleep 1

# Create a sidecar entry pointing at that pane
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'NOSHELLEOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {"pane": "test-claude:0.0", "tool": "claude", "session_id": "ses_noshell_test", "cwd": "/tmp", "pid": "99999"}
  ]
}
NOSHELLEOF

>"$RESTORE_LOG"
restore_exit_noshell=0
just restore 2>&1 || restore_exit_noshell=$?
sleep 3

assert_eq "Restore doesn't crash on non-shell pane" "0" "$restore_exit_noshell"
assert_contains "Restore skips non-shell pane" "$(cat "$RESTORE_LOG")" "not a shell"

# Clean up — kill the sleep and get the pane back to a shell
kill_pane_children test-claude

# --- Test 4: Uninstall ---

suite "uninstall"
echo ""
echo "=== Test 4: just uninstall ==="
echo ""

just uninstall 2>&1

# Verify Claude hooks removed
remaining_hooks=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Claude hooks removed after uninstall" "0" "$remaining_hooks"

# Verify OpenCode plugin removed
assert_file_not_exists "OpenCode plugin removed" "$HOME/.config/opencode/plugins/session-tracker.js"

# Verify tmux.conf cleaned
if grep -qF "begin tmux-assistant-resurrect" "$HOME/.tmux.conf" 2>/dev/null; then
	fail "tmux.conf still has marker block after uninstall"
else
	pass "tmux.conf marker block removed"
fi

# Verify plugin lines within the block are also gone
if grep -qF "assistant_resurrect.py" "$HOME/.tmux.conf" 2>/dev/null; then
	fail "tmux.conf still has Python hook paths after uninstall"
else
	pass "tmux.conf hook paths removed"
fi

# --- Test 5: Claude hooks (SessionStart / SessionEnd) ---

suite "hooks"
echo ""
echo "=== Test 5: Claude hook scripts ==="
echo ""

# Test SessionStart hook: feed it rich JSON on stdin (matching Claude's actual
# SessionStart payload), verify state file preserves all fields.
export TMUX_ASSISTANT_RESURRECT_DIR="/tmp/tmux-assistant-resurrect-test5"
mkdir -p "$TMUX_ASSISTANT_RESURRECT_DIR"
export TMUX_PANE="%99"
echo '{"session_id": "ses_hook_test", "cwd": "/tmp/project", "model": "claude-sonnet-4-5-20250929", "source": "startup", "permission_mode": "default", "transcript_path": "/tmp/transcript.jsonl", "hook_event_name": "SessionStart"}' | bash "$REPO_DIR/hooks/claude-session-track.sh"

state_file="$TMUX_ASSISTANT_RESURRECT_DIR/claude-$$.json"
assert_file_exists "SessionStart hook creates state file" "$state_file"

if [ -f "$state_file" ]; then
	hook_sid=$(jq -r '.session_id' "$state_file")
	assert_eq "SessionStart hook writes correct session ID" "ses_hook_test" "$hook_sid"

	# Verify fields from Claude's stdin JSON are preserved (full merge)
	hook_model=$(jq -r '.model' "$state_file")
	assert_eq "SessionStart hook preserves model" "claude-sonnet-4-5-20250929" "$hook_model"
	hook_source=$(jq -r '.source' "$state_file")
	assert_eq "SessionStart hook preserves source" "startup" "$hook_source"
	hook_perm=$(jq -r '.permission_mode' "$state_file")
	assert_eq "SessionStart hook preserves permission_mode" "default" "$hook_perm"

	# Verify our added fields
	hook_tool=$(jq -r '.tool' "$state_file")
	assert_eq "SessionStart hook adds tool field" "claude" "$hook_tool"
	hook_ppid=$(jq -r '.ppid' "$state_file")
	assert_eq "SessionStart hook adds ppid field" "$$" "$hook_ppid"
	hook_ts=$(jq -r '.timestamp' "$state_file")
	if [ -n "$hook_ts" ] && [ "$hook_ts" != "null" ]; then
		pass "SessionStart hook adds timestamp"
	else
		fail "SessionStart hook missing timestamp"
	fi

	# Verify hardcoded env vars are captured
	hook_env_pane=$(jq -r '.env.tmux_pane' "$state_file")
	assert_eq "SessionStart hook captures TMUX_PANE" "%99" "$hook_env_pane"
	hook_env_shell=$(jq -r '.env.shell' "$state_file")
	if [ -n "$hook_env_shell" ] && [ "$hook_env_shell" != "null" ]; then
		pass "SessionStart hook captures SHELL"
	else
		fail "SessionStart hook missing SHELL in env"
	fi
fi

# Test SessionEnd hook: should remove the state file
echo '{}' | bash "$REPO_DIR/hooks/claude-session-cleanup.sh"
assert_file_not_exists "SessionEnd hook removes state file" "$state_file"

# Test SessionStart hook with user-configured env var capture
# (via tmux option @assistant-resurrect-capture-env)
export MY_CUSTOM_VAR="custom_value_123"
tmux set-option -g @assistant-resurrect-capture-env 'MY_CUSTOM_VAR' 2>/dev/null || true
echo '{"session_id": "ses_envtest", "cwd": "/tmp"}' | bash "$REPO_DIR/hooks/claude-session-track.sh"
env_state="$TMUX_ASSISTANT_RESURRECT_DIR/claude-$$.json"
if [ -f "$env_state" ]; then
	env_custom=$(jq -r '.env.MY_CUSTOM_VAR' "$env_state")
	assert_eq "SessionStart hook captures user-configured env var" "custom_value_123" "$env_custom"
	rm -f "$env_state"
else
	fail "SessionStart hook state file not created for env capture test"
fi
# Clean up tmux option
tmux set-option -gu @assistant-resurrect-capture-env 2>/dev/null || true
unset MY_CUSTOM_VAR

# Test backward compatibility: minimal JSON (old format) still works
echo '{"session_id": "ses_minimal_test", "cwd": "/tmp"}' | bash "$REPO_DIR/hooks/claude-session-track.sh"
minimal_state="$TMUX_ASSISTANT_RESURRECT_DIR/claude-$$.json"
if [ -f "$minimal_state" ]; then
	minimal_sid=$(jq -r '.session_id' "$minimal_state")
	assert_eq "Minimal input still produces valid session_id" "ses_minimal_test" "$minimal_sid"
	# model should be absent (null) — not crash
	minimal_model=$(jq -r '.model // "absent"' "$minimal_state")
	assert_eq "Minimal input has no model field" "absent" "$minimal_model"
	# tool field should still be present
	minimal_tool=$(jq -r '.tool' "$minimal_state")
	assert_eq "Minimal input still has tool field" "claude" "$minimal_tool"
	rm -f "$minimal_state"
else
	fail "SessionStart hook state file not created for minimal input test"
fi

# Test SessionStart hook with special characters (JSON escaping)
echo '{"session_id": "ses_quote\"test", "cwd": "/tmp/project'\''s dir"}' | bash "$REPO_DIR/hooks/claude-session-track.sh"
special_state="$TMUX_ASSISTANT_RESURRECT_DIR/claude-$$.json"
if [ -f "$special_state" ]; then
	# Verify the file is valid JSON (jq can parse it)
	if jq empty "$special_state" 2>/dev/null; then
		pass "SessionStart hook produces valid JSON with special chars"
	else
		fail "SessionStart hook produces invalid JSON with special chars"
	fi
	special_sid=$(jq -r '.session_id' "$special_state")
	assert_eq "SessionStart hook preserves special chars in session_id" 'ses_quote"test' "$special_sid"
	rm -f "$special_state"
else
	fail "SessionStart hook state file not created for special chars test"
fi

unset TMUX_PANE

# Restore the test-wide state dir
export TMUX_ASSISTANT_RESURRECT_DIR="$TEST_STATE_DIR"

suite "regression"
# --- Test 5b: Claude state file keyed by child PID (regression) ---
#
# The SessionStart hook's $PPID = Claude's PID (not the shell PID), because
# Claude spawns the hook. The save script must look up state files by the
# Claude child PID. Previously the save script used the shell PID, which
# never matched — session IDs were silently lost.

echo ""
echo "=== Test 5b: Claude state file lookup by child PID (regression) ==="
echo ""

# Set up a fresh tmux session with a Claude process
tmux new-session -d -s test-claude-pid -c /tmp
tmux send-keys -t test-claude-pid "claude --resume ses_pid_test" Enter
claude_pid_test_shell=$(tmux display-message -t test-claude-pid -p '#{pane_pid}')
wait_for_child "$claude_pid_test_shell" "claude" 10 >/dev/null || echo "WARN: claude child not found for pid test"

claude_pid_test_child=$(ps -eo pid=,ppid=,args= | awk -v ppid="$claude_pid_test_shell" '$2 == ppid && /claude/ {print $1; exit}')

# Sanity: make sure we found the child
if [ -n "$claude_pid_test_child" ]; then
	pass "Found Claude child PID ($claude_pid_test_child) under shell PID ($claude_pid_test_shell)"
else
	fail "Could not find Claude child PID under shell $claude_pid_test_shell"
fi

PID_TEST_STATE_DIR="$TEST_STATE_DIR"
mkdir -p "$PID_TEST_STATE_DIR"

# Clean up any prior state files for these PIDs
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json" "$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json"

# Create state file keyed by CHILD PID (correct — matches how the hook works)
cat >"$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json" <<CEOF
{
  "tool": "claude",
  "session_id": "ses_child_pid_test",
  "ppid": $claude_pid_test_child,
  "timestamp": "2026-01-01T00:00:00Z"
}
CEOF

# Run save and check that the session ID is picked up
rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

child_pid_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-pid")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Save finds state file keyed by Claude child PID" "ses_child_pid_test" "$child_pid_sid"

# --- Test 5c: State file keyed by shell PID must NOT match (regression) ---
#
# If someone (or a bug) creates a state file keyed by the shell PID instead
# of the Claude child PID, the save script must NOT pick it up via the state
# file path. The session ID may still be found via --resume in process args
# (the chicken-and-egg fallback), but it must NOT come from the wrong file.

echo ""
echo "=== Test 5c: State file keyed by shell PID must NOT match (regression) ==="
echo ""

# Remove the correct (child-keyed) state file
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_child}.json"

# Create state file keyed by SHELL PID (incorrect — the old bug)
cat >"$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json" <<SEOF
{
  "tool": "claude",
  "session_id": "ses_shell_pid_WRONG",
  "ppid": $claude_pid_test_shell,
  "timestamp": "2026-01-01T00:00:00Z"
}
SEOF

# Run save — should NOT pick up the shell-keyed file's session ID
rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

shell_pid_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-pid")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
if [ "$shell_pid_sid" = "ses_shell_pid_WRONG" ]; then
	fail "Save incorrectly matched state file keyed by shell PID (regression!)"
else
	pass "Save correctly ignores state file keyed by shell PID"
fi

# The session ID may still be found from --resume in process args (the
# chicken-and-egg fallback). That's fine — the key assertion is that the
# WRONG file's ID was not used.
if [ "$shell_pid_sid" = "ses_pid_test" ]; then
	pass "Fallback correctly found session ID from --resume args instead"
else
	# No args fallback available — should log warning
	if grep -q "test-claude-pid.*no session ID available" "$HOME/.tmux/resurrect/assistant-save.log"; then
		pass "Log correctly reports no session ID for shell-PID-keyed state"
	else
		fail "Expected either args fallback or log warning for test-claude-pid"
	fi
fi

# Clean up test state files and session
rm -f "$PID_TEST_STATE_DIR/claude-${claude_pid_test_shell}.json"
kill_pane_children test-claude-pid true

# --- Test 5c2: Python runtime unit tests ---
#
# v2 deliberately drops the sourced-shell helper contract. Unit coverage now
# imports the Python runtime directly instead of sourcing bash wrappers.

suite "runtime_unit"
echo ""
echo "=== Test 5c2: Python runtime unit tests ==="
echo ""

runtime_unit_exit=0
python3 "$REPO_DIR/test/test_runtime.py" || runtime_unit_exit=$?
assert_eq "Python runtime unit tests pass" "0" "$runtime_unit_exit"

suite "regression"

# --- Test 5c3: Claude state file takes priority over --resume arg ---
#
# If both a state file and --resume arg exist, the state file should win
# because the user may have switched sessions inside the TUI after launch.

echo ""
echo "=== Test 5c3: Claude state file takes priority over --resume arg ==="
echo ""

tmux new-session -d -s test-claude-priority -c /tmp
tmux send-keys -t test-claude-priority "claude --resume ses_args_old" Enter
priority_shell_pid=$(tmux display-message -t test-claude-priority -p '#{pane_pid}')
wait_for_child "$priority_shell_pid" "claude" 10 >/dev/null || echo "WARN: claude child not found for priority test"

priority_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$priority_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')

# Create a state file with a DIFFERENT session ID (simulating a session switch)
cat >"$PID_TEST_STATE_DIR/claude-${priority_child_pid}.json" <<PEOF
{
  "tool": "claude",
  "session_id": "ses_hook_newer",
  "ppid": $priority_child_pid,
  "timestamp": "2026-01-01T00:00:00Z"
}
PEOF

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

priority_sid=$(jq -r '.sessions[] | select(.pane | contains("test-claude-priority")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "State file session ID takes priority over --resume arg" "ses_hook_newer" "$priority_sid"

rm -f "$PID_TEST_STATE_DIR/claude-${priority_child_pid}.json"
kill_pane_children test-claude-priority true

# --- Test 5c4: Codex resume arg fallback (chicken-and-egg) ---
#
# After restore, Codex is launched as `codex resume <session_id>`. Even
# without a session-tags.jsonl entry, the save script should extract the
# session ID from the process args.

echo ""
echo "=== Test 5c4: Codex resume arg fallback (chicken-and-egg) ==="
echo ""

tmux new-session -d -s test-codex-resume -c /tmp
tmux send-keys -t test-codex-resume "codex resume ses_codex_from_args" Enter
codex_resume_shell_pid=$(tmux display-message -t test-codex-resume -p '#{pane_pid}')
wait_for_child "$codex_resume_shell_pid" "codex" 10 >/dev/null || echo "WARN: codex child not found for resume test"

# Make sure NO session-tags.jsonl entry exists for this PID
rm -f "$HOME/.codex/session-tags.jsonl"

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

codex_resume_sid=$(jq -r '.sessions[] | select(.pane | contains("test-codex-resume")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Codex resume arg fallback extracts session ID" "ses_codex_from_args" "$codex_resume_sid"

kill_pane_children test-codex-resume true

# --- Test 5c4b: Codex rollout session files (e2e) ---
#
# When session-tags.jsonl is absent but rollout files exist under
# ~/.codex/sessions/, the save script should extract the session ID
# from the rollout file matching the pane's cwd.

echo ""
echo "=== Test 5c4b: Codex rollout session file (e2e) ==="
echo ""

ROLLOUT_CWD="/tmp/test-codex-rollout"
mkdir -p "$ROLLOUT_CWD"

tmux new-session -d -s test-codex-rollout -c "$ROLLOUT_CWD"
tmux send-keys -t test-codex-rollout "codex resume ses_codex_rollout_e2e" Enter
codex_rollout_shell_pid=$(tmux display-message -t test-codex-rollout -p '#{pane_pid}')
wait_for_child "$codex_rollout_shell_pid" "codex" 10 >/dev/null || echo "WARN: codex child not found for rollout test"

# Remove session-tags.jsonl so Method 1 cannot succeed
rm -f "$HOME/.codex/session-tags.jsonl"

# Create a rollout file that matches this pane's cwd
mkdir -p "$HOME/.codex/sessions/2026/03/24"
cat >"$HOME/.codex/sessions/2026/03/24/rollout-test-codex-rollout.jsonl" <<ROLLOUT
{"timestamp":"2026-03-24T10:00:00.000Z","type":"session_meta","payload":{"id":"ses_codex_rollout_e2e","timestamp":"2026-03-24T10:00:00.000Z","cwd":"$ROLLOUT_CWD","originator":"codex_cli_rs","cli_version":"0.116.0"}}
ROLLOUT

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

codex_rollout_sid=$(jq -r '.sessions[] | select(.pane | contains("test-codex-rollout")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
assert_eq "Codex rollout e2e: session ID from rollout file" "ses_codex_rollout_e2e" "$codex_rollout_sid"

# Clean up
rm -f "$HOME/.codex/sessions/2026/03/24/rollout-test-codex-rollout.jsonl"
kill_pane_children test-codex-rollout true
rm -rf "$ROLLOUT_CWD"

# --- Test 5c4c: Codex rollout dedup — two panes same cwd (e2e) ---
#
# Two codex panes in the same cwd should get distinct session IDs
# when two rollout files exist for that cwd.

echo ""
echo "=== Test 5c4c: Codex rollout dedup — two panes same cwd (e2e) ==="
echo ""

DEDUP_CWD="/tmp/test-codex-dedup"
mkdir -p "$DEDUP_CWD"

tmux new-session -d -s test-codex-dedup1 -c "$DEDUP_CWD"
tmux send-keys -t test-codex-dedup1 "codex resume ses_dedup_pane1" Enter
tmux new-session -d -s test-codex-dedup2 -c "$DEDUP_CWD"
tmux send-keys -t test-codex-dedup2 "codex resume ses_dedup_pane2" Enter

dedup1_shell_pid=$(tmux display-message -t test-codex-dedup1 -p '#{pane_pid}')
dedup2_shell_pid=$(tmux display-message -t test-codex-dedup2 -p '#{pane_pid}')
wait_for_child "$dedup1_shell_pid" "codex" 10 >/dev/null || echo "WARN: codex child not found for dedup1"
wait_for_child "$dedup2_shell_pid" "codex" 10 >/dev/null || echo "WARN: codex child not found for dedup2"

# Remove session-tags.jsonl, provide two rollout files for same cwd
rm -f "$HOME/.codex/session-tags.jsonl"
mkdir -p "$HOME/.codex/sessions/2026/03/24"
cat >"$HOME/.codex/sessions/2026/03/24/rollout-test-dedup-aaa.jsonl" <<ROLLOUT
{"timestamp":"2026-03-24T10:00:00.000Z","type":"session_meta","payload":{"id":"ses_dedup_aaa","timestamp":"2026-03-24T10:00:00.000Z","cwd":"$DEDUP_CWD","originator":"codex_cli_rs","cli_version":"0.116.0"}}
ROLLOUT
cat >"$HOME/.codex/sessions/2026/03/24/rollout-test-dedup-bbb.jsonl" <<ROLLOUT
{"timestamp":"2026-03-24T10:01:00.000Z","type":"session_meta","payload":{"id":"ses_dedup_bbb","timestamp":"2026-03-24T10:01:00.000Z","cwd":"$DEDUP_CWD","originator":"codex_cli_rs","cli_version":"0.116.0"}}
ROLLOUT

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

dedup_sid1=$(jq -r '.sessions[] | select(.pane | contains("test-codex-dedup1")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)
dedup_sid2=$(jq -r '.sessions[] | select(.pane | contains("test-codex-dedup2")) | .session_id' "$HOME/.tmux/resurrect/assistant-sessions.json" 2>/dev/null)

if [ -n "$dedup_sid1" ] && [ -n "$dedup_sid2" ] && [ "$dedup_sid1" != "$dedup_sid2" ]; then
	pass "Codex rollout dedup e2e: two panes same cwd get distinct sessions ($dedup_sid1 vs $dedup_sid2)"
else
	fail "Codex rollout dedup e2e: expected distinct sessions, got '$dedup_sid1' and '$dedup_sid2'"
fi

# Clean up
rm -f "$HOME/.codex/sessions/2026/03/24/rollout-test-dedup-aaa.jsonl"
rm -f "$HOME/.codex/sessions/2026/03/24/rollout-test-dedup-bbb.jsonl"
kill_pane_children test-codex-dedup1 true
kill_pane_children test-codex-dedup2 true
rm -rf "$DEDUP_CWD"

# --- Test 5c5: Corrupt/empty state file doesn't crash save ---
#
# If a state file is corrupt (not valid JSON) or empty, the save script
# should not crash — it should fall through gracefully.
# Note: Claude Code overwrites its process title, so --resume args are NOT
# visible in `ps`. The unit tests (5c2) verify the args fallback in isolation.

echo ""
echo "=== Test 5c5: Corrupt state file doesn't crash save ==="
echo ""

tmux new-session -d -s test-corrupt -c /tmp
tmux send-keys -t test-corrupt "claude" Enter
corrupt_shell_pid=$(tmux display-message -t test-corrupt -p '#{pane_pid}')
wait_for_child "$corrupt_shell_pid" "claude" 10 >/dev/null || echo "WARN: claude child not found for corrupt test"

corrupt_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$corrupt_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')

# Write a corrupt (non-JSON) state file
echo "THIS IS NOT JSON" >"$PID_TEST_STATE_DIR/claude-${corrupt_child_pid}.json"

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
save_exit_code=0
just save 2>&1 || save_exit_code=$?

assert_eq "Save doesn't crash on corrupt state file" "0" "$save_exit_code"

# Claude is detected but neither state file (corrupt) nor args (title overwritten) yield an ID
# Verify the save script logged the warning rather than crashing
if grep -q "test-corrupt.*no session ID available" "$HOME/.tmux/resurrect/assistant-save.log"; then
	pass "Save gracefully handles corrupt state file"
else
	fail "Expected log warning about no session ID for corrupt state file pane"
fi

rm -f "$PID_TEST_STATE_DIR/claude-${corrupt_child_pid}.json"
kill_pane_children test-corrupt true

# --- Test 6: Clean recipe ---

suite "clean"
echo ""
echo "=== Test 6: just clean ==="
echo ""

# Re-install for the clean test
just install 2>&1 >/dev/null

# Create a stale state file with a dead PID
STATE_DIR="$TEST_STATE_DIR"
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/claude-99999.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_stale",
  "ppid": 99999,
  "timestamp": "2025-01-01T00:00:00Z"
}
EOF

clean_output=$(just clean 2>&1)
assert_contains "Clean removes stale files" "$clean_output" "Cleaned"
assert_file_not_exists "Stale state file removed" "$STATE_DIR/claude-99999.json"

# Test: corrupt state file with non-numeric PID should be cleaned
cat >"$STATE_DIR/claude-corrupt.json" <<EOF
{
  "tool": "claude",
  "session_id": "ses_corrupt_pid",
  "ppid": "not-a-number",
  "timestamp": "2025-01-01T00:00:00Z"
}
EOF

# Test: state file with PID 0 should be cleaned (kill -0 0 succeeds for process group)
cat >"$STATE_DIR/opencode-zeropid.json" <<EOF
{
  "tool": "opencode",
  "session_id": "ses_zero_pid",
  "pid": 0,
  "timestamp": "2025-01-01T00:00:00Z"
}
EOF

clean_output_2=$(just clean 2>&1)
assert_file_not_exists "Clean removes corrupt PID state file" "$STATE_DIR/claude-corrupt.json"
assert_file_not_exists "Clean removes zero-PID state file" "$STATE_DIR/opencode-zeropid.json"

# --- Test 7: TPM plugin entry point ---

suite "tpm"
echo ""
echo "=== Test 7: TPM plugin entry point (.tmux file) ==="
echo ""

# Clean up from previous tests — remove claude hooks and opencode plugin
just uninstall 2>&1 >/dev/null

# Remove claude settings entirely to test from scratch
rm -f "$HOME/.claude/settings.json"
rm -rf "$HOME/.config/opencode/plugins"

# Run the TPM plugin entry point (simulates what TPM does on prefix+I)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"

# Verify Claude hooks installed
assert_file_exists "TPM: Claude settings.json created" "$HOME/.claude/settings.json"
tpm_hook_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Claude SessionStart hook present" "1" "$tpm_hook_count"
tpm_cleanup_count=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Claude SessionEnd hook present" "1" "$tpm_cleanup_count"

# Verify OpenCode plugin symlinked
if [ -L "$HOME/.config/opencode/plugins/session-tracker.js" ]; then
	pass "TPM: OpenCode plugin symlinked"
else
	fail "TPM: OpenCode plugin not symlinked"
fi

# Verify idempotent (run again, no duplicates)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"
tpm_hook_count_after=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "TPM: Idempotent (no duplicate hooks)" "1" "$tpm_hook_count_after"

# --- Test 7b: Upgrade path — old unquoted hooks don't cause duplicates ---
#
# Before the contains() fix, the plugin used exact string matching. If a user
# had the old unquoted form (bash /path/to/hook.sh) and upgraded to the new
# quoted form (bash '/path/to/hook.sh'), the idempotency check would miss
# the old entry and create a duplicate.

echo ""
echo "=== Test 7b: Upgrade path — unquoted-to-quoted hook migration ==="
echo ""

# Start fresh
rm -f "$HOME/.claude/settings.json"
echo '{}' >"$HOME/.claude/settings.json"

# Simulate the OLD (pre-fix) unquoted hook format by injecting directly
old_unquoted_track="bash $REPO_DIR/hooks/claude-session-track.sh"
old_unquoted_cleanup="bash $REPO_DIR/hooks/claude-session-cleanup.sh"
tmp_upgrade=$(mktemp)
jq --arg track "$old_unquoted_track" --arg cleanup "$old_unquoted_cleanup" '
    .hooks = {
        "SessionStart": [{
            "matcher": "",
            "hooks": [{"type": "command", "command": $track}]
        }],
        "SessionEnd": [{
            "matcher": "",
            "hooks": [{"type": "command", "command": $cleanup}]
        }]
    }
' "$HOME/.claude/settings.json" >"$tmp_upgrade" && mv "$tmp_upgrade" "$HOME/.claude/settings.json"

# Verify old hooks are in place
old_track_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Upgrade: old unquoted hook present before upgrade" "1" "$old_track_count"

# Run the TPM plugin entry point (simulates upgrade to new quoted form)
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"

# The plugin should detect the old entry via contains() and NOT add a duplicate
upgrade_track_count=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Upgrade: no duplicate SessionStart hooks after upgrade" "1" "$upgrade_track_count"

upgrade_cleanup_count=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json")
assert_eq "Upgrade: no duplicate SessionEnd hooks after upgrade" "1" "$upgrade_cleanup_count"

# Now test uninstall via justfile — it should remove both old and new forms
just uninstall 2>&1 >/dev/null

upgrade_remaining=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Upgrade: uninstall removes old unquoted hooks" "0" "$upgrade_remaining"

upgrade_remaining_cleanup=$(jq '[.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-session-cleanup"))] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Upgrade: uninstall removes old unquoted cleanup hooks" "0" "$upgrade_remaining_cleanup"

# --- Test 7c: Install/uninstall with malformed hook entries (null .command) ---
#
# If another tool adds hook entries without a .command field (or with null),
# the jq contains() call must not crash. The (.command // "") null-coalescing
# ensures graceful handling.

echo ""
echo "=== Test 7c: Install with malformed hook entries (null .command) ==="
echo ""

# Create a settings.json with a malformed hook entry (missing .command)
cat >"$HOME/.claude/settings.json" <<'MALEOF'
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{"type": "url", "url": "https://example.com/webhook"}]
    }]
  }
}
MALEOF

# Install should not crash — the malformed entry has no .command at all
install_malformed_exit=0
bash "$REPO_DIR/tmux-assistant-resurrect.tmux" 2>&1 || install_malformed_exit=$?
assert_eq "Install doesn't crash on hook entry without .command" "0" "$install_malformed_exit"

# Our hook should be added alongside the existing malformed entry
malformed_track=$(jq '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains("claude-session-track"))] | length' "$HOME/.claude/settings.json")
assert_eq "Install adds hook alongside malformed entry" "1" "$malformed_track"

# The original malformed entry should still be there
malformed_url=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.url == "https://example.com/webhook")] | length' "$HOME/.claude/settings.json")
assert_eq "Install preserves existing malformed entries" "1" "$malformed_url"

# Uninstall should not crash either
uninstall_malformed_exit=0
just uninstall 2>&1 || uninstall_malformed_exit=$?
assert_eq "Uninstall doesn't crash on hook entry without .command" "0" "$uninstall_malformed_exit"

# The malformed entry should survive uninstall (we only remove our hooks)
malformed_url_after=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.url == "https://example.com/webhook")] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Uninstall preserves non-matching entries" "1" "$malformed_url_after"

# --- Test 7d: invalid Claude settings fail closed ---
#
# A malformed ~/.claude/settings.json must not be overwritten. Direct install
# should fail nonzero, and the TPM entrypoint should leave the file untouched.

echo ""
echo "=== Test 7d: invalid Claude settings fail closed ==="
echo ""

mkdir -p "$HOME/.claude"
printf '{ invalid\n' >"$HOME/.claude/settings.json"
invalid_before=$(cat "$HOME/.claude/settings.json")

invalid_install_exit=0
python3 "$REPO_DIR/scripts/assistant_admin.py" install-claude-hook >/dev/null 2>/tmp/invalid-claude-install.err || invalid_install_exit=$?
assert_eq "Direct install fails on invalid Claude settings" "1" "$invalid_install_exit"
assert_eq "Direct install leaves invalid Claude settings untouched" "$invalid_before" "$(cat "$HOME/.claude/settings.json")"

# TPM entrypoint suppresses hook-install stderr, but it must still preserve the file.
bash "$REPO_DIR/tmux-assistant-resurrect.tmux"
assert_eq "TPM entrypoint leaves invalid Claude settings untouched" "$invalid_before" "$(cat "$HOME/.claude/settings.json")"
rm -f /tmp/invalid-claude-install.err
rm -f "$HOME/.claude/settings.json"

# --- Test 7e: tmux.conf upgrade from legacy source-file to marker block ---
#
# If ~/.tmux.conf has the old source-file line (pre-marker), configure-tmux
# should remove it and write the new marker block.

echo ""
echo "=== Test 7e: tmux.conf upgrade from legacy source-file format ==="
echo ""

# Simulate an old-format ~/.tmux.conf with a legacy source-file line,
# a CUSTOM TPM path, and a commented-out TPM example after the real init.
# The commented line must NOT be captured as the TPM init.
cat >"$HOME/.tmux.conf" <<'LEGEOF'
# user settings
set -g mouse on

# tmux-assistant-resurrect
source-file '/old/path/to/tmux-assistant-resurrect/config/resurrect-assistants.conf'

run '/custom/path/tpm/tpm'
# example: run '~/.tmux/plugins/tpm/tpm'
LEGEOF

just configure-tmux 2>&1

# The legacy source-file line should be gone
if grep -qF "resurrect-assistants.conf" "$HOME/.tmux.conf" 2>/dev/null; then
	fail "Legacy source-file line still present after upgrade"
else
	pass "Legacy source-file line removed on upgrade"
fi

# The new marker block should be present
if grep -qF "begin tmux-assistant-resurrect" "$HOME/.tmux.conf" 2>/dev/null; then
	pass "Marker block added on upgrade"
else
	fail "Marker block missing after upgrade"
fi

# The hook paths should point to the real repo dir
if grep -qF "assistant_resurrect.py" "$HOME/.tmux.conf" 2>/dev/null; then
	pass "Hook paths present in marker block"
else
	fail "Hook paths missing from marker block"
fi

# TPM init must come AFTER the marker block (TPM ignores lines after its run line)
end_line=$(grep -n "end tmux-assistant-resurrect" "$HOME/.tmux.conf" | tail -1 | cut -d: -f1)
tpm_line_num=$(grep -n "tpm/tpm" "$HOME/.tmux.conf" | tail -1 | cut -d: -f1)
if [ -n "$end_line" ] && [ -n "$tpm_line_num" ] && [ "$tpm_line_num" -gt "$end_line" ]; then
	pass "TPM init line is after marker block"
else
	fail "TPM init line is NOT after marker block (end=$end_line, tpm=$tpm_line_num)"
fi

# Custom TPM path must be preserved verbatim (not replaced with default)
# The real init (uncommented) should be the one re-added, not the comment
if grep "^run '/custom/path/tpm/tpm'" "$HOME/.tmux.conf" >/dev/null 2>&1; then
	pass "Custom TPM path preserved during upgrade"
else
	fail "Custom TPM path was replaced with default"
fi

# The commented TPM example must still be present (not mistaken for real init)
if grep -qF "# example: run" "$HOME/.tmux.conf" 2>/dev/null; then
	pass "Commented TPM line preserved (not captured as init)"
else
	fail "Commented TPM line was removed"
fi

# User settings outside the block should be preserved
if grep -qF "set -g mouse on" "$HOME/.tmux.conf" 2>/dev/null; then
	pass "User settings preserved during upgrade"
else
	fail "User settings lost during upgrade"
fi

# Uninstall should remove the marker block completely
just unconfigure-tmux 2>&1

if grep -qF "begin tmux-assistant-resurrect" "$HOME/.tmux.conf" 2>/dev/null; then
	fail "Marker block still present after unconfigure"
else
	pass "Unconfigure removes marker block"
fi

# User settings should still be there
if grep -qF "set -g mouse on" "$HOME/.tmux.conf" 2>/dev/null; then
	pass "User settings preserved after unconfigure"
else
	fail "User settings lost during unconfigure"
fi

# --- Test 9b: saved session includes replayable fields ---

echo ""
echo "=== Test 9b: saved session includes replayable fields ==="
echo ""

# Re-install so save/restore use the updated scripts
just install 2>&1 >/dev/null

# Create a tmux session with claude running
tmux new-session -d -s test-enrich-claude -c /tmp
tmux send-keys -t test-enrich-claude "claude --dangerously-skip-permissions --resume ses_enrich_test" Enter
enrich_shell_pid=$(tmux display-message -t test-enrich-claude -p '#{pane_pid}')
wait_for_child "$enrich_shell_pid" "claude" 10 >/dev/null || echo "WARN: claude child not found for enrich test"
enrich_child_pid=$(ps -eo pid=,ppid=,args= | awk -v ppid="$enrich_shell_pid" '$2 == ppid && /claude/ {print $1; exit}')

# Create a state file with env metadata keyed by child PID
mkdir -p "$TEST_STATE_DIR"
cat >"$TEST_STATE_DIR/claude-${enrich_child_pid}.json" <<EEOF
{
  "session_id": "ses_enrich_test",
  "source": "startup",
  "tool": "claude",
  "ppid": $enrich_child_pid,
  "timestamp": "2026-01-01T00:00:00Z",
  "env": {
    "tmux_pane": "%5",
    "shell": "/bin/bash",
    "ANTHROPIC_BASE_URL": "https://proxy.internal"
  }
}
EEOF

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
STATE_DIR="$TEST_STATE_DIR"
just save 2>&1

SAVED="$HOME/.tmux/resurrect/assistant-sessions.json"
enrich_entry=$(jq '.sessions[] | select(.pane | contains("test-enrich-claude"))' "$SAVED")

# Verify cli_args present (stripped of --resume)
enrich_cli_args=$(echo "$enrich_entry" | jq -r '.cli_args // empty')
assert_contains "Enriched: cli_args has --dangerously-skip-permissions" "$enrich_cli_args" "--dangerously-skip-permissions"

# Verify env from state file
enrich_env=$(echo "$enrich_entry" | jq -r '.env.ANTHROPIC_BASE_URL // empty')
assert_eq "Enriched: env from state file" "https://proxy.internal" "$enrich_env"

# Verify env has tmux_pane and shell
enrich_env_pane=$(echo "$enrich_entry" | jq -r '.env.tmux_pane // empty')
assert_eq "Enriched: env has tmux_pane" "%5" "$enrich_env_pane"

rm -f "$TEST_STATE_DIR/claude-${enrich_child_pid}.json"
kill_pane_children test-enrich-claude true

# --- Test 9c: save tolerates minimal state files ---

echo ""
echo "=== Test 9c: save tolerates minimal state files ==="
echo ""

# Create a session with a MINIMAL state file (no model, no env — old format)
tmux new-session -d -s test-enrich-minimal -c /tmp
tmux send-keys -t test-enrich-minimal "claude --resume ses_minimal_enrich" Enter
minimal_enrich_shell=$(tmux display-message -t test-enrich-minimal -p '#{pane_pid}')
wait_for_child "$minimal_enrich_shell" "claude" 10 >/dev/null || echo "WARN"
minimal_enrich_child=$(ps -eo pid=,ppid=,args= | awk -v ppid="$minimal_enrich_shell" '$2 == ppid && /claude/ {print $1; exit}')

cat >"$TEST_STATE_DIR/claude-${minimal_enrich_child}.json" <<MEOF
{
  "session_id": "ses_minimal_enrich",
  "tool": "claude",
  "ppid": $minimal_enrich_child,
  "timestamp": "2026-01-01T00:00:00Z"
}
MEOF

rm -f "$HOME/.tmux/resurrect/assistant-sessions.json"
just save 2>&1

SAVED="$HOME/.tmux/resurrect/assistant-sessions.json"
minimal_entry=$(jq '.sessions[] | select(.pane | contains("test-enrich-minimal"))' "$SAVED")

# session_id must still be present
minimal_sid=$(echo "$minimal_entry" | jq -r '.session_id')
assert_eq "Backward compat: session_id present" "ses_minimal_enrich" "$minimal_sid"

# Should not crash with missing env
minimal_env=$(echo "$minimal_entry" | jq -r '.env // empty')
if [ -z "$minimal_env" ]; then
	pass "Minimal state file: missing env tolerated"
else
	fail "Minimal state file: unexpected env value '$minimal_env'"
fi

rm -f "$TEST_STATE_DIR/claude-${minimal_enrich_child}.json"
kill_pane_children test-enrich-minimal true

# --- Test 10: restore uses enriched fields ---

suite "restore_enriched"
echo ""
echo "=== Test 10: restore uses enriched fields ==="
echo ""

# Ensure a clean test pane
tmux new-session -d -s test-restore-enrich -c /tmp 2>/dev/null || true
sleep 0.5

# Create enriched sidecar JSON with cli_args
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RENRICH'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-enrich:0.0",
      "tool": "claude",
      "session_id": "ses_restore_flags",
      "cwd": "/tmp",
      "pid": "99999",
      "model": "claude-opus-4-6",
      "cli_args": "--dangerously-skip-permissions --model claude-opus-4-6",
      "env": {"tmux_pane": "%5", "shell": "/bin/bash", "ANTHROPIC_BASE_URL": "https://proxy.internal"}
    }
  ]
}
RENRICH

RESTORE_LOG="$HOME/.tmux/resurrect/assistant-restore.log"
>"$RESTORE_LOG"
just restore 2>&1
sleep 5

restore_enrich_log=$(cat "$RESTORE_LOG")

# The restore command should include the saved CLI flags
assert_contains "Restore includes --dangerously-skip-permissions" "$restore_enrich_log" "--dangerously-skip-permissions"
assert_contains "Restore includes --model" "$restore_enrich_log" "'--model' 'claude-opus-4-6'"

kill_pane_children test-restore-enrich true

# --- Test 10b: restore with env vars ---

echo ""
echo "=== Test 10b: restore with env vars ==="
echo ""

tmux new-session -d -s test-restore-env -c /tmp 2>/dev/null || true
sleep 0.5

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RENVEOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-env:0.0",
      "tool": "claude",
      "session_id": "ses_restore_env",
      "cwd": "/tmp",
      "pid": "99999",
      "cli_args": "",
      "env": {"tmux_pane": "%5", "shell": "/bin/bash", "ANTHROPIC_BASE_URL": "https://proxy.internal"}
    }
  ]
}
RENVEOF

# Set the capture-env option so restore knows ANTHROPIC_BASE_URL is user-configured
tmux set-option -g @assistant-resurrect-capture-env 'ANTHROPIC_BASE_URL' 2>/dev/null || true

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

restore_env_log=$(cat "$RESTORE_LOG")
assert_contains "Restore includes ANTHROPIC_BASE_URL env prefix" "$restore_env_log" "ANTHROPIC_BASE_URL="

tmux set-option -gu @assistant-resurrect-capture-env 2>/dev/null || true
kill_pane_children test-restore-env true

# --- Test 10c: Backward compat — restore with old-format sidecar JSON ---

echo ""
echo "=== Test 10c: restore backward compat — no enriched fields ==="
echo ""

tmux new-session -d -s test-restore-compat -c /tmp 2>/dev/null || true
sleep 0.5

# Old-format sidecar (no cli_args, no model, no env)
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RCOMPAT'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-compat:0.0",
      "tool": "claude",
      "session_id": "ses_compat_test",
      "cwd": "/tmp",
      "pid": "99999"
    }
  ]
}
RCOMPAT

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

compat_log=$(cat "$RESTORE_LOG")
assert_contains "Backward compat: restore still works" "$compat_log" "ses_compat_test"
assert_contains "Backward compat: bare resume command" "$compat_log" "restoring claude"

kill_pane_children test-restore-compat true

# --- Test 10d: Restore with empty cli_args ---

echo ""
echo "=== Test 10d: restore with empty cli_args ==="
echo ""

tmux new-session -d -s test-restore-empty -c /tmp 2>/dev/null || true
sleep 0.5

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'REMPTY'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-empty:0.0",
      "tool": "opencode",
      "session_id": "ses_empty_cli",
      "cwd": "/tmp",
      "pid": "99999",
      "model": "",
      "cli_args": "",
      "env": {}
    }
  ]
}
REMPTY

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

empty_log=$(cat "$RESTORE_LOG")
assert_contains "Empty cli_args: restore still works" "$empty_log" "ses_empty_cli"
assert_contains "Empty cli_args: tool identified" "$empty_log" "restoring opencode"

kill_pane_children test-restore-empty true

# --- Test 10e: Restore filters out tmux_pane and shell from env prefix ---

echo ""
echo "=== Test 10e: restore filters built-in env vars ==="
echo ""

tmux new-session -d -s test-restore-envfilter -c /tmp 2>/dev/null || true
sleep 0.5

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RENVF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-envfilter:0.0",
      "tool": "claude",
      "session_id": "ses_envfilter",
      "cwd": "/tmp",
      "pid": "99999",
      "cli_args": "",
      "env": {"tmux_pane": "%99", "shell": "/bin/zsh", "MY_CUSTOM": "hello"}
    }
  ]
}
RENVF

# Set the capture-env option so restore knows MY_CUSTOM is a user var
tmux set-option -g @assistant-resurrect-capture-env 'MY_CUSTOM' 2>/dev/null || true

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

envfilter_log=$(cat "$RESTORE_LOG")
# MY_CUSTOM should be in the env prefix
assert_contains "Env filter: MY_CUSTOM restored" "$envfilter_log" "MY_CUSTOM="

# tmux_pane and shell should NOT be in the env prefix (they're built-in, not user-configured)
if echo "$envfilter_log" | grep -q "tmux_pane="; then
	fail "Env filter: tmux_pane should NOT be in restore command"
else
	pass "Env filter: tmux_pane correctly excluded"
fi

tmux set-option -gu @assistant-resurrect-capture-env 2>/dev/null || true
kill_pane_children test-restore-envfilter true

# --- Test 10f: Restore quotes cli_args containing shell-special chars (e.g., []) ---

suite "restore_special_chars"
echo ""
echo "=== Test 10f: restore quotes cli_args with brackets (zsh glob safety) ==="
echo ""

tmux new-session -d -s test-restore-bracket -c /tmp 2>/dev/null || true
sleep 0.5

# Model name with brackets — this caused "zsh: no matches found" before the fix
cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RBRACKET'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-bracket:0.0",
      "tool": "claude",
      "session_id": "ses_bracket_test",
      "cwd": "/tmp",
      "pid": "99999",
      "model": "claude-opus-4-6[1m]",
      "cli_args": "--allow-dangerously-skip-permissions --model claude-opus-4-6[1m] -r"
    }
  ]
}
RBRACKET

>"$RESTORE_LOG"
restore_bracket_exit=0
just restore 2>&1 || restore_bracket_exit=$?
sleep 5

bracket_log=$(cat "$RESTORE_LOG")
assert_eq "Restore doesn't crash with bracket model name" "0" "$restore_bracket_exit"
assert_contains "Bracket model: session ID present" "$bracket_log" "ses_bracket_test"
# cli_args should be posix_quote'd so brackets are safe
assert_contains "Bracket model: model name quoted" "$bracket_log" "'claude-opus-4-6[1m]'"
assert_contains "Bracket model: uses command claude" "$bracket_log" "command claude"

kill_pane_children test-restore-bracket true

# --- Test 10g: Restore strips stale codex bare-resume cli_args ---

echo ""
echo "=== Test 10g: restore strips stale codex bare-resume cli_args ==="
echo ""

tmux new-session -d -s test-restore-codex-stale -c /tmp 2>/dev/null || true
sleep 0.5

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RCODEXSTALE'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-codex-stale:0.0",
      "tool": "codex",
      "session_id": "019stalecliargs00000000000000000000",
      "cwd": "/tmp",
      "pid": "99999",
      "cli_args": "resume",
      "env": null
    }
  ]
}
RCODEXSTALE

>"$RESTORE_LOG"
just restore 2>&1
sleep 5

codex_stale_log=$(cat "$RESTORE_LOG")
assert_contains "Codex stale cli_args: restore still runs" "$codex_stale_log" "019stalecliargs00000000000000000000"
assert_contains "Codex stale cli_args: single resume subcommand" "$codex_stale_log" "cmd: command codex resume '019stalecliargs00000000000000000000'"
if echo "$codex_stale_log" | grep -q "resume resume"; then
	fail "Codex stale cli_args: duplicate resume should not appear"
else
	pass "Codex stale cli_args: duplicate resume removed"
fi

kill_pane_children test-restore-codex-stale true

# --- Test 10h: Restore retries split panes until assistants actually launch ---

echo ""
echo "=== Test 10h: restore retries split panes until launch is confirmed ==="
echo ""

RETRY_BIN_DIR=$(mktemp -d)
cat >"$RETRY_BIN_DIR/claude" <<'RETRYCLAUDE'
#!/usr/bin/env bash
sleep 300
RETRYCLAUDE
chmod +x "$RETRY_BIN_DIR/claude"

TMUX_PROXY_DROP_STATE=$(mktemp)
rm -f "$TMUX_PROXY_DROP_STATE"
cat >"$RETRY_BIN_DIR/tmux-proxy" <<'RETRYTMUX'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 5 ] && [ "$1" = "-L" ] && [ "$3" = "-f" ] && [ "$5" = "send-keys" ]; then
	target=""
	idx=6
	while [ "$idx" -le "$#" ]; do
		eval "arg=\${$idx}"
		if [ "$arg" = "-t" ]; then
			idx=$((idx + 1))
			eval "target=\${$idx}"
			break
		fi
		idx=$((idx + 1))
	done
	if [ "$target" = "test-restore-retry:0.1" ] && [ ! -f "${TMUX_PROXY_DROP_STATE:?}" ]; then
		touch "$TMUX_PROXY_DROP_STATE"
		exit 0
	fi
fi

exec /usr/bin/tmux "$@"
RETRYTMUX
chmod +x "$RETRY_BIN_DIR/tmux-proxy"

OLD_PATH="$PATH"
export PATH="$RETRY_BIN_DIR:$PATH"
tmux set-environment -g PATH "$PATH"

tmux new-session -d -s test-restore-retry -c /tmp 2>/dev/null || true
tmux split-window -t test-restore-retry:0.0 -h -c /tmp
sleep 0.5

retry_left_shell=$(tmux display-message -t test-restore-retry:0.0 -p '#{pane_pid}')
retry_right_shell=$(tmux display-message -t test-restore-retry:0.1 -p '#{pane_pid}')

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RRETRY'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-retry:0.0",
      "tool": "claude",
      "session_id": "ses_retry_left",
      "cwd": "/tmp",
      "pid": "99991"
    },
    {
      "pane": "test-restore-retry:0.1",
      "tool": "claude",
      "session_id": "ses_retry_right",
      "cwd": "/tmp",
      "pid": "99992"
    }
  ]
}
RRETRY

>"$RESTORE_LOG"
export TMUX_ASSISTANT_TMUX_BIN="$RETRY_BIN_DIR/tmux-proxy"
export TMUX_PROXY_DROP_STATE
just restore 2>&1

retry_left_pid=$(wait_for_descendant "$retry_left_shell" 10) || retry_left_pid=""
retry_right_pid=$(wait_for_descendant "$retry_right_shell" 10) || retry_right_pid=""
if [ -n "$retry_left_pid" ]; then
	pass "Retry restore: left pane assistant launched"
else
	fail "Retry restore: left pane assistant did not launch"
fi
if [ -n "$retry_right_pid" ]; then
	pass "Retry restore: right pane assistant launched"
else
	fail "Retry restore: right pane assistant did not launch"
fi

retry_log=$(cat "$RESTORE_LOG")
assert_contains "Retry restore log confirms both panes" "$retry_log" "restored 2 of 2 assistant session(s)"
assert_contains "Retry restore log records retries" "$retry_log" "retrying claude in test-restore-retry"

kill_pane_children test-restore-retry true
tmux set-environment -g PATH "$OLD_PATH"
export PATH="$OLD_PATH"
rm -rf "$RETRY_BIN_DIR"
rm -f "$TMUX_PROXY_DROP_STATE"
unset TMUX_ASSISTANT_TMUX_BIN
unset TMUX_PROXY_DROP_STATE

echo ""
echo "=== Test 12: transient assistant launch must not count as restored ==="
echo ""

TRANSIENT_BIN_DIR=$(mktemp -d)
TRANSIENT_CLAUDE_STATE=$(mktemp)
cat >"$TRANSIENT_BIN_DIR/claude" <<'TRANSIENTCLAUDE'
#!/usr/bin/env bash
set -euo pipefail

state_file="${TRANSIENT_CLAUDE_STATE:?}"
count=0
if [ -f "$state_file" ]; then
	count=$(cat "$state_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$state_file"

if [ "$count" -eq 1 ]; then
	sleep 0.20
	exit 1
fi

sleep 15
TRANSIENTCLAUDE
chmod +x "$TRANSIENT_BIN_DIR/claude"

OLD_PATH="$PATH"
export PATH="$TRANSIENT_BIN_DIR:$PATH"
tmux set-environment -g PATH "$PATH"
tmux set-environment -g TRANSIENT_CLAUDE_STATE "$TRANSIENT_CLAUDE_STATE"

tmux new-session -d -s test-restore-confirm -c /tmp 2>/dev/null || true
sleep 0.2

confirm_shell=$(tmux display-message -t test-restore-confirm:0.0 -p '#{pane_pid}')

cat >"$HOME/.tmux/resurrect/assistant-sessions.json" <<'RCONFIRM'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "sessions": [
    {
      "pane": "test-restore-confirm:0.0",
      "tool": "claude",
      "session_id": "ses_confirmed_after_dwell",
      "cwd": "/tmp"
    }
  ]
}
RCONFIRM

>"$RESTORE_LOG"
export TRANSIENT_CLAUDE_STATE
export TMUX_ASSISTANT_RESTORE_POLL_INTERVAL_SECONDS="0.05"
export TMUX_ASSISTANT_RESTORE_RETRY_INTERVAL_SECONDS="0.20"
export TMUX_ASSISTANT_RESTORE_CONFIRMATION_SECONDS="0.40"
export TMUX_ASSISTANT_RESTORE_TIMEOUT_SECONDS="5"
just restore 2>&1

confirm_pid=$(wait_for_descendant "$confirm_shell" 10) || confirm_pid=""
if [ -n "$confirm_pid" ]; then
	pass "Confirmation restore: assistant relaunched after transient failure"
else
	fail "Confirmation restore: assistant did not relaunch after transient failure"
fi

confirm_attempts=$(cat "$TRANSIENT_CLAUDE_STATE" 2>/dev/null || echo 0)
assert_eq "Confirmation restore retried after transient launch" "2" "$confirm_attempts"

confirm_log=$(cat "$RESTORE_LOG")
assert_contains "Confirmation restore log records retry" "$confirm_log" "retrying claude in test-restore-confirm:0.0"
assert_contains "Confirmation restore log confirms pane" "$confirm_log" "confirmed claude running in test-restore-confirm:0.0 after restore attempt"
assert_contains "Confirmation restore log reports success" "$confirm_log" "restored 1 of 1 assistant session(s)"

kill_pane_children test-restore-confirm true
tmux set-environment -g PATH "$OLD_PATH"
tmux set-environment -gu TRANSIENT_CLAUDE_STATE
export PATH="$OLD_PATH"
rm -rf "$TRANSIENT_BIN_DIR"
rm -f "$TRANSIENT_CLAUDE_STATE"
unset TRANSIENT_CLAUDE_STATE
unset TMUX_ASSISTANT_RESTORE_POLL_INTERVAL_SECONDS
unset TMUX_ASSISTANT_RESTORE_RETRY_INTERVAL_SECONDS
unset TMUX_ASSISTANT_RESTORE_CONFIRMATION_SECONDS
unset TMUX_ASSISTANT_RESTORE_TIMEOUT_SECONDS

# --- Summary ---

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

write_junit

if [ "$FAIL" -gt 0 ]; then
	echo -e "\nFailures:$ERRORS"
	echo ""
	exit 1
fi

echo ""
exit 0
