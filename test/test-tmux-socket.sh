#!/bin/bash
# test/test-tmux-socket.sh
# ORCH_TMUX_SOCKET: when set, every tmux call of the scripts a GUI app runs
# passes `-L <name>`; unset, nothing changes. Live parts use ONLY private -L
# servers (a test server and a decoy that holds a same-named session), never the
# default server, and are cleaned up with `tmux -L <name> kill-server` only.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(type -P tmux)" || { echo "SKIP: tmux not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SOCK="orch-sock-test-$$"
DECOY="orch-sock-test-decoy-$$"
SCRATCH="$(mktemp -d /tmp/tsock.XXXXXX)" || exit 1
unset TMUX TMUX_PANE ORCH_TMUX_SOCKET ORCH_PROJECT_ROOT
P() { "$REAL_TMUX" -L "$SOCK" "$@"; }
D() { "$REAL_TMUX" -L "$DECOY" "$@"; }
cleanup() { P kill-server 2>/dev/null; D kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- (a) attach command -----------------------------------------------------
old="$(printf '%q new-session -A -t \\=%q -s %q \\; select-window -t \\=%q' "$REAL_TMUX" b b-l b-l:=l)"
got="$(tmux_client_attach_cmd b l)"
[[ "$got" == "$old" ]] && pass "unset: attach command is unchanged" || fail "unset: attach command changed: $got"
got="$(ORCH_TMUX_SOCKET="" tmux_client_attach_cmd b l)"
[[ "$got" == "$old" ]] && pass "empty: attach command is unchanged" || fail "empty: attach command changed: $got"
got="$(ORCH_TMUX_SOCKET='my sock' tmux_client_attach_cmd b l)"
want="$(printf '%q -L %q new-session -A -t \\=%q -s %q \\; select-window -t \\=%q' "$REAL_TMUX" 'my sock' b b-l b-l:=l)"
[[ "$got" == "$want" ]] && pass "set: attach command carries -L with the quoted name" || fail "set: attach command: $got"

# ---- (b) live, private sockets ------------------------------------------------
folder="$SCRATCH/orch-sock-proj-$$"
mkdir -p "$folder"
BASE="$(tmux_base_session_name "$folder")"
ENVFILE="$SCRATCH/app.env"
printf 'PATH=/usr/bin:/bin\nHOME=%s\n' "$SCRATCH" >"$ENVFILE"

D new-session -d -s decoy-only 'sleep 300' && D new-session -d -s "$BASE" 'sleep 300' \
    || { fail "decoy server did not start"; exit 1; }

export ORCH_TMUX_SOCKET="$SOCK"
source "$REPO_DIR/orchestration/lib/tmux-session.sh"
tmux_ensure_base_session "$BASE" dashboard 'sleep 300' "$folder" "$ENVFILE" >/dev/null 2>&1
P has-session -t "=$BASE" 2>/dev/null && pass "env-file path: base session is on the private socket" || fail "env-file path: no base session on the private socket"
tmux_ensure_base_session "$BASE-plain" dashboard 'sleep 300' >/dev/null 2>&1
P has-session -t "=$BASE-plain" 2>/dev/null && pass "plain path: base session is on the private socket" || fail "plain path: no base session on the private socket"
[[ "$(D ls -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' ')" == "decoy-only $BASE " ]] \
    && pass "decoy server is untouched by session creation" || fail "decoy server changed during creation"

( cd / && timeout 60 bash "$DISPATCH" --teardown-project "$folder" ) >"$SCRATCH/out" 2>&1
P has-session -t "=$BASE" 2>/dev/null && fail "teardown: private base session still runs" || pass "teardown: private base session ended"
P has-session -t "=$BASE-plain" 2>/dev/null && pass "teardown: another private session stays" || fail "teardown: killed a session it does not own"
D has-session -t "=$BASE" 2>/dev/null && D has-session -t =decoy-only 2>/dev/null \
    && pass "teardown: decoy server sessions survive" || fail "teardown: decoy server lost a session"

[[ "$FAILS" -eq 0 ]] && echo "ALL PASSED" || echo "$FAILS FAILED"
[[ "$FAILS" -eq 0 ]]
