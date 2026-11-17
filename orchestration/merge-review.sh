#!/usr/bin/env bash
set +o posix  # enable bash-specific features: [[ ]], arrays, local vars
# merge-review.sh — review and merge completed session branches
# Usage: merge-review.sh [<label>] [--merge | --teardown] [--yes]
#   No args:           List all sessions with their status
#   <label>:           Show diff summary (files changed + commits) for session/label
#   <label> --merge:   Perform dry-run conflict check, display diff, prompt for confirmation, then merge and cleanup
#   <label> --teardown: For a branch already merged elsewhere (e.g. a squash-merged GitHub PR): verify it is
#                      merged, then close its window, remove worktree/branch and delete the remote branch. Merges nothing.

# Resolve project root
TARGET_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Source session state helper library
source "$(dirname "$0")/lib/session-state.sh" || {
    echo "Error: cannot source session-state.sh" >&2
    exit 1
}
source "$(dirname "$0")/lib/tmux-session.sh" 2>/dev/null || true
source "$(dirname "$0")/lib/branch-merged.sh" || {
    echo "Error: cannot source branch-merged.sh" >&2
    exit 1
}

# Helper: fetch session status from state store
get_session_status() {
    local label="$1"
    local status
    
    # Query state store for this agent_id
    status=$(session_state_read "$label" 2>/dev/null)
    if [[ $? -eq 0 && -n "$status" ]]; then
        echo "$status"
    else
        # Gracefully return unknown if state store lookup fails
        echo "unknown"
    fi
}

# Helper: list all sessions from state store
list_sessions() {
    local sessions_output
    
    # Query state store for all sessions
    sessions_output=$(session_state_list)
    if [[ $? -ne 0 || -z "$sessions_output" ]]; then
        echo "No sessions found."
        return 0
    fi
    
    # Print header
    echo "Available sessions:"
    echo ""
    
    # Print table
    printf "%-15s %-30s %s\n" "Label" "Branch" "Status"
    printf "%-15s %-30s %s\n" "-----" "------" "------"
    
    # Parse state store output (tab-separated: agent_id, status, worktree_path, pid, created_at)
    while IFS=$'\t' read -r agent_id status wt_path pid created_at; do
        [[ -z "$agent_id" ]] && continue
        # Extract label from agent_id (use as-is for display)
        local label="$agent_id"
        printf "%-15s %-30s %s\n" "$label" "session/$label" "$status"
    done <<< "$sessions_output"
}

# Helper: base branch = the branch checked out in the main checkout (workers
# branch from its HEAD at dispatch). Refuses detached HEAD.
resolve_base() {
    BASE_BRANCH=$(git -C "$TARGET_DIR" symbolic-ref --short HEAD 2>/dev/null)
    if [[ -z "$BASE_BRANCH" ]]; then
        echo "Error: $TARGET_DIR is on a detached HEAD; check out a branch to merge into" >&2
        return 1
    fi
}

# Helper: show diff summary for a specific session
show_diff_summary() {
    local label="$1"
    local worktree_dir="$TARGET_DIR/.claude/worktrees"
    
    # Validate label exists
    if [[ ! -d "$worktree_dir/$label" ]] && ! git rev-parse --verify -q "session/$label" >/dev/null 2>&1; then
        echo "Error: session '$label' not found" >&2
        return 1
    fi
    
    # Verify we're in a git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "Error: not in a git repository" >&2
        return 1
    fi
    
    # Verify branch exists
    if ! git rev-parse "session/$label" >/dev/null 2>&1; then
        echo "Error: branch session/$label does not exist" >&2
        return 1
    fi

    resolve_base || return 1
    
    echo "=== Changes in session/$label ==="
    echo ""
    
    # Show diff summary (triple-dot: changes since merge-base)
    local diff_output
    diff_output=$(git diff --stat "$BASE_BRANCH...session/$label" 2>/dev/null)
    if [[ -n "$diff_output" ]]; then
        echo "$diff_output"
    else
        echo "No changes in this branch."
    fi
    
    echo ""
    echo "=== Commits ==="
    echo ""
    
    # Show commit log (double-dot: commits in branch but not in the base branch)
    local log_output
    log_output=$(git log "$BASE_BRANCH..session/$label" --oneline 2>/dev/null)
    if [[ -n "$log_output" ]]; then
        echo "$log_output"
    else
        echo "No commits in this branch."
    fi
}

# Helper: per-label lock (mkdir is atomic) so repeated merge-review runs for
# one label don't race on the merge or the teardown. The pid file lets a run
# reclaim a lock whose owner died.
acquire_merge_lock() {
    local lock_dir="$1" owner
    if ! mkdir "$lock_dir" 2>/dev/null; then
        owner=$(cat "$lock_dir/pid" 2>/dev/null)
        if [[ -z "$owner" ]] || kill -0 "$owner" 2>/dev/null; then
            return 1
        fi
        rm -rf "$lock_dir"
        mkdir "$lock_dir" 2>/dev/null || return 1
    fi
    echo $$ > "$lock_dir/pid"
}

# Helper: close the worker's iTerm tab by session ID (only when it has one) and
# always tear down its tmux window -- closing the tab only detaches a client, it
# does not kill the underlying claude process once tmux-hosted (Open Question 1 /
# Pitfall 1), and a headless worker has no tab at all.
close_worker_tab() {
    local label="$1" iterm_id="$2" result
    if [[ -n "$iterm_id" ]]; then
        result=$(tmux_close_terminal_tab "$iterm_id")
        case "$result" in
            closed)
                echo "✓ Closed iTerm tab for $label"
                ;;
            not_found)
                echo "Warning: iTerm tab already closed for $label" >&2
                ;;
            error)
                echo "Warning: error closing iTerm tab for $label (logged to system.log)" >&2
                ;;
        esac
    fi
    if declare -f tmux_teardown_worker &>/dev/null; then
        tmux_teardown_worker "$(tmux_base_session_name "$TARGET_DIR")" "$label"
    fi
}

# Helper: close the worker's tab/window (the worker already ran /om-wrap-up itself),
# fold its wrap-up output into
# the base branch, then remove the worktree and branch. Runs in the foreground, or detached
# for --yes (see run_teardown). With teardown_only=true the base already has the
# work (--teardown): no fold into the base, and the remote branch is deleted too.
# Returns 0 when cleaned up, 2 when cleanup was deferred, 1 on failure.
teardown_session() {
    local label="$1"
    local non_interactive="$2"
    local worktree_path="$3"
    local branch="$4"
    local iterm_id="$5"
    local teardown_only="${6:-false}"

    if [[ ! -d "$worktree_path" ]]; then
        echo "Warning: worktree $worktree_path is gone; skipping .planning fold and worktree remove" >&2
        close_worker_tab "$label" "$iterm_id"
        # Drop the stale worktree registration, or git refuses to delete the branch.
        git worktree prune >/dev/null 2>&1
        if ! git branch -D "$branch" >/dev/null 2>&1; then
            echo "Warning: Could not delete branch $branch. Clean up manually if needed." >&2
        fi
        [[ "$teardown_only" == "true" ]] && delete_remote_branch "$TARGET_DIR" "$branch"
        echo "✓ Merge complete: $branch → $BASE_BRANCH"
        return 0
    fi

    # Close the tab (if any) and kill the window. The worker ran /om-wrap-up
    # itself before it was marked done (D-01), so nothing is sent into it here and
    # nothing is waited for. This must run BEFORE the worktree is removed -- the
    # worker session's working directory IS the worktree, so removing it first
    # leaves the session spawning its hooks from a directory that no longer
    # exists (posix_spawn ENOENT on /bin/sh).
    close_worker_tab "$label" "$iterm_id"

    # Wrap-up may have left uncommitted output in the worktree (e.g.
    # /om-wrap-up updating .planning/STATE.md) -- fold it into the base branch before
    # removing the worktree below, or removal fails and that output is
    # stranded with no path back into history. Scoped to .planning/ (what
    # wrap-up actually writes) rather than `add -A`, so a worker's stray
    # scratch files don't ride into the base branch in the same commit.
    if [[ "$teardown_only" != "true" && -n "$(git -C "$worktree_path" status --porcelain -- .planning 2>/dev/null)" ]]; then
        local fold_output
        if ! fold_output=$(git -C "$worktree_path" add -- .planning 2>&1 >/dev/null); then
            echo "Error: Could not stage wrap-up output for $label:" >&2
            echo "$fold_output" >&2
            return 1
        fi
        if ! fold_output=$(git -C "$worktree_path" commit -q -m "chore: capture wrap-up output for $label" 2>&1 >/dev/null); then
            echo "Error: Could not commit wrap-up output for $label:" >&2
            echo "$fold_output" >&2
            return 1
        fi
        # Capture stdout too: git prints CONFLICT lines there. On failure, abort
        # so the base branch is not left mid-merge; worktree and branch stay for manual resolve.
        if ! fold_output=$(git merge "$branch" 2>&1); then
            git merge --abort >/dev/null 2>&1
            echo "Error: Could not fold wrap-up commit from $branch into $BASE_BRANCH (merge aborted, worktree and branch kept):" >&2
            echo "$fold_output" >&2
            return 1
        fi
    fi

    # Remove the worktree -- only now that the session living in it is gone.
    if ! git worktree remove "$worktree_path" >/dev/null 2>&1; then
        echo "Error: Cannot remove worktree $worktree_path. Blocking status:" >&2
        git -C "$worktree_path" status --short >&2
        return 1
    fi
    
    # Delete the branch (warn if it fails, but don't fail the overall operation)
    if ! git branch -D "$branch" >/dev/null 2>&1; then
        echo "Warning: Could not delete branch $branch. Clean up manually if needed." >&2
    fi
    [[ "$teardown_only" == "true" ]] && delete_remote_branch "$TARGET_DIR" "$branch"
    
    # Success message
    echo "✓ Merge complete: $branch → $BASE_BRANCH"
    return 0
}

# Helper: take the per-label lock around the merge. The lock is released here
# unless teardown went detached, in which case the detached job owns it.
do_merge() {
    local label="$1"
    MERGE_LOCK_DIR="$(git -C "$TARGET_DIR" rev-parse --path-format=absolute --git-common-dir)/merge-review-$label.lock"
    if ! acquire_merge_lock "$MERGE_LOCK_DIR"; then
        echo "Error: another merge-review for '$label' is in progress (lock: $MERGE_LOCK_DIR)" >&2
        return 1
    fi

    TEARDOWN_DETACHED=false
    local rc
    if [[ "${3:-false}" == "true" ]]; then
        do_teardown_locked "$1" "$2"
    else
        do_merge_locked "$@"
    fi
    rc=$?
    [[ "$TEARDOWN_DETACHED" == "true" ]] || rm -rf "$MERGE_LOCK_DIR"
    return $rc
}

# Helper: perform merge with conflict detection and cleanup
do_merge_locked() {
    local label="$1"
    local non_interactive="${2:-false}"
    local worktree_dir="$TARGET_DIR/.claude/worktrees"
    local worktree_path="$worktree_dir/$label"
    local branch="session/$label"
    
    # Validate label exists
    if [[ ! -d "$worktree_path" ]] && ! git rev-parse --verify -q "$branch" >/dev/null 2>&1; then
        echo "Error: session '$label' not found" >&2
        return 1
    fi
    
    # Verify we're in a git repo
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "Error: not in a git repository" >&2
        return 1
    fi
    
    # Verify branch exists
    if ! git rev-parse "$branch" >/dev/null 2>&1; then
        echo "Error: branch $branch does not exist" >&2
        return 1
    fi
    
    # Verify git version supports merge-tree --write-tree (git >= 2.38.0)
    local git_version
    git_version=$(git --version | sed -n 's/^git version \([0-9]*\.[0-9]*\).*/\1/p')
    [[ -z "$git_version" ]] && git_version="0.0"
    if [[ $(printf "%s\n" "$git_version" "2.38" | sort -V | head -n1) != "2.38" ]]; then
        echo "Error: git version 2.38.0 or later required for conflict detection. Found: $git_version" >&2
        return 1
    fi
    
    resolve_base || return 1

    # Display diff summary first
    show_diff_summary "$label"
    echo ""
    
    # Check for conflicts using git merge-tree --write-tree
    local conflicts_output merge_tree_exit_code
    conflicts_output=$(git merge-tree --write-tree "$BASE_BRANCH" "$branch" 2>&1)
    merge_tree_exit_code=$?
    
    # Verify merge-tree succeeded before processing output
    if [[ $merge_tree_exit_code -ne 0 ]]; then
        echo "Error: git merge-tree failed (exit code $merge_tree_exit_code)" >&2
        echo "$conflicts_output" | head -5 >&2
        return 1
    fi
    
    # Extract and display conflict information
    conflicts_output=$(echo "$conflicts_output" | grep "^Conflicted file")
    
    if [[ -n "$conflicts_output" ]]; then
        echo "Error: Merge would have conflicts in the following files:" >&2
        echo "$conflicts_output" | while IFS= read -r line; do
            # Extract file path from 'Conflicted file <path>'
            local filepath
            filepath=$(echo "$line" | sed 's/^Conflicted file //')
            echo "  - $filepath" >&2
        done
        echo "" >&2
        echo "Resolve conflicts in the worktree, then re-run merge-review.sh" >&2
        return 1
    fi
    
    # Prompt user for confirmation (skipped when non_interactive -- the
    # orchestrator only ever passes --yes after explicit chat-level consent,
    # per task-drafting-mode.md; the in-script y/n is redundant with that)
    if [[ "$non_interactive" == "true" ]]; then
        echo "  Auto-confirmed (--yes): merging $branch into $BASE_BRANCH"
    else
        local confirm
        read -rp "Merge $branch into $BASE_BRANCH? (y/n): " confirm
        echo ""

        # If user didn't confirm, exit cleanly
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Merge cancelled."
            return 0
        fi
    fi
    
    # Ensure we're in the main worktree (not inside the linked worktree)
    cd "$TARGET_DIR" || {
        echo "Error: cannot cd to repository root" >&2
        return 1
    }
    
    # Perform the merge
    local merge_output
    if ! merge_output=$(git merge "$branch" 2>&1 >/dev/null); then
        echo "Error: Merge failed:" >&2
        echo "$merge_output" >&2
        return 1
    fi
    
    run_teardown "$label" "$non_interactive" "$worktree_path" "$branch"
}

# Helper: --teardown for a branch already merged elsewhere (e.g. a squash-merged
# GitHub PR). Merges nothing: verifies the work is on the base, then tears down.
do_teardown_locked() {
    local label="$1"
    local non_interactive="${2:-false}"
    local worktree_path="$TARGET_DIR/.claude/worktrees/$label"
    local branch="session/$label"
    local pr_branch

    if [[ ! -d "$worktree_path" ]] && ! git rev-parse --verify -q "$branch" >/dev/null 2>&1; then
        echo "Error: session '$label' not found" >&2
        return 1
    fi
    if ! git rev-parse "$branch" >/dev/null 2>&1; then
        echo "Error: branch $branch does not exist" >&2
        return 1
    fi

    resolve_base || return 1

    pr_branch=$(git -C "$worktree_path" symbolic-ref --short HEAD 2>/dev/null)
    if ! branch_is_merged "$TARGET_DIR" "$BASE_BRANCH" "$branch" "$pr_branch"; then
        echo "Error: $branch is not merged into $BASE_BRANCH (no ancestry, no matching tree, no merged PR for its current tip); nothing torn down" >&2
        return 1
    fi
    echo "$branch is already merged into $BASE_BRANCH; tearing down"

    cd "$TARGET_DIR" || {
        echo "Error: cannot cd to repository root" >&2
        return 1
    }
    run_teardown "$label" "$non_interactive" "$worktree_path" "$branch" true
}

# Helper: run teardown_session in the foreground, or detached for --yes (with or
# without a tab). Takes over the per-label lock when it detaches.
run_teardown() {
    local label="$1" non_interactive="$2" worktree_path="$3" branch="$4" teardown_only="${5:-false}"
    local iterm_id
    iterm_id=$(session_state_get_iterm_id "$label") || iterm_id=""
    session_state_update_status "$label" merged 2>/dev/null || true

    # --yes: the orchestrator's caller must not block on the teardown, and its
    # exit must not cut teardown short. Detach into its
    # own process group (set -m) with stdio on a log, so reaping the caller's
    # process group or closing its output pipe can't touch the teardown.
    if [[ "$non_interactive" == "true" ]]; then
        local log_file="$TARGET_DIR/.claude/merge-review-$label.log"
        mkdir -p "$TARGET_DIR/.claude"
        set -m
        (
            trap '' HUP
            trap 'rm -rf "$MERGE_LOCK_DIR"' EXIT
            teardown_session "$label" "$non_interactive" "$worktree_path" "$branch" "$iterm_id" "$teardown_only"
            echo "Teardown finished (exit $?)"
        ) >"$log_file" 2>&1 </dev/null &
        echo $! > "$MERGE_LOCK_DIR/pid"
        disown $! 2>/dev/null || true
        set +m
        TEARDOWN_DETACHED=true
        echo "✓ Merged $branch → $BASE_BRANCH; wrap-up and teardown continue in the background"
        echo "  Teardown log: $log_file"
        return 0
    fi

    teardown_session "$label" "$non_interactive" "$worktree_path" "$branch" "$iterm_id" "$teardown_only"
}

if [[ $# -eq 0 ]]; then
    # No arguments: list all sessions
    list_sessions
elif [[ $# -eq 1 ]]; then
    # Single argument: show diff summary for that label
    show_diff_summary "$1"
else
    # Two or more arguments: label plus --merge or --teardown and/or --yes/-y flags
    label="$1"
    shift
    do_merge_flag=false
    teardown_flag=false
    yes_flag=false
    bad_arg=""
    for arg in "$@"; do
        case "$arg" in
            --merge) do_merge_flag=true ;;
            --teardown) teardown_flag=true ;;
            --yes|-y) yes_flag=true ;;
            *) bad_arg="$arg" ;;
        esac
    done
    if [[ -n "$bad_arg" ]]; then
        echo "Error: Unknown argument '$bad_arg'. Use: merge-review.sh <label> --merge|--teardown [--yes]" >&2
        exit 1
    elif [[ "$do_merge_flag" == "true" && "$teardown_flag" == "true" ]]; then
        echo "Error: --teardown cannot be combined with --merge. Use: merge-review.sh <label> --merge|--teardown [--yes]" >&2
        exit 1
    elif [[ "$do_merge_flag" != "true" && "$teardown_flag" != "true" ]]; then
        echo "Error: --yes only applies with --merge or --teardown. Use: merge-review.sh <label> --merge|--teardown [--yes]" >&2
        exit 1
    else
        do_merge "$label" "$yes_flag" "$teardown_flag"
    fi
fi
