#!/bin/bash
# test/test-real-claude-messaging.sh
# Real-claude proof for messaging (phase 1, plan 2, task 5: AC2, MSG-01).
# Skips unless ORCH_REAL_CLAUDE=1. Fixture repo, PRIVATE tmux socket
# (ORCH_TMUX_SOCKET for the scripts, t() = tmux -L for direct calls). The
# orchestrator is started by launch-claude.sh --gui-folder; a worker by
# dispatch-task.sh. A wrapper claude swallows `claude update` and keeps headroom
# off PATH, so nothing outside the fixture and the private socket changes.

set -u
if [ "${ORCH_REAL_CLAUDE:-}" != 1 ]; then echo "SKIP: set ORCH_REAL_CLAUDE=1 to run real claude"; exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
REAL_CLAUDE="$(command -v claude)"
for c in claude tmux jq sqlite3 node git; do
    command -v "$c" >/dev/null || { echo "FAIL: $c is required"; exit 1; }
done

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(cd "$(mktemp -d /tmp/rcm.XXXXXX)" && pwd -P)" || exit 1
SOCK="rcm-$$"
export ORCH_TMUX_SOCKET="$SOCK"
unset TMUX
t() { tmux -L "$SOCK" "$@"; }
LABEL="rcm-worker"
FIX="$SCRATCH/proj"
cleanup() {
    ( cd "$FIX" 2>/dev/null && bash "$DISPATCH" --kill "$LABEL" >/dev/null 2>&1 )
    t kill-server 2>/dev/null
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# shellcheck source=../orchestration/lib/stream-json.sh
source "$REPO_DIR/orchestration/lib/stream-json.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

mkdir -p "$FIX" "$SCRATCH/bin"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name Test
echo root > "$FIX/README.md"
git -C "$FIX" add README.md && git -C "$FIX" commit -q -m "init

Context: scratch fixture repo for the messaging test"

# claude wrapper: `claude update` is a no-op, everything else is the real claude
printf '#!/bin/bash\n[ "${1-}" = update ] && exit 0\nexec "%s" "$@"\n' "$REAL_CLAUDE" > "$SCRATCH/bin/claude"
chmod +x "$SCRATCH/bin/claude"
# Symlink each tool into the scratch bin instead of adding its directory, so a
# headroom that shares a directory with jq stays off PATH (the launcher would
# start the proxy and point claude at it).
for tool in tmux git sqlite3 jq node perl; do
    ln -s "$(type -P "$tool")" "$SCRATCH/bin/$tool"
done
TOOLPATH="$SCRATCH/bin:/usr/bin:/bin"
if PATH="$TOOLPATH" command -v headroom >/dev/null; then
    echo "SKIP: headroom is on the minimal PATH, so the launcher would start its proxy"; exit 0
fi
# USER and LOGNAME: the macOS keychain login lookup of claude needs them
printf 'PATH=%s\nTERM=dumb\nCLAUDE_IN_TMUX=0\nHOME=%s\nUSER=%s\nLOGNAME=%s\n' "$TOOLPATH" "$HOME" "$(id -un)" "$(id -un)" > "$SCRATCH/app.env"
export PATH="$TOOLPATH"

wait_for() { # seconds cmd...
    local n=$(($1 * 2)) i; shift
    for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.5; done
    return 1
}

# orchestrator: new base session on the private socket
( cd "$FIX" && timeout 120 bash "$LAUNCHER" --gui-folder "$FIX" --env-file "$SCRATCH/app.env" </dev/null >"$SCRATCH/launch.out" 2>&1 ) \
    || { fail "launch-claude.sh failed: $(tail -c 300 "$SCRATCH/launch.out")"; exit 1; }
ODIR="$FIX/.claude/sessions/dashboard"
OIN="$ODIR/inbox.jsonl"; OOUT="$ODIR/out.jsonl"

# worker
( cd "$FIX" && DISPATCH_MODEL=haiku bash "$DISPATCH" "$LABEL" "Messaging proof worker" ) >"$SCRATCH/dispatch.out" 2>&1 \
    || { fail "dispatch failed: $(head -c 300 "$SCRATCH/dispatch.out")"; exit 1; }
WIN="$FIX/.claude/sessions/$LABEL/out.jsonl"
results() { jq -c 'select(.type == "result")' "$1" 2>/dev/null | wc -l | tr -d ' '; }
have_result() { [ "$(results "$1")" -ge "$2" ]; }

# the orchestrator answers the seed prompt first; wait for that result
wait_for 240 have_result "$OOUT" 1 || { fail "the orchestrator never finished its seed turn"; exit 1; }
if jq -r 'select(.type == "result") | .result' "$OOUT" | grep -q "Not logged in"; then
    fail "the orchestrator is not logged in (the env file is missing a variable claude needs)"; exit 1
fi
SEED_RESULTS="$(results "$OOUT")"

# keep the fresh worker idle until the orchestrator has found it
wait_for 90 test -s "$WIN" || true

MARKER="MSGPROOF-$$"
stream_json_user_line "Call the ListAgents tool now and show me its output. Then use SendMessage to send the agent named exactly $LABEL this text: 'Marker $MARKER. Reply to the orchestrator with one line that starts with RPL- followed by the sum of 4417 and 3112.' Report what ListAgents returned for yourself and for $LABEL." >> "$OIN"

have_more() { [ "$(results "$OOUT")" -gt "$SEED_RESULTS" ]; }
worker_has_marker() { grep -qF "$MARKER" "$WIN" 2>/dev/null; }
reply_seen() { grep -qF "RPL-7529" "$OOUT" 2>/dev/null; }

wait_for 240 have_more || echo "  note: the orchestrator produced no second result within 240s"
# only a tool_result counts: the replayed user message also holds the label
if jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | .content | tostring' "$OOUT" 2>/dev/null | grep -Eq "^ +$LABEL \["; then
    pass "AC2: ListAgents output in the orchestrator out log lists $LABEL"
else
    fail "AC2: $LABEL not in a ListAgents result of the orchestrator out log"
fi
wait_for 120 worker_has_marker && pass "AC2: the marker reached the worker out log" || fail "AC2: marker $MARKER not in the worker out log"
wait_for 180 reply_seen && pass "AC2: the worker's reply (RPL-7529) reached the orchestrator out log" \
    || fail "AC2: no RPL-7529 reply in the orchestrator out log"
if [ $FAILS -ne 0 ]; then
    echo "  orchestrator tool calls and results (diagnostics):"
    jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "CALL " + .name + " " + (.input | tostring | .[0:300])' "$OOUT" 2>/dev/null | head -20
    jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | "RESULT " + (.content | tostring | .[0:500])' "$OOUT" 2>/dev/null | head -20
    jq -r 'select(.type == "result") | "FINAL " + (.result | tostring | .[0:500])' "$OOUT" 2>/dev/null | head -5
fi

[ $FAILS -eq 0 ]
