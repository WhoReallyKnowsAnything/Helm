#!/bin/bash
# test/test-notion-pickup-prompt.sh
# Pins the phase 3 drafting-prompt wording (AC4): the app pick-up prefix in
# ### Free-Form Pick-Up Matching, the ### Task-List File rules, and the refresh
# clause at each Status-change site. DRAFT=<copy> runs it against a scratch copy.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAFT="${DRAFT:-$SCRIPT_DIR/../orchestration/prompts/task-drafting-mode.md}"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
# has <text> <fixed string> <description>; hasE: same with an extended regex.
has() { if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3"; fi; }
hasE() { if printf '%s' "$1" | grep -qE -- "$2"; then pass "$3"; else fail "$3"; fi; }

FREEFORM=$(awk '/^### Free-Form Pick-Up Matching/{p=1} /^### Immediate Write/{p=0} p' "$DRAFT")
PREFIX_PARA=$(printf '%s\n' "$FREEFORM" | grep -F 'Pick up the Notion task: ')
ONE_MATCH=$(printf '%s\n' "$FREEFORM" | grep -F '**Exactly one match:**')
TASKLIST=$(awk '/^### Task-List File/{p=1} /^### Zero-Tasks Fallback/{p=0} p' "$DRAFT")
IMMEDIATE=$(awk '/^### Immediate Write/{p=1} /^### Mapping to the Drafted Prompt Shape/{p=0} p' "$DRAFT")
STEP4=$(grep -E '^4\. \*\*Discovery-timeout cleanup' "$DRAFT")
STEP8=$(grep -E '^8\. \*\*Delivery-failure cleanup' "$DRAFT")
CHECKIN4=$(grep -E '^4\. \*\*On a completion ping' "$DRAFT")
[ -n "$FREEFORM" ] && [ -n "$TASKLIST" ] && [ -n "$IMMEDIATE" ] \
    || { echo "FAIL: a required section is missing in $DRAFT"; echo "Results: 0 passed, 1 failed"; exit 1; }

# App pick-up (D-03, D-09, D-10, D-11)
has "$PREFIX_PARA" 'Pick up the Notion task: ' "pick-up paragraph holds the exact prefix literal"
has "$PREFIX_PARA" 'whole rest of the message' "title is the whole rest of the message"
has "$PREFIX_PARA" 'Never split the title on a later `: `' "title is never split on a later ': '"
has "$PREFIX_PARA" 'Tool-Availability Wait and Query steps 1-3 again' "pick-up runs the Query again"
has "$PREFIX_PARA" 'exact string equality' "pick-up matches by exact string equality"
hasE "$PREFIX_PARA" 'already `In progress`, tell the user so and ask before' "pick-up asks first on an In progress task"
hasE "$ONE_MATCH" '`In progress`, tell the user so and ask before' "free-form exactly-one-match asks first on an In progress task"

# Task-List File (D-01, D-04, D-05, D-07, D-08)
has "$TASKLIST" '--write-notion-tasks' "Task-List File names --write-notion-tasks"
for k in id title status priority tags url parent_id; do
    has "$TASKLIST" "\`$k\`:" "Task-List File maps key $k"
done
has "$TASKLIST" 'after every Query' "file is written after every Query"
has "$TASKLIST" 'zero tasks writes `[]`' "zero tasks writes []"
has "$TASKLIST" 'After every Status change this session makes, run Query steps 1-3 again' "Status change re-runs the Query"
hasE "$TASKLIST" 'If the Query fails.*do not run the subcommand.*existing file stays' "failed Query leaves the file untouched"
hasE "$TASKLIST" '`has_more` true.*`start_cursor`' "Tasks query pages with has_more and start_cursor"
hasE "$TASKLIST" 'file-write tool.*`\.notion-tasks-rows\.json`' "rows go to .notion-tasks-rows.json with the file-write tool"
if printf '%s' "$TASKLIST" | grep -qF CLAUDE_GUI; then fail "Task-List File has a CLAUDE_GUI gate"; else pass "Task-List File has no CLAUDE_GUI gate"; fi

# The prescribed command carries no title: every span naming the subcommand is the exact command.
EXPECTED='`<orch_root>/orchestration/lib/dispatch-task.sh --write-notion-tasks .notion-tasks-rows.json`'
SPANS=$(printf '%s' "$TASKLIST" | grep -oE '`[^`]*`' | grep -F 'dispatch-task.sh --write-notion-tasks')
if [ -n "$SPANS" ] && [ -z "$(printf '%s\n' "$SPANS" | grep -vxF -- "$EXPECTED")" ]; then
    pass "every command span is exactly the rows-file command"
else
    fail "a command span differs from the rows-file command, or none exists"
fi

# Refresh clause at every Status-change site
has "$IMMEDIATE" 'Task-List File' "Immediate Write refreshes the file"
has "$STEP4" 'Task-List File' "Dispatch step 4 refreshes the file"
has "$STEP8" 'Task-List File' "Dispatch step 8 refreshes the file"
has "$CHECKIN4" 'Task-List File' "Worker Check-In step 4 refreshes the file"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
