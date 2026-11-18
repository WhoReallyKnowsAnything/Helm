#!/bin/bash
# test/test-g5-wrap-prompt.sh
# Pins the G5 wrap rule in ### Off-Roadmap Wrap (G5) of the drafting prompt.
# DRAFT=<copy> runs it against a scratch copy.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAFT="${DRAFT:-$SCRIPT_DIR/../orchestration/prompts/task-drafting-mode.md}"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
has() { if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3"; fi; }

SEC=$(awk '/^### Off-Roadmap Wrap \(G5\)/{p=1} /^### Board Stage Dispatch/{p=0} p' "$DRAFT")
[ -n "$SEC" ] || { echo "FAIL: ### Off-Roadmap Wrap (G5) is missing in $DRAFT"; echo "Results: 0 passed, 1 failed"; exit 1; }

has "$SEC" 'user-drafted task or a Notion-sourced task' "wrap applies to drafted and Notion tasks"
has "$SEC" 'carries no CADENCE-REQUIRED marker' "wrap only without a CADENCE-REQUIRED marker"
has "$SEC" '<orch_root>/orchestration/lib/dispatch-task.sh --cycle-open` through the Bash tool with no argument' "--cycle-open runs with no argument"
has "$SEC" 'Branch on the exit status alone' "branch on exit status alone"
has "$SEC" 'Exit 0: wrap' "exit 0 wraps"
has "$SEC" 'Exit 1: send the text unchanged and say nothing' "exit 1 sends unchanged and silent"
has "$SEC" 'Any other status is a script error: send the text unchanged and tell the user in 1 line' "other status sends unchanged with a 1-line message"
has "$SEC" 'Dispatch never waits on the check' "dispatch never waits"
has "$SEC" 'Run the Skill tool with skill cadence:cad-task, and pass everything below this line as its args' "message shape: skill instruction line then task text"
has "$SEC" 'Do not start the message with a `/cadence:cad-task` slash command' "wrapped message is not a leading slash command"
has "$SEC" 'Add no `--plan` and no other flag' "no --plan"
has "$SEC" 'task text holds a cad-task flag' "task text holding a cad-task flag is not wrapped"
has "$SEC" 'never in a shell command or argument' "task text never in a shell command or argument"
has "$SEC" 'native `SendMessage` `text` argument' "task text crosses as SendMessage text"
has "$SEC" 'Cadence stage: skill=' "never wrap board stage dispatch"
has "$SEC" 'a CADENCE-REQUIRED task' "never wrap CADENCE-REQUIRED task"
has "$SEC" 'DEPENDENCY-SATISFIED' "never wrap DEPENDENCY-SATISFIED"
has "$SEC" 'a board reason message' "never wrap board reason message"
has "$SEC" 'a Worker Check-In reply' "never wrap Worker Check-In reply"
has "$SEC" 'skip Cadence' "skip Cadence opt-out"
has "$SEC" 'do not run the check' "skip Cadence runs no check"

STEP7=$(awk '/^7\. \*\*Send/{p=1} /^8\. \*\*Delivery/{p=0} p' "$DRAFT")
has "$STEP7" 'Off-Roadmap Wrap (G5)' "Step 7 names the wrap section"

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
