#!/bin/bash
# test/test-question-stages.sh
# orchestration/lib/question-stages.sh: the one list of stage labels whose
# workers may use AskUserQuestion. Plain bash, no framework.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/orchestration/lib/question-stages.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

if ! source "$LIB" 2>/dev/null || ! declare -F question_stage_allowed >/dev/null; then
    fail "question-stages.sh loads and defines question_stage_allowed"
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
    exit 1
fi

for L in cad-context-p3 cad-context-p1-1 cad-plan-p4 cad-plan-p1-1 cad-verify-p3 cad-verify-p1-1 cad-execute-p1 cad-execute-p4 cad-execute-p1-1 cad-milestone-p1 cad-milestone-p1-1 cad-milestone-p3; do
    question_stage_allowed "$L" && pass "$L is allowed" || fail "$L is allowed"
done
for L in cad-milestone-p3x xcad-milestone-p3 cad-milestonex-p3 cad-milestone-p3- live dashboard cad-context-p3x xcad-context-p3 cad-contextx-p3 cad-context-p3- cad-execute-p4x xcad-execute-p4 cad-executex-p4 cad-execute-p4- cad-plan-p4x xcad-plan-p4 cad-planx-p4 cad-plan-p4- cad-verify-p3x xcad-verify-p3 cad-verifyx-p3 cad-verify-p3- ""; do
    question_stage_allowed "$L" && fail "'$L' is not allowed" || pass "'$L' is not allowed"
done

# Every listed stage passes, so a later entry needs no test edit.
for S in "${QUESTION_STAGES[@]}"; do
    question_stage_allowed "cad-$S-p7" && pass "listed stage '$S' is allowed" || fail "listed stage '$S' is allowed"
done
case " ${QUESTION_STAGES[*]} " in *" verify "*) pass "QUESTION_STAGES contains verify" ;; *) fail "QUESTION_STAGES contains verify" ;; esac
case " ${QUESTION_STAGES[*]} " in *" execute "*) pass "QUESTION_STAGES contains execute" ;; *) fail "QUESTION_STAGES contains execute" ;; esac
case " ${QUESTION_STAGES[*]} " in *" milestone "*) pass "QUESTION_STAGES contains milestone" ;; *) fail "QUESTION_STAGES contains milestone" ;; esac

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
