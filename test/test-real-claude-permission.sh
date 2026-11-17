#!/bin/bash
# test/test-real-claude-permission.sh
# Real-claude proof for the stdio permission path (phase 4, plan 1, task 5: AC5, AC3 machine half).
# Skips unless ORCH_REAL_CLAUDE=1. Fixture repos, a PRIVATE tmux socket
# (ORCH_TMUX_SOCKET for the scripts, t() = tmux -L for direct calls), haiku, and the
# real claude on PATH. Never touches the default tmux server. Gate holds are only read
# through lib/gate-hold.sh and never answered: the user decides the worker hold in the app.
# Part A (D-05): a worker's git commit raises the existing hold and no can_use_tool request.
# Part B (D-01, D-06): a non-worker headless session with --permission-prompt-tool stdio
# gets a can_use_tool request for a gated commit; allow lands it, deny blocks it.

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

SCRATCH="$(mktemp -d /tmp/rcp.XXXXXX)" || exit 1
SOCK="rcp-$$"
export ORCH_TMUX_SOCKET="$SOCK"
unset TMUX
t() { tmux -L "$SOCK" "$@"; }
DEFAULT_BEFORE="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort)"
LABEL="rcp-worker"
FIX=""
cleanup() {
    [ -n "$FIX" ] && ( cd "$FIX" 2>/dev/null && bash "$DISPATCH" --kill "$LABEL" >/dev/null 2>&1 )
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

wait_for() { # seconds cmd...
    local n=$(($1 * 2)) i; shift
    for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.5; done
    return 1
}
mkrepo() { # dir
    mkdir -p "$1" && git -C "$1" init -q -b main
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name Test
    echo root > "$1/README.md"
    git -C "$1" add README.md && git -C "$1" commit -q -m init
}

# ---- Part A: worker commit raises the hold, never a can_use_tool request ----------
FIX="$(cd "$SCRATCH" && mkdir -p proj && cd proj && pwd -P)"
mkrepo "$FIX"
"$REPO_DIR/orchestration/init/init-state-store.sh" "$FIX" >/dev/null 2>&1
export ORCH_PROJECT_ROOT="$FIX"
BASE="$(tmux_base_session_name "$FIX")"
t new-session -d -s "$BASE" -n dashboard "sleep 1800"
INBOX="$FIX/.claude/sessions/$LABEL/inbox.jsonl"
OUT="$FIX/.claude/sessions/$LABEL/out.jsonl"

( cd "$FIX" && DISPATCH_MODEL=haiku bash "$DISPATCH" "$LABEL" "Permission proof worker" ) >"$SCRATCH/dispatch.out" 2>&1 \
    || { fail "dispatch failed: $(head -c 300 "$SCRATCH/dispatch.out")"; exit 1; }
stream_json_user_line "Create a file named hello.txt in your current directory with the text hi, then run: git add hello.txt && git commit -m 'add hello' -m 'Context: permission proof fixture'" >> "$INBOX"
holds() { gate_hold_live_ids "$(gate_hold_dir "$FIX")" | grep -q .; }
if wait_for 120 holds; then
    pass "A: the worker's git commit raised a live gate hold record"
else
    fail "A: no live gate hold within 120s (a missing hold is a hard failure)"
    exit 1
fi
if jq -e 'select(.type == "control_request" and .request.subtype == "can_use_tool")' "$OUT" >"$SCRATCH/a-req" 2>/dev/null && [ -s "$SCRATCH/a-req" ]; then
    fail "A: the worker wrote a can_use_tool request, so its hold could be bypassed: $(head -c 600 "$SCRATCH/a-req")"
else
    pass "A: no can_use_tool request in the worker's out log for the commit"
fi
echo "HUMAN-VERIFY: decide the worker's commit hold in the app (AC5, --gate-decide path). This test never answers it."

# ---- Part B: stdio answer path in a non-worker headless session ------------------
FIXB="$SCRATCH/plain"
mkrepo "$FIXB"
BIN="$SCRATCH/b-in.jsonl"; BOUT="$SCRATCH/b-out.jsonl"
: > "$BIN"; : > "$BOUT"
CLAUDE_CMD="env -u ORCH_PROJECT_ROOT claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --model haiku --permission-mode default --permission-prompt-tool stdio"
t new-window -d -t "=$BASE" -n plain "cd '$FIXB' && $(tmux_headless_cmd "$BIN" "$BOUT" "$CLAUDE_CMD")"
sleep 5
req_count() { jq -c 'select(.type == "control_request" and .request.subtype == "can_use_tool")' "$BOUT" 2>/dev/null | wc -l | tr -d ' '; }
answer() { # nth mode: append the allow or deny line for the nth can_use_tool request
    local line
    line="$(jq -c "select(.type == \"control_request\" and .request.subtype == \"can_use_tool\")" "$BOUT" | sed -n "${1}p")"
    if [ "$2" = allow ]; then
        jq -nc --argjson r "$line" '{type:"control_response",response:{subtype:"success",request_id:$r.request_id,response:{behavior:"allow",updatedInput:$r.request.input}}}' >> "$BIN"
    else
        jq -nc --argjson r "$line" '{type:"control_response",response:{subtype:"success",request_id:$r.request_id,response:{behavior:"deny",message:"Denied from Helm."}}}' >> "$BIN"
    fi
}
has_req() { test "$(req_count)" -ge "$1"; }

stream_json_user_line "Run exactly this with a shell tool: echo one > one.txt && git add one.txt && git commit -m 'add one' -m 'Context: permission proof fixture'. Then reply done." >> "$BIN"
if wait_for 120 has_req 1; then
    pass "B: the plain session wrote a can_use_tool request with the stdio flag"
    answer 1 allow
    landed() { [ "$(git -C "$FIXB" rev-list --count HEAD 2>/dev/null)" = 2 ]; }
    wait_for 60 landed && pass "B: the allow answer landed the commit" || fail "B: no second commit after the allow answer"
else
    fail "B: no can_use_tool request within 120s"
fi
wait_for 60 test "$(jq -c 'select(.type == "result")' "$BOUT" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 || true

stream_json_user_line "Now run exactly: echo two > two.txt && git add two.txt && git commit -m 'add two' -m 'Context: permission proof fixture'. If it is denied, say so and stop." >> "$BIN"
if wait_for 120 has_req 2; then
    answer 2 deny
    denied() { grep -qF '"content":"Denied from Helm."' "$BOUT"; }
    wait_for 60 denied && pass "B: the deny answer reached the tool result with the fixed message" || fail "B: the fixed deny message is not in a tool result: $(jq -c 'select(.type == "user" or .type == "result") | {type, c: (.message.content // .result | tostring | .[0:300])}' "$BOUT" 2>/dev/null | tail -4)"
    [ "$(git -C "$FIXB" rev-list --count HEAD)" = 2 ] && pass "B: the denied commit did not run" || fail "B: a commit ran after the deny answer"
else
    fail "B: no second can_use_tool request within 120s"
fi

# ---- Private server is the only thing that dies; the default server is unchanged ---
t kill-server 2>/dev/null
if t ls >/dev/null 2>&1; then fail "private tmux socket $SOCK still has a server"; else pass "private tmux socket has no server after kill-server"; fi
DEFAULT_AFTER="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort)"
# Only this test's own session may not leak; other sessions on the default server change independently.
if printf '%s\n' "$DEFAULT_AFTER" | grep -qxF "$BASE" && ! printf '%s\n' "$DEFAULT_BEFORE" | grep -qxF "$BASE"; then
    fail "the test's session $BASE leaked onto the default tmux server"
else
    pass "default tmux server holds no session from this test"
fi

[ $FAILS -eq 0 ]
