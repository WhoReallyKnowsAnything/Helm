#!/bin/bash
# test/test-session-files.sh
# Headless sessions (phase 1, plan 1): the inbox/out-log columns, the setter
# and (later tasks) the session-file helpers. Disposable fixture repo only.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT="$REPO_DIR/orchestration/init/init-state-store.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_MAIN=""
cleanup() { [ -n "$TMP_MAIN" ] && rm -rf "$TMP_MAIN"; }
trap cleanup EXIT

TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "Test"
echo "root" > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" commit -q -m "initial"
DB="$TMP_MAIN/.claude/session-state.db"

cols() { sqlite3 "$1" "PRAGMA table_info(sessions);" | cut -d'|' -f2; }

# --- Task 1: columns ---
"$INIT" "$TMP_MAIN" >/dev/null 2>&1
if cols "$DB" | grep -qx inbox_path && cols "$DB" | grep -qx out_path; then
    pass "fresh database has inbox_path and out_path"
else
    fail "fresh database lacks the new columns"
fi

# Database created before this change: pre-change schema, no new columns.
OLD="$TMP_MAIN/old"
mkdir -p "$OLD"
git -C "$OLD" init -q -b main
mkdir -p "$OLD/.claude"
sqlite3 "$OLD/.claude/session-state.db" "CREATE TABLE sessions (agent_id TEXT PRIMARY KEY, worktree_path TEXT NOT NULL UNIQUE, status TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, pid INTEGER, last_activity_at DATETIME, iterm_session_id TEXT, model TEXT);"
"$INIT" "$OLD" >/dev/null 2>&1
if cols "$OLD/.claude/session-state.db" | grep -qx inbox_path && cols "$OLD/.claude/session-state.db" | grep -qx out_path; then
    pass "pre-change database gains the new columns"
else
    fail "pre-change database lacks the new columns"
fi

if "$INIT" "$TMP_MAIN" >/dev/null 2>&1 && "$INIT" "$TMP_MAIN" >/dev/null 2>&1; then
    pass "running init twice succeeds"
else
    fail "second init failed"
fi

# --- Task 1: setter ---
cd "$TMP_MAIN" || exit 1
# shellcheck disable=SC1090
source "$REPO_DIR/orchestration/lib/session-state.sh"
session_state_write alpha "$TMP_MAIN/wt-alpha" running >/dev/null 2>&1
sqlite3 "$DB" "UPDATE sessions SET model='opus', updated_at='2000-01-01 00:00:00' WHERE agent_id='alpha';"
BEFORE=$(sqlite3 "$DB" "SELECT status||'|'||updated_at||'|'||model FROM sessions WHERE agent_id='alpha';")
IN="/p/it's/inbox.jsonl"
OUT="/p/it's/out.jsonl"
session_state_set_session_files alpha "$IN" "$OUT"
AFTER=$(sqlite3 "$DB" "SELECT status||'|'||updated_at||'|'||model FROM sessions WHERE agent_id='alpha';")
GOT=$(sqlite3 "$DB" "SELECT inbox_path||'#'||out_path FROM sessions WHERE agent_id='alpha';")
[ "$BEFORE" = "$AFTER" ] && pass "setter leaves status, updated_at and model unchanged" || fail "setter changed other columns: $BEFORE vs $AFTER"
[ "$GOT" = "$IN#$OUT" ] && pass "path with a single quote round-trips" || fail "round trip: $GOT"

# Missing column -> return 1 with Error line.
BAD="$TMP_MAIN/bad"
mkdir -p "$BAD/.claude"
git -C "$BAD" init -q -b main
sqlite3 "$BAD/.claude/session-state.db" "CREATE TABLE sessions (agent_id TEXT PRIMARY KEY, worktree_path TEXT, status TEXT);"
ERR=$(cd "$BAD" && session_state_set_session_files x a b 2>&1 >/dev/null); RC=$?
if [ $RC -ne 0 ] && echo "$ERR" | grep -q '^Error:'; then pass "setter errors when a column is missing"; else fail "missing column: rc=$RC err=$ERR"; fi

# --- Task 2: helpers ---
R="$TMP_MAIN"
D="$R/.claude/sessions/h1"
P=$(session_files_paths "$R" h1)
[ "$P" = "$D
$D/inbox.jsonl
$D/out.jsonl" ] && pass "paths prints dir, inbox, out" || fail "paths: $P"

mkdir -p "$D" && printf 'old\n' > "$D/out.jsonl"
session_files_create "$R" h1
if [ -f "$D/inbox.jsonl" ] && [ "$(cat "$D/out.jsonl")" = old ]; then pass "create makes both files and keeps out-log bytes"; else fail "create"; fi

printf 'line\n' > "$D/inbox.jsonl"
session_files_empty_inbox "$R" h1
if [ ! -s "$D/inbox.jsonl" ] && [ -f "$D/inbox.jsonl" ] && [ "$(cat "$D/out.jsonl")" = old ]; then pass "empty-inbox zeroes inbox, out untouched"; else fail "empty-inbox"; fi

session_files_delete "$R" h1
[ ! -e "$D" ] && pass "delete removes both files and the directory" || fail "delete left $D"

mkdir -p "$D" && touch "$D/inbox.jsonl" "$D/out.jsonl" "$D/other"
session_files_delete "$R" h1
if [ ! -e "$D/inbox.jsonl" ] && [ ! -e "$D/out.jsonl" ] && [ -f "$D/other" ]; then pass "delete keeps directory with an unrelated file"; else fail "delete unrelated"; fi

mkdir -p "$R/.claude/sessions" && touch "$R/.claude/inbox.jsonl" "$R/.claude/out.jsonl" "$R/inbox.jsonl"
for L in .. . a/b ""; do
    OK=1
    session_files_paths "$R" "$L" >/dev/null 2>&1 && OK=0
    session_files_create "$R" "$L" >/dev/null 2>&1 && OK=0
    session_files_empty_inbox "$R" "$L" >/dev/null 2>&1 && OK=0
    session_files_delete "$R" "$L" >/dev/null 2>&1 && OK=0
    [ $OK -eq 1 ] && pass "label '$L' refused by every helper" || fail "label '$L' accepted"
done
if [ -f "$R/.claude/inbox.jsonl" ] && [ -f "$R/.claude/out.jsonl" ] && [ -f "$R/inbox.jsonl" ]; then pass "no file outside .claude/sessions touched"; else fail "outside file removed"; fi

# --- Task 4: dispatch creates the files, stores the paths; undo deletes them ---
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
STUB_BIN=$(mktemp -d)
trap 'rm -rf "$STUB_BIN"; cleanup' EXIT
export ORCH_PROJECT_ROOT="$TMP_MAIN" STUB_RELEASE_DIR="$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'EOF'
#!/bin/bash
case "$1" in
    new-window)
        [ -n "${STUB_NW_REGISTER:-}" ] && echo ready > "$STUB_RELEASE_DIR/registered"
        if [ -n "${STUB_NW_RELEASE:-}" ]; then
            while [ ! -e "$STUB_NW_RELEASE" ]; do sleep 0.1; done
        fi
        [ -z "${STUB_TMUX_FAIL:-}" ] ;;
    has-session) exit 0 ;;
    *) exit 0 ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"
chmod +x "$STUB_BIN/tmux" "$STUB_BIN/claude"
disp() { (cd "$TMP_MAIN" && env "$@" PATH="$STUB_BIN:$PATH" "$DISPATCH" ${DLABEL:-x} "t" >/dev/null 2>&1); }
sql() { sqlite3 "$DB" "$1"; }
SD="$TMP_MAIN/.claude/sessions"

DLABEL=ok1 disp A=1; RC=$?
ROW=$(sql "SELECT inbox_path||'#'||out_path FROM sessions WHERE agent_id='ok1'")
if [ $RC -eq 0 ] && [ "$ROW" = "$SD/ok1/inbox.jsonl#$SD/ok1/out.jsonl" ] && [ -f "$SD/ok1/inbox.jsonl" ] && [ -f "$SD/ok1/out.jsonl" ] \
    && [ ! -e "$TMP_MAIN/.claude/worktrees/ok1/.claude/sessions" ]; then
    pass "dispatch stores both paths, creates both files outside the worktree"
else
    fail "dispatch files: rc=$RC row=$ROW"
fi

DLABEL=bad1 disp STUB_TMUX_FAIL=1; RC=$?
if [ $RC -ne 0 ] && [ "$(sql "SELECT status FROM sessions WHERE agent_id='bad1'")" = dead ] && [ ! -e "$SD/bad1" ]; then
    pass "window failure leaves no session files and a dead row"
else
    fail "window failure: rc=$RC ls=$(ls "$SD" | tr '\n' ' ')"
fi

rm -f "$STUB_BIN/registered"
HERE="$PWD"; cd "$TMP_MAIN"
STUB_NW_RELEASE="$STUB_BIN/rel" STUB_NW_REGISTER=1 PATH="$STUB_BIN:$PATH" \
    perl -e '$SIG{$_}="DEFAULT" for qw(INT TERM HUP); exec @ARGV' "$DISPATCH" sig1 t >/dev/null 2>&1 &
SPID=$!
cd "$HERE"
for _ in $(seq 1 100); do [ -e "$STUB_BIN/registered" ] && break; sleep 0.1; done
[ -f "$SD/sig1/inbox.jsonl" ] && SEEN=1 || SEEN=0
kill -s TERM "$SPID"; touch "$STUB_BIN/rel"; wait "$SPID"
if [ $SEEN -eq 1 ] && [ ! -e "$SD/sig1" ]; then pass "SIGTERM during dispatch removes the session files"; else fail "SIGTERM: seen=$SEEN ls=$(ls "$SD" | tr '\n' ' ')"; fi

# Re-dispatch of an existing label: inbox truncated, out log byte-identical.
printf 'old line\n' > "$SD/ok1/inbox.jsonl"; printf 'history\n' > "$SD/ok1/out.jsonl"
sql "UPDATE sessions SET status='dead' WHERE agent_id='ok1'"
git -C "$TMP_MAIN" worktree remove --force "$TMP_MAIN/.claude/worktrees/ok1" 2>/dev/null
git -C "$TMP_MAIN" branch -D session/ok1 >/dev/null 2>&1
DLABEL=ok1 disp A=1
if [ ! -s "$SD/ok1/inbox.jsonl" ] && [ "$(cat "$SD/ok1/out.jsonl")" = history ]; then
    pass "re-dispatch empties the inbox and keeps the out log"
else
    fail "re-dispatch: inbox=$(cat "$SD/ok1/inbox.jsonl") out=$(cat "$SD/ok1/out.jsonl")"
fi

# --- Task 6: --kill deletes only that label's files; a bad label changes nothing ---
for l in ka kb; do
    mkdir -p "$SD/$l"; printf 'in\n' > "$SD/$l/inbox.jsonl"; printf 'out\n' > "$SD/$l/out.jsonl"
done
(cd "$TMP_MAIN" && PATH="$STUB_BIN:$PATH" "$DISPATCH" --kill ka >/dev/null 2>&1); RC=$?
if [ $RC -eq 0 ] && [ ! -e "$SD/ka" ] && [ -f "$SD/kb/inbox.jsonl" ] && [ -f "$SD/kb/out.jsonl" ]; then
    pass "--kill removes that label's files and leaves the other's"
else
    fail "--kill ka: rc=$RC ls=$(ls "$SD" | tr '\n' ' ')"
fi
listing() { (cd "$TMP_MAIN" && find .claude -path .claude/session-state.db\* -prune -o -print | sort; git branch --list | sort; sqlite3 "$DB" "SELECT agent_id, status FROM sessions ORDER BY agent_id"); }
mkdir -p "$TMP_MAIN/.claude/x"; touch "$TMP_MAIN/.claude/x/keep"
BEFORE_L=$(listing)
(cd "$TMP_MAIN" && PATH="$STUB_BIN:$PATH" "$DISPATCH" --kill ../x >/dev/null 2>&1); RC=$?
AFTER_L=$(listing)
if [ $RC -ne 0 ] && [ "$BEFORE_L" = "$AFTER_L" ]; then
    pass "--kill ../x exits non-zero and changes nothing"
else
    fail "--kill ../x: rc=$RC"
fi

# --- Task 7: --attach is refused; no tab, no tmux call, no worker ---
LOGD=$(mktemp -d); LOGBIN=$(mktemp -d)
for c in osascript tmux; do printf '#!/bin/bash\necho "$0 $*" >> "%s/calls"\nexit 0\n' "$LOGD" > "$LOGBIN/$c"; chmod +x "$LOGBIN/$c"; done
BR_BEFORE=$(git -C "$TMP_MAIN" branch --list | sort)
ROWS_BEFORE=$(sqlite3 "$DB" "SELECT group_concat(agent_id) FROM (SELECT agent_id FROM sessions ORDER BY agent_id)")
ERR=$(cd "$TMP_MAIN" && PATH="$LOGBIN:$PATH" "$DISPATCH" --attach alpha 2>&1 >/dev/null); RC=$?
ATTACH_ROWS=$(sqlite3 "$DB" "SELECT group_concat(agent_id) FROM (SELECT agent_id FROM sessions ORDER BY agent_id)")
if [ $RC -ne 0 ] && [ ! -s "$LOGD/calls" ] && [ "$ATTACH_ROWS" = "$ROWS_BEFORE" ] \
   && [ "$BR_BEFORE" = "$(git -C "$TMP_MAIN" branch --list | sort)" ] \
   && ! git -C "$TMP_MAIN" branch --list 'session/attach*' | grep -q .; then
    pass "--attach alpha exits non-zero, calls neither osascript nor tmux, starts no worker"
else
    fail "--attach alpha: rc=$RC calls=$(cat "$LOGD/calls" 2>/dev/null) rows=$ATTACH_ROWS err=$ERR"
fi
rm -rf "$LOGD" "$LOGBIN"

echo "Passed: $PASS_COUNT Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
