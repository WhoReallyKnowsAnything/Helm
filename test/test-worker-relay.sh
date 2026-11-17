#!/bin/bash
# test/test-worker-relay.sh
# Exercises the worker relay: the five new sessions columns, the session-state
# event helpers, live_worker_agent in session-state.sh, the worker-relay.sh
# hook and the dispatch-task.sh --mark-done mode. Everything runs against
# disposable fixture repos, never the real state db.
# Plain bash, no framework.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT="$REPO_ROOT/orchestration/init/init-state-store.sh"
# shellcheck source=../orchestration/lib/session-state.sh
source "$REPO_ROOT/orchestration/lib/session-state.sh"

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

TMP_ROOT=$(mktemp -d)
new_tmp() { mktemp -d "$TMP_ROOT/d.XXXXXX"; }

cleanup() {
    cd / || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# A git repo with one commit. Prints its path.
new_repo() {
    local d
    d=$(new_tmp)
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "test"
    echo seed > "$d/seed.txt"
    git -C "$d" add seed.txt
    git -C "$d" commit -qm "seed"
    echo "$d"
}

NEW_COLS="last_event last_message claude_session_id model effort"

cols_of() { sqlite3 "$1/.claude/session-state.db" "PRAGMA table_info(sessions);" | cut -d'|' -f2; }

has_all_new_cols() {
    local cols c
    cols=$(cols_of "$1")
    for c in $NEW_COLS; do
        echo "$cols" | grep -qx "$c" || return 1
    done
}

# --- Task 1: the five new columns, by the guarded ALTER path ---

# 1. fresh database
R_FRESH=$(new_repo)
"$INIT" "$R_FRESH" >/dev/null 2>&1
if has_all_new_cols "$R_FRESH"; then
    pass "fresh db has last_event, last_message, claude_session_id, model, effort"
else
    fail "fresh db missing a new column (got: $(cols_of "$R_FRESH" | tr '\n' ' '))"
fi

# 2. db built from the old schema text (no pending_operation, no new columns)
R_OLD=$(new_repo)
mkdir -p "$R_OLD/.claude"
sqlite3 "$R_OLD/.claude/session-state.db" "
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
INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('old-row', '/tmp/old-row', 'running');"
"$INIT" "$R_OLD" >/dev/null 2>&1
if has_all_new_cols "$R_OLD"; then
    pass "old-schema db gains the five new columns through the ALTER path"
else
    fail "old-schema db missing a new column (got: $(cols_of "$R_OLD" | tr '\n' ' '))"
fi

# 3. a second run changes nothing, and no new status value exists
BEFORE=$(cols_of "$R_OLD")
"$INIT" "$R_OLD" >/dev/null 2>&1
RUN2=$?
AFTER=$(cols_of "$R_OLD")
if [ "$RUN2" -eq 0 ] && [ "$BEFORE" = "$AFTER" ]; then
    pass "second init run exits 0 and leaves the column list unchanged"
else
    fail "second init run changed the columns or failed (exit=$RUN2)"
fi
if sqlite3 "$R_FRESH/.claude/session-state.db" "SELECT sql FROM sqlite_master WHERE name='sessions';" |
    grep -q "CHECK(status IN ('running','blocked','done','merged','stalled','dead'))"; then
    pass "status CHECK list is unchanged"
else
    fail "status CHECK list changed"
fi

# 4. a lost ALTER race is not an error: simulate the loser by pre-adding the
# column between the PRAGMA check and the ALTER, using a sqlite3 shim on PATH
# that adds the column itself right before the first ALTER it is asked to run.
R_RACE=$(new_repo)
"$INIT" "$R_RACE" >/dev/null 2>&1
sqlite3 "$R_RACE/.claude/session-state.db" "ALTER TABLE sessions DROP COLUMN effort;" 2>/dev/null
SHIM=$(new_tmp)
REAL_SQLITE=$(command -v sqlite3)
cat > "$SHIM/sqlite3" <<EOF
#!/bin/bash
case "\$2" in
  "ALTER TABLE sessions ADD COLUMN effort TEXT;")
    "$REAL_SQLITE" "\$1" "\$2" >/dev/null 2>&1   # the winner's ALTER lands first
    ;;
esac
exec "$REAL_SQLITE" "\$@"
EOF
chmod +x "$SHIM/sqlite3"
PATH="$SHIM:$PATH" "$INIT" "$R_RACE" >/dev/null 2>&1
RACE_EXIT=$?
if [ "$RACE_EXIT" -eq 0 ] && has_all_new_cols "$R_RACE"; then
    pass "init treats a lost ALTER race (duplicate column) as success"
else
    fail "init failed on a lost ALTER race (exit=$RACE_EXIT)"
fi

# --- worker fixtures --------------------------------------------------------

OLD_UPDATED='2020-01-01 00:00:00'

# make_worker agent [status]: a repo with an initialised db, a linked worktree
# and one row for it. Sets W_REPO, W_WT (symlink-resolved) and W_DB. The row's
# updated_at is pinned to a past time so "unchanged" is a real check.
make_worker() {
    local agent="$1" status="${2:-running}" wt
    W_REPO=$(new_repo)
    "$INIT" "$W_REPO" >/dev/null 2>&1
    wt="$(new_tmp)/wt"
    git -C "$W_REPO" worktree add -q -b "br-$agent" "$wt"
    W_WT=$(git -C "$wt" rev-parse --show-toplevel)
    W_DB="$W_REPO/.claude/session-state.db"
    sqlite3 "$W_DB" "INSERT INTO sessions (agent_id, worktree_path, status, updated_at) VALUES ('$agent', '$W_WT', '$status', '$OLD_UPDATED');"
}

# q sql: query the current fixture db.
q() { sqlite3 "$W_DB" "$1"; }

# row agent: the whole relay-visible row, for before/after comparison.
row() { q "SELECT status, updated_at, IFNULL(last_event,''), IFNULL(last_message,''), IFNULL(last_activity_at,''), IFNULL(claude_session_id,'') FROM sessions WHERE agent_id='$1';"; }

# in_repo cmd...: run a function with the fixture repo as cwd, as the hooks do.
in_repo() { (cd "$W_REPO" && "$@"); }

# --- Task 2: session-state helpers ---

make_worker w1
in_repo session_state_record_event w1 start "hello"
if [ "$(q "SELECT last_event||'|'||last_message FROM sessions WHERE agent_id='w1'")" = "start|hello" ] &&
    [ -n "$(q "SELECT last_activity_at FROM sessions WHERE agent_id='w1'")" ]; then
    pass "record_event round-trips event, message and last_activity_at"
else
    fail "record_event round trip (row: $(row w1))"
fi
if [ "$(q "SELECT status||'|'||updated_at FROM sessions WHERE agent_id='w1'")" = "running|$OLD_UPDATED" ]; then
    pass "record_event leaves status and updated_at unchanged"
else
    fail "record_event touched status or updated_at (row: $(row w1))"
fi

LONG=$(printf "it's\nthe 'quoted' line\r\twith ESC\033[31m and "; head -c 500 /dev/zero | tr '\0' 'x')
in_repo session_state_record_event w1 commit "$LONG"
STORED=$(q "SELECT last_message FROM sessions WHERE agent_id='w1'")
if [ "${#STORED}" -eq 200 ] && [[ "$STORED" == "it's the 'quoted' line  with ESC[31m and "* ]]; then
    pass "message with quotes, newline, CR, tab, ESC and 500 chars is stored flattened and cut to 200"
else
    fail "message flattening (len=${#STORED}, got: $STORED)"
fi
if [ "$(q "SELECT count(*) FROM sessions WHERE last_message GLOB '*[^ -~]*'")" = "0" ]; then
    pass "stored message holds no control byte"
else
    fail "stored message still holds a control byte"
fi

in_repo session_state_record_event w1 idle "turn over" keep-done
if [ "$(q "SELECT last_event FROM sessions WHERE agent_id='w1'")" = "idle" ]; then
    pass "keep-done write replaces an event that is not done"
else
    fail "keep-done write did not apply to a commit row"
fi
in_repo session_state_record_event w1 done "finished"
BEFORE_ROW=$(row w1)
in_repo session_state_record_event w1 idle "later turn" keep-done
if [ "$(row w1)" = "$BEFORE_ROW" ] && [ "$(q "SELECT last_event FROM sessions WHERE agent_id='w1'")" = "done" ]; then
    pass "keep-done write leaves a done row exactly as it was"
else
    fail "keep-done write changed a done row (before: $BEFORE_ROW, after: $(row w1))"
fi
in_repo session_state_record_event w1 commit "new work"
if [ "$(q "SELECT last_event FROM sessions WHERE agent_id='w1'")" = "commit" ]; then
    pass "a plain write replaces done"
else
    fail "a plain write did not replace done"
fi

in_repo session_state_set_claude_session_id w1 "ab'cd-123"
in_repo session_state_set_model_effort w1 "claude-sonnet-5-5" "high"
if [ "$(q "SELECT claude_session_id||'|'||model||'|'||effort FROM sessions WHERE agent_id='w1'")" = "ab'cd-123|claude-sonnet-5-5|high" ] &&
    [ "$(q "SELECT status||'|'||updated_at FROM sessions WHERE agent_id='w1'")" = "running|$OLD_UPDATED" ]; then
    pass "set_claude_session_id and set_model_effort round-trip and leave status and updated_at alone"
else
    fail "session id / model / effort round trip (row: $(row w1))"
fi

in_repo session_state_record_event ghost start "x"
GHOST_EXIT=$?
if [ "$GHOST_EXIT" -eq 0 ] && [ "$(q "SELECT count(*) FROM sessions WHERE agent_id='ghost'")" = "0" ]; then
    pass "unknown agent id changes no row and returns 0"
else
    fail "unknown agent id (exit=$GHOST_EXIT)"
fi
in_repo session_state_record_event w1 bogus "x" 2>/dev/null
BOGUS_EXIT=$?
if [ "$BOGUS_EXIT" -ne 0 ]; then
    pass "unknown event name is refused"
else
    fail "unknown event name was accepted"
fi

# a db without the columns: Error: line on stderr, non-zero
R_NOCOL=$(new_repo)
mkdir -p "$R_NOCOL/.claude"
sqlite3 "$R_NOCOL/.claude/session-state.db" "
CREATE TABLE sessions (
    agent_id TEXT PRIMARY KEY, worktree_path TEXT NOT NULL UNIQUE, status TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, pid INTEGER, last_activity_at DATETIME, iterm_session_id TEXT);
INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('old-row', '/tmp/old-row', 'running');"
for helper in "session_state_record_event old-row start x" "session_state_set_claude_session_id old-row s1" "session_state_set_model_effort old-row m e"; do
    ERR=$(cd "$R_NOCOL" && $helper 2>&1 >/dev/null)
    CODE=$?
    if [ "$CODE" -ne 0 ] && [[ "$ERR" == *"Error:"* ]]; then
        pass "${helper%% *} on a db without the columns prints Error: and returns non-zero"
    else
        fail "${helper%% *} on a db without the columns (exit=$CODE, stderr: $ERR)"
    fi
done

# --- Task 3: live_worker_agent in session-state.sh ---

# lwa path [process-cwd]: source ONLY session-state.sh in a fresh shell.
lwa() {
    bash -c 'source "$1"; cd "$2" && live_worker_agent "$3"' _ \
        "$REPO_ROOT/orchestration/lib/session-state.sh" "${3:-$W_REPO}" "$2"
}

make_worker lw1
mkdir -p "$W_WT/sub/dir"
if [ "$(lwa x "$W_WT/sub/dir")" = "lw1" ]; then
    pass "live_worker_agent finds the worker from a subdirectory of its worktree"
else
    fail "live_worker_agent did not resolve a subdirectory (got: $(lwa x "$W_WT/sub/dir"))"
fi
if [ "$(lwa x "$W_WT/sub/dir" "$W_WT/sub")" = "lw1" ]; then
    pass "live_worker_agent works when the process cwd is inside the worktree"
else
    fail "live_worker_agent failed with process cwd inside the worktree"
fi
q "UPDATE sessions SET status='blocked' WHERE agent_id='lw1'"
[ "$(lwa x "$W_WT")" = "lw1" ] && pass "live_worker_agent counts a blocked worker as live" || fail "blocked worker not live"
q "UPDATE sessions SET status='stalled' WHERE agent_id='lw1'"
[ "$(lwa x "$W_WT")" = "lw1" ] && pass "live_worker_agent counts a stalled worker as live" || fail "stalled worker not live"
for dead in done dead merged; do
    q "UPDATE sessions SET status='$dead' WHERE agent_id='lw1'"
    if [ -z "$(lwa x "$W_WT")" ]; then
        pass "live_worker_agent returns no agent for a $dead row"
    else
        fail "live_worker_agent returned an agent for a $dead row"
    fi
done
q "UPDATE sessions SET status='running', agent_id='dashboard' WHERE agent_id='lw1'"
if [ -z "$(lwa x "$W_WT")" ]; then
    pass "live_worker_agent returns no agent for the dashboard row"
else
    fail "live_worker_agent returned the dashboard row"
fi
OUTSIDE=$(new_tmp)
if [ -z "$(lwa x "$OUTSIDE")" ] && [ -z "$(lwa x "")" ] && [ -z "$(lwa x "$OUTSIDE/missing")" ]; then
    pass "live_worker_agent returns no agent for a path outside any worktree, an empty path and a missing path"
else
    fail "live_worker_agent returned an agent for an outside path"
fi
R_NODB=$(new_repo)
if [ -z "$(lwa x "$R_NODB" "$R_NODB")" ] && [ ! -e "$R_NODB/.claude/session-state.db" ]; then
    pass "live_worker_agent returns none and creates no db when the state db is absent"
else
    fail "live_worker_agent created or used a missing db"
fi
if [ "$(grep -rn 'live_worker_agent()' "$REPO_ROOT/orchestration" | wc -l | tr -d ' ')" = "1" ]; then
    pass "live_worker_agent is defined exactly once under orchestration"
else
    fail "live_worker_agent is defined more than once"
fi

# --- Task 4: worker-relay.sh hook ---

HOOK="$REPO_ROOT/orchestration/hooks/worker-relay.sh"
SID_OK="7377925c-4b9b-4427-80cf-2a61f848f201"
HOOK_ERR="$TMP_ROOT/hook.err"

# mk_payload event cwd [extra-json]: a payload shaped like the spike dumps
# (SessionStart/Stop) and the live PostToolUse capture.
mk_payload() {
    node -e 'process.stdout.write(JSON.stringify(Object.assign({session_id:process.env.SID,cwd:process.argv[2],hook_event_name:process.argv[1],transcript_path:"/x/t.jsonl"},JSON.parse(process.argv[3]||"{}"))))' \
        "$1" "$2" "${3:-}"
}

# run_hook payload [process-cwd]: sets HOOK_OUT, HOOK_EXIT.
run_hook() {
    HOOK_OUT=$(cd "${2:-/}" && printf '%s' "$1" | bash "$HOOK" 2>"$HOOK_ERR")
    HOOK_EXIT=$?
}

# ev agent: last_event|last_message of the row.
ev() { q "SELECT IFNULL(last_event,'')||'|'||IFNULL(last_message,'') FROM sessions WHERE agent_id='$1'"; }
sid() { q "SELECT IFNULL(claude_session_id,'') FROM sessions WHERE agent_id='$1'"; }

check_silent() { # label
    if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
        pass "$1: exit 0, empty stdout"
    else
        fail "$1: exit=$HOOK_EXIT stdout=[$HOOK_OUT]"
    fi
}

make_worker h1
SID=$SID_OK
mkdir -p "$W_WT/sub"

run_hook "$(SID=$SID_OK mk_payload SessionStart "$W_WT" '{"source":"startup","model":"claude-sonnet-5-5"}')"
check_silent "SessionStart"
if [ "$(ev h1)" = "start|" ] && [ "$(sid h1)" = "$SID_OK" ] &&
    [ -n "$(q "SELECT last_activity_at FROM sessions WHERE agent_id='h1'")" ]; then
    pass "SessionStart sets claude_session_id, records start and sets last_activity_at"
else
    fail "SessionStart row: $(row h1)"
fi
if [ "$(q "SELECT status||'|'||updated_at FROM sessions WHERE agent_id='h1'")" = "running|$OLD_UPDATED" ]; then
    pass "hook leaves status and updated_at alone"
else
    fail "hook touched status or updated_at"
fi

run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT/sub" '{"last_assistant_message":"I fixed it.\nIt'"'"'s ready.","stop_hook_active":true}')"
check_silent "Stop from a subdirectory"
if [ "$(ev h1)" = "idle|I fixed it. It's ready." ]; then
    pass "Stop records idle with the last assistant message (subdirectory cwd resolves)"
else
    fail "Stop row: $(ev h1)"
fi

# a real commit, then PostToolUse for it
echo change > "$W_WT/f.txt"
git -C "$W_WT" add f.txt
git -C "$W_WT" commit -qm "feat(9-9): the real subject"
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"mcp__lean-ctx__ctx_shell","tool_input":{"command":"git commit -m x"},"tool_response":[{"type":"text","text":"ok"}]}')"
check_silent "PostToolUse ctx_shell git commit"
if [ "$(ev h1)" = "commit|feat(9-9): the real subject" ]; then
    pass "PostToolUse for git commit records commit with the commit subject"
else
    fail "commit row: $(ev h1)"
fi
q "UPDATE sessions SET last_event='idle', last_message='keep' WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"mcp__lean-ctx__ctx_shell","tool_input":{"command":"git status"}}')"
check_silent "PostToolUse git status"
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"Read","tool_input":{"command":"git commit"}}')"
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"git status && echo commit"}}')"
if [ "$(ev h1)" = "idle|keep" ]; then
    pass "git status, a non-shell tool and 'git status && echo commit' write nothing"
else
    fail "unrelated PostToolUse wrote: $(ev h1)"
fi

# busy: idle -> busy on UserPromptSubmit and PreToolUse, once, never over done
run_hook "$(SID=$SID_OK mk_payload UserPromptSubmit "$W_WT" '{"prompt":"go on"}')"
check_silent "UserPromptSubmit"
if [ "$(ev h1)" = "busy|" ]; then
    pass "UserPromptSubmit on an idle worker records busy"
else
    fail "UserPromptSubmit row: $(ev h1)"
fi
q "UPDATE sessions SET last_event='idle', last_message='keep' WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload PreToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
check_silent "PreToolUse"
if [ "$(ev h1)" = "busy|" ]; then
    pass "PreToolUse on an idle worker records busy"
else
    fail "PreToolUse row: $(ev h1)"
fi
q "UPDATE sessions SET last_event='commit', last_message='keep' WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload PreToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
if [ "$(ev h1)" = "commit|keep" ]; then
    pass "PreToolUse leaves a non-idle row alone (no write per tool call)"
else
    fail "PreToolUse wrote over non-idle: $(ev h1)"
fi
q "UPDATE sessions SET last_event='done', last_message='fin' WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload UserPromptSubmit "$W_WT" '{"prompt":"x"}')"
if [ "$(ev h1)" = "done|fin" ]; then
    pass "busy never overwrites done"
else
    fail "busy overwrote done: $(ev h1)"
fi
in_repo session_state_record_event h1 busy "" keep-done
if [ "$(ev h1)" = "done|fin" ]; then
    pass "record_event accepts busy and keep-done guards done"
else
    fail "record_event busy over done: $(ev h1)"
fi
q "UPDATE sessions SET last_event='idle', last_message='keep' WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"cd x && git commit -m \"a b\""}}')"
if [ "$(ev h1)" = "commit|feat(9-9): the real subject" ]; then
    pass "PostToolUse via Bash with a chained git commit records commit"
else
    fail "Bash commit row: $(ev h1)"
fi

# done survives Stop; a new commit replaces it
q "UPDATE sessions SET last_event='done', last_message='all done' WHERE agent_id='h1'"
BEFORE_DONE=$(row h1)
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"turn after done"}')"
if [ "$(row h1)" = "$BEFORE_DONE" ] && [ "$(ev h1)" = "done|all done" ]; then
    pass "Stop for a row already holding done leaves it done with its message"
else
    fail "Stop overwrote done: $(ev h1)"
fi
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"git commit -m y"}}')"
if [ "$(ev h1)" = "commit|feat(9-9): the real subject" ]; then
    pass "a commit after done sets commit"
else
    fail "commit after done: $(ev h1)"
fi

# the session id reaches `claude --resume` later: a non-token id is dropped
q "UPDATE sessions SET claude_session_id=NULL WHERE agent_id='h1'"
run_hook "$(SID='x; touch /tmp/pwned' mk_payload SessionStart "$W_WT" '{"source":"resume"}')"
if [ -z "$(sid h1)" ] && [ "$(ev h1)" = "start|" ]; then
    pass "a session id with shell characters is not stored (start still recorded)"
else
    fail "unsafe session id stored: [$(sid h1)]"
fi

# control bytes in a Stop message never reach the row
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"a\u001b[2Jb\u0007c"}')"
if [ "$(ev h1)" = "idle|a[2Jbc" ]; then
    pass "ESC and BEL in a Stop message are dropped before storing"
else
    fail "control bytes stored: $(ev h1 | od -c | head -3)"
fi

# no live worker: nothing written, still silent
snap() { q "SELECT agent_id, status, IFNULL(last_event,''), IFNULL(last_message,''), IFNULL(claude_session_id,'') FROM sessions ORDER BY agent_id"; }
q "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('dashboard', '$W_REPO', 'running')"
BEFORE_SNAP=$(snap)
run_hook "$(SID=$SID_OK mk_payload SessionStart "$W_REPO")"
check_silent "dashboard row"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_REPO" '{"last_assistant_message":"x"}')"
OUT_DIR=$(new_tmp)
run_hook "$(SID=$SID_OK mk_payload SessionStart "$OUT_DIR")"
check_silent "path outside any worktree"
run_hook "$(SID=$SID_OK mk_payload SessionStart "$OUT_DIR/missing")"
run_hook "$(SID=$SID_OK mk_payload SessionStart "relative/path")"
run_hook "$(SID=$SID_OK mk_payload SessionStart "")"
run_hook '{"hook_event_name":"SessionStart"}'
for st in done dead merged; do
    q "UPDATE sessions SET status='$st' WHERE agent_id='h1'"
    BEFORE_SNAP2=$(snap)
    run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"zzz"}')"
    run_hook "$(SID=$SID_OK mk_payload SessionStart "$W_WT")"
    [ "$(snap)" = "$BEFORE_SNAP2" ] && pass "a $st row: hook writes nothing" || fail "hook wrote to a $st row"
done
if [ "$(snap | grep -c '^dashboard')" = "1" ] && [ "$(snap | grep '^dashboard')" = "dashboard|running|||" ]; then
    pass "dashboard row, outside, missing, relative, empty and no-cwd payloads write nothing"
else
    fail "a non-worker payload wrote: $(snap)"
fi

# garbage and unknown events
run_hook 'not json'
check_silent "garbage on stdin"
run_hook ''
check_silent "empty stdin"
q "UPDATE sessions SET status='running', last_event=NULL, last_message=NULL WHERE agent_id='h1'"
run_hook "$(SID=$SID_OK mk_payload Notification "$W_WT" '{"message":"m"}')"
check_silent "unknown event"
[ "$(ev h1)" = "|" ] && pass "an event the hook does not handle writes nothing" || fail "unknown event wrote: $(ev h1)"

# stdout stays empty and exit stays 0 on a db without the columns
make_worker h2
sqlite3 "$W_DB" "ALTER TABLE sessions DROP COLUMN last_event;"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"x"}')"
check_silent "missing column"
if grep -q 'Error:' "$HOOK_ERR"; then
    pass "a missing column goes to stderr as an Error: line"
else
    fail "missing column was swallowed (stderr: $(cat "$HOOK_ERR"))"
fi

# --- Stop nudge: a worker with committed work, a clean tree and no done event is blocked once ---

check_block() { # label
    if [ "$HOOK_EXIT" -eq 0 ] && printf '%s' "$HOOK_OUT" | node -e '
        let d=""; process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{ try{ const o=JSON.parse(d); process.exit(o.decision==="block" && o.reason.includes("--mark-done "+process.argv[1]) ? 0 : 1) }catch{ process.exit(1) } });
      ' "$1"; then
        pass "Stop nudge: exit 0, one JSON object, decision=block, reason names $1"
    else
        fail "Stop nudge: exit=$HOOK_EXIT stdout=[$HOOK_OUT]"
    fi
}

make_worker nz1
echo work > "$W_WT/nz.txt"
git -C "$W_WT" add nz.txt
git -C "$W_WT" commit -qm "feat(9-9): nudge work"

run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done","stop_hook_active":false}')"
check_block nz1

run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done","stop_hook_active":true}')"
check_silent "Stop with stop_hook_active true"

echo dirty > "$W_WT/untracked.txt"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done"}')"
check_silent "Stop with a dirty tree"
rm "$W_WT/untracked.txt"

q "UPDATE sessions SET last_event='done' WHERE agent_id='nz1'"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done"}')"
check_silent "Stop after the done event"

run_hook "$(SID=$SID_OK mk_payload Stop "$W_REPO" '{"last_assistant_message":"done"}')"
check_silent "Stop from a session that is not a worker"

check_start_nudge() { # label
    if [ "$HOOK_EXIT" -eq 0 ] && printf '%s' "$HOOK_OUT" | node -e '
        let d=""; process.stdin.on("data",c=>d+=c);
        process.stdin.on("end",()=>{ try{ const o=JSON.parse(d); process.exit(o.decision==="block" && o.reason.includes("do not wait for a") && !o.reason.includes("--mark-done") ? 0 : 1) }catch{ process.exit(1) } });
      '; then
        pass "$1: exit 0, one JSON object, decision=block, reason says do not wait for a go"
    else
        fail "$1: exit=$HOOK_EXIT stdout=[$HOOK_OUT]"
    fi
}

make_worker nz2
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done"}')"
check_start_nudge "0 commits ahead -> start nudge"

run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done","stop_hook_active":true}')"
check_silent "No start nudge with stop_hook_active true"

echo dirty > "$W_WT/untracked.txt"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done"}')"
check_silent "No start nudge with a dirty tree"
rm "$W_WT/untracked.txt"

q "UPDATE sessions SET last_event='done' WHERE agent_id='nz2'"
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"done"}')"
check_silent "No start nudge when last_event is done"

# --- Plan 8 Task 2: a resume prints the worker prompt, nothing else does ---

PROMPT="$REPO_ROOT/orchestration/prompts/worker-dependency-awareness.md"
make_worker r1
RSID="9a1b2c3d-0000-4000-8000-000000000001"
mkdir -p "$W_WT/vendor"
git -C "$W_WT" init -q "$W_WT/vendor/nested"
CTX_FILE="$TMP_ROOT/ctx.out"

run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT" '{"source":"resume"}')"
if [ "$HOOK_EXIT" -eq 0 ] && [ "$(printf '%s' "$HOOK_OUT" | jq -s 'length')" = "1" ] \
    && [ "$(printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]; then
    pass "resume for a live worker: exit 0 and exactly one JSON output with hookEventName SessionStart"
else
    fail "resume output: exit=$HOOK_EXIT out=[$(printf '%s' "$HOOK_OUT" | head -c 120)]"
fi
printf '%s' "$HOOK_OUT" | jq -j '.hookSpecificOutput.additionalContext' > "$CTX_FILE" 2>/dev/null
if cmp -s "$CTX_FILE" "$PROMPT"; then
    pass "the resume context equals worker-dependency-awareness.md byte for byte"
else
    fail "the resume context differs from the prompt file"
fi
if [ "$(ev r1)" = "start|" ] && [ "$(sid r1)" = "$RSID" ]; then
    pass "a resume still records start and the session id"
else
    fail "resume row: $(row r1)"
fi

for src in startup clear compact; do
    run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT" "{\"source\":\"$src\"}")"
    check_silent "SessionStart source $src"
done
run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT")"
check_silent "SessionStart with no source"
run_hook "$(SID=$RSID mk_payload Stop "$W_WT" '{"source":"resume","last_assistant_message":"x"}')"
check_silent "Stop carrying source resume"
run_hook "$(SID=$RSID mk_payload PostToolUse "$W_WT" '{"source":"resume","tool_name":"Bash","tool_input":{"command":"git commit -m z"}}')"
check_silent "PostToolUse carrying source resume"

# not a live worker: the dashboard row, a done row, a path outside any worktree
q "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('dashboard', '$W_REPO', 'running')"
run_hook "$(SID=$RSID mk_payload SessionStart "$W_REPO" '{"source":"resume"}')"
check_silent "resume for the dashboard row"
q "UPDATE sessions SET status='done' WHERE agent_id='r1'"
run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT" '{"source":"resume"}')"
check_silent "resume for a done row"
q "UPDATE sessions SET status='running' WHERE agent_id='r1'"
run_hook "$(SID=$RSID mk_payload SessionStart "$(new_tmp)" '{"source":"resume"}')"
check_silent "resume from a path outside any worktree"

# a worker whose cwd is inside a nested git repo is still found (walk the ancestors)
q "UPDATE sessions SET last_event=NULL WHERE agent_id='r1'"
run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT/vendor/nested" '{"source":"resume"}')"
if [ "$HOOK_EXIT" -eq 0 ] && printf '%s' "$HOOK_OUT" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null 2>&1 \
    && [ "$(ev r1)" = "start|" ]; then
    pass "a resume from inside a nested git repo of the worktree prints the prompt and records start"
else
    fail "nested-repo resume: exit=$HOOK_EXIT row=$(ev r1) out=[$(printf '%s' "$HOOK_OUT" | head -c 80)]"
fi
run_hook "$(SID=$RSID mk_payload Stop "$W_WT/vendor/nested" '{"last_assistant_message":"nested stop"}')"
[ "$(ev r1)" = "idle|nested stop" ] && pass "a Stop from inside a nested git repo records idle" || fail "nested Stop row: $(ev r1)"

# an unreadable prompt file: nothing on stdout, one stderr line, exit 0
ALT="$(new_tmp)/orchestration"
mkdir -p "$ALT/hooks" "$ALT/lib" "$ALT/prompts"
cp "$REPO_ROOT/orchestration/hooks/worker-relay.sh" "$ALT/hooks/"
cp "$REPO_ROOT"/orchestration/lib/*.sh "$ALT/lib/"
cp "$PROMPT" "$ALT/prompts/"
chmod 000 "$ALT/prompts/worker-dependency-awareness.md"
REAL_HOOK="$HOOK"; HOOK="$ALT/hooks/worker-relay.sh"
run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT" '{"source":"resume"}')"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_OUT" ] && [ "$(wc -l < "$HOOK_ERR" | tr -d ' ')" = "1" ] \
    && grep -q 'worker-relay: cannot read' "$HOOK_ERR"; then
    pass "an unreadable prompt file: empty stdout, one stderr line, exit 0"
else
    fail "unreadable prompt: exit=$HOOK_EXIT out=[$HOOK_OUT] err=[$(cat "$HOOK_ERR")]"
fi
chmod 644 "$ALT/prompts/worker-dependency-awareness.md"
rm "$ALT/prompts/worker-dependency-awareness.md"
run_hook "$(SID=$RSID mk_payload SessionStart "$W_WT" '{"source":"resume"}')"
if [ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_OUT" ] && grep -q 'worker-relay: cannot read' "$HOOK_ERR"; then
    pass "a missing prompt file: empty stdout, a stderr line, exit 0"
else
    fail "missing prompt: exit=$HOOK_EXIT out=[$HOOK_OUT] err=[$(cat "$HOOK_ERR")]"
fi
HOOK="$REAL_HOOK"

# the guide's SessionStart registration must not carry a matcher that excludes resume
GUIDE="$REPO_ROOT/docs/orchestrator/approval-relay-setup.md"
REG="$(awk '/Add one entry to each of/{f=1} f&&/^```json/{b=1;next} b&&/^```/{exit} b' "$GUIDE")"
if [ -n "$REG" ] && printf '%s' "$REG" | jq -e '(.matcher // "") as $m | $m == "" or ($m | test("resume"))' >/dev/null 2>&1; then
    pass "the guide's relay SessionStart registration has no matcher (or one that matches resume)"
else
    fail "the guide's relay SessionStart registration: [$REG]"
fi

# --- Task 6: dispatch-task.sh --mark-done ---


DISPATCH="$REPO_ROOT/orchestration/lib/dispatch-task.sh"
STUB_BIN=$(new_tmp)
STUB_LOG="$TMP_ROOT/stub.log"
: > "$STUB_LOG"
for stub in osascript tmux; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 0\n' "$stub" "$STUB_LOG" > "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
done

# mark_done dir args...: run the mode with dir as cwd; sets MD_EXIT, MD_ERR.
mark_done() {
    local dir="$1"; shift
    MD_ERR=$(cd "$dir" && PATH="$STUB_BIN:$PATH" bash "$DISPATCH" --mark-done "$@" 2>&1 >/dev/null)
    MD_EXIT=$?
}

make_worker md1
mkdir -p "$W_WT/deep/sub"
mark_done "$W_WT" md1
if [ "$MD_EXIT" -eq 0 ] && [ "$(ev md1)" = "done|" ] &&
    [ "$(q "SELECT status||'|'||updated_at FROM sessions WHERE agent_id='md1'")" = "running|$OLD_UPDATED" ]; then
    pass "--mark-done exits 0, records done, leaves status and updated_at alone"
else
    fail "--mark-done basic (exit=$MD_EXIT err=$MD_ERR row=$(row md1))"
fi
mark_done "$W_WT" md1 "all done"
if [ "$MD_EXIT" -eq 0 ] && [ "$(ev md1)" = "done|all done" ]; then
    pass "--mark-done with a message stores the message"
else
    fail "--mark-done message (exit=$MD_EXIT row=$(ev md1))"
fi

SID=$SID_OK
run_hook "$(SID=$SID_OK mk_payload Stop "$W_WT" '{"last_assistant_message":"final turn"}')"
if [ "$(ev md1)" = "done|all done" ]; then
    pass "a Stop payload after --mark-done leaves done"
else
    fail "Stop after --mark-done: $(ev md1)"
fi
run_hook "$(SID=$SID_OK mk_payload PostToolUse "$W_WT" '{"tool_name":"Bash","tool_input":{"command":"git commit -m z"}}')"
if [ "$(ev md1 | cut -d'|' -f1)" = "commit" ]; then
    pass "a git commit PostToolUse payload after --mark-done sets commit"
else
    fail "commit after --mark-done: $(ev md1)"
fi

# a worker that cd'd into a subdirectory: the label is still the worktree's
q "UPDATE sessions SET last_event='idle', last_message='before' WHERE agent_id='md1'"
mark_done "$W_WT/deep/sub" md1 "from a subdirectory"
if [ "$MD_EXIT" -eq 0 ] && [ "$(ev md1)" = "done|from a subdirectory" ]; then
    pass "--mark-done works from a subdirectory of the worktree"
else
    fail "--mark-done from subdirectory (exit=$MD_EXIT err=$MD_ERR)"
fi
q "UPDATE sessions SET last_event='idle', last_message='before' WHERE agent_id='md1'"
BEFORE_ROW=$(row md1)
mark_done "$W_WT/deep/sub" sub
if [ "$MD_EXIT" -eq 1 ] && [ "$(row md1)" = "$BEFORE_ROW" ] && [[ "$MD_ERR" == *"the label of this worktree is 'md1'"* ]]; then
    pass "basename of a subdirectory is refused, the error names the real label, nothing written"
else
    fail "subdirectory basename as label (exit=$MD_EXIT err=$MD_ERR)"
fi

# refusals: each exits 1 and changes no row
refuse() { # label description dir args...
    local desc="$1" dir="$2"; shift 2
    local snapshot
    snapshot=$(q "SELECT agent_id||status||IFNULL(last_event,'')||IFNULL(last_message,'')||updated_at FROM sessions ORDER BY agent_id")
    mark_done "$dir" "$@"
    if [ "$MD_EXIT" -eq 1 ] && [[ "$MD_ERR" == *"Error:"* ]] &&
        [ "$(q "SELECT agent_id||status||IFNULL(last_event,'')||IFNULL(last_message,'')||updated_at FROM sessions ORDER BY agent_id")" = "$snapshot" ]; then
        pass "--mark-done refuses $desc: exit 1, Error: line, no row changed"
    else
        fail "--mark-done $desc (exit=$MD_EXIT err=$MD_ERR)"
    fi
}
refuse "a label with a slash" "$W_WT" "md1/../x"
refuse "a label starting with a dash" "$W_WT" "-md1"
refuse "an empty label" "$W_WT"
refuse "an unknown label" "$W_WT" "nobody"
refuse "a label with a quote" "$W_WT" "md1' OR '1'='1"
q "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('other', '/tmp/other-wt', 'running')"
refuse "another live worker's label" "$W_WT" "other" "stolen"
for st in merged done dead; do
    q "UPDATE sessions SET status='$st' WHERE agent_id='md1'"
    refuse "a $st row" "$W_WT" md1
done
q "UPDATE sessions SET status='running' WHERE agent_id='md1'"
refuse "a directory outside any worktree" "$(new_tmp)" md1

for st in blocked stalled; do
    q "UPDATE sessions SET status='$st', last_event='idle' WHERE agent_id='md1'"
    mark_done "$W_WT" md1
    if [ "$MD_EXIT" -eq 0 ] && [ "$(ev md1 | cut -d'|' -f1)" = "done" ] && [ "$(q "SELECT status FROM sessions WHERE agent_id='md1'")" = "$st" ]; then
        pass "--mark-done accepts a $st worker and keeps its status"
    else
        fail "--mark-done on a $st worker (exit=$MD_EXIT err=$MD_ERR)"
    fi
done

# a db without the new columns
sqlite3 "$W_DB" "ALTER TABLE sessions DROP COLUMN last_event;"
q "UPDATE sessions SET status='running' WHERE agent_id='md1'"
mark_done "$W_WT" md1
if [ "$MD_EXIT" -eq 1 ] && [[ "$MD_ERR" == *"Error:"* ]]; then
    pass "--mark-done on a db without the new columns exits 1 with an Error: line"
else
    fail "--mark-done on an unmigrated db (exit=$MD_EXIT err=$MD_ERR)"
fi

if [ ! -s "$STUB_LOG" ]; then
    pass "stub osascript and tmux logged zero calls in every --mark-done case"
else
    fail "osascript/tmux were called: $(cat "$STUB_LOG")"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

[[ $FAIL_COUNT -eq 0 ]]
