#!/bin/bash
# test/test-approval-relay.sh
# Exercises the pending_operation/task_title schema migration and the
# session_state_set_pending_operation / get_pending_operation /
# clear_pending_operation / set_task_title / list_blocked /
# agent_id_for_worktree helpers against the real .claude/session-state.db,
# using disposable test-apr-* fixture rows.
# Plain bash, no framework. Safe to re-run: cleans up its own fixtures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/session-state.sh
source "$SCRIPT_DIR/../orchestration/lib/session-state.sh"
# shellcheck source=../orchestration/lib/notify.sh
source "$SCRIPT_DIR/../orchestration/lib/notify.sh"

# session_state_list_blocked field separator (ASCII unit separator, \x1f)
US=$'\x1f'

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

cleanup() {
    [ -n "${TMP_MAIN:-}" ] && rm -rf "$TMP_MAIN"
    [ -n "${TMP_OLD:-}" ] && rm -rf "$TMP_OLD"
    local db_path
    db_path=$(session_state_db_path) || return 0
    sqlite3 "$db_path" "DELETE FROM sessions WHERE agent_id LIKE 'test-apr-%';" 2>/dev/null
    cd / && [ -n "${TMP_FIXTURE:-}" ] && rm -rf "$TMP_FIXTURE"
}
trap cleanup EXIT

# Isolate from the live db: run from a throwaway git repo with its own
# initialised state store, so session_state_db_path (cwd-based) never
# resolves to the real repo's .claude/session-state.db.
TMP_FIXTURE=$(mktemp -d)
git -C "$TMP_FIXTURE" init -q
git -C "$TMP_FIXTURE" config user.email "test@example.com"
git -C "$TMP_FIXTURE" config user.name "test"
echo seed > "$TMP_FIXTURE/seed.txt"
git -C "$TMP_FIXTURE" add seed.txt
git -C "$TMP_FIXTURE" commit -qm "seed"
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$TMP_FIXTURE" >/dev/null 2>&1
cd "$TMP_FIXTURE" || { echo "FAIL: could not enter fixture repo"; exit 1; }

DB_PATH=$(session_state_db_path) || { echo "FAIL: could not resolve db_path"; exit 1; }

# --- Task 2: additive schema columns + guarded live-database migration (D-02, D-15) ---
TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "test"
echo seed > "$TMP_MAIN/seed.txt"
git -C "$TMP_MAIN" add seed.txt
git -C "$TMP_MAIN" commit -qm "seed"

# 1. fresh database: running the initialiser once gains both new columns
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$TMP_MAIN" >/dev/null 2>&1
FRESH_COLS=$(sqlite3 "$TMP_MAIN/.claude/session-state.db" "PRAGMA table_info(sessions);" | cut -d'|' -f2)
if echo "$FRESH_COLS" | grep -qx 'pending_operation' && echo "$FRESH_COLS" | grep -qx 'task_title'; then
    pass "fresh database gains pending_operation and task_title columns"
else
    fail "fresh database missing pending_operation/task_title (got: $FRESH_COLS)"
fi

# --- pre-existing database fixture: starts from the schema text WITHOUT the
# new columns, so the guarded migration is genuinely exercised ---
TMP_OLD=$(mktemp -d)
git -C "$TMP_OLD" init -q
git -C "$TMP_OLD" config user.email "test@example.com"
git -C "$TMP_OLD" config user.name "test"
echo seed > "$TMP_OLD/seed.txt"
git -C "$TMP_OLD" add seed.txt
git -C "$TMP_OLD" commit -qm "seed"
mkdir -p "$TMP_OLD/.claude"
sqlite3 "$TMP_OLD/.claude/session-state.db" "
CREATE TABLE sessions (
    agent_id TEXT PRIMARY KEY,
    worktree_path TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK(status IN ('running','blocked','done','merged','stalled','dead')),
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    pid INTEGER,
    last_activity_at DATETIME,
    iterm_session_id TEXT
);
"
sqlite3 "$TMP_OLD/.claude/session-state.db" "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('test-apr-preexist', '/tmp/test-apr-preexist', 'running');"

# 2. pre-existing database (old schema, no new columns): migration adds both
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$TMP_OLD" >/dev/null 2>&1
OLD_COLS=$(sqlite3 "$TMP_OLD/.claude/session-state.db" "PRAGMA table_info(sessions);" | cut -d'|' -f2)
if echo "$OLD_COLS" | grep -qx 'pending_operation' && echo "$OLD_COLS" | grep -qx 'task_title'; then
    pass "pre-existing database gains pending_operation and task_title columns via migration"
else
    fail "pre-existing database migration did not add both columns (got: $OLD_COLS)"
fi

# 3. idempotence: running the initialiser again exits 0, each column appears once
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$TMP_OLD" >/dev/null 2>&1
RUN2_EXIT=$?
PENDING_COUNT=$(sqlite3 "$TMP_OLD/.claude/session-state.db" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -cx 'pending_operation')
TITLE_COUNT=$(sqlite3 "$TMP_OLD/.claude/session-state.db" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -cx 'task_title')
if [ "$RUN2_EXIT" -eq 0 ] && [ "$PENDING_COUNT" = "1" ] && [ "$TITLE_COUNT" = "1" ]; then
    pass "re-running the initialiser is idempotent, each new column appears exactly once"
else
    fail "re-running the initialiser was not idempotent (exit=$RUN2_EXIT pending_count=$PENDING_COUNT title_count=$TITLE_COUNT)"
fi

# 4. a row written before the migration survives with NULL in the new columns
ROW=$(sqlite3 "$TMP_OLD/.claude/session-state.db" "SELECT agent_id, status, worktree_path, ifnull(pending_operation,'<NULL>'), ifnull(task_title,'<NULL>') FROM sessions WHERE agent_id='test-apr-preexist';")
if [ "$ROW" = "test-apr-preexist|running|/tmp/test-apr-preexist|<NULL>|<NULL>" ]; then
    pass "a pre-migration row survives with its fields intact and NULL in the new columns"
else
    fail "pre-migration row did not survive intact (got: $ROW)"
fi

rm -rf "$TMP_OLD"
TMP_OLD=""
rm -rf "$TMP_MAIN"
TMP_MAIN=""

# --- Task 3: session_state_* helpers for pending_operation / task_title (D-02, D-15) ---
session_state_write "test-apr-round" "/tmp/test-apr-round-worktree" "blocked" >/dev/null

# 5. set_pending_operation then get_pending_operation round-trips a plain string
if session_state_set_pending_operation "test-apr-round" "npm install lodash"; then
    GOT=$(session_state_get_pending_operation "test-apr-round")
    if [ "$GOT" = "npm install lodash" ]; then
        pass "set/get_pending_operation round-trips a plain string"
    else
        fail "set/get_pending_operation round-trip mismatch (got: $GOT)"
    fi
else
    fail "session_state_set_pending_operation returned non-zero"
fi

# 6. the same round-trip holds byte-identically for a metacharacter-hostile
#    string, and no subshell runs as a side effect of writing it
MARKER="/tmp/test-apr-pwn-marker-$$"
rm -f "$MARKER"
HOSTILE="it's a \"test\" \`touch $MARKER\` \$(touch $MARKER) ; touch $MARKER"
if session_state_set_pending_operation "test-apr-round" "$HOSTILE"; then
    GOT_HOSTILE=$(session_state_get_pending_operation "test-apr-round")
    if [ "$GOT_HOSTILE" = "$HOSTILE" ] && [ ! -e "$MARKER" ]; then
        pass "set/get_pending_operation round-trips a metacharacter-hostile string byte-identically, no subshell runs"
    else
        fail "hostile round-trip failed (got: $GOT_HOSTILE)"
    fi
else
    fail "session_state_set_pending_operation returned non-zero for hostile input"
fi
rm -f "$MARKER"

# 7. clear_pending_operation leaves the column NULL; get returns empty; the
#    row itself and its status are untouched
if session_state_clear_pending_operation "test-apr-round"; then
    CLEARED=$(session_state_get_pending_operation "test-apr-round")
    STATUS_AFTER=$(session_state_read "test-apr-round")
    if [ -z "$CLEARED" ] && [ "$STATUS_AFTER" = "blocked" ]; then
        pass "clear_pending_operation leaves pending_operation NULL, status untouched"
    else
        fail "clear_pending_operation left cleared='$CLEARED' status='$STATUS_AFTER'"
    fi
else
    fail "session_state_clear_pending_operation returned non-zero"
fi

# 8. set_task_title round-trips through a fresh session_state_list_blocked read
if session_state_set_task_title "test-apr-round" "Fix the thing"; then
    BLOCKED_ROWS=$(session_state_list_blocked)
    if echo "$BLOCKED_ROWS" | grep -qF "test-apr-round${US}/tmp/test-apr-round-worktree${US}Fix the thing${US}"; then
        pass "set_task_title round-trips through session_state_list_blocked"
    else
        fail "set_task_title did not round-trip through list_blocked (got: $BLOCKED_ROWS)"
    fi
else
    fail "session_state_set_task_title returned non-zero"
fi

# 9. list_blocked returns only blocked rows, one per line, five \x1f-separated fields
session_state_write "test-apr-running" "/tmp/test-apr-running-worktree" "running" >/dev/null
BLOCKED_ROWS2=$(session_state_list_blocked)
if echo "$BLOCKED_ROWS2" | grep -q "test-apr-round" && ! echo "$BLOCKED_ROWS2" | grep -q "test-apr-running"; then
    FIELD_COUNT=$(echo "$BLOCKED_ROWS2" | grep "test-apr-round" | awk -F"$US" '{print NF}')
    if [ "$FIELD_COUNT" = "5" ]; then
        pass "list_blocked returns only blocked rows with five \\x1f-separated fields"
    else
        fail "list_blocked row has $FIELD_COUNT fields, expected 5"
    fi
else
    fail "list_blocked returned the wrong row set (got: $BLOCKED_ROWS2)"
fi

# 9b. regression: pending_operation/task_title containing a literal '|' must
#     not shift fields -- this is exactly what broke under the old
#     pipe-separated format (shell command text and untrusted Notion titles
#     routinely contain '|')
session_state_set_pending_operation "test-apr-round" "git log --oneline | head -5" >/dev/null
session_state_set_task_title "test-apr-round" "Fix the | thing" >/dev/null
PIPE_ROW=$(session_state_list_blocked | grep "test-apr-round")
PIPE_FIELD_COUNT=$(echo "$PIPE_ROW" | awk -F"$US" '{print NF}')
PIPE_FIELD5=$(echo "$PIPE_ROW" | awk -F"$US" '{print $5}')
if [ "$PIPE_FIELD_COUNT" = "5" ] && echo "$PIPE_FIELD5" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    pass "list_blocked survives literal '|' in pending_operation and task_title"
else
    fail "list_blocked mis-split a row containing '|' (fields=$PIPE_FIELD_COUNT field5='$PIPE_FIELD5')"
fi

# 10. agent_id_for_worktree resolves a known path and returns empty for an unknown one
FOUND_AGENT=$(session_state_agent_id_for_worktree "/tmp/test-apr-round-worktree")
UNKNOWN_AGENT=$(session_state_agent_id_for_worktree "/tmp/test-apr-does-not-exist")
if [ "$FOUND_AGENT" = "test-apr-round" ] && [ -z "$UNKNOWN_AGENT" ]; then
    pass "agent_id_for_worktree resolves a known path and returns empty for an unknown one"
else
    fail "agent_id_for_worktree mismatch (found='$FOUND_AGENT' unknown='$UNKNOWN_AGENT')"
fi

# 11. bash 3.2 source-time parse check
if /bin/bash -c "source '$SCRIPT_DIR/../orchestration/lib/session-state.sh'"; then
    pass "session-state.sh sources cleanly under /bin/bash"
else
    fail "session-state.sh failed to source under /bin/bash"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
