#!/bin/bash
# test/test-watchdog-wiring.sh
# The detached iTerm watchdog that launch-claude.sh spawns (Phase 2, D-04/D-15): it keeps
# its dedupe token and the `ps` loop, and at the end calls tmux_watchdog_kill instead of a
# bare server-wide kill, so projects the GUI app started survive an iTerm quit.
# The EXACT payload is extracted from the launcher source and run with a stub `ps` that
# shows no iTerm2 (the loop ends at once). DESTRUCTIVE payload: every tmux call goes to a
# PRIVATE server (TMUX_TMPDIR in a scratch dir exported first, TMUX unset), never the
# default server. HOME is a scratch directory.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
LIB="$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/wdw.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$SCRATCH/stub"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
[[ "$TMUX_TMPDIR" == /tmp/wdw.* ]] || { echo "ABORT: TMUX_TMPDIR is not the private scratch dir"; exit 1; }

# stub ps: no iTerm2 process, so the watchdog loop ends at once
printf '#!/bin/bash\necho /usr/bin/launchd\n' >"$SCRATCH/stub/ps"
chmod +x "$SCRATCH/stub/ps"

alive() { T has-session -t "=$1" 2>/dev/null; }
reset_all() { T kill-server 2>/dev/null; while T ls &>/dev/null; do sleep 0.05; done; }
mk() { T new-session -d -s "$1" 'sleep 300'; }
wait_server_gone() { local i; for ((i = 0; i < 100; i++)); do T ls &>/dev/null || return 0; sleep 0.05; done; return 1; }

# ---- static wiring -----------------------------------------------------------
if grep -qF "if ! pgrep -f 'orchestrator-iterm-watchdog' >/dev/null 2>&1; then" "$LAUNCHER"; then
    pass "the pgrep dedupe line is unchanged"
else
    fail "the pgrep dedupe line changed"
fi

# the single-quoted payload of the nohup line (it holds no single quote itself)
PAYLOAD="$(sed -n "s/.*nohup bash -c '\([^']*\)'.*/\1/p" "$LAUNCHER")"
if [[ -n "$PAYLOAD" && "$(wc -l <<<"$PAYLOAD")" -eq 1 ]]; then
    pass "one nohup payload found in the launcher"
else
    fail "could not extract exactly one nohup payload"
fi
[[ "$PAYLOAD" == *': orchestrator-iterm-watchdog;'* ]] && pass "the payload keeps the dedupe token" || fail "the dedupe token is missing from the payload"
[[ "$PAYLOAD" == *'ps -Ao comm= | grep -q "/iTerm2$"'* ]] && pass "the payload keeps the ps loop" || fail "the ps loop is missing from the payload"
[[ "$PAYLOAD" == *'tmux_watchdog_kill' ]] && pass "the payload ends by calling tmux_watchdog_kill" || fail "the payload does not end with tmux_watchdog_kill"
if grep -q 'kill-server' "$LAUNCHER"; then fail "kill-server still appears in launch-claude.sh"; else pass "kill-server does not appear in launch-claude.sh"; fi

# ---- the payload, run -----------------------------------------------------------
run_payload() { PATH="$SCRATCH/stub:$PATH" timeout 30 bash -c "$PAYLOAD" orchestrator-iterm-watchdog "$LIB" </dev/null >/dev/null 2>&1; }

reset_all
mk mproj; T set-environment -t "=mproj" CLAUDE_GUI 1
mk uproj
run_payload
if alive mproj && ! alive uproj; then
    pass "payload with a marked and an unmarked project: the marked one survives, the unmarked one goes"
else
    fail "payload (marked + unmarked): sessions: $(T ls -F '#{session_name}' 2>&1 | tr '\n' ' ')"
fi

reset_all
mk uproj; mk lone
run_payload
if wait_server_gone; then
    pass "payload with unmarked projects only: the tmux server ends"
else
    fail "payload (unmarked only): the server still answers"
fi

if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS test(s) failed"
exit 1
