#!/bin/bash
# test/test-dispatch-dependency-shape.sh
# Regression test: a dispatch whose Depends-on artifact already exists must
# not fold the DEPENDENCY-SATISFIED block into the task text (the worker
# rejects any DEPENDENCY-SATISFIED-first message that is not exactly 3 lines).
# The block goes out as its own SendMessage after the task, and the worker's
# strict 3-line / exact CADENCE-REQUIRED first-line contracts stay intact.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAFT="$SCRIPT_DIR/../orchestration/prompts/task-drafting-mode.md"
WORKER="$SCRIPT_DIR/../orchestration/prompts/worker-dependency-awareness.md"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

STEP6=$(awk '/^6\. \*\*Probe/{p=1} /^7\. \*\*Send/{p=0} p' "$DRAFT")
STEP7=$(awk '/^7\. \*\*Send/{p=1} /^8\. \*\*Delivery/{p=0} p' "$DRAFT")
STEP9=$(awk '/^9\. \*\*Success report/{p=1} /^### /{p=0} p' "$DRAFT")
[ -n "$STEP6" ] && [ -n "$STEP7" ] && [ -n "$STEP9" ] || { echo "FAIL: Step 6/7/9 not found in $DRAFT"; exit 1; }

# Dispatch side: no fold into task text.
if printf '%s' "$STEP6" | grep -qiE 'prepend'; then
    fail "Step 6 still prepends the DEPENDENCY-SATISFIED block to the task text"
else
    pass "Step 6 does not prepend the block to the task text"
fi
if printf '%s' "$STEP7" | grep -qF 'DEPENDENCY-SATISFIED'; then
    fail "Step 7 still stacks a DEPENDENCY-SATISFIED block into the task text"
else
    pass "Step 7 task text carries only the optional CADENCE-REQUIRED marker"
fi

# Dispatch side: block is its own message, sent after the task, then marked.
if printf '%s' "$STEP6" | grep -qF 'separate `SendMessage`' \
    && printf '%s' "$STEP6" | grep -qF 'after the task'; then
    pass "Step 6 sends the block as a separate SendMessage after the task"
else
    fail "Step 6 does not send the block as a separate SendMessage after the task"
fi
if printf '%s' "$STEP6" | grep -qF -- '--mark-notified'; then
    pass "Step 6 still marks the edge notified"
else
    fail "Step 6 lost --mark-notified"
fi
if printf '%s' "$STEP9" | grep -qi 'folded'; then
    fail "Step 9 success report still says the block was folded in"
else
    pass "Step 9 success report matches the separate-message flow"
fi

# Worker side: strict contracts unchanged.
if tr '\n' '|' < "$WORKER" | grep -qF 'exactly two more lines -- no more, no fewer'; then
    pass "worker still requires exactly 3 lines for a peer notification"
else
    fail "worker 3-line peer rule changed or missing"
fi
if grep -qF "dispatched task text's first line is EXACTLY the literal string" "$WORKER"; then
    pass "worker CADENCE-REQUIRED exact first-line check intact"
else
    fail "worker CADENCE-REQUIRED first-line check changed or missing"
fi

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
