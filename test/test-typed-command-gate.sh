#!/bin/bash
# test/test-typed-command-gate.sh
# Exercises orchestration/hooks/typed-command-gate.sh and its node helper.
# Fixture repos and a scratch HOME only; no real settings or state db.
# Plain bash, no framework.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT="$REPO_ROOT/orchestration/init/init-state-store.sh"
HOOK="$REPO_ROOT/orchestration/hooks/typed-command-gate.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_ROOT=$(mktemp -d)
new_tmp() { mktemp -d "$TMP_ROOT/d.XXXXXX"; }
cleanup() { cd / || true; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

new_repo() {
    local d
    d=$(new_tmp)
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "test"
    echo seed > "$d/seed.txt"
    git -C "$d" add seed.txt
    git -C "$d" commit -qm "seed"
    git -C "$d" rev-parse --show-toplevel
}

# make_worker agent: a repo, a state db and a live worktree row. Sets W_REPO, W_WT.
make_worker() {
    local agent="$1" wt
    W_REPO=$(new_repo)
    "$INIT" "$W_REPO" >/dev/null 2>&1
    wt="$(new_tmp)/wt"
    git -C "$W_REPO" worktree add -q -b "br-$agent" "$wt"
    W_WT=$(git -C "$wt" rev-parse --show-toplevel)
    sqlite3 "$W_REPO/.claude/session-state.db" "INSERT INTO sessions (agent_id, worktree_path, status, updated_at) VALUES ('$agent', '$W_WT', 'running', '2020-01-01 00:00:00');"
}

SCRATCH_HOME=$(new_tmp)

# payload cwd prompt
payload() { printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"%s"}' "$1" "$2"; }

# run_hook cwd prompt [VAR=value...]: stdout in OUT, exit code in RC. CLAUDE_GUI unset unless given.
run_hook() {
    local cwd="$1" prompt="$2"; shift 2
    OUT=$(payload "$cwd" "$prompt" | env -u CLAUDE_GUI HOME="$SCRATCH_HOME" "$@" bash "$HOOK" 2>/dev/null)
    RC=$?
}

# --- Task 1: Helm-session scope ---

if [ -x "$HOOK" ]; then pass "hook is executable"; else fail "hook is not executable"; fi

PLAIN=$(new_repo)
run_hook "$PLAIN" "/cadence:cad-execute 2"
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then pass "plain repo, CLAUDE_GUI unset: no output"; else fail "plain repo, CLAUDE_GUI unset (rc=$RC out=$OUT)"; fi

run_hook "$PLAIN" "hello" CLAUDE_GUI=1
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then pass "CLAUDE_GUI=1: no output, exit 0"; else fail "CLAUDE_GUI=1 (rc=$RC out=$OUT)"; fi

make_worker w1
run_hook "$W_WT" "hello"
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then pass "live worker worktree: no output, exit 0"; else fail "live worker worktree (rc=$RC out=$OUT)"; fi

NOGIT=$(new_tmp)
run_hook "$NOGIT" "/cadence:cad-execute 2" CLAUDE_GUI=1
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then pass "cwd outside a git repo: exit 0"; else fail "cwd outside a git repo (rc=$RC out=$OUT)"; fi

# --- Task 2: command match, phase resolution, G2 ---

# A stub Cadence: a scratch HOME whose installed_plugins.json points at a stub
# install. The stub scripts answer from environment variables.
STUB_HOME=$(new_tmp)
STUB_INSTALL=$(new_tmp)
mkdir -p "$STUB_HOME/.claude/plugins" "$STUB_INSTALL/cadence-core/bin"
printf '{"plugins":{"cadence@cadence":[{"installPath":"%s"}]}}' "$STUB_INSTALL" > "$STUB_HOME/.claude/plugins/installed_plugins.json"
cat > "$STUB_INSTALL/cadence-core/bin/planning.mjs" <<'EOF'
const e = process.env, c = process.argv[2];
const k = { status: 'STATUS', audit: 'AUDIT', 'criteria-coverage': 'COVERAGE' }[c];
if (!k) process.exit(2);
if (e['STUB_' + k + '_SLEEP']) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Number(e['STUB_' + k + '_SLEEP']) * 1000);
if (e['STUB_' + k + '_EXIT']) { process.stderr.write('stub failure'); process.exit(Number(e['STUB_' + k + '_EXIT'])); }
process.stdout.write(e['STUB_' + k] || '');
EOF
cat > "$STUB_INSTALL/cadence-core/bin/config.mjs" <<'EOF'
process.stdout.write(process.env.STUB_CONFIG || '');
process.exit(Number(process.env.STUB_CONFIG_EXIT || 0));
EOF

STATUS_12='{"ok":true,"current":2,"phases":[{"n":1,"name":"a","status":"complete"},{"n":2,"name":"b","status":"unplanned"}]}'

# run_stub prompt [VAR=value...]: a Helm session (CLAUDE_GUI=1) against the stub Cadence.
run_stub() {
    local prompt="$1"; shift
    OUT=$(payload "${CASE_REPO:-$PLAIN}" "$prompt" | env -u CLAUDE_GUI HOME="$STUB_HOME" CLAUDE_GUI=1 "$@" bash "$HOOK" 2>/dev/null)
    RC=$?
}
expect_block() { # label prompt vars...
    local label="$1"; shift
    run_stub "$@"
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"decision":"block"' && printf '%s' "$OUT" | grep -q "$EXPECT_TEXT"; then
        pass "$label"
    else fail "$label (rc=$RC out=$OUT)"; fi
}
expect_silent() { # label prompt vars...
    local label="$1"; shift
    run_stub "$@"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "$label"; else fail "$label (rc=$RC out=$OUT)"; fi
}

EXPECT_TEXT='G2:'
expect_block "G2 blocks /cadence:cad-execute 2" "/cadence:cad-execute 2" STUB_STATUS="$STATUS_12"
expect_block "G2 blocks /cad-execute 2" "/cad-execute 2" STUB_STATUS="$STATUS_12"
expect_block "G2 blocks bare /cad-execute (first open phase)" "/cad-execute" STUB_STATUS="$STATUS_12"
expect_block "G2 block reason names override" "/cad-execute 2" STUB_STATUS="$STATUS_12"
printf '%s' "$OUT" | grep -q 'override: <reason>' && pass "block names the override form" || fail "block lacks override sentence"
expect_silent "G2 passes /cad-execute 1 (complete)" "/cad-execute 1" STUB_STATUS="$STATUS_12"
expect_silent "G2 passes a phase not in the list" "/cad-execute 9" STUB_STATUS="$STATUS_12"
expect_silent "/cad-executed 2 does not match" "/cad-executed 2" STUB_STATUS="$STATUS_12"
expect_silent "plain prompt does not match" "hello" STUB_STATUS="$STATUS_12"
expect_silent "a flag argument is a bare command on a planned phase" "/cad-execute --gaps" \
    STUB_STATUS='{"ok":true,"phases":[{"n":1,"name":"a","status":"planned"}]}'

STATUS_110='{"ok":true,"current":1.10,"phases":[{"n":1.1,"name":"a","status":"complete"},{"n":1.10,"name":"b","status":"unplanned"}]}'
expect_block "phase 1.10 is judged as 1.10, not 1.1" "/cad-execute 1.10" STUB_STATUS="$STATUS_110"
expect_silent "phase 1.1 is still its own phase" "/cad-execute 1.1" STUB_STATUS="$STATUS_110"

# Fail open with a visible context line.
expect_context() { # label prompt vars...
    local label="$1"; shift
    run_stub "$@"
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'gate check could not run' && ! printf '%s' "$OUT" | grep -q '"decision":"block"'; then
        pass "$label"
    else fail "$label (rc=$RC out=$OUT)"; fi
}
expect_context "status exit 1 with no JSON passes with a context line" "/cad-execute 2" STUB_STATUS_EXIT=1
NO_PLUGINS_HOME=$(new_tmp)
OUT=$(payload "$PLAIN" "/cad-execute 2" | env -u CLAUDE_GUI HOME="$NO_PLUGINS_HOME" CLAUDE_GUI=1 bash "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'gate check could not run' && ! printf '%s' "$OUT" | grep -q '"decision":"block"'; then
    pass "no installed_plugins.json passes with a context line"
else fail "no installed_plugins.json (rc=$RC out=$OUT)"; fi

# AC6: a session that is not Helm's gets no output for a failing command.
OUT=$(payload "$PLAIN" "/cad-execute 2" | env -u CLAUDE_GUI HOME="$STUB_HOME" STUB_STATUS="$STATUS_12" bash "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "non-Helm session: failing command passes untouched"; else fail "non-Helm session (rc=$RC out=$OUT)"; fi

# --- Tasks 3 and 4: G1 and G4 ---

CTX_REPO=$(new_repo); mkdir -p "$CTX_REPO/.planning/phases/2"; : > "$CTX_REPO/.planning/phases/2/CONTEXT.md"
case_in() { CASE_REPO="$1"; shift; "$@"; CASE_REPO=""; }
CASE_REPO=""
EXPECT_TEXT='G1:'
for p in "/cadence:cad-plan 2" "/cad-plan 2"; do
    expect_block "G1 blocks $p without CONTEXT.md" "$p" STUB_STATUS="$STATUS_12" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":false}}'
done
case_in "$CTX_REPO" expect_silent "G1 passes with CONTEXT.md" "/cad-plan 2" STUB_STATUS="$STATUS_12" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":false}}'
expect_silent "G1 passes when skip_discuss is true" "/cad-plan 2" STUB_STATUS="$STATUS_12" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":true}}'
expect_block "G1 blocks when config exits 1 with no JSON" "/cad-plan 2" STUB_STATUS="$STATUS_12" STUB_CONFIG_EXIT=1

EXPECT_TEXT='finds 3 problems'
AUDIT_2='{"ok":true,"counts":{"total":5,"broken":2},"requirements":[]}'
AUDIT_0='{"ok":true,"counts":{"total":5,"broken":0},"requirements":[]}'
AUDIT_DRIFT='{"ok":true,"counts":{"total":5,"broken":0},"version_drift":{"doc_version":"1","published_as":"2","cycle_state":"x"}}'
COV_1='{"ok":true,"breaks":[{"break":"x","id":"R1"}]}'
COV_0='{"ok":true,"breaks":[],"counts":{"uncovered":4}}'
expect_block "G4 counts broken 2 + 1 coverage break" "/cad-milestone" STUB_AUDIT="$AUDIT_2" STUB_COVERAGE="$COV_1"
EXPECT_TEXT='finds 1 problems'
expect_block "G4 counts version drift as 1" "/cad-milestone" STUB_AUDIT="$AUDIT_DRIFT" STUB_COVERAGE="$COV_0"
expect_silent "G4 passes at 0 (uncovered is not counted)" "/cadence:cad-milestone 1.0" STUB_AUDIT="$AUDIT_0" STUB_COVERAGE="$COV_0"
EXPECT_TEXT='did not run'
expect_block "G4 blocks when audit exits 1 with no JSON" "/cad-milestone" STUB_AUDIT_EXIT=1 STUB_COVERAGE="$COV_0"
expect_block "G4 blocks when coverage times out" "/cad-milestone" STUB_AUDIT="$AUDIT_0" STUB_COVERAGE="$COV_0" STUB_COVERAGE_SLEEP=3 TYPED_GATE_TIMEOUT_MS=1000

# --- Task 5: parity with the board (Sources/Helm/WorkflowGates.swift) ---

SWIFT="$REPO_ROOT/Sources/Helm/WorkflowGates.swift"
HELPER="${TYPED_GATE_HELPER:-$REPO_ROOT/orchestration/lib/typed-command-gate.js}"
for s in 'G1: this phase has no CONTEXT.md and skip discuss is off. Run context first.' \
         'G2: this phase is unplanned. Plan it before you execute it.' \
         'G4: the audit finds ' \
         'G4: the audit did not run.'; do
    if grep -qF "$s" "$SWIFT" && grep -qF "$s" "$HELPER"; then pass "parity: board and hook share \"$s\""; else fail "parity: sentence differs: $s"; fi
done

# The g1/g2/g4 case table of WorkflowGatesTests.swift, through the hook.
EXPECT_TEXT='G2:'
expect_block "table g2: unplanned blocks" "/cad-execute" STUB_STATUS='{"ok":true,"phases":[{"n":1,"name":"x","status":"unplanned"}]}'
expect_silent "table g2: planned passes" "/cad-execute" STUB_STATUS='{"ok":true,"phases":[{"n":1,"name":"x","status":"planned"}]}'
EXPECT_TEXT='G1:'
S1='{"ok":true,"phases":[{"n":1,"name":"x","status":"unplanned"}]}'
expect_block "table g1: no context, not waived blocks" "/cad-plan" STUB_STATUS="$S1" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":false}}'
expect_silent "table g1: waived passes" "/cad-plan" STUB_STATUS="$S1" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":true}}'
EXPECT_TEXT='G4:'
expect_block "table g4: broken 12 blocks" "/cad-milestone" STUB_AUDIT='{"ok":true,"counts":{"total":12,"broken":12}}' STUB_COVERAGE="$COV_0"
expect_silent "table g4: 0 passes" "/cad-milestone" STUB_AUDIT="$AUDIT_0" STUB_COVERAGE="$COV_0"
EXPECT_TEXT='boom\|did not run'
expect_block "table g4: failed run blocks" "/cad-milestone" STUB_AUDIT_EXIT=1

# --- Plan 3: override and the shared marker ---

MH=$(new_tmp)
cat > "$TMP_ROOT/marker.js" <<'EOF'
const g = require(process.argv[2]);
const [op, root, skill, phase] = process.argv.slice(3);
if (op === 'write') g.writeMarker(root, skill, phase);
else process.stdout.write(String(g.consumeMarker(root, skill, phase)));
EOF
marker() { HELM_SUPPORT_DIR="$MH" node "$TMP_ROOT/marker.js" "$HELPER" "$@"; }

expect_context() { # label prompt vars...
    local label="$1"; shift
    run_stub "$@"
    if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '"decision"' \
        && printf '%s' "$OUT" | grep -q 'not a phase or version argument' \
        && printf '%s' "$OUT" | grep -q 'cad-capture' && printf '%s' "$OUT" | grep -qF -- "$EXPECT_TEXT"; then
        pass "$label"
    else fail "$label (rc=$RC out=$OUT)"; fi
}

EXPECT_TEXT='tests are slow'
expect_context "override on an unplanned phase runs with context" "/cad-execute 2 override: tests are slow" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
EXPECT_TEXT='tests are slow'
expect_context "override on a bare command passes with context" "/cad-execute override: tests are slow" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
EXPECT_TEXT='override reason is empty'
expect_block "empty override reason blocks" "/cad-execute 2 override:" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
expect_block "blank override reason blocks" "/cad-execute 2 override:   " STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
EXPECT_TEXT='2000'
LONG=$(head -c 2001 /dev/zero | tr '\0' 'a')
expect_block "a 2001 character reason blocks and names the cap" "/cad-execute 2 override: $LONG" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"

# The phase comes from the text before override:, never from the reason.
rm -rf "$MH/typed-gate-override"
run_stub "/cad-execute override: 2" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
if [ "$(marker consume "$PLAIN" execute)" = true ] && [ "$(marker consume "$PLAIN" execute 2)" = false ]; then
    pass "a reason word is not read as the phase"; else fail "reason word read as the phase"; fi

# The reason never reaches a shell.
rm -f /tmp/x
EXPECT_TEXT='touch /tmp/x'
expect_context "shell text in a reason is only printed" '/cad-execute 2 override: $(touch /tmp/x) `touch /tmp/x`' STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
if [ ! -e /tmp/x ]; then pass "shell text in a reason creates no file"; else fail "shell text ran"; rm -f /tmp/x; fi

# Marker store
marker write "$PLAIN" plan 3
if [ "$(marker consume "$PLAIN" plan 3)" = true ] && [ "$(marker consume "$PLAIN" plan 3)" = false ]; then
    pass "marker is read once"; else fail "marker not one-time"; fi
rm -rf "$MH/typed-gate-override"
marker write "$PLAIN" plan 3
F=$(ls "$MH/typed-gate-override" | head -1)
touch -t 200001010000 "$MH/typed-gate-override/$F"
if [ "$(marker consume "$PLAIN" plan 3)" = false ] && [ ! -e "$MH/typed-gate-override/$F" ]; then
    pass "an expired marker is false and gone"; else fail "expired marker"; fi
touch -t 200001010000 "$MH/typed-gate-override/stale"
marker write "$PLAIN" plan 4
if [ ! -e "$MH/typed-gate-override/stale" ]; then pass "a write sweeps old files"; else fail "old file not swept"; fi
F=$(ls "$MH/typed-gate-override" | head -1)
if [ "$(stat -f %Lp "$MH/typed-gate-override")" = 700 ] && [ "$(stat -f %Lp "$MH/typed-gate-override/$F")" = 600 ]; then
    pass "marker folder is 700 and file is 600"; else fail "marker modes"; fi
make_worker w9
marker write "$W_WT" execute 5
if [ "$(marker consume "$W_REPO" execute 5)" = true ]; then pass "worktree and main checkout share a marker"; else fail "worktree key differs"; fi

# Typed override and board line write markers
rm -rf "$MH/typed-gate-override"
run_stub "/cad-execute 2 override: slow" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
if [ "$(marker consume "$PLAIN" execute 2)" = true ] && [ "$(marker consume "$PLAIN" execute 2)" = false ]; then
    pass "typed override writes one marker"; else fail "typed override marker"; fi
BL='Cadence stage: skill=/cadence:cad-plan phase=2 model=none effort=none'
run_stub "$BL reason: user checked" HELM_SUPPORT_DIR="$MH"
if [ -z "$OUT" ] && [ "$(marker consume "$PLAIN" plan 2)" = true ]; then pass "board line with a reason writes a marker"; else fail "board reason marker (out=$OUT)"; fi
run_stub "$BL" HELM_SUPPORT_DIR="$MH"
if [ -z "$OUT" ] && [ "$(marker consume "$PLAIN" plan 2)" = false ]; then pass "board line without a reason writes none"; else fail "board no-reason (out=$OUT)"; fi
run_stub "Cadence stage: skill=/cadence:cad-progress phase=2 model=none effort=none reason: x" HELM_SUPPORT_DIR="$MH"
if [ -z "$OUT" ] && [ "$(marker consume "$PLAIN" progress 2)" = false ] && [ -z "$(ls "$MH/typed-gate-override" 2>/dev/null)" ]; then
    pass "board line for another skill writes none"; else fail "board other skill"; fi

# --- Plan 4: the Skill tool path ---

# skill_payload tool cwd skill args
skill_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"%s","cwd":"%s","tool_input":{"skill":"%s","args":"%s"}}' "$1" "$2" "$3" "$4"; }
# run_skill tool skill args [VAR=value...]: a Helm session against the stub Cadence.
run_skill() {
    local tool="$1" skill="$2" args="$3"; shift 3
    OUT=$(skill_payload "$tool" "${CASE_REPO:-$PLAIN}" "$skill" "$args" | env -u CLAUDE_GUI HOME="$STUB_HOME" CLAUDE_GUI=1 "$@" bash "$HOOK" 2>/dev/null)
    RC=$?
}
skill_deny() { # label skill args vars...
    local label="$1" skill="$2" args="$3"; shift 3
    run_skill Skill "$skill" "$args" "$@"
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' && printf '%s' "$OUT" | grep -q "$EXPECT_TEXT"; then
        pass "$label"
    else fail "$label (rc=$RC out=$OUT)"; fi
}
skill_silent() { # label tool skill args vars...
    local label="$1" tool="$2" skill="$3" args="$4"; shift 4
    run_skill "$tool" "$skill" "$args" "$@"
    if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "$label"; else fail "$label (rc=$RC out=$OUT)"; fi
}

MH=$(new_tmp)
EXPECT_TEXT='G2:'
for sk in cadence:cad-execute /cadence:cad-execute cad-execute /cad-execute; do
    skill_deny "Skill $sk 2 gets the G2 deny output" "$sk" 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
done
skill_silent "Skill cadence:cad-progress prints nothing" Skill cadence:cad-progress 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_silent "tool Bash prints nothing" Bash cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
EXPECT_TEXT='G1:'
skill_deny "Skill cad-plan 2 without CONTEXT.md gets G1" cad-plan 2 STUB_STATUS="$STATUS_12" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":false}}' HELM_SUPPORT_DIR="$MH"
EXPECT_TEXT='G4:'
skill_deny "Skill cadence:cad-milestone with 3 broken gets G4" cadence:cad-milestone "" STUB_AUDIT='{"ok":true,"counts":{"total":3,"broken":3}}' STUB_COVERAGE="$COV_0" HELM_SUPPORT_DIR="$MH"
# A session that is not Helm's.
OUT=$(skill_payload Skill "$PLAIN" cadence:cad-execute 2 | env -u CLAUDE_GUI HOME="$STUB_HOME" STUB_STATUS="$STATUS_12" bash "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass "Skill path: non-Helm session prints nothing"; else fail "Skill path non-Helm (rc=$RC out=$OUT)"; fi

# Override marker on the Skill path.
EXPECT_TEXT='G2:'
run_stub "/cad-execute 2 override: slow" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_silent "typed override lets one Skill call pass" Skill cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_deny "the second Skill call is blocked" cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
run_stub "/cad-execute 2 override: slow" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_deny "a marker for phase 2 does not pass phase 3" cadence:cad-execute 3 \
    STUB_STATUS='{"ok":true,"phases":[{"n":2,"name":"b","status":"unplanned"},{"n":3,"name":"c","status":"unplanned"}]}' HELM_SUPPORT_DIR="$MH"
skill_deny "a marker for phase 2 does not pass a bare Skill call" cadence:cad-execute "" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
for f in "$MH"/typed-gate-override/*; do touch -t 200001010000 "$f"; done
skill_deny "an expired marker does not pass" cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
run_stub "Cadence stage: skill=/cadence:cad-execute phase=2 model=none effort=none reason: x" STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_silent "a board line with a reason lets one Skill call pass" Skill cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"
skill_deny "and only one" cadence:cad-execute 2 STUB_STATUS="$STATUS_12" HELM_SUPPORT_DIR="$MH"

# Agreement: the typed path and the Skill path give the same verdict and the same reason text.
reason_of() { node -e 'const d=require("fs").readFileSync(0,"utf8");if(d){const j=JSON.parse(d);process.stdout.write(j.reason||j.hookSpecificOutput.permissionDecisionReason||"")}'; }
agree() { # label command phase vars...
    local label="$1" cmd="$2" ph="$3"; shift 3
    run_stub "/cad-$cmd $ph" "$@" HELM_SUPPORT_DIR="$MH"; local typed; typed=$(printf '%s' "$OUT" | reason_of)
    run_skill Skill "cad-$cmd" "$ph" "$@" HELM_SUPPORT_DIR="$MH"; local viaskill; viaskill=$(printf '%s' "$OUT" | reason_of)
    if [ "$typed" = "$viaskill" ]; then pass "agree: $label${typed:+ (blocked)}"; else fail "agree: $label (typed=[$typed] skill=[$viaskill])"; fi
}
CFG_OFF='{"ok":true,"values":{"workflow.skip_discuss":false}}'
agree "G1 block" plan 2 STUB_STATUS="$STATUS_12" STUB_CONFIG="$CFG_OFF"
agree "G1 waived" plan 2 STUB_STATUS="$STATUS_12" STUB_CONFIG='{"ok":true,"values":{"workflow.skip_discuss":true}}'
agree "G2 block" execute 2 STUB_STATUS="$STATUS_12"
agree "G2 pass" execute 1 STUB_STATUS="$STATUS_12"
agree "G4 block" milestone "" STUB_AUDIT='{"ok":true,"counts":{"total":2,"broken":2}}' STUB_COVERAGE="$COV_0"
agree "G4 audit failure" milestone "" STUB_AUDIT_EXIT=1
agree "G4 pass" milestone "" STUB_AUDIT="$AUDIT_0" STUB_COVERAGE="$COV_0"

# Review finding (plan 2): HOME unset must not allow silently by a thrown TypeError.
OUT=$(payload "$PLAIN" "/cad-execute 2" | env -u HOME CLAUDE_GUI=1 STUB_STATUS="$STATUS_12" node "$HELPER" "$PLAIN" 2>/dev/null)
if printf '%s' "$OUT" | grep -q 'HOME is not set'; then pass "HOME unset reports a gate check that could not run"; else fail "HOME unset (out=$OUT)"; fi

echo "---"
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
