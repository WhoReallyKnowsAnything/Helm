#!/bin/bash
# test/test-teardown-helper.sh
# tmux_kill_session_group <base> (Phase 2 plan 2, AC3/AC10): kills the base session
# and every session of its #{session_group}, by exact =name, and nothing else.
# Runs against a PRIVATE tmux server (TMUX_TMPDIR in a scratch directory, exported
# before any tmux call, TMUX unset) so the user's default server is never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }

# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

SCRATCH="$(mktemp -d /tmp/tkh.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
mkdir -p "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
trap '"$REAL_TMUX" kill-server 2>/dev/null; rm -rf "$SCRATCH"' EXIT

FAILS=0
check() { # name, 0 = pass
    if [[ "$2" -eq 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi
}
has_session() { "$REAL_TMUX" has-session -t "=$1" 2>/dev/null; }
alive() { has_session "$1" && echo 0 || echo 1; }
gone() { has_session "$1" && echo 1 || echo 0; }
reset() { "$REAL_TMUX" kill-server 2>/dev/null; while "$REAL_TMUX" ls &>/dev/null; do sleep 0.05; done; }
fixture() {
    reset
    "$REAL_TMUX" new-session -d -s proj -n main 'sleep 300'
    "$REAL_TMUX" new-window -t '=proj:' -n worker 'sleep 300'
    "$REAL_TMUX" new-session -d -t '=proj' -s proj-one
    "$REAL_TMUX" new-session -d -t '=proj' -s proj-two
    "$REAL_TMUX" new-session -d -s proj-2 -n main 'sleep 300'
    "$REAL_TMUX" new-session -d -t '=proj-2' -s proj-2-dashboard
    "$REAL_TMUX" new-session -d -s pro -n main 'sleep 300'
    "$REAL_TMUX" new-session -d -s lone -n main 'sleep 300'
}
all_windows() { "$REAL_TMUX" list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null; }

# ---- the group goes, siblings stay ----
fixture
OUT="$(tmux_kill_session_group proj 2>&1)"; RC=$?
check "group: exit 0" $([[ "$RC" -eq 0 ]] && echo 0 || echo 1)
check "group: base gone" "$(gone proj)"
check "group: client proj-one gone" "$(gone proj-one)"
check "group: client proj-two gone" "$(gone proj-two)"
check "group: worker window gone" $(all_windows | grep -q ':worker$' && echo 1 || echo 0)
check "group: prefix sibling proj-2 alive" "$(alive proj-2)"
check "group: its client proj-2-dashboard alive" "$(alive proj-2-dashboard)"
check "group: prefix sibling pro alive" "$(alive pro)"
check "group: lone session alive" "$(alive lone)"
check "group: server still answers tmux ls" $("$REAL_TMUX" ls &>/dev/null && echo 0 || echo 1)
check "group: output names what it stopped" $(echo "$OUT" | grep -q 'proj-one' && echo 0 || echo 1)

# ---- clients outlive a base killed by hand: selection is by group equality ----
fixture
"$REAL_TMUX" kill-session -t '=proj'
tmux_kill_session_group proj >/dev/null 2>&1
check "orphaned clients: proj-one gone" "$(gone proj-one)"
check "orphaned clients: proj-two gone" "$(gone proj-two)"
check "orphaned clients: proj-2 alive" "$(alive proj-2)"
check "orphaned clients: pro alive" "$(alive pro)"

# ---- no session of that name: nothing changes, nothing found ----
fixture
BEFORE="$("$REAL_TMUX" ls -F '#{session_name}' | sort)"
OUT="$(tmux_kill_session_group nothere 2>&1)"; RC=$?
check "absent: exit 0" $([[ "$RC" -eq 0 ]] && echo 0 || echo 1)
check "absent: reports nothing found" $(echo "$OUT" | grep -qi 'no session' && echo 0 || echo 1)
check "absent: every session unchanged" $([[ "$("$REAL_TMUX" ls -F '#{session_name}' | sort)" == "$BEFORE" ]] && echo 0 || echo 1)

# ---- a lone base (empty #{session_group}) goes by its exact name ----
fixture
tmux_kill_session_group lone >/dev/null 2>&1
check "lone: lone gone" "$(gone lone)"
check "lone: pro alive" "$(alive pro)"
check "lone: proj group alive" "$(alive proj-one)"

# ---- R1: an empty base name refuses and kills nothing ----
fixture
BEFORE="$("$REAL_TMUX" ls -F '#{session_name}' | sort)"
OUT="$(tmux_kill_session_group '' 2>&1)"; RC=$?
check "R1 empty: returns 1" $([[ "$RC" -eq 1 ]] && echo 0 || echo 1)
check "R1 empty: stderr names a reason" $([[ -n "$OUT" ]] && echo 0 || echo 1)
check "R1 empty: every fixture session survives" $([[ "$("$REAL_TMUX" ls -F '#{session_name}' | sort)" == "$BEFORE" ]] && echo 0 || echo 1)
tmux_kill_session_group >/dev/null 2>&1; RC=$?
check "R1 no argument: returns 1" $([[ "$RC" -eq 1 ]] && echo 0 || echo 1)
check "R1 no argument: every fixture session survives" $([[ "$("$REAL_TMUX" ls -F '#{session_name}' | sort)" == "$BEFORE" ]] && echo 0 || echo 1)

# ---- R2: no tmux server is "no session", status 0, under set -euo pipefail ----
reset
OUT="$( ( set -euo pipefail; source "$REPO_DIR/orchestration/lib/tmux-session.sh"; tmux_kill_session_group proj; echo reached ) 2>&1)"; RC=$?
check "R2 no server: exit 0 under set -euo pipefail" $([[ "$RC" -eq 0 ]] && echo 0 || echo 1)
check "R2 no server: reports no session" $(echo "$OUT" | grep -qi 'no session' && echo 0 || echo 1)
check "R2 no server: execution continued" $(echo "$OUT" | grep -qx reached && echo 0 || echo 1)

# ---- no kill-server in the helper ----
# (tmux_watchdog_kill holds the library's one kill-server, so only this function's body is checked)
HELPER_BODY="$(sed -n '/^tmux_kill_session_group() {/,/^}/p' "$REPO_DIR/orchestration/lib/tmux-session.sh")"
check "tmux_kill_session_group body found" $(grep -q 'kill-session' <<<"$HELPER_BODY" && echo 0 || echo 1)
check "tmux_kill_session_group has no kill-server" $(grep -q 'kill-server' <<<"$HELPER_BODY" && echo 1 || echo 0)

[[ "$FAILS" -eq 0 ]] && echo "ALL PASSED" || echo "$FAILS FAILED"
[[ "$FAILS" -eq 0 ]]
