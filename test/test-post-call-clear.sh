#!/bin/bash
# test/test-post-call-clear.sh
# A worker row shows blocked only while a call really waits. worker-relay.sh
# puts a blocked row back to running as soon as a call completes, unless a live
# gate hold still waits for that worker.
# Disposable fixture repos only. Plain bash, no framework.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT="$REPO_ROOT/orchestration/init/init-state-store.sh"
RELAY="$REPO_ROOT/orchestration/hooks/worker-relay.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_ROOT=$(mktemp -d)
trap 'cd /; rm -rf "$TMP_ROOT"' EXIT

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -qm seed
"$INIT" "$REPO" >/dev/null 2>&1
WT="$TMP_ROOT/wt"
git -C "$REPO" worktree add -q -b br-w1 "$WT"
WT=$(git -C "$WT" rev-parse --show-toplevel)
DB="$REPO/.claude/session-state.db"
sqlite3 "$DB" "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('w1', '$WT', 'running');"
q() { sqlite3 "$DB" "$1"; }
row() { q "SELECT status FROM sessions WHERE agent_id='w1'"; }

# hook event tool [command]: run a hook from the worktree with a payload.
hook() {
    local script="$1" event="$2" tool="$3" cmd="${4:-}"
    (cd "$WT" && node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],hook_event_name:process.argv[2],tool_name:process.argv[3],tool_input:{command:process.argv[4]}}))' "$WT" "$event" "$tool" "$cmd" | bash "$script" >/dev/null 2>&1)
}

# 1. A row marked blocked returns to running when the call completes.
q "UPDATE sessions SET status='blocked' WHERE agent_id='w1'"
hook "$RELAY" PostToolUse WebFetch "https://example.com"
[ "$(row)" = "running" ] && pass "PostToolUse puts a blocked row back to running" || fail "blocked row after PostToolUse: $(row)"

# 2. A Stop event does not clear a blocked row.
q "UPDATE sessions SET status='blocked' WHERE agent_id='w1'"
hook "$RELAY" Stop Stop
[ "$(row)" = "blocked" ] && pass "a Stop event does not clear a waiting call" || fail "after Stop: $(row)"

# 3b. A worker with a live gate hold stays blocked when another (parallel) call
# completes; once the hold is gone the next PostToolUse clears it.
source "$REPO_ROOT/orchestration/lib/session-state.sh"
source "$REPO_ROOT/orchestration/lib/gate-hold.sh"
q "UPDATE sessions SET status='blocked' WHERE agent_id='w1'"
HOLD_DIR="$(cd "$WT" && gate_hold_dir .)"
(cd "$WT" && gate_hold_pending_write "$HOLD_DIR" toolu_1 w1 hash1 "$WT" Bash "git push")
hook "$RELAY" PostToolUse Bash "ls"
[ "$(row)" = "blocked" ] && pass "a live gate hold keeps the row blocked after another call completes" || fail "held row after PostToolUse: $(row)"
rm -f "$HOLD_DIR/toolu_1.pending"
hook "$RELAY" PostToolUse Bash "ls"
[ "$(row)" = "running" ] && pass "the next PostToolUse clears the row once the hold is gone" || fail "row after hold gone: $(row)"

# 4. Done and merged rows are left alone.
q "UPDATE sessions SET status='done' WHERE agent_id='w1'"
hook "$RELAY" PostToolUse Bash "ls"
[ "$(q "SELECT status FROM sessions WHERE agent_id='w1'")" = "done" ] && pass "a done row keeps its status" || fail "done row changed: $(row)"

echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
