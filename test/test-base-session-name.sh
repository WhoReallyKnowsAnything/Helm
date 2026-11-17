#!/bin/bash
# test/test-base-session-name.sh
# tmux_base_session_name: a linked worktree is named after its MAIN repository
# (D-01); every other folder keeps the plain slug of its basename.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

WORK="$(mktemp -d /tmp/bsn.XXXXXX)" || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

# Independent slug: basename, lower-case, runs of non [a-z0-9] become "-", trimmed.
slug() { basename "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

check_name() { # label folder expected
    local got
    got="$(tmux_base_session_name "$2")"
    if [[ "$got" == "$3" ]]; then pass "$1 -> '$got'"; else fail "$1: expected '$3', got '$got'"; fi
}

git_init() { # dir
    mkdir -p "$1"
    ( cd "$1" && command git init -q && command git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
}

# 1. plain repo
git_init "$WORK/plain"
check_name "plain repo" "$WORK/plain" "$(slug "$WORK/plain")"

# 2. linked worktree: named after the MAIN repository, not the worktree folder
git_init "$WORK/Main_Repo"
( cd "$WORK/Main_Repo" && command git worktree add -q -b feat "$WORK/wt-feature" )
check_name "linked worktree" "$WORK/wt-feature" "$(slug "$WORK/Main_Repo")"

# 3. non-git directory
mkdir -p "$WORK/plain-dir"
check_name "non-git directory" "$WORK/plain-dir" "$(slug "$WORK/plain-dir")"

# 4. odd name: capitals, underscores, spaces
mkdir -p "$WORK/My_Odd Name"
check_name "odd name" "$WORK/My_Odd Name" "$(slug "$WORK/My_Odd Name")"

# 5. path that does not exist
check_name "missing path" "$WORK/does/not/exist-Here" "$(slug "$WORK/does/not/exist-Here")"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
