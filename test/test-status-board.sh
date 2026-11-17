#!/bin/bash
# test/test-status-board.sh
# dispatch-task.sh --status-board: one \x1e record per live worker, read-only.
# Runs against a disposable fixture repo, never the real state db.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT="$REPO_ROOT/orchestration/init/init-state-store.sh"
DISPATCH="$REPO_ROOT/orchestration/lib/dispatch-task.sh"
source "$REPO_ROOT/orchestration/lib/gate-hold.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_ROOT=$(mktemp -d)
trap 'cd /; rm -rf "$TMP_ROOT"' EXIT

new_repo() {
    local d
    d=$(mktemp -d "$TMP_ROOT/r.XXXXXX")
    git -C "$d" init -q
    echo "$d"
}

# board repo: the board's stdout -> BOARD_OUT, stderr -> BOARD_ERR, status -> BOARD_RC
board() {
    local errf="$TMP_ROOT/err"
    BOARD_OUT=$(ORCH_PROJECT_ROOT="$1" bash "$DISPATCH" --status-board 2>"$errf")
    BOARD_RC=$?
    BOARD_ERR=$(cat "$errf")
}
# rec label: the record of one worker, fields separated by "|"
rec() { printf '%s' "$BOARD_OUT" | tr '\036' '\n' | awk -F'\037' -v l="$1" '$1 == l {OFS="|"; $1=$1; print}'; }
nrec() { printf '%s' "$BOARD_OUT" | tr '\036' '\n' | grep -c .; }
field() { printf '%s' "$BOARD_OUT" | tr '\036' '\n' | awk -F'\037' -v l="$1" -v n="$2" '$1 == l {print $n}'; }

HASH=$(printf '%064d' 0 | tr 0 a)

# --- fixture: workers in every status plus the dashboard row --------------
R=$(new_repo)
"$INIT" "$R" >/dev/null 2>&1
DB="$R/.claude/session-state.db"
ins() { # label status title event message
    sqlite3 "$DB" "INSERT INTO sessions (agent_id, worktree_path, status, task_title, last_event, last_message, last_activity_at) VALUES ('$1', '/wt/$1', '$2', '$3', NULLIF('$4',''), '$5', '2026-01-02 03:04:05');"
}
ins w-run running "Run task" start "hello"
ins w-blk blocked "Blocked task" blocked "needs approval"
ins w-stl stalled "Stalled task" commit "committed"
ins w-idle running "Idle task" idle "turn ended"
ins w-fin running "Finished task" done "all done"
ins w-done done "Done row" done "x"
ins w-merged merged "Merged row" done "x"
ins w-dead dead "Dead row" start "x"
ins dashboard running "Dashboard" start "x"
sqlite3 "$DB" "UPDATE sessions SET task_title = 'a'||char(30)||'b'||char(31)||'c'||char(10)||'d' WHERE agent_id = 'w-run';"
# live hold: this shell's pid is alive and its start time matches
GD=$(gate_hold_dir "$R")
gate_hold_pending_write "$GD" toolu_live w-blk "$HASH" "$R" Bash "git push origin main"
# stale hold on w-run: a dead pid
sleep 300 & DEAD=$!; kill -9 "$DEAD"; wait "$DEAD" 2>/dev/null
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' w-run "$HASH" "$DEAD" "$(date +%s)" "$R" "x" "Bash: stale" > "$GD/toolu_stale.pending"

# the call running now: control characters and newlines are cleaned like the other fields
sqlite3 "$DB" "UPDATE sessions SET pending_operation = 'Bash: ls'||char(31)||char(30)||' -la'||char(10)||'x' WHERE agent_id = 'w-run';"

UPDATED_BEFORE=$(sqlite3 "$DB" "SELECT group_concat(agent_id||status||updated_at) FROM sessions;")
board "$R"
LABELS=$(printf '%s' "$BOARD_OUT" | tr '\036' '\n' | awk -F'\037' 'NF {print $1}' | sort | tr '\n' ' ')
if [ "$BOARD_RC" = 0 ] && [ "$LABELS" = "w-blk w-fin w-idle w-run w-stl " ]; then
    pass "lists exactly the running, blocked and stalled workers, never dashboard or done, merged, dead rows"
else
    fail "labels '$LABELS' rc=$BOARD_RC err='$BOARD_ERR'"
fi
if [ "$(rec w-run | awk -F'|' '{print NF}')" = 9 ]; then
    pass "each record has 9 fields"
else
    fail "w-run record: $(rec w-run)"
fi
if [ "$(field w-run 2)" = "abc d" ]; then
    pass "x1e and x1f are stripped from a title, newline flattened"
else
    fail "title '$(field w-run 2)'"
fi
if [ "$(field w-blk 7)" = 1 ] && [ "$(field w-blk 8)" = "Bash: git push origin main" ]; then
    pass "a live hold shows count 1 and its op"
else
    fail "w-blk hold fields '$(field w-blk 7)' '$(field w-blk 8)'"
fi
if [ "$(field w-run 9)" = "Bash: ls -la x" ] && [ -z "$(field w-idle 9)" ]; then
    pass "the pending operation is the ninth field, cleaned, empty when none"
else
    fail "pending operation '$(field w-run 9)' '$(field w-idle 9)'"
fi
if [ "$(field w-run 7)" = 0 ] && [ -z "$(field w-run 8)" ]; then
    pass "a stale pending record (dead pid) shows 0"
else
    fail "w-run hold fields '$(field w-run 7)' '$(field w-run 8)'"
fi
if [ "$(field w-idle 4)" = idle ] && [ "$(field w-fin 4)" = done ] && [ "$(field w-run 4)" = start ] \
    && [ "$(field w-blk 4)" = blocked ] && [ "$(field w-stl 4)" = commit ]; then
    pass "idle and done print unchanged and distinct, with start, blocked and commit"
else
    fail "events '$(field w-idle 4)' '$(field w-fin 4)' '$(field w-run 4)'"
fi
if [ "$(field w-run 5)" = "$(date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-02 03:04:05' +%s 2>/dev/null || date -u -d '2026-01-02 03:04:05' +%s)" ] \
    && [ "$(field w-run 6)" = hello ]; then
    pass "event time is epoch seconds of last_activity_at, message is carried"
else
    fail "time '$(field w-run 5)' message '$(field w-run 6)'"
fi
if [ "$(sqlite3 "$DB" "SELECT group_concat(agent_id||status||updated_at) FROM sessions;")" = "$UPDATED_BEFORE" ]; then
    pass "the board writes no status and no updated_at"
else
    fail "rows changed"
fi

# oldest of two live holds
gate_hold_pending_write "$GD" toolu_live2 w-blk "$HASH" "$R" Bash "second op"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' w-blk "$HASH" "$$" 1000 "$R" "$(_gate_hold_start_time $$)" "Bash: oldest op" > "$GD/toolu_old.pending"
board "$R"
if [ "$(field w-blk 7)" = 3 ] && [ "$(field w-blk 8)" = "Bash: oldest op" ]; then
    pass "several live holds: the count is 3 and the op is the oldest hold's"
else
    fail "w-blk '$(field w-blk 7)' '$(field w-blk 8)'"
fi

# --- a db without the relay columns --------------------------------------
R2=$(new_repo)
"$INIT" "$R2" >/dev/null 2>&1
DB2="$R2/.claude/session-state.db"
sqlite3 "$DB2" "INSERT INTO sessions (agent_id, worktree_path, status, task_title) VALUES ('old-w', '/wt/old', 'running', 'Old task');"
sqlite3 "$DB2" "ALTER TABLE sessions DROP COLUMN last_event;"
board "$R2"
if [ "$BOARD_RC" = 0 ] && [ "$(nrec)" = 1 ] && [ "$(field old-w 2)" = "Old task" ] && [ -z "$(field old-w 4)" ] \
    && [ -z "$(field old-w 5)" ] && [[ "$BOARD_ERR" == *last_event* ]] && [ "$(printf '%s' "$BOARD_ERR" | grep -c .)" = 1 ]; then
    pass "a db without last_event lists the worker with empty fields and one stderr line naming the column"
else
    fail "rc=$BOARD_RC out='$(rec old-w)' err='$BOARD_ERR'"
fi

# --- no db: empty output, nothing created --------------------------------
R3=$(new_repo)
mkdir -p "$R3/.claude"
board "$R3"
if [ "$BOARD_RC" = 0 ] && [ -z "$BOARD_OUT" ] && [ -z "$(ls -A "$R3/.claude")" ]; then
    pass "no state db: empty output, exit 0, no file created"
else
    fail "rc=$BOARD_RC out='$BOARD_OUT' files: $(ls -A "$R3/.claude")"
fi

echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
