#!/bin/bash
# test/test-dispatch-guard.sh
# Regression test: dispatch-task.sh must refuse to spawn a session for
# --help/-h, an unknown flag, or a missing/blank task title -- before any
# git worktree or tmux work runs. Points ORCH_PROJECT_ROOT at a
# disposable fixture repo (same idiom as test-dependency-graph.sh) so a
# guard that fails to fire creates its worktree there, not in the real repo.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../orchestration/lib/dispatch-task.sh"

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

TMP_MAIN=""
cleanup() {
    [ -n "$TMP_MAIN" ] && rm -rf "$TMP_MAIN"
}
trap cleanup EXIT

TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "Test"
echo "root" > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" commit -q -m "initial"

export ORCH_PROJECT_ROOT="$TMP_MAIN"

no_worktrees_created() {
    [ ! -d "$TMP_MAIN/.claude/worktrees" ]
}

# 1. --help: usage, exit 0, no worktree
OUTPUT=$("$DISPATCH" --help 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ] && echo "$OUTPUT" | grep -qi usage; then
    pass "--help prints usage and exits 0"
else
    fail "--help exit=$EXIT_CODE output=$OUTPUT"
fi
if no_worktrees_created; then pass "--help creates no worktree"; else fail "--help created a worktree"; fi

# 2. -h: same
OUTPUT=$("$DISPATCH" -h 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ] && echo "$OUTPUT" | grep -qi usage; then
    pass "-h prints usage and exits 0"
else
    fail "-h exit=$EXIT_CODE output=$OUTPUT"
fi
if no_worktrees_created; then pass "-h creates no worktree"; else fail "-h created a worktree"; fi

# 3. unknown flag: usage to stderr, non-zero exit, no side effects
ERR_OUTPUT=$("$DISPATCH" --bogus-flag 2>&1 1>/dev/null)
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ] && echo "$ERR_OUTPUT" | grep -qi usage; then
    pass "unknown flag prints usage to stderr and exits non-zero"
else
    fail "unknown flag exit=$EXIT_CODE stderr=$ERR_OUTPUT"
fi
if no_worktrees_created; then pass "unknown flag creates no worktree"; else fail "unknown flag created a worktree"; fi

# 4. label with no task title: refuse
OUTPUT=$("$DISPATCH" guard-test-label 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "missing task title exits non-zero"
else
    fail "missing task title exit=$EXIT_CODE output=$OUTPUT"
fi
if no_worktrees_created; then pass "missing task title creates no worktree"; else fail "missing task title created a worktree"; fi

# 5. label with empty task title: refuse
OUTPUT=$("$DISPATCH" guard-test-label "" 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "empty task title exits non-zero"
else
    fail "empty task title exit=$EXIT_CODE output=$OUTPUT"
fi
if no_worktrees_created; then pass "empty task title creates no worktree"; else fail "empty task title created a worktree"; fi

# 6. label with whitespace-only task title: refuse
OUTPUT=$("$DISPATCH" guard-test-label "   " 2>&1)
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
    pass "whitespace-only task title exits non-zero"
else
    fail "whitespace-only task title exit=$EXIT_CODE output=$OUTPUT"
fi
if no_worktrees_created; then pass "whitespace-only task title creates no worktree"; else fail "whitespace-only task title created a worktree"; fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
