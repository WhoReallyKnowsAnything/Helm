#!/bin/bash
# test/test-hook-wrapper.sh
# Runs the registration wrapper text EXACTLY as docs/orchestrator/approval-relay-setup.md gives
# it (the fence tagged "json wrapper-git-gate"), with the gate script absent, and
# checks it fails closed for a live worker and prints nothing for anyone else.
# The one change made to the text is the gate's absolute path, swapped for a path
# in the scratch dir; the test fails if that path is not found exactly once, so it
# cannot pass on text it did not mean to run.
# HOOK_WRAPPER_DOC overrides the guide path (used for the falsifiability check).
# Plain bash, no framework. Never touches ~/.claude or the default tmux server.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="${HOOK_WRAPPER_DOC:-$REPO_ROOT/docs/orchestrator/approval-relay-setup.md}"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

SCRATCH=$(mktemp -d) || { echo "FAIL: no scratch dir"; exit 1; }
SCRATCH=$(cd "$SCRATCH" && pwd -P)
cleanup() { cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

# --- pull the wrapper command out of the guide ---
BLOCK=$(awk '/^```json wrapper-git-gate[[:space:]]*$/{f=1;next} f&&/^```/{exit} f' "$DOC")
CMD_TEXT=$(printf '%s' "$BLOCK" | jq -r .command 2>/dev/null)
if [ -z "$BLOCK" ] || [ -z "$CMD_TEXT" ] || [ "$CMD_TEXT" = null ]; then
    fail "wrapper: no json wrapper-git-gate block with a .command in $DOC"
    echo; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
fi

# The gate path: the one token that starts with $HOME/ (it may hold a space) and ends in the
# gate script name. The reason text also names the script, but without a "/" before it.
GATE_ABS=$(printf '%s' "$CMD_TEXT" | grep -oE '\$HOME/[^"]*orchestration/hooks/git-approval-gate\.sh')
GATE_ABS_N=$(printf '%s\n' "$GATE_ABS" | grep -c .)
STRIPPED=${CMD_TEXT//"$GATE_ABS"/}
if [ "$GATE_ABS_N" = 1 ] && [ $(( ${#CMD_TEXT} - ${#STRIPPED} )) -eq ${#GATE_ABS} ]; then
    pass "wrapper: the gate's absolute path appears exactly once in the documented command"
else
    fail "wrapper: the gate path was found $GATE_ABS_N time(s) as a token and not exactly once in the text"
    echo; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
fi

# --- fixture: a git repo with a state store, two linked worktrees, a dashboard row ---
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
mkdir -p "$LIVE_WT/sub"
for QL in cad-context-p3 cad-execute-p1 cad-plan-p4 cad-milestone-p1 cad-milestone-p3 cad-milestone-p3x; do git -C "$FIX" worktree add -q -b "session/$QL" "$FIX/.claude/worktrees/$QL" 2>/dev/null; done
LIVE_WT=$(cd "$LIVE_WT" && pwd -P)
DONE_WT=$(cd "$DONE_WT" && pwd -P)
PLAIN="$SCRATCH/plain"
mkdir -p "$PLAIN"
(
    cd "$FIX" || exit 1
    # shellcheck source=../orchestration/lib/session-state.sh
    source "$REPO_ROOT/orchestration/lib/session-state.sh"
    session_state_write live "$LIVE_WT" running >/dev/null
    session_state_write finished "$DONE_WT" done >/dev/null
    session_state_write dashboard "$FIX" running >/dev/null
    for QL in cad-context-p3 cad-execute-p1 cad-plan-p4 cad-milestone-p1 cad-milestone-p3 cad-milestone-p3x; do session_state_write "$QL" "$(cd "$FIX/.claude/worktrees/$QL" && pwd -P)" running >/dev/null; done
) || { echo "FAIL: fixture rows"; exit 1; }

# --- scratch layouts ---
# A: lib/ copied from the repo (so session-state.sh is the real one), hooks/ with no gate.
# B: hooks/ only, no lib/.   C: hooks/ holding a stub gate that echoes its stdin.
LAY_A="$SCRATCH/layA"; LAY_B="$SCRATCH/layB"; LAY_C="$SCRATCH/layC"
mkdir -p "$LAY_A/hooks" "$LAY_B/hooks" "$LAY_C/hooks" "$LAY_C/lib"
cp -R "$REPO_ROOT/orchestration/lib" "$LAY_A/lib"
printf '#!/bin/bash\ncat\n' > "$LAY_C/hooks/git-approval-gate.sh"
chmod +x "$LAY_C/hooks/git-approval-gate.sh"

# wrap_run layout cwd stdin_file -> W_OUT / W_RC. Runs the documented text with the
# working directory set to the payload cwd (Claude Code runs a hook there).
wrap_run() {
    local text=${CMD_TEXT//"$GATE_ABS"/"$1/hooks/git-approval-gate.sh"} raw
    # The marker after the run keeps a trailing newline in the output intact.
    raw=$(cd "$2" && bash -c "$text" < "$3" 2>/dev/null; echo "@@RC=$?")
    W_RC=${raw##*@@RC=}
    W_OUT=${raw%@@RC=*}
}

payload_file() { # cwd [command] -> path of a payload file
    local f; f=$(mktemp "$SCRATCH/payload.XXXXXX")
    jq -nj --arg cwd "$1" --arg cmd "${2:-git push origin main}" \
        '{cwd:$cwd,tool_name:"Bash",tool_use_id:"toolu_w1",tool_input:{command:$cmd}}' > "$f"
    echo "$f"
}

expect_deny() { # name layout cwd stdin_file
    wrap_run "$2" "$3" "$4"
    if [ "$W_RC" = 0 ] && [[ "$W_OUT" == *'"permissionDecision":"deny"'* ]] \
        && printf '%s' "$W_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | test("missing"))' >/dev/null 2>&1; then
        pass "wrapper: $1 gives a PreToolUse deny that says the script is missing, exit 0"
    else
        fail "wrapper: $1: rc=$W_RC out='$W_OUT'"
    fi
}

expect_silent() { # name layout cwd stdin_file
    wrap_run "$2" "$3" "$4"
    if [ "$W_RC" = 0 ] && [ -z "$W_OUT" ]; then
        pass "wrapper: $1 prints nothing, exit 0"
    else
        fail "wrapper: $1: rc=$W_RC out='$W_OUT'"
    fi
}

expect_ask() { # name layout cwd stdin_file: the wrapper cannot read the cwd, so it must hand the call to the native prompt
    wrap_run "$2" "$3" "$4"
    if [ "$W_RC" = 0 ] && printf '%s' "$W_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then
        pass "wrapper: $1 gives a PreToolUse ask, exit 0"
    else
        fail "wrapper: $1: rc=$W_RC out='$W_OUT'"
    fi
}

# --- gate script absent, lib present (layout A) ---
expect_deny   "missing script, live worker at its worktree root" "$LAY_A" "$LIVE_WT"     "$(payload_file "$LIVE_WT")"
expect_deny   "missing script, live worker in a subdirectory"    "$LAY_A" "$LIVE_WT/sub" "$(payload_file "$LIVE_WT/sub")"
expect_silent "missing script, the dashboard checkout"           "$LAY_A" "$FIX"         "$(payload_file "$FIX")"
expect_silent "missing script, a done row's worktree (its path contains /.claude/worktrees/)" "$LAY_A" "$DONE_WT" "$(payload_file "$DONE_WT")"
expect_silent "missing script, a directory outside any repo"     "$LAY_A" "$PLAIN"       "$(payload_file "$PLAIN")"
GARBAGE=$(mktemp "$SCRATCH/garbage.XXXXXX"); printf 'this is {not json' > "$GARBAGE"
expect_ask    "missing script, garbage on stdin (run in the live worktree)" "$LAY_A" "$LIVE_WT" "$GARBAGE"
# A worker cannot spoof its cwd through the command text: only the parsed cwd field counts.
SPOOF=$(mktemp "$SCRATCH/spoof.XXXXXX")
jq -nj --arg cwd "$LIVE_WT" --arg cmd "echo \"cwd\":\"$PLAIN\"" '{tool_input:{command:$cmd},cwd:$cwd,tool_name:"Bash"}' > "$SPOOF"
expect_deny   "missing script, a command that quotes a fake cwd field (key order moved)" "$LAY_A" "$LIVE_WT" "$SPOOF"

# --- gate script absent, no lib either (layout B): the last-resort path rule ---
expect_deny   "no script and no lib, a cwd containing /.claude/worktrees/" "$LAY_B" "$LIVE_WT" "$(payload_file "$LIVE_WT")"
expect_silent "no script and no lib, any other cwd"                        "$LAY_B" "$PLAIN"   "$(payload_file "$PLAIN")"

# --- gate script present: the payload passes through untouched ---
PASS_IN=$(mktemp "$SCRATCH/passthru.XXXXXX")
printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"echo caf\xc3\xa9 \\n tab\\t end"}}' "$LIVE_WT" > "$PASS_IN"
wrap_run "$LAY_C" "$LIVE_WT" "$PASS_IN"
if [ "$W_RC" = 0 ] && [ "$W_OUT" = "$(cat "$PASS_IN")" ]; then
    pass "wrapper: with the gate script present the wrapper's stdout equals the payload byte for byte"
else
    fail "wrapper: pass-through differs: rc=$W_RC out='$W_OUT'"
fi

# =====================================================================
# PermissionRequest hook wrapper: the fence tagged "json wrapper-permission-hold".
# Stub hook scripts stand in for permission-hold.sh; a real lib/ copy supplies
# live_worker_agent. The bound is shortened to 2 s through the env var the text
# reads, the text itself is not edited. perl is required, so its absence is a FAIL.
# =====================================================================
if command -v perl >/dev/null 2>&1; then
    pass "permission wrapper: perl is on PATH"
else
    fail "permission wrapper: perl is not on PATH (the wrapper depends on it)"
fi
PBLOCK=$(awk '/^```json wrapper-permission-hold[[:space:]]*$/{f=1;next} f&&/^```/{exit} f' "$DOC")
PCMD_TEXT=$(printf '%s' "$PBLOCK" | jq -r .command 2>/dev/null)
if [ -z "$PBLOCK" ] || [ -z "$PCMD_TEXT" ] || [ "$PCMD_TEXT" = null ]; then
    fail "permission wrapper: no json wrapper-permission-hold block with a .command in $DOC"
    echo; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
fi
PH_ABS=$(printf '%s' "$PCMD_TEXT" | grep -oE '\$HOME/[^"]*orchestration/hooks/permission-hold\.sh')
PH_ABS_N=$(printf '%s\n' "$PH_ABS" | grep -c .)
PH_STRIPPED=${PCMD_TEXT//"$PH_ABS"/}
if [ "$PH_ABS_N" = 1 ] && [ $(( ${#PCMD_TEXT} - ${#PH_STRIPPED} )) -eq ${#PH_ABS} ]; then
    pass "permission wrapper: the hook's absolute path appears exactly once in the documented command"
else
    fail "permission wrapper: the hook path was found $PH_ABS_N time(s) as a token and not exactly once in the text"
    echo; echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"; exit 1
fi
case "$PCMD_TEXT" in *'${APPROVAL_HOOK_ALARM_SECS:-'*) pass "permission wrapper: the bound is read as \${APPROVAL_HOOK_ALARM_SECS:-<default>}" ;; *) fail "permission wrapper: the bound is not read from APPROVAL_HOOK_ALARM_SECS" ;; esac

git -C "$LIVE_WT" init -q "$LIVE_WT/vendor/nested"
NESTED="$LIVE_WT/vendor/nested"

# pl_layout name stub_body|-|NOLIB: a scratch tree with hooks/permission-hold.sh = the stub
# (none for "-"), and a real lib/ copy unless the body is NOLIB.
pl_layout() {
    local d="$SCRATCH/pl-$1"
    mkdir -p "$d/hooks"
    [ "$2" = NOLIB ] || cp -R "$REPO_ROOT/orchestration/lib" "$d/lib"
    if [ "$2" != - ] && [ "$2" != NOLIB ]; then
        printf '#!/bin/bash\n%s\n' "$2" > "$d/hooks/permission-hold.sh"
        chmod +x "$d/hooks/permission-hold.sh"
    fi
    echo "$d"
}
ALLOW_SHAPE='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# pw_run layout cwd stdin_file -> W_OUT / W_RC (bound 2 s)
pw_run() {
    local text=${PCMD_TEXT//"$PH_ABS"/"$1/hooks/permission-hold.sh"} raw
    raw=$(cd "$2" && APPROVAL_HOOK_ALARM_SECS=2 bash -c "$text" < "$3" 2>/dev/null; echo "@@RC=$?")
    W_RC=${raw##*@@RC=}
    W_OUT=${raw%@@RC=*}
}
pw_payload() { # cwd -> a PermissionRequest payload file
    local f; f=$(mktemp "$SCRATCH/pp.XXXXXX")
    jq -nj --arg cwd "$1" --arg t "${2:-WebFetch}" '{session_id:"s1",cwd:$cwd,tool_name:$t,tool_input:{url:"https://example.com"},hook_event_name:"PermissionRequest"}' > "$f"
    echo "$f"
}
pw_expect_deny() { # name layout cwd message_regex
    local t0 t1
    t0=$SECONDS; pw_run "$2" "$3" "$(pw_payload "$3")"; t1=$SECONDS
    if [ "$W_RC" = 0 ] && [ $((t1 - t0)) -le 6 ] && [ -n "$W_OUT" ] && printf '%s' "$W_OUT" | jq -e --arg re "$4" '.hookSpecificOutput.hookEventName == "PermissionRequest" and .hookSpecificOutput.decision.behavior == "deny" and (.hookSpecificOutput.decision.message | test($re))' >/dev/null 2>&1; then
        pass "permission wrapper: $1 gives the deny shape naming the failure, exit 0 ($((t1 - t0)) s)"
    else
        fail "permission wrapper: $1: rc=$W_RC after $((t1 - t0)) s out='$W_OUT'"
    fi
}
pw_expect_silent() { # name layout cwd
    local t0 t1
    t0=$SECONDS; pw_run "$2" "$3" "$(pw_payload "$3")"; t1=$SECONDS
    if [ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && [ $((t1 - t0)) -le 6 ]; then
        pass "permission wrapper: $1 prints nothing, exit 0"
    else
        fail "permission wrapper: $1: rc=$W_RC after $((t1 - t0)) s out='$W_OUT'"
    fi
}

# name|stub body|message regex: the six failure cases (a missing script has no stub)
PW_CASES=(
    "exit 1, no output|cat >/dev/null; exit 1|crashed"
    "exit 2|cat >/dev/null; exit 2|crashed"
    "invalid JSON, exit 0|echo 'not json'; exit 0|crashed"
    "valid JSON with no decision, exit 0|echo '{}'; exit 0|crashed"
    "empty output, exit 0|exit 0|no decision"
    "a hang past the bound|exec sleep 30|timed out"
    "a missing script|-|missing"
)
for PW_CASE in "${PW_CASES[@]}"; do
    IFS='|' read -r PW_NAME PW_BODY PW_RE <<< "$PW_CASE"
    PW_LAY=$(pl_layout "$(printf '%s' "$PW_NAME" | tr -c 'A-Za-z0-9' _)" "$PW_BODY")
    pw_expect_deny   "$PW_NAME, live worker at its worktree root" "$PW_LAY" "$LIVE_WT"     "$PW_RE"
    pw_expect_deny   "$PW_NAME, live worker in a nested git repo"  "$PW_LAY" "$NESTED"      "$PW_RE"
    pw_expect_silent "$PW_NAME, the dashboard checkout"            "$PW_LAY" "$FIX"
    pw_expect_silent "$PW_NAME, a done row's worktree"             "$PW_LAY" "$DONE_WT"
    pw_expect_silent "$PW_NAME, a directory outside any repo"      "$PW_LAY" "$PLAIN"
done

# A healthy hook's allow shape passes through byte for byte for a live worker.
PW_OK=$(pl_layout allow "printf '%s' '$ALLOW_SHAPE'")
pw_run "$PW_OK" "$LIVE_WT" "$(pw_payload "$LIVE_WT")"
if [ "$W_RC" = 0 ] && [ "$W_OUT" = "$ALLOW_SHAPE" ]; then
    pass "permission wrapper: a hook that prints the allow shape is passed through byte for byte, exit 0"
else
    fail "permission wrapper: allow pass-through differs: rc=$W_RC out='$W_OUT'"
fi
# Empty hook output: passed through only for AskUserQuestion from a listed stage worker.
QW="$FIX/.claude/worktrees"
PW_EMPTY=$(pl_layout emptyq 'exit 0')
pw_run "$PW_EMPTY" "$QW/cad-context-p3" "$(pw_payload "$QW/cad-context-p3" AskUserQuestion)"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: empty output for AskUserQuestion from cad-context-p3 is passed through" || fail "permission wrapper: listed empty pass-through: rc=$W_RC out='$W_OUT'"
pw_run "$PW_EMPTY" "$QW/cad-plan-p4" "$(pw_payload "$QW/cad-plan-p4" AskUserQuestion)"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: empty output for AskUserQuestion from cad-plan-p4 is passed through" || fail "permission wrapper: plan empty pass-through: rc=$W_RC out='$W_OUT'"
pw_run "$PW_EMPTY" "$QW/cad-execute-p1" "$(pw_payload "$QW/cad-execute-p1" AskUserQuestion)"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: empty output for AskUserQuestion from cad-execute-p1 is passed through" || fail "permission wrapper: execute empty pass-through: rc=$W_RC out='$W_OUT'"
pw_run "$PW_EMPTY" "$QW/cad-milestone-p3" "$(pw_payload "$QW/cad-milestone-p3" AskUserQuestion)"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: empty output for AskUserQuestion from cad-milestone-p3 is passed through" || fail "permission wrapper: milestone empty pass-through: rc=$W_RC out='$W_OUT'"
pw_run "$PW_EMPTY" "$QW/cad-milestone-p3x" "$(pw_payload "$QW/cad-milestone-p3x" AskUserQuestion)"
printf '%s' "$W_OUT" | grep -q 'no decision' && pass "permission wrapper: empty output, AskUserQuestion, unlisted label: deny" || fail "permission wrapper: unlisted empty: '$W_OUT'"
pw_run "$PW_EMPTY" "$QW/cad-context-p3" "$(pw_payload "$QW/cad-context-p3" WebFetch)"
printf '%s' "$W_OUT" | grep -q 'no decision' && pass "permission wrapper: empty output, other tool, listed label: deny" || fail "permission wrapper: other tool empty: '$W_OUT'"
# A hook that prints nothing for a cwd that is not a live worker (the native prompt shows).
pw_run "$(pl_layout quiet 'exit 0')" "$PLAIN" "$(pw_payload "$PLAIN")"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: a quiet hook for a non-worker stays quiet" || fail "permission wrapper: quiet pass-through: rc=$W_RC out='$W_OUT'"

# No lib/ at all: the last-resort path rule.
PW_NOLIB=$(pl_layout nolib NOLIB)
pw_expect_deny   "no script and no lib, a cwd containing /.claude/worktrees/" "$PW_NOLIB" "$LIVE_WT" "missing"
pw_expect_silent "no script and no lib, any other cwd"                        "$PW_NOLIB" "$PLAIN"
pw_run "$(pl_layout garbage '[ -n "$NEVER" ]; exit 1')" "$LIVE_WT" "$GARBAGE"
[ "$W_RC" = 0 ] && [ -z "$W_OUT" ] && pass "permission wrapper: a crash with garbage on stdin (no readable cwd) prints nothing, exit 0" || fail "permission wrapper: garbage stdin: rc=$W_RC out='$W_OUT'"

echo
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
