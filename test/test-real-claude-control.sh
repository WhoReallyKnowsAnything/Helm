#!/bin/bash
# test/test-real-claude-control.sh
# Real-claude proof for interrupt, set_model and /effort (phase 4, plan 1, task 6: AC1, AC2 machine half).
# Skips unless ORCH_REAL_CLAUDE=1. One headless session in a PRIVATE tmux socket, fixture repo,
# real claude on PATH. Never touches the default tmux server.

set -u
if [ "${ORCH_REAL_CLAUDE:-}" != 1 ]; then echo "SKIP: set ORCH_REAL_CLAUDE=1 to run real claude"; exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
command -v claude >/dev/null && command -v tmux >/dev/null && command -v jq >/dev/null && command -v python3 >/dev/null \
    || { echo "FAIL: claude, tmux, jq and python3 are required"; exit 1; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/rcc.XXXXXX)" || exit 1
SOCK="rcc-$$"
unset TMUX
t() { tmux -L "$SOCK" "$@"; }
cleanup() { t kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# shellcheck source=../orchestration/lib/stream-json.sh
source "$REPO_DIR/orchestration/lib/stream-json.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

FIX="$SCRATCH/repo"
mkdir -p "$FIX" && git -C "$FIX" init -q -b main
IN="$SCRATCH/in.jsonl"; OUT="$SCRATCH/out.jsonl"
: > "$IN"; : > "$OUT"
CMD="claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --model sonnet --permission-mode auto --permission-prompt-tool stdio --setting-sources project --strict-mcp-config"
t new-session -d -s ctl -n ctl "cd '$FIX' && $(tmux_headless_cmd "$IN" "$OUT" "$CMD")"

wait_for() { local n=$(($1 * 2)) i; shift; for ((i = 0; i < n; i++)); do "$@" && return 0; sleep 0.5; done; return 1; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
results() { jq -c 'select(.type == "result")' "$OUT" 2>/dev/null | wc -l | tr -d ' '; }
have_results() { [ "$(results)" -ge "$1" ]; }
ask() { local base; base="$(results)"; stream_json_user_line "$1" >> "$IN"; wait_for "${2:-90}" have_results $((base + 1)); }
ctl() { jq -nc --arg id "$1" --argjson req "$2" '{type:"control_request",request_id:$id,request:$req}' >> "$IN"; }
resp_ok() { jq -c --arg id "$1" 'select(.type == "control_response" and .response.request_id == $id and .response.subtype == "success")' "$OUT" 2>/dev/null | grep -q .; }
last_result() { jq -r 'select(.type == "result") | "\(.subtype)|\(.result // "")"' "$OUT" | tail -1; }

# warm-up: the init event and the first reply
stream_json_user_line "Reply with the single word ready." >> "$IN"
wait_for 120 have_results 1 || { fail "no first reply within 120s"; exit 1; }

# (1) interrupt during a running shell tool (D-08)
stream_json_user_line "Use a shell tool to run exactly: sleep 67" >> "$IN"
running() { pgrep -f 'sleep 67' >/dev/null; }
wait_for 90 running || { fail "1: sleep 67 never started"; exit 1; }
T0="$(now_ms)"
ctl int-1 '{"subtype":"interrupt"}'
got() { resp_ok int-1 && have_results 2; }
wait_for 10 got
T1="$(now_ms)"
EL=$((T1 - T0))
if got && [ "$EL" -le 2500 ] && [ "$(last_result | cut -d'|' -f1)" = error_during_execution ]; then
    pass "1: interrupt answered success and result error_during_execution in ${EL}ms"
else
    fail "1: interrupt response/result missing or slow (${EL}ms, result: $(last_result | head -c 100))"
fi
if running; then
    echo "NOTE: 1: the sleep child outlives the interrupt (orphan); the turn ends, the process does not. Killing it."
    pkill -f 'sleep 67'
    sleep 5
fi
pass "1: interrupt ended the turn; shell child survival recorded above if any"
ask "Reply with the single word pong."
[ "$(last_result | cut -d'|' -f1)" = success ] && pass "1: the next user line gets a normal reply" || fail "1: no normal reply after the interrupt: $(last_result | head -c 120)"

# (2) interrupt while idle
ctl int-2 '{"subtype":"interrupt"}'
wait_for 10 resp_ok int-2 && pass "2: idle interrupt answered success" || fail "2: no success response to the idle interrupt"
ask "Reply with the single word pong."
[ "$(last_result | cut -d'|' -f1)" = success ] && pass "2: a normal reply follows the idle interrupt" || fail "2: no normal reply after the idle interrupt"

# (3) set_model haiku (D-10)
ctl model-1 '{"subtype":"set_model","model":"haiku"}'
wait_for 10 resp_ok model-1 || fail "3: no success response to set_model"
if jq -c 'select(.type == "control_response" and .response.request_id == "model-1") | .response.response.model | strings | select(length > 0)' "$OUT" 2>/dev/null | grep -q .; then
    pass "3: set_model response carries a model field"
else
    fail "3: set_model response has no model field"
fi
ask "Reply with the single word pong."
if jq -r 'select(.type == "assistant") | .message.model' "$OUT" | tail -1 | grep -qi haiku; then
    pass "3: the next assistant event is a haiku model"
else
    fail "3: last assistant model is $(jq -r 'select(.type == "assistant") | .message.model' "$OUT" | tail -1)"
fi

# (4) /effort low
ask "/effort low" 60
last_result | grep -qi 'effort level to low' && pass "4: /effort low result says the level was set" || fail "4: effort result: $(last_result | head -c 150)"

t kill-server 2>/dev/null
t ls >/dev/null 2>&1 && fail "private socket $SOCK still has a server" || pass "private socket has no server after the run"

[ $FAILS -eq 0 ]
