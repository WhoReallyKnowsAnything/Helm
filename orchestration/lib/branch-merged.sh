#!/usr/bin/env bash
# branch-merged.sh -- decide whether a session branch's work is already on its base.
# Repos that squash-merge worker PRs on GitHub never get the branch tip into the
# base's history, so ancestry alone reports a merged branch as unmerged.

# branch_is_merged <repo_root> <base_ref> <branch> [<pr_branch>]
# Returns 0 when the branch is an ancestor of base, merging it would not change
# base's tree (squash/no-op), or a merged PR for branch/pr_branch has exactly the
# local tip of branch as its head. A tip that differs from the PR head (commits
# made after the merge) is never treated as merged. gh missing or failing means
# "not merged".
branch_is_merged() {
    local repo_root="$1" base_ref="$2" branch="$3" pr_branch="${4:-}"
    local base_tree merged_tree tip name

    command git -C "$repo_root" merge-base --is-ancestor "$branch" "$base_ref" 2>/dev/null && return 0

    base_tree=$(command git -C "$repo_root" rev-parse "$base_ref^{tree}" 2>/dev/null) || return 1
    # A clean merge-tree --write-tree prints the merged tree's oid on its first line
    merged_tree=$(command git -C "$repo_root" merge-tree --write-tree "$base_ref" "$branch" 2>/dev/null) \
        && [[ "${merged_tree%%$'\n'*}" == "$base_tree" ]] && return 0

    tip=$(command git -C "$repo_root" rev-parse --verify "$branch^{commit}" 2>/dev/null) || return 1
    command -v gh >/dev/null 2>&1 || return 1
    for name in "$branch" "$pr_branch"; do
        [[ -n "$name" ]] || continue
        (cd "$repo_root" && gh pr list --head "$name" --state merged --json headRefOid --jq '.[].headRefOid' 2>/dev/null) \
            | grep -qx "$tip" && return 0
    done
    return 1
}

# delete_remote_branch <repo_root> <branch>
# Best-effort: a missing origin or remote branch is fine, a failed delete only warns.
delete_remote_branch() {
    local repo_root="$1" branch="$2"
    command git -C "$repo_root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 || return 0
    command git -C "$repo_root" push origin --delete "$branch" >/dev/null 2>&1 \
        || echo "Warning: Could not delete remote branch $branch. Clean up manually if needed." >&2
}
