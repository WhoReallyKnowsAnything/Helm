#!/bin/bash
# test/test-hold-pane-clear.sh
# A PermissionRequest hold ends when its call is answered at the native dialog:
# the answered call's PostToolUse reaches worker-relay.sh, which ends exactly that
# call's hold (session + tool + op hash) by signalling its hook. No decision is
# ever written, so the ended hook prints nothing and the registration wrapper turns
# that into a deny (settings.json PermissionRequest wrapper, rc 143 = "crashed").
# A parallel call's hold stays. Disposable fixture repo only. Plain bash.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/orchestration/hooks/permission-hold.sh"
RELAY="$REPO_ROOT/orchestration/hooks/worker-relay.sh"
unset APPROVAL_NTFY_TOPIC_URL APPROVAL_GATE_DEADLINE_SECS

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

SCRATCH=$(mktemp -d) || { echo "FAIL: no scratch dir"; exit 1; }
SCRATCH=$(cd "$SCRATCH" && pwd -P)
PH_PIDS=""
cleanup() { local p; for p in $PH_PIDS; do kill "$p" 2>/dev/null; done; cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

STUB="$SCRATCH/stub"; mkdir -p "$STUB"
OSA_LOG="$STUB/osascript.log"; : > "$OSA_LOG"
printf '#!/bin/bash\nexit 0\n' > "$STUB/tmux"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$OSA_LOG" > "$STUB/osascript"
chmod +x "$STUB/tmux" "$STUB/osascript"
no_notify() { [ ! -s "$OSA_LOG" ]; }   # a hold ended by its answered call must not notify

FIX="$SCRATCH/repo"; mkdir -p "$FIX"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email test@example.com
git -C "$FIX" config user.name test
echo seed > "$FIX/seed.txt"; git -C "$FIX" add seed.txt; git -C "$FIX" commit -qm seed
"$REPO_ROOT/orchestration/init/init-state-store.sh" "$FIX" >/dev/null 2>&1
FIX=$(cd "$FIX" && pwd -P)
LIVE_WT="$FIX/.claude/worktrees/live"
git -C "$FIX" worktree add -q -b session/live "$LIVE_WT" 2>/dev/null
LIVE_WT=$(cd "$LIVE_WT" && pwd -P)
PLAIN="$SCRATCH/plain"; mkdir -p "$PLAIN"
( cd "$FIX" || exit 1
  source "$REPO_ROOT/orchestration/lib/session-state.sh"
  session_state_write live "$LIVE_WT" running >/dev/null
) || { echo "FAIL: fixture rows"; exit 1; }
HOLD="$FIX/.claude/gate-holds"; mkdir -p "$HOLD"

# payload event session tool input_json [tool_use_id]
payload() {
    jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --argjson i "$4" --arg c "$LIVE_WT" --arg u "${5:-}" \
        '{session_id:$s,cwd:$c,tool_name:$t,tool_input:$i,hook_event_name:$e,permission_mode:"default"}
         + (if $u != "" then {tool_use_id:$u} else {} end)'
}

ph_start() { # payload -> PH_PID, PH_OUTF
    local in; in=$(mktemp "$SCRATCH/in.XXXXXX"); PH_OUTF=$(mktemp "$SCRATCH/out.XXXXXX")
    printf '%s' "$1" > "$in"
    ( cd "$PLAIN" || exit 1
      export PATH="$STUB:$PATH"
      exec perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' bash "$HOOK" < "$in" > "$PH_OUTF" 2>/dev/null
    ) &
    PH_PID=$!; PH_PIDS="$PH_PIDS $PH_PID"
}
ph_alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$st" ] && [[ "$st" != Z* ]]; }
ph_wait_gone() { local n=$(( $2 * 10 )); while [ "$n" -gt 0 ] && ph_alive "$1"; do sleep 0.1; n=$((n - 1)); done; ! ph_alive "$1"; }
ph_pending_count() { ls "$HOLD"/perm-*.pending 2>/dev/null | grep -c .; }
ph_wait_pending() { local n=$(( $2 * 10 )); while [ "$n" -gt 0 ] && [ "$(ph_pending_count)" -lt "$1" ]; do sleep 0.1; n=$((n - 1)); done; [ "$(ph_pending_count)" -ge "$1" ]; }
ph_reset() { rm -f "$HOLD"/* 2>/dev/null; }
relay() { (cd "$PLAIN" && printf '%s' "$1" | env PATH="$STUB:$PATH" bash "$RELAY" >/dev/null 2>&1); }
no_allow() { ! grep -q '"behavior":"allow"' "$1"; }   # empty output counts: the wrapper turns it into a deny
no_decision() { ! ls "$HOLD"/*.decision >/dev/null 2>&1; }

BASH_IN='{"command":"touch /tmp/x","description":"d"}'

# 1. The answered call's PostToolUse ends its hold; no decision, no allow.
ph_reset
ph_start "$(payload PermissionRequest sess-1 Bash "$BASH_IN")"
if ph_wait_pending 1 5; then
    relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_a)"
    check "answered call: hook ends after its PostToolUse" ph_wait_gone "$PH_PID" 4
    check "answered call: pending record is gone" [ "$(ph_pending_count)" = 0 ]
    check "answered call: hook printed no allow" no_allow "$PH_OUTF"
    check "answered call: no decision file was written" no_decision
    check "answered call: no notification was sent" no_notify
else
    fail "answered call: no pending record appeared"
fi

# 2. A parallel call (other op) keeps its hold.
ph_reset
ph_start "$(payload PermissionRequest sess-1 Bash "$BASH_IN")"; A_PID=$PH_PID
ph_start "$(payload PermissionRequest sess-1 Bash '{"command":"touch /tmp/y","description":"d"}')"; B_PID=$PH_PID; B_OUT=$PH_OUTF
if ph_wait_pending 2 5; then
    relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_a)"
    check "parallel call: the answered one ends" ph_wait_gone "$A_PID" 4
    sleep 1
    check "parallel call: the other hold stays alive" ph_alive "$B_PID"
    check "parallel call: the other hold keeps its pending record" [ "$(ph_pending_count)" = 1 ]
    kill "$B_PID" 2>/dev/null
else
    fail "parallel call: two pending records did not appear"
fi

# 3. Same op, other session: that hold stays.
ph_reset
ph_start "$(payload PermissionRequest sess-2 Bash "$BASH_IN")"; S_PID=$PH_PID
if ph_wait_pending 1 5; then
    relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_a)"
    sleep 1
    check "other session: hold stays alive" ph_alive "$S_PID"
    kill "$S_PID" 2>/dev/null
else
    fail "other session: no pending record appeared"
fi

# 4. Two identical parallel calls: one PostToolUse ends ONE hold (the oldest); the
#    one still waiting is never allowed, and a second PostToolUse ends it, still no allow.
ph_reset
ph_start "$(payload PermissionRequest sess-1 Bash "$BASH_IN")"; I1_PID=$PH_PID; I1_OUT=$PH_OUTF
ph_wait_pending 1 5; sleep 1.1
ph_start "$(payload PermissionRequest sess-1 Bash "$BASH_IN")"; I2_PID=$PH_PID; I2_OUT=$PH_OUTF
if ph_wait_pending 2 5; then
    relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_a)"
    sleep 1.5
    n=0; ph_alive "$I1_PID" && n=$((n + 1)); ph_alive "$I2_PID" && n=$((n + 1))
    check "identical calls: one PostToolUse ends exactly one hold" [ "$n" = 1 ]
    check "identical calls: the oldest hold is the one ended" bash -c "! ps -p $I1_PID >/dev/null 2>&1 || ps -o stat= -p $I1_PID | grep -q '^Z'"
    relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_b)"
    check "identical calls: the second PostToolUse ends the other" ph_wait_gone "$I2_PID" 4
    check "identical calls: neither hook ever printed allow" bash -c "! grep -q allow '$I1_OUT' '$I2_OUT'"
    check "identical calls: no decision file was written" no_decision
    check "identical calls: no notification was sent" no_notify
else
    fail "identical calls: two pending records did not appear"
fi

# 5. A live-hook-less PostToolUse (nothing held) is harmless and still clears the row.
ph_reset
( cd "$FIX" && source "$REPO_ROOT/orchestration/lib/session-state.sh" && session_state_update_status live blocked >/dev/null )
relay "$(payload PostToolUse sess-1 Bash "$BASH_IN" toolu_a)"
check "no hold: blocked row returns to running" \
    bash -c "cd '$FIX' && source '$REPO_ROOT/orchestration/lib/session-state.sh' && [ \"\$(session_state_read live)\" = running ]"

echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
