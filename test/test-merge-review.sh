#!/bin/bash
# test/test-merge-review.sh
# Regression test: a --yes merge whose worker wrote wrap-up output into the
# worktree (e.g. /om-wrap-up updating .planning/STATE.md) must fold that
# output into main and remove the worktree/branch -- not fail cleanup while
# reporting success. Builds a disposable fixture git repo; does not touch
# the real project repo or session-state.db.
#
# Missing-worktree repro note: a worktree dir gone while its branch survives
# is handled (merge proceeds, wrap-up skipped). Git never removes a worktree
# dir on `git branch -D`, and refuses -D of a branch checked out in a worktree,
# so the cause of the disappearing worktree is UNCONFIRMED.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_REVIEW="$SCRIPT_DIR/../orchestration/merge-review.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_MAIN=""
EXTRA_DIRS=()
ISO_TMUX=""
cleanup() {
    # kills only the isolated tmux server (TMUX unset, TMUX_TMPDIR scratch dir)
    [ -n "$ISO_TMUX" ] && env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$ISO_TMUX" tmux kill-server 2>/dev/null
    [ -n "$TMP_MAIN" ] && rm -rf "$TMP_MAIN"
    [ ${#EXTRA_DIRS[@]} -gt 0 ] && rm -rf "${EXTRA_DIRS[@]}"
}
trap cleanup EXIT

LABEL="test-merge-fixture"
BRANCH="session/$LABEL"

# osascript/tmux are stubbed (first on PATH for every merge-review run below) so
# no real iTerm or tmux session is touched. Every osascript call is appended to
# $STUB_OSA_LOG (when set), so a test can assert zero calls.
STUB_BIN=$(mktemp -d)
EXTRA_DIRS+=("$STUB_BIN")
cat > "$STUB_BIN/osascript" <<'STUB'
#!/bin/bash
echo "osascript $*" >> "${STUB_OSA_LOG:-/dev/null}"
[ $# -gt 0 ] && exit 0
script=$(cat)
case "$script" in
    *"close t"*) echo closed ;;
esac
STUB
cat > "$STUB_BIN/tmux" <<'STUB'
#!/bin/bash
echo "tmux $*" >> "${STUB_TMUX_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUB_BIN/osascript" "$STUB_BIN/tmux"
# tmux_close_terminal_tab skips osascript when iTerm2 is not running: show one iTerm2
# process for `ps -Ao comm=` so the tab-close assertions hold on any host; every other
# ps call goes to the real ps.
cat > "$STUB_BIN/ps" <<'STUB'
#!/bin/bash
if [ "$*" = "-Ao comm=" ]; then echo /Applications/iTerm.app/Contents/MacOS/iTerm2; exit 0; fi
exec /bin/ps "$@"
STUB
chmod +x "$STUB_BIN/ps"

# wait_for cmd... -> polls up to 30s for the command to succeed
wait_for() {
    local i
    for i in $(seq 1 30); do
        "$@" && return 0
        sleep 1
    done
    return 1
}

TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "Test"
echo "root" > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" commit -q -m "initial"

WORKTREE_DIR="$TMP_MAIN/.claude/worktrees"
mkdir -p "$WORKTREE_DIR"
WORKTREE_PATH="$WORKTREE_DIR/$LABEL"
git -C "$TMP_MAIN" worktree add -q -b "$BRANCH" "$WORKTREE_PATH" main
echo "feature work" > "$WORKTREE_PATH/feature.txt"
git -C "$WORKTREE_PATH" add feature.txt
git -C "$WORKTREE_PATH" commit -q -m "feature work"

# Simulate wrap-up writing uncommitted output into the worktree, the way
# /om-wrap-up updates .planning/STATE.md before the worktree is torn down.
mkdir -p "$WORKTREE_PATH/.planning"
MARKER="wrap-up-marker-$$"
echo "$MARKER" > "$WORKTREE_PATH/.planning/STATE.md"

# No session-state.db row for this label -> iterm_id lookup is empty ->
# the teardown skips the tab close and goes straight to the window teardown
# and the dirty-worktree cleanup path under test. The --yes teardown is
# detached, so wait for its log.
OUTPUT=$(cd "$TMP_MAIN" && PATH="$STUB_BIN:$PATH" "$MERGE_REVIEW" "$LABEL" --merge --yes 2>&1)
EXIT_CODE=$?
wait_for grep -q "Teardown finished" "$TMP_MAIN/.claude/merge-review-$LABEL.log"

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "exit code 0 on dirty-worktree merge"
else
    fail "exit code 0 on dirty-worktree merge (got $EXIT_CODE); output: $OUTPUT"
fi

if [[ -d "$WORKTREE_PATH" ]]; then
    fail "worktree removed ($WORKTREE_PATH still exists)"
else
    pass "worktree removed"
fi

if git -C "$TMP_MAIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    fail "branch $BRANCH deleted (still exists)"
else
    pass "branch $BRANCH deleted"
fi

if git -C "$TMP_MAIN" show main:.planning/STATE.md 2>/dev/null | grep -q "$MARKER"; then
    pass "wrap-up content committed to main (.planning/STATE.md)"
else
    fail "wrap-up content ($MARKER) not found on main"
fi


# --- Detached teardown: --yes ---------------------------------------------------
# The caller gets control back right after the merge; tab/window close, fold,
# worktree removal and branch delete finish in the background (D-01: nothing is
# sent into the worker and nothing is waited for).
# new_fixture label [no-session] -> sets FX_MAIN, FX_WT; seeds a session row with an
# iTerm id unless no-session
new_fixture() {
    local label="$1"
    FX_MAIN=$(mktemp -d)
    EXTRA_DIRS+=("$FX_MAIN")
    git -C "$FX_MAIN" init -q -b main
    git -C "$FX_MAIN" config user.email "test@example.com"
    git -C "$FX_MAIN" config user.name "Test"
    echo "root" > "$FX_MAIN/README.md"
    git -C "$FX_MAIN" add README.md
    git -C "$FX_MAIN" commit -q -m "initial"
    FX_WT="$FX_MAIN/.claude/worktrees/$label"
    mkdir -p "$FX_MAIN/.claude/worktrees"
    git -C "$FX_MAIN" worktree add -q -b "session/$label" "$FX_WT" main
    echo "feature work" > "$FX_WT/feature.txt"
    git -C "$FX_WT" add feature.txt
    git -C "$FX_WT" commit -q -m "feature work"
    [[ "${2:-}" == "no-session" ]] && return 0
    (
        cd "$FX_MAIN" || exit 1
        "$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$FX_MAIN" >/dev/null
        source "$SCRIPT_DIR/../orchestration/lib/session-state.sh"
        session_state_write_with_iterm_id "$label" "$FX_WT" running "" "fake-iterm-id" >/dev/null
    )
}

run_yes_merge() {
    (cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" "$MERGE_REVIEW" "$1" --merge --yes 2>&1)
}

worktree_gone() { [[ ! -d "$FX_WT" ]]; }
log_finished() { grep -q "Teardown finished" "$FX_MAIN/.claude/merge-review-$1.log" 2>/dev/null; }

row_status() { sqlite3 "$FX_MAIN/.claude/session-state.db" "SELECT status FROM sessions WHERE agent_id='$1';"; }

# retired: D-01, teardown sends nothing and waits for nothing

# Headless --yes merge (AC1, teardown half): the session row has no iTerm ID and
# the worker's tmux window is live on an isolated tmux server. Teardown must
# finish, kill the window and the grouped session, remove the worktree and branch,
# leave the row 'merged', and type into nothing (no osascript call, no send-keys).
REAL_TMUX=$(command -v tmux)
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"
LABELH="test-headless-fixture"
new_fixture "$LABELH" no-session
(
    cd "$FX_MAIN" || exit 1
    "$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$FX_MAIN" >/dev/null
    source "$SCRIPT_DIR/../orchestration/lib/session-state.sh"
    session_state_write "$LABELH" "$FX_WT" running "" >/dev/null
)
ISO_TMUX=$(mktemp -d)
EXTRA_DIRS+=("$ISO_TMUX")
# TMUX is unset so the real server of whoever runs this test is never addressed.
itmux() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$ISO_TMUX" "$REAL_TMUX" "$@"; }
HBASE=$(tmux_base_session_name "$FX_MAIN")
itmux new-session -d -s "$HBASE" -n placeholder "sleep 120"
itmux new-window -t "=$HBASE" -n "$LABELH" "sleep 120"
itmux new-session -d -t "=$HBASE" -s "${HBASE}-${LABELH}"
HBIN=$(mktemp -d)
EXTRA_DIRS+=("$HBIN")
TMUX_LOG="$HBIN/tmux.log"
OSA_LOG="$HBIN/osascript.log"
: > "$TMUX_LOG"
: > "$OSA_LOG"
cat > "$HBIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$TMUX_LOG"
exec "$REAL_TMUX" "\$@"
STUB
chmod +x "$HBIN/tmux"
DEFAULT_TMUX_BEFORE=$(tmux ls -F '#{session_name}' 2>&1 | grep -F -- "$HBASE" || true)

OUTPUT=$(cd "$FX_MAIN" && PATH="$HBIN:$STUB_BIN:$PATH" TMUX_TMPDIR="$ISO_TMUX" STUB_OSA_LOG="$OSA_LOG" \
    env -u TMUX -u TMUX_PANE "$MERGE_REVIEW" "$LABELH" --merge --yes 2>&1)
EXIT_CODE=$?
HLOG="$FX_MAIN/.claude/merge-review-$LABELH.log"

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "merge-review-$LABELH.log" && wait_for log_finished "$LABELH" \
    && tail -n 1 "$HLOG" | grep -q "Teardown finished (exit 0)"; then
    pass "headless --yes merge: teardown log ends 'Teardown finished (exit 0)'"
else
    fail "headless --yes merge did not finish (exit $EXIT_CODE); output: $OUTPUT; log: $(cat "$HLOG" 2>/dev/null)"
fi
if ! itmux list-windows -t "=$HBASE" -F '#{window_name}' | grep -qxF -- "$LABELH"; then
    pass "headless teardown: tmux window gone"
else
    fail "headless teardown: window $LABELH still live"
fi
if ! itmux has-session -t "=${HBASE}-${LABELH}" 2>/dev/null; then
    pass "headless teardown: grouped session gone"
else
    fail "headless teardown: grouped session ${HBASE}-${LABELH} still live"
fi
if itmux list-windows -t "=$HBASE" -F '#{window_name}' | grep -qxF -- placeholder; then
    pass "headless teardown: other windows of the base session untouched"
else
    fail "headless teardown: killed more than the label's window"
fi
if worktree_gone; then
    pass "headless teardown: worktree removed"
else
    fail "headless teardown: worktree left behind"
fi
if ! git -C "$FX_MAIN" show-ref --verify --quiet "refs/heads/session/$LABELH"; then
    pass "headless teardown: branch deleted"
else
    fail "headless teardown: branch session/$LABELH left behind"
fi
if [[ "$(row_status "$LABELH")" == "merged" ]]; then
    pass "headless teardown: row is 'merged'"
else
    fail "headless teardown: row is '$(row_status "$LABELH")' (expected merged)"
fi
if [[ ! -s "$OSA_LOG" ]]; then
    pass "headless teardown: osascript log is empty"
else
    fail "headless teardown: osascript was called: $(cat "$OSA_LOG")"
fi
if grep -q "kill-window" "$TMUX_LOG" && ! grep -q "send-keys" "$TMUX_LOG"; then
    pass "headless teardown: tmux killed the window and sent no keys"
else
    fail "headless teardown: tmux log wrong: $(cat "$TMUX_LOG")"
fi
if [[ "$(tmux ls -F '#{session_name}' 2>&1 | grep -F -- "$HBASE" || true)" == "$DEFAULT_TMUX_BEFORE" ]]; then
    pass "headless teardown: default tmux server unchanged"
else
    fail "headless teardown: default tmux server changed"
fi
if [[ ! -e "$FX_MAIN/.git/merge-review-$LABELH.lock" ]]; then
    pass "headless teardown: per-label lock released"
else
    fail "headless teardown: per-label lock left behind"
fi

# Lock: a live owner blocks a second run for the same label
LABELK="test-lock-fixture"
new_fixture "$LABELK"
mkdir "$FX_MAIN/.git/merge-review-$LABELK.lock"
echo $$ > "$FX_MAIN/.git/merge-review-$LABELK.lock/pid"
OUTPUT=$(run_yes_merge "$LABELK")
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "in progress"; then
    pass "second run for a locked label is refused"
else
    fail "locked label not refused (exit $EXIT_CODE); output: $OUTPUT"
fi
rm -rf "$FX_MAIN/.git/merge-review-$LABELK.lock"

# Fold conflict: main changed STATE.md after the branch forked, and the worker's
# wrap-up edits the same line -> fold must abort, leaving main clean and the
# worktree/branch intact.
LABEL4="test-fold-conflict-fixture"
FX_MAIN=$(mktemp -d)
EXTRA_DIRS+=("$FX_MAIN")
git -C "$FX_MAIN" init -q -b main
git -C "$FX_MAIN" config user.email "test@example.com"
git -C "$FX_MAIN" config user.name "Test"
mkdir -p "$FX_MAIN/.planning"
echo "phase: 0" > "$FX_MAIN/.planning/STATE.md"
git -C "$FX_MAIN" add .planning/STATE.md
git -C "$FX_MAIN" commit -q -m "initial"
FX_WT="$FX_MAIN/.claude/worktrees/$LABEL4"
mkdir -p "$FX_MAIN/.claude/worktrees"
git -C "$FX_MAIN" worktree add -q -b "session/$LABEL4" "$FX_WT" main
echo "feature" > "$FX_WT/feature.txt"
git -C "$FX_WT" add feature.txt
git -C "$FX_WT" commit -q -m "feature"
echo "phase: main" > "$FX_MAIN/.planning/STATE.md"
git -C "$FX_MAIN" commit -q -am "main edits STATE"
echo "phase: worker" > "$FX_WT/.planning/STATE.md"
OUTPUT=$(cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" "$MERGE_REVIEW" "$LABEL4" --merge --yes 2>&1)
FOLD_LOG="$FX_MAIN/.claude/merge-review-$LABEL4.log"
wait_for grep -q "Teardown finished" "$FOLD_LOG"
OUTPUT=$(cat "$FOLD_LOG" 2>/dev/null)
if echo "$OUTPUT" | grep -q "Teardown finished (exit 1)" && echo "$OUTPUT" | grep -q "Could not fold" && echo "$OUTPUT" | grep -q "CONFLICT"; then
    pass "fold conflict fails and reports git's CONFLICT output in the teardown log"
else
    fail "fold conflict not reported; teardown log: $OUTPUT"
fi
if [[ -z "$(git -C "$FX_MAIN" status --porcelain --untracked-files=no)" && ! -e "$FX_MAIN/.git/MERGE_HEAD" ]]; then
    pass "fold conflict leaves main clean (merge aborted)"
else
    fail "main left mid-merge or dirty after fold conflict"
fi
if [[ -d "$FX_WT" ]] && git -C "$FX_MAIN" show-ref --verify --quiet "refs/heads/session/$LABEL4"; then
    pass "fold conflict keeps worktree and branch"
else
    fail "worktree or branch removed after fold conflict"
fi
# Base branch = the checkout's current branch, not hardcoded main. Fixture:
# main and development diverge on .gitignore; checkout is on development and
# the worker branched from it. A merge-tree against main would conflict.
LABEL5="test-dev-base-fixture"
FX_MAIN=$(mktemp -d)
EXTRA_DIRS+=("$FX_MAIN")
git -C "$FX_MAIN" init -q -b main
git -C "$FX_MAIN" config user.email "test@example.com"
git -C "$FX_MAIN" config user.name "Test"
echo "base" > "$FX_MAIN/.gitignore"
git -C "$FX_MAIN" add .gitignore
git -C "$FX_MAIN" commit -q -m "initial"
git -C "$FX_MAIN" checkout -q -b development
echo "dev" > "$FX_MAIN/.gitignore"
git -C "$FX_MAIN" commit -q -am "development edits .gitignore"
git -C "$FX_MAIN" checkout -q main
echo "main" > "$FX_MAIN/.gitignore"
git -C "$FX_MAIN" commit -q -am "main edits .gitignore"
git -C "$FX_MAIN" checkout -q development
FX_WT="$FX_MAIN/.claude/worktrees/$LABEL5"
mkdir -p "$FX_MAIN/.claude/worktrees"
git -C "$FX_MAIN" worktree add -q -b "session/$LABEL5" "$FX_WT"
echo "feature" > "$FX_WT/feature.txt"
git -C "$FX_WT" add feature.txt
git -C "$FX_WT" commit -q -m "feature"
OUTPUT=$(cd "$FX_MAIN" && "$MERGE_REVIEW" "$LABEL5" 2>&1)
if echo "$OUTPUT" | grep -q "feature.txt" && ! echo "$OUTPUT" | grep -q "gitignore"; then
    pass "summary diffs against development"
else
    fail "summary not against development; output: $OUTPUT"
fi
OUTPUT=$(cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" "$MERGE_REVIEW" "$LABEL5" --merge --yes 2>&1)
EXIT_CODE=$?
wait_for grep -q "Teardown finished" "$FX_MAIN/.claude/merge-review-$LABEL5.log"
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "into development" \
    && [[ "$(git -C "$FX_MAIN" rev-parse --abbrev-ref HEAD)" == "development" ]] \
    && [[ -f "$FX_MAIN/feature.txt" ]]; then
    pass "--merge --yes merges into development"
else
    fail "merge into development failed (exit $EXIT_CODE); output: $OUTPUT"
fi

# Detached HEAD: refused, nothing merged.
LABEL6="test-detached-fixture"
git -C "$FX_MAIN" checkout -q development
FX_WT6="$FX_MAIN/.claude/worktrees/$LABEL6"
git -C "$FX_MAIN" worktree add -q -b "session/$LABEL6" "$FX_WT6"
echo "f6" > "$FX_WT6/f6.txt"
git -C "$FX_WT6" add f6.txt
git -C "$FX_WT6" commit -q -m "f6"
git -C "$FX_MAIN" checkout -q --detach
HEAD_BEFORE=$(git -C "$FX_MAIN" rev-parse HEAD)
OUTPUT=$(cd "$FX_MAIN" && "$MERGE_REVIEW" "$LABEL6" --merge --yes 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "detached" \
    && [[ "$(git -C "$FX_MAIN" rev-parse HEAD)" == "$HEAD_BEFORE" ]] && [[ ! -f "$FX_MAIN/f6.txt" ]]; then
    pass "detached HEAD refused, nothing merged"
else
    fail "detached HEAD not refused (exit $EXIT_CODE); output: $OUTPUT"
fi

# --- Squash-merged on GitHub: --teardown and --kill must recognise the merge --
# A squash merge leaves the branch tip out of the base's history, so ancestry
# alone calls it unmerged. gh is stubbed: it reports a merged PR with head oid
# STUB_PR_OID when asked about STUB_PR_HEAD.
cat > "$STUB_BIN/gh" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
    [ "$1" = "--head" ] && head="$2"
    shift
done
[ -n "$STUB_PR_HEAD" ] && [ "$head" = "$STUB_PR_HEAD" ] && echo "$STUB_PR_OID"
exit 0
STUB
chmod +x "$STUB_BIN/gh"

squash_merge() {
    git -C "$FX_MAIN" merge --squash "session/$1" >/dev/null 2>&1
    git -C "$FX_MAIN" commit -q -m "squash $1"
}
# A later base edit to the squashed file makes merge-tree conflict, so only the
# PR lookup can prove the merge
diverge_base() {
    echo "later edit" >> "$FX_MAIN/feature.txt"
    git -C "$FX_MAIN" commit -q -am "later edit"
}
branch_exists() { git -C "$FX_MAIN" show-ref --verify --quiet "refs/heads/$1"; }
# $1 = label, $2 = head oid the stubbed gh reports as a merged PR (empty = none)
run_teardown_cmd() {
    (cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" STUB_PR_HEAD="session/$1" STUB_PR_OID="${2:-}" \
        "$MERGE_REVIEW" "$1" --teardown 2>&1)
}
run_kill_cmd() {
    (cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" STUB_PR_HEAD="session/$1" STUB_PR_OID="${2:-}" \
        ORCH_PROJECT_ROOT="$FX_MAIN" bash "$SCRIPT_DIR/../orchestration/lib/dispatch-task.sh" --kill "$1" >/dev/null 2>&1)
}
orphans() { git -C "$FX_MAIN" branch --list "session/$1-orphaned-*"; }

# --teardown: PR-merged label (squash on base, base moved on) is torn down
LABEL7="test-pr-merged"
new_fixture "$LABEL7" no-session
squash_merge "$LABEL7"; diverge_base
TIP=$(git -C "$FX_MAIN" rev-parse "session/$LABEL7")
OUTPUT=$(run_teardown_cmd "$LABEL7" "$TIP")
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && [[ ! -d "$FX_WT" ]] && ! branch_exists "session/$LABEL7"; then
    pass "--teardown removes worktree and branch of a PR-merged label"
else
    fail "--teardown PR-merged (exit $EXIT_CODE); output: $OUTPUT"
fi

# --teardown: unmerged label is refused and left intact
LABEL8="test-teardown-unmerged"
new_fixture "$LABEL8" no-session
OUTPUT=$(run_teardown_cmd "$LABEL8" "")
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "not merged" \
    && [[ -d "$FX_WT" ]] && branch_exists "session/$LABEL8"; then
    pass "--teardown refuses an unmerged label and leaves worktree and branch"
else
    fail "--teardown unmerged (exit $EXIT_CODE); output: $OUTPUT"
fi

# --teardown: PR head differs from the local tip (post-merge commit) -> not merged
LABEL9="test-pr-head-differs"
new_fixture "$LABEL9" no-session
squash_merge "$LABEL9"; diverge_base
OLD_TIP=$(git -C "$FX_MAIN" rev-parse "session/$LABEL9")
echo "after the PR" > "$FX_WT/post.txt"
git -C "$FX_WT" add post.txt
git -C "$FX_WT" commit -q -m "post-merge work"
OUTPUT=$(run_teardown_cmd "$LABEL9" "$OLD_TIP")
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "not merged" \
    && [[ -d "$FX_WT" ]] && branch_exists "session/$LABEL9"; then
    pass "--teardown refuses when the merged PR head differs from the branch tip"
else
    fail "--teardown PR head differs (exit $EXIT_CODE); output: $OUTPUT"
fi

# --teardown cannot combine with --merge
OUTPUT=$(cd "$FX_MAIN" && "$MERGE_REVIEW" "$LABEL9" --teardown --merge 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -q -- "--teardown cannot" \
    && [[ -d "$FX_WT" ]]; then
    pass "--teardown with --merge is an error"
else
    fail "--teardown --merge not rejected (exit $EXIT_CODE); output: $OUTPUT"
fi

# --kill: squash-merged branch (PR lookup only) is removed, not orphaned
LABEL10="test-kill-pr-merged"
new_fixture "$LABEL10"
squash_merge "$LABEL10"; diverge_base
TIP=$(git -C "$FX_MAIN" rev-parse "session/$LABEL10")
run_kill_cmd "$LABEL10" "$TIP"
if [[ ! -d "$FX_WT" ]] && ! branch_exists "session/$LABEL10" && [[ -z "$(orphans "$LABEL10")" ]]; then
    pass "--kill removes a PR-merged branch and worktree without orphaning"
else
    fail "--kill PR-merged: worktree/branch kept or orphaned: $(git -C "$FX_MAIN" branch --list 'session/*' | tr '\n' ' ')"
fi

# --teardown also deletes the pushed remote branch
LABEL13="test-teardown-remote"
new_fixture "$LABEL13" no-session
REMOTE=$(mktemp -d)
EXTRA_DIRS+=("$REMOTE")
git init -q --bare "$REMOTE"
git -C "$FX_MAIN" remote add origin "$REMOTE"
git -C "$FX_MAIN" push -q origin "session/$LABEL13" 2>/dev/null
squash_merge "$LABEL13"
OUTPUT=$(run_teardown_cmd "$LABEL13" "")
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$(git -C "$REMOTE" branch --list "session/$LABEL13")" ]]; then
    pass "--teardown deletes the remote branch"
else
    fail "--teardown remote branch kept (exit $EXIT_CODE); output: $OUTPUT"
fi

# --kill: squash-merged branch whose tree is already on base (no gh needed)
LABEL11="test-kill-squash-tree"
new_fixture "$LABEL11"
squash_merge "$LABEL11"
run_kill_cmd "$LABEL11" ""
if [[ ! -d "$FX_WT" ]] && ! branch_exists "session/$LABEL11" && [[ -z "$(orphans "$LABEL11")" ]]; then
    pass "--kill removes a squash-merged branch whose tree is on base"
else
    fail "--kill squash-tree: worktree/branch kept or orphaned: $(git -C "$FX_MAIN" branch --list 'session/*' | tr '\n' ' ')"
fi

# --kill: unmerged branch is still preserved as -orphaned-*
LABEL12="test-kill-unmerged"
new_fixture "$LABEL12"
run_kill_cmd "$LABEL12" ""
if [[ -d "$FX_WT" ]] && ! branch_exists "session/$LABEL12" && [[ -n "$(orphans "$LABEL12")" ]]; then
    pass "--kill still renames an unmerged branch to -orphaned-*"
else
    fail "--kill unmerged: branches: $(git -C "$FX_MAIN" branch --list 'session/*' | tr '\n' ' ')"
fi

# Worktree dir gone, branch present: merge, tab close, window teardown and branch
# delete still run; .planning fold and worktree remove are skipped with a warning.
LABEL14="test-missing-worktree-fixture"
new_fixture "$LABEL14"
rm -rf "$FX_WT"
STUB_TMUX_LOG="$FX_MAIN/tmux-stub.log"
OUTPUT=$(STUB_TMUX_LOG="$STUB_TMUX_LOG" run_yes_merge "$LABEL14")
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && wait_for log_finished "$LABEL14"; then
    pass "missing worktree dir: --merge --yes exits 0 and teardown finishes"
else
    fail "missing worktree dir not merged (exit $EXIT_CODE); output: $OUTPUT"
fi
if git -C "$FX_MAIN" show main:feature.txt >/dev/null 2>&1; then
    pass "missing worktree dir: branch merged into main"
else
    fail "missing worktree dir: feature.txt not on main; output: $OUTPUT"
fi
if grep -q "Closed iTerm tab" "$FX_MAIN/.claude/merge-review-$LABEL14.log" 2>/dev/null; then
    pass "missing worktree dir: tab still closed"
else
    fail "missing worktree dir: tab not closed; log: $(cat "$FX_MAIN/.claude/merge-review-$LABEL14.log" 2>/dev/null)"
fi
if grep -q "kill-window.*$LABEL14" "$STUB_TMUX_LOG" 2>/dev/null; then
    pass "missing worktree dir: tmux window still torn down"
else
    fail "missing worktree dir: no kill-window for $LABEL14; tmux calls: $(cat "$STUB_TMUX_LOG" 2>/dev/null)"
fi
if ! git -C "$FX_MAIN" show-ref --verify --quiet "refs/heads/session/$LABEL14" \
    && grep -q "is gone; skipping" "$FX_MAIN/.claude/merge-review-$LABEL14.log" 2>/dev/null; then
    pass "missing worktree dir: branch deleted, fold/remove skip warned"
else
    fail "missing worktree dir: branch/warning wrong; log: $(cat "$FX_MAIN/.claude/merge-review-$LABEL14.log" 2>/dev/null)"
fi

# --teardown --yes with a live tab: session row ends 'merged'
LABEL15="test-teardown-marks-merged"
new_fixture "$LABEL15"
squash_merge "$LABEL15"
STUB_TMUX_LOG="$FX_MAIN/tmux-stub.log"
(cd "$FX_MAIN" && PATH="$STUB_BIN:$PATH" STUB_TMUX_LOG="$STUB_TMUX_LOG" "$MERGE_REVIEW" "$LABEL15" --teardown --yes >/dev/null 2>&1)
wait_for log_finished "$LABEL15"
if grep -q "Closed iTerm tab" "$FX_MAIN/.claude/merge-review-$LABEL15.log" 2>/dev/null \
    && grep -q "kill-window.*$LABEL15" "$STUB_TMUX_LOG" 2>/dev/null; then
    pass "tabbed worker: tab closed and window killed"
else
    fail "tabbed worker: tab/window not both closed; log: $(cat "$FX_MAIN/.claude/merge-review-$LABEL15.log" 2>/dev/null)"
fi
if [[ "$(row_status "$LABEL15")" == "merged" ]]; then
    pass "--teardown leaves the session row 'merged'"
else
    fail "--teardown left session row '$(row_status "$LABEL15")' (expected merged)"
fi

# Both dir and branch missing: still 'not found'.
OUTPUT=$(cd "$FX_MAIN" && "$MERGE_REVIEW" "test-no-such-session" --merge --yes 2>&1)
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]] && echo "$OUTPUT" | grep -q "not found"; then
    pass "dir and branch both missing: session not found"
else
    fail "unknown session not refused (exit $EXIT_CODE); output: $OUTPUT"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
