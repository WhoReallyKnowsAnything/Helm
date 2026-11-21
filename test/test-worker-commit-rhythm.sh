#!/bin/bash
# test/test-worker-commit-rhythm.sh
# Regression test: the worker prompt tells workers to commit after each
# finished step, keeps the Context: and push-approval rules, and leaves
# Cadence executors on their own commit rhythm.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/../orchestration/prompts/worker-dependency-awareness.md"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TEXT=$(tr '\n' ' ' < "$WORKER")

check() {
    if printf '%s' "$TEXT" | grep -qF -- "$1"; then pass "$2"; else fail "$2"; fi
}

check 'Commit after each finished step, not only at the end of the task.' "worker commits after each finished step"
check 'A step is finished when it builds or its tests pass.' "step-finished definition present"
check 'WIP commits are fine.' "WIP commits allowed"
check 'Every commit needs a `Context:` section.' "Context section rule kept"
check 'Pushes still need approval.' "push approval rule kept"
check 'Cadence executors (`/cadence:cad-execute`, `/cadence:cad-task`) keep their own commit rhythm.' "Cadence commit rhythm carved out"

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
