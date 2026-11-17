#!/bin/bash
# test/test-active-project-isolation.sh
# Regression test: the dispatch-writing tests must not touch the shared
# .claude/active-project file. Overlapping suite runs used to save/restore it
# in turn and could leave a fixture path behind. Runs two of them concurrently
# (several rounds, since the race is timing-dependent) and asserts the file is
# byte-identical to its snapshot afterwards.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVE_PROJECT_FILE="$SCRIPT_DIR/../.claude/active-project"
ROUNDS=10

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

CREATED_DIR=0
SENTINEL="/nonexistent/active-project-sentinel"
if [ ! -f "$ACTIVE_PROJECT_FILE" ]; then
    [ -d "$SCRIPT_DIR/../.claude" ] || CREATED_DIR=1
    mkdir -p "$SCRIPT_DIR/../.claude"
    printf '%s\n' "$SENTINEL" > "$ACTIVE_PROJECT_FILE"
    CREATED_FILE=1
else
    CREATED_FILE=0
fi
SNAPSHOT=$(mktemp)
cleanup() {
    if [ "$CREATED_FILE" -eq 1 ]; then
        rm -f "$ACTIVE_PROJECT_FILE"
        [ "$CREATED_DIR" -eq 1 ] && rmdir "$SCRIPT_DIR/../.claude" 2>/dev/null
    fi
    rm -f "$SNAPSHOT"
    rm -rf "${TMP_ROOT:-}"
}
trap cleanup EXIT
cp "$ACTIVE_PROJECT_FILE" "$SNAPSHOT"

for round in $(seq 1 "$ROUNDS"); do
    # Several copies: one guard + one tab-failure run rarely overlap (the guard
    # exits first), and the interleave window is only a few ms wide.
    for t in test-dispatch-guard.sh test-dispatch-tab-failure.sh test-dispatch-guard.sh test-dispatch-tab-failure.sh test-dispatch-tab-failure.sh test-dispatch-tab-failure.sh; do
        "$SCRIPT_DIR/$t" >/dev/null 2>&1 &
    done
    wait

    if [ -f "$ACTIVE_PROJECT_FILE" ] && cmp -s "$SNAPSHOT" "$ACTIVE_PROJECT_FILE"; then
        pass "round $round: .claude/active-project unchanged"
    else
        fail "round $round: .claude/active-project changed to: $(cat "$ACTIVE_PROJECT_FILE" 2>/dev/null || echo '<absent>')"
        cp "$SNAPSHOT" "$ACTIVE_PROJECT_FILE"
    fi
done

# Project resolution: with orchestrator sessions in two projects, the shared
# pointer (last launch wins) must not decide which project a dispatch or kill
# hits -- the caller's cwd must. Runs a private copy of orchestration/ so the
# pointer can be pointed at the "other" project without touching the real one.
TMP_ROOT=$(mktemp -d)
ORCH="$TMP_ROOT/orch"
mkdir -p "$ORCH/.claude" "$TMP_ROOT/bin" "$TMP_ROOT/nogit"
cp -R "$SCRIPT_DIR/../orchestration" "$ORCH/orchestration"
ISO_DISPATCH="$ORCH/orchestration/lib/dispatch-task.sh"
printf '#!/bin/bash\nexit 0\n' > "$TMP_ROOT/bin/tmux"
cp "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/claude"
printf '#!/bin/bash\nexit 1\n' > "$TMP_ROOT/bin/osascript"
chmod +x "$TMP_ROOT/bin/"*

make_project() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "Test"
    echo root > "$1/README.md"
    git -C "$1" add README.md
    git -C "$1" commit -q -m initial
    mkdir -p "$1/.claude"
    printf '%s\n' "$ORCH" > "$1/.claude/orchestrator-root"
    "$ORCH/orchestration/init/init-state-store.sh" "$1" >/dev/null 2>&1
}
PROJ_A="$TMP_ROOT/proj-a"
PROJ_B="$TMP_ROOT/proj-b"
make_project "$PROJ_A"
make_project "$PROJ_B"
# Last launch was project B: the stale pointer says B.
printf '%s\n' "$PROJ_B" > "$ORCH/.claude/active-project"

# iso_run <cwd> [VAR=val ...] -- <dispatch args>
iso_run() {
    local dir="$1"; shift
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$dir" && env -u ORCH_PROJECT_ROOT ${envs[@]+"${envs[@]}"} PATH="$TMP_ROOT/bin:$PATH" "$ISO_DISPATCH" "$@") >/dev/null 2>&1
}
wt() { echo "$1/.claude/worktrees/$2"; }

iso_run "$PROJ_A" -- iso-task "Isolation task"
iso_run "$PROJ_B" -- iso-task "Isolation task"
if [ -d "$(wt "$PROJ_A" iso-task)" ] && [ -d "$(wt "$PROJ_B" iso-task)" ]; then
    pass "dispatch from each project's cwd creates the worktree in that project"
else
    fail "dispatch from each project's cwd: A has worktree=$([ -d "$(wt "$PROJ_A" iso-task)" ] && echo yes || echo no), B has worktree=$([ -d "$(wt "$PROJ_B" iso-task)" ] && echo yes || echo no)"
fi

iso_run "$PROJ_A" -- --kill iso-task
if [ ! -d "$(wt "$PROJ_A" iso-task)" ] && [ -d "$(wt "$PROJ_B" iso-task)" ]; then
    pass "--kill from project A removes A's worker and leaves B's"
else
    fail "--kill from project A: A worktree gone=$([ ! -d "$(wt "$PROJ_A" iso-task)" ] && echo yes || echo no), B worktree kept=$([ -d "$(wt "$PROJ_B" iso-task)" ] && echo yes || echo no)"
fi
iso_run "$PROJ_B" -- --kill iso-task
if [ ! -d "$(wt "$PROJ_B" iso-task)" ]; then
    pass "--kill from project B removes B's worker"
else
    fail "--kill from project B left B's worktree"
fi

# A worker's cwd is a linked worktree: it must resolve to the main checkout.
iso_run "$PROJ_A" -- parent-task "Parent task"
iso_run "$(wt "$PROJ_A" parent-task)" -- from-worker "Dispatched by a worker"
if [ -d "$(wt "$PROJ_A" from-worker)" ] && [ ! -d "$(wt "$PROJ_B" from-worker)" ] && [ ! -d "$(wt "$(wt "$PROJ_A" parent-task)" from-worker)" ]; then
    pass "dispatch from inside a worker worktree resolves to the main checkout"
else
    fail "dispatch from a worker worktree did not land in the main checkout's .claude/worktrees"
fi

# ORCH_PROJECT_ROOT still wins over the cwd.
iso_run "$PROJ_A" ORCH_PROJECT_ROOT="$PROJ_B" -- override-task "Override task"
if [ -d "$(wt "$PROJ_B" override-task)" ] && [ ! -d "$(wt "$PROJ_A" override-task)" ]; then
    pass "ORCH_PROJECT_ROOT overrides the caller's cwd"
else
    fail "ORCH_PROJECT_ROOT override ignored"
fi

# No override and no git cwd: refuse rather than guess a project.
NOGIT_ERR=$(cd "$TMP_ROOT/nogit" && env -u ORCH_PROJECT_ROOT PATH="$TMP_ROOT/bin:$PATH" "$ISO_DISPATCH" nogit-task "No git task" 2>&1 1>/dev/null)
NOGIT_RC=$?
if [ "$NOGIT_RC" -ne 0 ] && [ -n "$NOGIT_ERR" ] && [ ! -d "$(wt "$PROJ_A" nogit-task)" ] && [ ! -d "$(wt "$PROJ_B" nogit-task)" ]; then
    pass "outside any git project with no override: errors and creates nothing"
else
    fail "non-git cwd: exit=$NOGIT_RC stderr=$NOGIT_ERR"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
