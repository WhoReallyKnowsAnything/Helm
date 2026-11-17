#!/bin/bash
# test/test-worker-resume.sh
# dispatch-task.sh --resume (Phase 2, plan 8, Task 1, AC7): after the tmux server
# is gone, one command starts a window for each worker that D-15 names, with
# `claude --resume <id>` and the row's model and effort. Runs against an ISOLATED
# tmux server (TMUX_TMPDIR in a scratch directory, exported before the first
# tmux call) so `tmux kill-server` never touches the user's server. A stub
# `claude` first on PATH records its argument list and then sleeps.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# A short path: a tmux socket path has a length limit.
SCRATCH="$(mktemp -d /tmp/wres.XXXXXX)"
TMP_MAIN="$SCRATCH/proj"
STUB_BIN="$SCRATCH/bin"
ARGS_DIR="$SCRATCH/args"
export TMUX_TMPDIR="$SCRATCH/tmx"
mkdir -p "$TMP_MAIN" "$STUB_BIN" "$ARGS_DIR" "$TMUX_TMPDIR"
unset TMUX
SOCK="wres-$$"
export ORCH_TMUX_SOCKET="$SOCK"
t() { tmux -L "$SOCK" "$@"; }
cleanup() {
    t kill-server 2>/dev/null
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# The window command runs in the tmux server's environment, so the stubs are on
# PATH before the first tmux call starts the server.
cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/bash
[ "${1:-}" = update ] && exit 0
printf '%s\n' "$@" > "$STUB_ARGS_DIR/$(basename "$PWD")"
sleep 300
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/lean-ctx"
chmod +x "$STUB_BIN/claude" "$STUB_BIN/lean-ctx"
export STUB_ARGS_DIR="$ARGS_DIR"
export PATH="$STUB_BIN:$PATH"
export ORCH_PROJECT_ROOT="$TMP_MAIN"

git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "Test"
echo root > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" commit -q -m initial
"$REPO_DIR/orchestration/init/init-state-store.sh" "$TMP_MAIN" >/dev/null 2>&1
DB="$TMP_MAIN/.claude/session-state.db"
BASE="$(basename "$TMP_MAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
sql() { sqlite3 "$DB" "$1"; }

# worker label status: a worktree on session/<label> with one commit of its own
# (so the branch is not merged), and a row.
worker() {
    git -C "$TMP_MAIN" worktree add -q -b "session/$1" "$TMP_MAIN/.claude/worktrees/$1" main
    # a real file change: an empty commit leaves the tree as it was, and
    # branch_is_merged counts a no-op merge as merged
    echo "work $1" > "$TMP_MAIN/.claude/worktrees/$1/$1.txt"
    git -C "$TMP_MAIN/.claude/worktrees/$1" add "$1.txt"
    git -C "$TMP_MAIN/.claude/worktrees/$1" -c user.email=t@e.com -c user.name=T commit -q -m "work on $1"
    sql "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('$1', '$TMP_MAIN/.claude/worktrees/$1', '$2');"
}
worker alpha running
sql "UPDATE sessions SET claude_session_id='sid-alpha', model='opus', effort='high' WHERE agent_id='alpha';"
worker beta blocked
sql "UPDATE sessions SET claude_session_id='sid-beta' WHERE agent_id='beta';"
worker charlie running
sql "UPDATE sessions SET claude_session_id='sid-charlie' WHERE agent_id='charlie';"
git -C "$TMP_MAIN" merge -q --no-edit session/charlie
worker delta running
sql "UPDATE sessions SET claude_session_id='sid-delta' WHERE agent_id='delta';"
rm -rf "$TMP_MAIN/.claude/worktrees/delta"
worker echo1 running
worker echo2 running
sql "UPDATE sessions SET claude_session_id='' WHERE agent_id='echo2';"
worker foxtrot done
sql "UPDATE sessions SET claude_session_id='sid-foxtrot' WHERE agent_id='foxtrot';"
# golf: killed before its first commit, so its branch tip is the commit it was cut from
git -C "$TMP_MAIN" worktree add -q -b session/golf "$TMP_MAIN/.claude/worktrees/golf" main
sql "INSERT INTO sessions (agent_id, worktree_path, status, claude_session_id) VALUES ('golf', '$TMP_MAIN/.claude/worktrees/golf', 'running', 'sid-golf');"
sql "INSERT INTO sessions (agent_id, worktree_path, status, claude_session_id) VALUES ('dashboard', '$TMP_MAIN', 'running', 'sid-dash');"
[ "$(sql "SELECT count(*) FROM sessions WHERE agent_id='echo1' AND claude_session_id IS NULL;")" = 1 ] \
    && pass "fixture: echo1 has a NULL session id" || fail "fixture: echo1 session id is not NULL"

# The reboot: every window and the tmux server go away; the base session returns.
t new-session -d -s "$BASE" -n shell "sleep 300"
t new-window -t "$BASE" -n alpha "sleep 300"
t kill-server 2>/dev/null
t new-session -d -s "$BASE" -n shell "sleep 300"

BEFORE="$(sql "SELECT agent_id||':'||status||':'||COALESCE(claude_session_id,'NULL')||':'||COALESCE(model,'')||':'||COALESCE(effort,'') FROM sessions ORDER BY agent_id;")"
SF="$TMP_MAIN/.claude/sessions"
for l in alpha charlie; do
    mkdir -p "$SF/$l"; printf 'old line\n' > "$SF/$l/inbox.jsonl"; printf 'history-%s\n' "$l" > "$SF/$l/out.jsonl"
done
OUT="$(cd "$TMP_MAIN" && bash "$DISPATCH" --resume 2>&1)"; RC=$?
echo "$OUT" | sed 's/^/    | /'
[ "$RC" = 0 ] && pass "--resume exits 0 though it skipped rows" || fail "--resume exited $RC"

for l in alpha beta golf; do
    echo "$OUT" | grep -qxF "resumed $l" && pass "$l: resumed" || fail "$l: no 'resumed $l' line"
done
for l in charlie delta echo1 echo2 foxtrot dashboard; do
    echo "$OUT" | grep -qE "^skipped $l: ." && pass "$l: skipped with a reason" || fail "$l: no skipped line with a reason"
done
echo "$OUT" | grep -c '^resumed ' | grep -qx 3 && pass "exactly 3 resumed lines" || fail "resumed line count is not 3"
for l in echo1 echo2; do
    echo "$OUT" | grep -qE "^skipped $l: .*session ID" && pass "$l: reason names the missing session ID" || fail "$l: reason does not name the session ID"
done

# Windows start asynchronously; wait up to 10 s for both argument files.
for _ in $(seq 1 50); do
    [ -f "$ARGS_DIR/alpha" ] && [ -f "$ARGS_DIR/beta" ] && [ -f "$ARGS_DIR/golf" ] && break
    sleep 0.2
done
WINS="$(t list-windows -t "=$BASE" -F '#{window_name}' | sort | tr '\n' ' ')"
[ "$WINS" = "alpha beta golf shell " ] && pass "windows: alpha, beta and golf only (plus the base shell)" || fail "windows are: $WINS"
[ ! -e "$ARGS_DIR/echo1" ] && [ ! -e "$ARGS_DIR/echo2" ] \
    && pass "claude never started for echo1 or echo2" || fail "claude started for a row with no session id"
[ ! -e "$ARGS_DIR/charlie" ] && [ ! -e "$ARGS_DIR/delta" ] && [ ! -e "$ARGS_DIR/foxtrot" ] \
    && pass "claude never started for merged, missing or done rows" || fail "claude started for an ineligible row"

args_of() { tr '\n' ' ' < "$ARGS_DIR/$1" 2>/dev/null; }
A="$(args_of alpha)"; B="$(args_of beta)"
for want in "--resume sid-alpha" "--model opus" "--effort high" "--permission-mode auto" "--permission-prompt-tool stdio" "--name alpha"; do
    case "$A " in *"$want "*) pass "alpha args contain: $want" ;; *) fail "alpha args lack '$want': $A" ;; esac
done
case "$A" in *"--permission-prompt-tool stdio"*"--permission-prompt-tool stdio"*) fail "alpha args hold the stdio flag twice: $A" ;; *) pass "alpha args hold the stdio flag once" ;; esac
for want in "--resume sid-beta" "--model sonnet[1m]" "--permission-mode auto" "--permission-prompt-tool stdio" "--name beta"; do
    case "$B " in *"$want "*) pass "beta args contain: $want" ;; *) fail "beta args lack '$want': $B" ;; esac
done
case "$B" in *--effort*) fail "beta args hold --effort: $B" ;; *) pass "beta args hold no --effort" ;; esac

# Headless files (phase 1): resume empties the inbox, keeps the out log, stores the paths.
for want in "-p" "--input-format stream-json" "--output-format stream-json"; do
    case "$A " in *"$want "*) pass "alpha args contain: $want" ;; *) fail "alpha args lack '$want': $A" ;; esac
done
if [ -f "$SF/alpha/inbox.jsonl" ] && [ ! -s "$SF/alpha/inbox.jsonl" ] && [ "$(cat "$SF/alpha/out.jsonl")" = "history-alpha" ]; then
    pass "resumed alpha: inbox empty, out log keeps its bytes"
else
    fail "alpha files: inbox=$(cat "$SF/alpha/inbox.jsonl" 2>&1) out=$(cat "$SF/alpha/out.jsonl" 2>&1)"
fi
[ "$(sql "SELECT inbox_path||'#'||out_path FROM sessions WHERE agent_id='alpha'")" = "$SF/alpha/inbox.jsonl#$SF/alpha/out.jsonl" ] \
    && pass "resumed alpha: row holds both paths" || fail "alpha row paths: $(sql "SELECT inbox_path, out_path FROM sessions WHERE agent_id='alpha'")"
if [ "$(cat "$SF/charlie/inbox.jsonl")" = "old line" ] && [ "$(cat "$SF/charlie/out.jsonl")" = "history-charlie" ] \
    && [ -z "$(sql "SELECT inbox_path FROM sessions WHERE agent_id='charlie'")" ]; then
    pass "skipped charlie: files and row untouched"
else
    fail "skipped charlie was touched"
fi

AFTER="$(sql "SELECT agent_id||':'||status||':'||COALESCE(claude_session_id,'NULL')||':'||COALESCE(model,'')||':'||COALESCE(effort,'') FROM sessions ORDER BY agent_id;")"
[ "$BEFORE" = "$AFTER" ] && pass "--resume changed no row" || fail "--resume changed a row"

OUT2="$(cd "$TMP_MAIN" && bash "$DISPATCH" --resume 2>&1)"; RC2=$?
[ "$RC2" = 0 ] && echo "$OUT2" | grep -qE '^skipped alpha: .*window' && echo "$OUT2" | grep -qE '^skipped beta: .*window' \
    && ! echo "$OUT2" | grep -q '^resumed ' \
    && pass "second run: alpha and beta skipped because the window exists" || fail "second run output: $OUT2"

# The worker-relay hook fails open when the orchestrator root's lib or prompt is
# missing, so --resume must say so. The normal runs above printed no such warning.
echo "$OUT" | grep -q 'gets no worker prompt' && fail "normal resume printed a hook-library warning" \
    || pass "normal resume prints no hook-library warning"
mkdir -p "$SCRATCH/emptyorch"
printf '%s\n' "$SCRATCH/emptyorch" > "$TMP_MAIN/.claude/orchestrator-root"
t kill-window -t "=$BASE:=alpha" 2>/dev/null
OUT4="$(cd "$TMP_MAIN" && bash "$DISPATCH" --resume 2>&1)"; RC4=$?
[ "$RC4" = 0 ] && echo "$OUT4" | grep -qxF "resumed alpha" \
    && echo "$OUT4" | grep -q "Warning: resumed worker 'alpha' gets no worker prompt.*orchestration/lib/session-state.sh" \
    && pass "missing hook library: alpha still resumed, with a warning naming the file" || fail "missing hook library output: rc=$RC4 $OUT4"
rm -f "$TMP_MAIN/.claude/orchestrator-root"

t kill-server 2>/dev/null
OUT3="$(cd "$TMP_MAIN" && bash "$DISPATCH" --resume 2>&1)"; RC3=$?
[ "$RC3" = 1 ] && echo "$OUT3" | grep -q 'launch-claude.sh' \
    && pass "no base session: exit 1 with the launch-claude.sh instruction" || fail "no base session: rc=$RC3 out=$OUT3"
[ -z "$(t list-sessions 2>/dev/null)" ] && pass "--resume did not create the base session" || fail "--resume created a tmux session"

echo ""
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
