#!/bin/bash
# test/test-worker-prompt-preapproval.sh
# Regression test: the worker system prompt must pre-approve the dispatched
# task (so the user's global Scope/File Operation Confirmation waits do not
# stall a worker at its first edit), keep every native approval gate in force,
# and leave the DEPENDENCY-SATISFIED / CADENCE-REQUIRED contracts untouched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT="$SCRIPT_DIR/../orchestration/prompts/worker-dependency-awareness.md"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

SECTION=$(awk '/^## /{p=($0=="## Dispatched Task Pre-Approval")} p' "$PROMPT")

if [ -n "$SECTION" ]; then pass "has '## Dispatched Task Pre-Approval' heading"; else fail "missing '## Dispatched Task Pre-Approval' heading"; fi

if printf '%s' "$SECTION" | grep -qF 'Skip the Scope Confirmation and File Operation Confirmation waits' \
    && printf '%s' "$SECTION" | grep -qF 'Scope Confirmation' \
    && printf '%s' "$SECTION" | grep -qF 'File Operation Confirmation'; then
    pass "section skips the Scope Confirmation and File Operation Confirmation waits"
else
    fail "section does not skip the Scope Confirmation and File Operation Confirmation waits"
fi

if printf '%s' "$SECTION" | grep -qF 'permission prompts' \
    && printf '%s' "$SECTION" | grep -qF 'approval gates' \
    && printf '%s' "$SECTION" | grep -qF 'git approvals' \
    && printf '%s' "$SECTION" | grep -qF 'self-approve'; then
    pass "section keeps permission prompts, approval gates and git approvals, never self-approved"
else
    fail "section does not keep permission prompts / approval gates / git approvals / no self-approve"
fi

if printf '%s' "$SECTION" | grep -qF 'every `git commit` your task asks for'; then
    pass "section pre-approves the commits the task asks for"
else
    fail "section does not pre-approve the commits the task asks for"
fi

if grep -qF 'CADENCE-REQUIRED' "$PROMPT"; then pass "CADENCE-REQUIRED literal present"; else fail "CADENCE-REQUIRED literal missing"; fi

if tr '\n' '|' < "$PROMPT" | grep -qF 'DEPENDENCY-SATISFIED|From: auth-service-refactor|Artifact: session/auth-service-refactor|```'; then
    pass "DEPENDENCY-SATISFIED 3-line example block unchanged"
else
    fail "DEPENDENCY-SATISFIED 3-line example block changed or missing"
fi

FINISH=$(awk '/^## /{p=($0=="## Finishing the Task")} p' "$PROMPT")

if printf '%s' "$FINISH" | grep -qF 'as your last step of work' \
    && printf '%s' "$FINISH" | grep -qF '`/om-wrap-up`' \
    && printf '%s' "$FINISH" | grep -qF -- '--mark-done'; then
    pass "'Finishing the Task' names /om-wrap-up as the last step before --mark-done"
else
    fail "'Finishing the Task' section missing or does not name /om-wrap-up as the last step before --mark-done"
fi

WRAP_LN=$(printf '%s\n' "$FINISH" | grep -nF -m1 '`/om-wrap-up`' | cut -d: -f1)
MARK_LN=$(printf '%s\n' "$FINISH" | grep -nF -m1 -- 'Mark yourself done' | cut -d: -f1)
DONE_LN=$(printf '%s\n' "$FINISH" | grep -nF -m1 'report done to the orchestrator' | cut -d: -f1)
if [ -n "$WRAP_LN" ] && [ -n "$MARK_LN" ] && [ -n "$DONE_LN" ] \
    && [ "$WRAP_LN" -lt "$MARK_LN" ] && [ "$MARK_LN" -lt "$DONE_LN" ]; then
    pass "wrap-up sentence, then mark-done sentence, then done-report sentence"
else
    fail "order wrong or sentence missing (wrap-up line '$WRAP_LN', mark-done line '$MARK_LN', done-report line '$DONE_LN')"
fi

if printf '%s' "$FINISH" | grep -qF -- '--mark-done <your label>'; then
    pass "--mark-done takes the literal '<your label>' placeholder"
else
    fail "--mark-done block does not use the literal '<your label>' placeholder"
fi

if grep -F 'dispatch-task.sh' "$PROMPT" | grep -qF -e '$(cat' -e '$(basename' -e '"$ORCH_ROOT/'; then
    fail "a dispatch-task.sh line builds the path or label with a shell substitution"
else
    pass "no dispatch-task.sh line uses \$(cat, \$(basename or \"\$ORCH_ROOT/"
fi

QUESTIONS=$(awk '/^## /{p=($0=="## Questions and Permission Prompts")} p' "$PROMPT")

for TERM_IN_SECTION in AskUserQuestion ExitPlanMode SendMessage; do
    if printf '%s' "$QUESTIONS" | grep -qF "\`$TERM_IN_SECTION\`"; then
        pass "'Questions and Permission Prompts' names $TERM_IN_SECTION"
    else
        fail "'Questions and Permission Prompts' section missing or does not name $TERM_IN_SECTION"
    fi
done

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/orchestration/lib/question-stages.sh"
printf '%s' "$QUESTIONS" | grep -qF 'QUESTION_STAGES' && pass "questions section names QUESTION_STAGES" || fail "questions section does not name QUESTION_STAGES"
HARD=""
for S in "${QUESTION_STAGES[@]}"; do printf '%s' "$QUESTIONS" | grep -qF "cad-$S" && HARD="$HARD $S"; done
[ -z "$HARD" ] && pass "questions section hard-codes no listed stage" || fail "questions section hard-codes stage(s):$HARD"
printf '%s' "$QUESTIONS" | grep -qF 'ExitPlanMode` is denied' && pass "questions section says ExitPlanMode is denied" || fail "questions section lost the ExitPlanMode deny"
BARE=$(printf '%s\n' "$QUESTIONS" | grep -o '[^ ]*question-stages\.sh' | grep -vc '^\$ORCH_ROOT/\|"\$ORCH_ROOT/' )
[ "$BARE" = 0 ] && pass "every question-stages.sh path starts with \$ORCH_ROOT/" || fail "$BARE bare question-stages.sh mention(s)"
BLOCK=$(printf '%s\n' "$QUESTIONS" | awk '/^```bash/{f=1;next} f&&/^```/{exit} f')
QT=$(mktemp -d); QT=$(cd "$QT" && pwd -P)
git -C "$QT" init -q -b main && git -C "$QT" -c user.email=t@e -c user.name=t commit -q --allow-empty -m s
mkdir -p "$QT/.claude/worktrees"; git -C "$QT" worktree add -q -b session/w "$QT/.claude/worktrees/w" 2>/dev/null
echo "$REPO_ROOT" > "$QT/.claude/orchestrator-root"
OUT=$(cd "$QT/.claude/worktrees/w" && bash -c "$BLOCK")
[ -n "$OUT" ] && grep -q QUESTION_STAGES "$OUT" 2>/dev/null && pass "the block resolves a path that holds QUESTION_STAGES" || fail "the block did not resolve the list (got '$OUT')"
rm -f "$QT/.claude/orchestrator-root"
OUT=$(cd "$QT/.claude/worktrees/w" && bash -c "$BLOCK")
[ -z "$OUT" ] && pass "with no pointer file the block prints no path" || fail "block printed '$OUT' with no pointer"
rm -rf "$QT"

VERIFY=$(awk '/^## /{p=(index($0,"cad-verify-p")>0)} p' "$PROMPT")
[ -n "$VERIFY" ] && pass "has a section keyed on cad-verify-p" || fail "missing a section keyed on cad-verify-p"
for LINE in 'UAT item <k>: pass' 'UAT item <k>: fail - <note>' 'UAT item <k>: skip - <reason>' 'UAT item <k>: blocked - <reason>'; do
    printf '%s' "$VERIFY" | grep -qF "$LINE" && pass "verify section has '$LINE'" || fail "verify section lacks '$LINE'"
done
printf '%s' "$VERIFY" | grep -qF 'exactly' && pass "verify section says exactly" || fail "verify section lacks 'exactly'"
printf '%s' "$VERIFY" | grep -qF 'stay open' && pass "verify section says stay open" || fail "verify section lacks 'stay open'"
printf '%s' "$VERIFY" | grep -qF 'UAT is complete or the user tells you to stop' && pass "verify section waits for complete or stop before mark done" || fail "verify section lacks the mark-done wait rule"
printf '%s' "$VERIFY" | grep -qF '/cadence:cad-capture' && printf '%s' "$VERIFY" | grep -qF 'only as the skill argument' && pass "verify section runs capture with the reason only as the skill argument" || fail "verify section lacks the capture rule"
printf '%s' "$VERIFY" | grep -qF 'then run the `--mark-done`' && pass "verify section marks done again after the capture commit" || fail "verify section lacks mark done after capture"

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
