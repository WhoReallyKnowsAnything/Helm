#!/bin/bash
# test/test-real-claude-worker.sh
# Real-claude proof for headless workers (phase 1, plan 2, task 4: AC1, AC3, AC4).
# Skips unless ORCH_REAL_CLAUDE=1. Uses a fixture repo, a PRIVATE tmux socket
# (ORCH_TMUX_SOCKET for the scripts, t() = tmux -L for direct calls), haiku, and
# the real claude on PATH. Never touches the default tmux server. Gate holds are
# only read through lib/gate-hold.sh and never answered.

set -u
if [ "${ORCH_REAL_CLAUDE:-}" != 1 ]; then echo "SKIP: set ORCH_REAL_CLAUDE=1 to run real claude"; exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
command -v claude >/dev/null && command -v tmux >/dev/null && command -v jq >/dev/null && command -v sqlite3 >/dev/null \
    || { echo "FAIL: claude, tmux, jq and sqlite3 are required"; exit 1; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/rcw.XXXXXX)" || exit 1
SOCK="rcw-$$"
export ORCH_TMUX_SOCKET="$SOCK"
unset TMUX
t() { tmux -L "$SOCK" "$@"; }
SAMPLER=""
cleanup() {
    [ -n "$SAMPLER" ] && kill "$SAMPLER" 2>/dev/null
    ( cd "$FIX" 2>/dev/null && bash "$DISPATCH" --kill "$LABEL" >/dev/null 2>&1 )
    t kill-server 2>/dev/null
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# shellcheck source=../orchestration/lib/stream-json.sh
source "$REPO_DIR/orchestration/lib/stream-json.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"
# shellcheck source=../orchestration/lib/gate-hold.sh
source "$REPO_DIR/orchestration/lib/gate-hold.sh"

LABEL="rcw-worker"
FIX="$(cd "$SCRATCH" && mkdir -p proj && cd proj && pwd -P)" # symlink-resolved: the hook sees the real path, the row must hold it
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name Test
echo root > "$FIX/README.md"
git -C "$FIX" add README.md && git -C "$FIX" commit -q -m init
"$REPO_DIR/orchestration/init/init-state-store.sh" "$FIX" >/dev/null 2>&1
export ORCH_PROJECT_ROOT="$FIX"
BASE="$(tmux_base_session_name "$FIX")"
t new-session -d -s "$BASE" -n dashboard "sleep 1800"

DB="$FIX/.claude/session-state.db"
row() { sqlite3 "$DB" "SELECT $1 FROM sessions WHERE agent_id = '$LABEL';" 2>/dev/null; }
INBOX="$FIX/.claude/sessions/$LABEL/inbox.jsonl"
OUT="$FIX/.claude/sessions/$LABEL/out.jsonl"
wait_for() { # seconds cmd...
    local n=$(($1 * 2)) i; shift
    for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.5; done
    return 1
}
worker_pid() { ps -wwAo pid=,args= | grep -F -- "--name $LABEL" | grep -F -- 'stream-json' | grep -v grep | awk 'NR==1{print $1}'; }
has_sid() { [ -n "$(row claude_session_id)" ]; }
result_count() { jq -c 'select(.type == "result")' "$OUT" 2>/dev/null | wc -l | tr -d ' '; }
# last_event sampler: every distinct value seen, in order
( prev=""; while :; do cur="$(row last_event)"; if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then echo "$cur" >>"$SCRATCH/events"; prev="$cur"; fi; sleep 0.2; done ) &
SAMPLER=$!

( cd "$FIX" && DISPATCH_MODEL=haiku bash "$DISPATCH" "$LABEL" "Real claude worker proof" ) >"$SCRATCH/dispatch.out" 2>&1 \
    || { fail "dispatch failed: $(head -c 300 "$SCRATCH/dispatch.out")"; exit 1; }
wait_for 60 has_sid || { fail "no claude_session_id on the row within 60s"; exit 1; }

# ---- AC1: command line and a result carrying the row's session id ------------
CMDLINE="$(ps -wwAo args= | grep -F -- "--name $LABEL" | grep -F stream-json | grep -v grep | head -1)"
ok=1
for f in ' -p ' '--input-format stream-json' '--output-format stream-json' \
    "--append-system-prompt-file $REPO_DIR/orchestration/prompts/worker-dependency-awareness.md"; do
    case "$CMDLINE" in *"$f"*) ;; *) ok=0; echo "  missing in ps: $f" ;; esac
done
[ $ok -eq 1 ] && pass "AC1: ps shows -p, stream-json in and out, and the worker prompt file" || fail "AC1: ps line: $CMDLINE"

stream_json_user_line "Remember: the code word is ZEBRA42. Marker INBOXLINE-ONE. Reply with PONG." >> "$INBOX"
wait_for 90 test "$(result_count)" -ge 1 || true
SID="$(row claude_session_id)"
if [ "$(jq -r 'select(.type == "result") | .session_id' "$OUT" 2>/dev/null | head -1)" = "$SID" ] && [ -n "$SID" ]; then
    pass "AC1: a result event carries the row's session id ($SID)"
else
    fail "AC1: no result with session id '$SID' in the out log"
fi

# ---- AC3: hooks record start, idle, busy; a git commit is held -----------------
stream_json_user_line "Create a file named hello.txt in your current directory with the text hi, then run: git add hello.txt && git commit -m 'add hello'" >> "$INBOX"
holds() { gate_hold_live_ids "$(gate_hold_dir "$FIX")" | grep -q .; }
wait_for 90 holds && pass "AC3: a git commit is held by the gate (live hold record)" || fail "AC3: no live gate hold within 90s"
ev="$(tr '\n' ' ' <"$SCRATCH/events")"
for e in start idle busy; do
    case " $ev" in *" $e "*) pass "AC3: last_event reached $e" ;; *) fail "AC3: last_event never $e (saw: $ev)" ;; esac
done

# ---- AC4: kill, window gone in 5s, --resume restores context -------------------
PID="$(worker_pid)"
[ -n "$PID" ] && kill "$PID" 2>/dev/null
gone() { ! t list-windows -t "=$BASE" -F '#{window_name}' 2>/dev/null | grep -qxF "$LABEL"; }
wait_for 5 gone && pass "AC4: the worker window is gone within 5s of the claude kill" || fail "AC4: window $LABEL still exists"
sleep 1
OFFSET="$(wc -l <"$OUT" | tr -d ' ')"
( cd "$FIX" && bash "$DISPATCH" --resume ) >"$SCRATCH/resume.out" 2>&1 || fail "AC4: --resume failed: $(head -c 300 "$SCRATCH/resume.out")"
sleep 3
stream_json_user_line "What was the code word I told you earlier? Answer with the word only." >> "$INBOX"
newout() { tail -n +"$((OFFSET + 1))" "$OUT"; }
answered() { newout | jq -e 'select(.type == "result")' >/dev/null 2>&1; }
wait_for 90 answered || true
if newout | jq -r 'select(.type == "result") | .result' 2>/dev/null | grep -q ZEBRA42; then
    pass "AC4: the resumed worker recalls the earlier fact"
else
    fail "AC4: no ZEBRA42 in the resumed answer: $(newout | jq -r 'select(.type == "result") | .result' 2>/dev/null | head -c 200)"
fi
if newout | grep -qF INBOXLINE-ONE; then fail "AC4: an earlier inbox line was read again after --resume"; else pass "AC4: no earlier inbox line repeated in the out log"; fi

[ $FAILS -eq 0 ]
