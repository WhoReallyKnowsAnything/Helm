#!/bin/bash
# test/test-permission-hold.sh
# orchestration/hooks/permission-hold.sh, the PermissionRequest hold: a live
# worker's prompt for any tool is held for the band, answered through the same
# decision files and --gate-decide as a git hold, and ended in a deny at the
# deadline. Anyone else gets no output. Fixture: a real repo with a state store,
# linked worktrees, and stub tmux and osascript first on PATH. Plain bash, no
# framework. Never touches ~/.claude or the default tmux server.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/orchestration/hooks/permission-hold.sh"
DISPATCH="$REPO_ROOT/orchestration/lib/dispatch-task.sh"
unset APPROVAL_NTFY_TOPIC_URL APPROVAL_GATE_DEADLINE_SECS

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() { # name command...: pass when the command succeeds
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

SCRATCH=$(mktemp -d) || { echo "FAIL: no scratch dir"; exit 1; }
SCRATCH=$(cd "$SCRATCH" && pwd -P)
PH_PIDS=""
cleanup() { local p; for p in $PH_PIDS; do kill "$p" 2>/dev/null; done; cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

# --- stubs: tmux and osascript log their arguments, one line per call ---
STUB="$SCRATCH/stub"; mkdir -p "$STUB"
TMUX_LOG="$STUB/tmux.log"; OSA_LOG="$STUB/osascript.log"
: > "$TMUX_LOG"; : > "$OSA_LOG"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$TMUX_LOG" > "$STUB/tmux"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$OSA_LOG" > "$STUB/osascript"
chmod +x "$STUB/tmux" "$STUB/osascript"

# --- fixture: state store, a live worker and a done worker (linked worktrees),
#     a nested git repo inside the live worktree, the dashboard row ---
FIX="$SCRATCH/repo"
mkdir -p "$FIX"
git -C "$FIX" init -q -b main
git -C "$FIX" config user.email test@example.com
git -C "$FIX" config user.name test
echo seed > "$FIX/seed.txt"
git -C "$FIX" add seed.txt
git -C "$FIX" commit -qm seed
"$REPO_ROOT/orchestration/init/init-state-store.sh" "$FIX" >/dev/null 2>&1
FIX=$(cd "$FIX" && pwd -P)
LIVE_WT="$FIX/.claude/worktrees/live"
DONE_WT="$FIX/.claude/worktrees/finished"
git -C "$FIX" worktree add -q -b session/live "$LIVE_WT" 2>/dev/null
git -C "$FIX" worktree add -q -b session/finished "$DONE_WT" 2>/dev/null
QLABELS="cad-context-p3 cad-context-p1-1 cad-context-p3x cad-execute-p1 cad-context-p3- xcad-context-p3 cad-plan-p4 cad-plan-p1-1 cad-plan-p4x cad-execute-p4 cad-verify-p3 cad-execute-p1-1 cad-execute-p4x cad-milestone-p1 cad-milestone-p3 cad-milestone-p3x"
for QL in $QLABELS; do git -C "$FIX" worktree add -q -b "session/$QL" "$FIX/.claude/worktrees/$QL" 2>/dev/null; done
mkdir -p "$LIVE_WT/sub"
git -C "$LIVE_WT" init -q "$LIVE_WT/vendor/nested"
LIVE_WT=$(cd "$LIVE_WT" && pwd -P)
DONE_WT=$(cd "$DONE_WT" && pwd -P)
NESTED="$LIVE_WT/vendor/nested"
PLAIN="$SCRATCH/plain"; mkdir -p "$PLAIN"
(
    cd "$FIX" || exit 1
    source "$REPO_ROOT/orchestration/lib/session-state.sh"
    session_state_write live "$LIVE_WT" running >/dev/null
    session_state_write finished "$DONE_WT" done >/dev/null
    session_state_write dashboard "$FIX" running >/dev/null
    for QL in $QLABELS; do session_state_write "$QL" "$(cd "$FIX/.claude/worktrees/$QL" && pwd -P)" running >/dev/null; done
) || { echo "FAIL: fixture rows"; exit 1; }
HOLD="$FIX/.claude/gate-holds"
mkdir -p "$HOLD"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

ph_payload() { # cwd tool input_json [session_id] -> a PermissionRequest payload
    jq -nc --arg c "$1" --arg t "$2" --argjson i "$3" --arg s "${4:-sess-1}" \
        '{session_id:$s,cwd:$c,tool_name:$t,tool_input:$i,hook_event_name:"PermissionRequest",permission_mode:"default"}'
}
ph_hash() { printf '%s: %s' "$1" "$2" | shasum -a 256 | cut -d' ' -f1; }

# ph_run payload [deadline_secs] [script] -> PH_OUT, PH_RC. The hook runs from a
# directory that is NOT the payload cwd: the lookup must not depend on it.
ph_run() {
    PH_OUT=$(cd "$PLAIN" && printf '%s' "$1" | env PATH="$STUB:$PATH" ${2:+APPROVAL_GATE_DEADLINE_SECS=$2} bash "${3:-$HOOK}" 2>/dev/null)
    PH_RC=$?
}

# ph_start payload [deadline_secs] -> PH_PID, PH_OUTF. Runs under perl so SIGINT
# keeps its default disposition (a background job ignores it, bash cannot trap it).
ph_start() {
    local in; in=$(mktemp "$SCRATCH/in.XXXXXX"); PH_OUTF=$(mktemp "$SCRATCH/out.XXXXXX")
    printf '%s' "$1" > "$in"
    (
        cd "$PLAIN" || exit 1
        [ -n "${2:-}" ] && export APPROVAL_GATE_DEADLINE_SECS="$2"
        export PATH="$STUB:$PATH"
        exec perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' bash "$HOOK" < "$in" > "$PH_OUTF" 2>/dev/null
    ) &
    PH_PID=$!
    PH_PIDS="$PH_PIDS $PH_PID"
}
ph_alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$st" ] && [[ "$st" != Z* ]]; }
ph_wait_gone() { # pid secs
    local n=$(( $2 * 10 ))
    while [ "$n" -gt 0 ] && ph_alive "$1"; do sleep 0.1; n=$((n - 1)); done
    ph_alive "$1" && return 1
    wait "$1" 2>/dev/null; PH_WRC=$?
    return 0
}
ph_pending() { ls "$HOLD"/perm-*.pending 2>/dev/null; }
ph_wait_pending() { # count secs
    local n=$(( $2 * 10 ))
    while [ "$n" -gt 0 ] && [ "$(ph_pending | grep -c .)" -lt "$1" ]; do sleep 0.1; n=$((n - 1)); done
    [ "$(ph_pending | grep -c .)" -ge "$1" ]
}
ph_decide() { # id verdict hash: the band's write, by temp file and rename
    printf '%s %s\n' "$2" "$3" > "$HOLD/.t.$1" && mv -f "$HOLD/.t.$1" "$HOLD/$1.decision"
}
ph_reset() { rm -f "$HOLD"/* "$HOLD"/.t.* 2>/dev/null; }

ALLOW_SHAPE='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
is_deny() { # json: a PermissionRequest deny with a non-empty message (empty input is not a deny: jq -e passes on it)
    [ -n "$1" ] && printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == "deny" and (.hookSpecificOutput.decision.message | length > 0)' >/dev/null 2>&1
}
is_silent() { [ "$PH_RC" = 0 ] && [ -z "$PH_OUT" ]; }

# --- a live worker's WebFetch is held, keyed and answered through a decision file ---
OP="https://example.com/a?x=1"
WANT=$(ph_hash WebFetch "$OP")
for V in allow deny; do
    ph_reset
    ph_start "$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u,prompt:"p"}')")"
    if ph_wait_pending 1 5; then
        F=$(ph_pending | head -1); ID=$(basename "$F" .pending)
        check "hold ($V): the pending hash equals the hash of 'WebFetch: <op>'" [ "$(sed -n 2p "$F")" = "$WANT" ]
        check "hold ($V): the record carries the worker label, the cwd and the op text" \
            [ "$(sed -n 1p "$F")" = live -a "$(sed -n 5p "$F")" = "$LIVE_WT" -a "$(tail -n +7 "$F")" = "WebFetch: $OP" ]
        check "hold ($V): the id is a valid, perm-prefixed hold id" \
            bash -c "source '$REPO_ROOT/orchestration/lib/gate-hold.sh'; gate_hold_id_valid '$ID' && [[ '$ID' == perm-* ]]"
        T0=$(now_ms); ph_decide "$ID" "$V" "$WANT"
        if ph_wait_gone "$PH_PID" 3; then
            ELAPSED=$(( $(now_ms) - T0 ))
            OUT=$(cat "$PH_OUTF")
            if [ "$V" = allow ]; then
                check "hold ($V): prints exactly the allow shape and exits 0" [ "$OUT" = "$ALLOW_SHAPE" -a "$PH_WRC" = 0 ]
            else
                check "hold ($V): prints a deny shape with a message and exits 0" \
                    bash -c "$(declare -f is_deny); is_deny '$OUT'; [ $PH_WRC = 0 ]"
            fi
            check "hold ($V): ends within 2 s of the decision ($ELAPSED ms)" [ "$ELAPSED" -lt 2000 ]
            check "hold ($V): the pending record is gone" [ -z "$(ph_pending)" ]
        else
            fail "hold ($V): the hook did not end after the decision"
        fi
    else
        fail "hold ($V): no pending record appeared"
    fi
done

# --- a decision with the wrong hash is ignored; the right one then ends the hold ---
ph_reset
ph_start "$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")"
if ph_wait_pending 1 5; then
    ID=$(basename "$(ph_pending | head -1)" .pending)
    ph_decide "$ID" allow "$(printf '0%.0s' $(seq 64))"
    sleep 1.5
    check "wrong hash: the hook keeps waiting" ph_alive "$PH_PID"
    ph_decide "$ID" allow "$(ph_hash WebFetch "$OP")"
    ph_wait_gone "$PH_PID" 3; check "wrong hash: the right hash then ends it in allow" [ "$(cat "$PH_OUTF")" = "$ALLOW_SHAPE" ]
else
    fail "wrong hash: no pending record appeared"
fi

# --- two identical requests started together get two keys ---
ph_reset
P2=$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")
ph_start "$P2"; PA=$PH_PID; OA=$PH_OUTF
ph_start "$P2"; PB=$PH_PID; OB=$PH_OUTF
if ph_wait_pending 2 5; then
    check "two identical requests: two distinct hold ids" [ "$(ph_pending | xargs -n1 basename | sort -u | grep -c .)" = 2 ]
    for F in $(ph_pending); do ph_decide "$(basename "$F" .pending)" allow "$(sed -n 2p "$F")"; done
    ph_wait_gone "$PA" 3; ph_wait_gone "$PB" 3
    check "two identical requests: both end in allow" [ "$(cat "$OA")" = "$ALLOW_SHAPE" -a "$(cat "$OB")" = "$ALLOW_SHAPE" ]
else
    fail "two identical requests: two pending records did not appear"
fi

# --- the op text: command, then url, then compact JSON ---
ph_reset
JSON_IN='{"file_path":"/x","content":"y"}'
ph_start "$(ph_payload "$LIVE_WT" Write "$JSON_IN")"
if ph_wait_pending 1 5; then
    F=$(ph_pending | head -1)
    check "op text: a tool with no command or url holds its compact JSON" \
        [ "$(tail -n +7 "$F")" = "Write: $JSON_IN" -a "$(sed -n 2p "$F")" = "$(ph_hash Write "$JSON_IN")" ]
    ph_decide "$(basename "$F" .pending)" deny "$(sed -n 2p "$F")"; ph_wait_gone "$PH_PID" 3
else
    fail "op text: no pending record appeared"
fi
ph_reset
ph_start "$(ph_payload "$LIVE_WT" Bash '{"command":"ls -la","url":"u"}')"
if ph_wait_pending 1 5; then
    F=$(ph_pending | head -1)
    check "op text: command wins over url" [ "$(tail -n +7 "$F")" = "Bash: ls -la" ]
    ph_decide "$(basename "$F" .pending)" deny "$(sed -n 2p "$F")"; ph_wait_gone "$PH_PID" 3
else
    fail "op text (command): no pending record appeared"
fi

# --- a worker whose cwd is a subdirectory or inside a nested git repo is still held ---
for C in "$LIVE_WT/sub" "$NESTED"; do
    ph_reset
    ph_start "$(ph_payload "$C" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")"
    if ph_wait_pending 1 5; then
        F=$(ph_pending | head -1)
        check "held at ${C#"$LIVE_WT"/} (hook started from another directory): label live" [ "$(sed -n 1p "$F")" = live ]
        ph_decide "$(basename "$F" .pending)" allow "$(sed -n 2p "$F")"
        ph_wait_gone "$PH_PID" 3; check "held at ${C#"$LIVE_WT"/}: allow ends it" [ "$(cat "$PH_OUTF")" = "$ALLOW_SHAPE" ]
    else
        fail "held at ${C#"$LIVE_WT"/}: no pending record appeared"
    fi
done

# --- the deadline ends in a deny with a reason and exactly one notification ---
ph_reset; : > "$OSA_LOG"
ph_run "$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")" 2
check "deadline: prints a deny with a reason and exits 0" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'; [ $PH_RC = 0 ]"
check "deadline: the reason names the wait" grep -q "2 seconds" <<< "$PH_OUT"
check "deadline: exactly one notification" [ "$(grep -c . "$OSA_LOG")" = 1 ]
check "deadline: the notification names the worker and carries no op text" \
    bash -c "grep -q live '$OSA_LOG' && ! grep -q example.com '$OSA_LOG'"
check "deadline: no pending record is left" [ -z "$(ph_pending)" ]

# --- D-04: the two question tools are denied at once, with no hold ---
ph_reset
Q_IN='{"questions":[{"question":"Which one?","options":[]}]}'
for TOOL in AskUserQuestion ExitPlanMode; do
    T0=$(now_ms)
    ph_run "$(ph_payload "$LIVE_WT" "$TOOL" "$Q_IN")"
    ELAPSED=$(( $(now_ms) - T0 ))
    check "$TOOL (live worker): a deny with a SendMessage instruction, exit 0" \
        bash -c "$(declare -f is_deny); is_deny '$PH_OUT' && printf '%s' '$PH_OUT' | jq -e '.hookSpecificOutput.decision.message | test(\"SendMessage\")' >/dev/null; [ $PH_RC = 0 ]"
    check "$TOOL (live worker): answered in under 1 s ($ELAPSED ms), no pending record" [ "$ELAPSED" -lt 1000 -a -z "$(ph_pending)" ]
    ph_run "$(ph_payload "$PLAIN" "$TOOL" "$Q_IN")"
    check "$TOOL (not a live worker): no output, exit 0" is_silent
done

# --- D-01 amendment: a listed stage worker may ask. The PermissionRequest schema
#     of Claude Code 2.1.322 has only allow and deny, so the lifted case prints
#     nothing (the registered wrapper passes that through for it) and never "allow". ---
qwt() { echo "$FIX/.claude/worktrees/$1"; }
for QL in cad-context-p3 cad-context-p1-1 cad-plan-p4 cad-plan-p1-1 cad-verify-p3 cad-execute-p1 cad-execute-p4 cad-execute-p1-1 cad-milestone-p3; do
    ph_reset
    ph_run "$(ph_payload "$(cd "$(qwt $QL)" && pwd -P)" AskUserQuestion "$Q_IN")"
    check "AskUserQuestion ($QL): no output, exit 0, no pending record" bash -c "[ '$PH_RC' = 0 ] && [ -z '$PH_OUT' ] && [ -z '$(ph_pending)' ]"
done
for QL in cad-execute-p4x cad-milestone-p3x cad-context-p3x cad-plan-p4x live; do
    D=$(qwt $QL); [ "$QL" = live ] && D="$LIVE_WT"
    ph_run "$(ph_payload "$(cd "$D" && pwd -P)" AskUserQuestion "$Q_IN")"
    check "AskUserQuestion ($QL): deny with the SendMessage message" \
        bash -c "$(declare -f is_deny); is_deny '$PH_OUT' && printf '%s' '$PH_OUT' | jq -e '.hookSpecificOutput.decision.message | test(\"SendMessage\")' >/dev/null"
done
ph_run "$(ph_payload "$(cd "$(qwt cad-context-p3)" && pwd -P)" ExitPlanMode "$Q_IN")"
check "ExitPlanMode (cad-context-p3): deny" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'"
ph_run "$(ph_payload "$(cd "$(qwt cad-plan-p4)" && pwd -P)" ExitPlanMode "$Q_IN")"
check "ExitPlanMode (cad-plan-p4): deny" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'"
ph_run "$(ph_payload "$(cd "$(qwt cad-verify-p3)" && pwd -P)" ExitPlanMode "$Q_IN")"
check "ExitPlanMode (cad-verify-p3): deny" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'"
ph_run "$(ph_payload "$(cd "$(qwt cad-execute-p1)" && pwd -P)" ExitPlanMode "$Q_IN")"
check "ExitPlanMode (cad-execute-p1): deny" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'"
ph_run "$(ph_payload "$(cd "$(qwt cad-milestone-p3)" && pwd -P)" ExitPlanMode "$Q_IN")"
check "ExitPlanMode (cad-milestone-p3): deny" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'"
NOALLOW_OK=1
for QL in cad-context-p3 cad-context-p1-1 cad-execute-p1 cad-context-p3x live cad-context-p3- xcad-context-p3 cad-plan-p4 cad-plan-p1-1 cad-plan-p4x cad-execute-p4 cad-verify-p3 cad-execute-p1-1 cad-execute-p4x cad-milestone-p1 cad-milestone-p3 cad-milestone-p3x; do
    D=$(qwt $QL); [ "$QL" = live ] && D="$LIVE_WT"
    ph_run "$(ph_payload "$(cd "$D" && pwd -P)" AskUserQuestion "$Q_IN")"
    case "$PH_OUT" in *'"behavior":"allow"'*) NOALLOW_OK=""; echo "allow printed for $QL" ;; esac
done
ph_run "$(ph_payload "$PLAIN" AskUserQuestion "$Q_IN")"
case "$PH_OUT" in *'"behavior":"allow"'*) NOALLOW_OK="" ;; esac
check "AskUserQuestion: no label ever gets an allow" [ -n "$NOALLOW_OK" ]
# Without question-stages.sh the case is not lifted, and other prompts are not denied by the load.
CPY="$SCRATCH/copy/orchestration"; mkdir -p "$CPY/hooks" "$CPY/lib"
cp "$REPO_ROOT"/orchestration/hooks/permission-hold.sh "$CPY/hooks/"
for F in "$REPO_ROOT"/orchestration/lib/*; do [ "$(basename "$F")" = question-stages.sh ] || cp "$F" "$CPY/lib/"; done
ph_run "$(ph_payload "$(cd "$(qwt cad-context-p3)" && pwd -P)" AskUserQuestion "$Q_IN")" "" "$CPY/hooks/permission-hold.sh"
check "no question-stages.sh: AskUserQuestion from cad-context-p3 is denied with SendMessage" \
    bash -c "$(declare -f is_deny); is_deny '$PH_OUT' && printf '%s' '$PH_OUT' | jq -e '.hookSpecificOutput.decision.message | test(\"SendMessage\")' >/dev/null"
ph_reset
ph_run "$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")" 1 "$CPY/hooks/permission-hold.sh"
check "no question-stages.sh: another tool still takes the hold path (deadline deny, not a load deny)" \
    bash -c "grep -q '1 seconds' <<< '$PH_OUT' && ! grep -q 'could not be loaded' <<< '$PH_OUT'"

# --- anyone else gets no output ---
for CASE in "a directory outside any repo|$PLAIN" "the dashboard checkout|$FIX" "a done row's worktree|$DONE_WT"; do
    ph_run "$(ph_payload "${CASE#*|}" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")"
    check "not a live worker (${CASE%%|*}): no output, exit 0, no hold" bash -c "[ $PH_RC = 0 ] && [ -z '$PH_OUT' ] && [ -z \"\$(ls '$HOLD'/perm-*.pending 2>/dev/null)\" ]"
done
ph_run 'this is {not json'; check "garbage on stdin: no output, exit 0" is_silent
ph_run '{"cwd":"relative/dir","tool_name":"Bash","tool_input":{}}'; check "a relative cwd: no output, exit 0" is_silent
ph_run ''; check "empty stdin: no output, exit 0" is_silent

# --- the libraries missing or partly deployed: a live worker is never handed the native prompt ---
LAY_NONE="$SCRATCH/layNone"; LAY_PART="$SCRATCH/layPart"
mkdir -p "$LAY_NONE/hooks" "$LAY_PART/hooks" "$LAY_PART/lib"
cp "$HOOK" "$LAY_NONE/hooks/"; cp "$HOOK" "$LAY_PART/hooks/"
cp "$REPO_ROOT/orchestration/lib/session-state.sh" "$LAY_PART/lib/"
for LAY in "$LAY_NONE" "$LAY_PART"; do
    ph_run "$(ph_payload "$LIVE_WT" WebFetch '{"url":"u"}')" "" "$LAY/hooks/permission-hold.sh"
    check "$(basename "$LAY") (libraries missing): a cwd under /.claude/worktrees/ is denied, exit 0" bash -c "$(declare -f is_deny); is_deny '$PH_OUT'; [ $PH_RC = 0 ]"
    ph_run "$(ph_payload "$PLAIN" WebFetch '{"url":"u"}')" "" "$LAY/hooks/permission-hold.sh"
    check "$(basename "$LAY") (libraries missing): any other cwd prints nothing, exit 0" is_silent
done

check "no case called tmux" [ ! -s "$TMUX_LOG" ]

# --- the band reads and answers the hold exactly as it does a git hold ---
ph_reset
ph_start "$(ph_payload "$LIVE_WT" WebFetch "$(jq -nc --arg u "$OP" '{url:$u}')")"
if ph_wait_pending 1 5; then
    ID=$(basename "$(ph_pending | head -1)" .pending)
    ROWS=$(PATH="$STUB:$PATH" SWEEP_QUIET=1 ORCH_PROJECT_ROOT="$FIX" bash "$DISPATCH" --blocked-sweep 2>/dev/null | tr '\036' '\n')
    check "sweep: the hold is a row with label, answerable 1, id and hash set" \
        bash -c "printf '%s\n' \"\$1\" | awk -F'\037' -v id='$ID' -v h='$WANT' '\$1==\"live\" && \$6==1 && \$7==id && \$8==h {f=1} END{exit !f}'" _ "$ROWS"
    PATH="$STUB:$PATH" ORCH_PROJECT_ROOT="$FIX" env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "$SCRIPT_DIR/fixtures/run-as-decider.sh" band bash "$DISPATCH" --gate-decide live "$ID" allow "$WANT" >/dev/null 2>&1
    check "--gate-decide exits 0 for the hold" [ $? = 0 ]
    ph_wait_gone "$PH_PID" 3; check "--gate-decide: the hook then prints the allow shape" [ "$(cat "$PH_OUTF")" = "$ALLOW_SHAPE" ]
else
    fail "sweep: no pending record appeared"
fi

# --- Helm.app/.../Helm is the decider; any other bundle or executable is not ---
decide_as_app() { # bundle exec: stderr of --gate-decide for an id with no pending hold
    PATH="$STUB:$PATH" ORCH_PROJECT_ROOT="$FIX" APP_BUNDLE="$1" APP_EXEC="$2" env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID "$SCRIPT_DIR/fixtures/run-as-decider.sh" app bash "$DISPATCH" --gate-decide live no-such-id allow "$WANT" 2>&1 >/dev/null
}
for APP in Helm/Helm; do
    check "$APP is accepted as the decider" bash -c "! grep -q 'not the orchestrator-gui app' <<< \"\$1\"" _ "$(decide_as_app "${APP%/*}" "${APP#*/}")"
done
for APP in Other/Helm Helm/OrchestratorGUI OrchestratorGUI/OrchestratorGUI Canopy-Foreman/OrchestratorGUI; do
    check "$APP is refused as the decider" bash -c "grep -q 'not the orchestrator-gui app' <<< \"\$1\"" _ "$(decide_as_app "${APP%/*}" "${APP#*/}")"
done

echo
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
