#!/bin/bash
# test/test-orch-session-name.sh
# The orchestrator's roster name (claude --name) carries its project, so 2+ open
# projects never collide in ListAgents, and every worker is told its own
# orchestrator's exact name at dispatch. The state-store id "dashboard" is untouched.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: expected '$3', got '$2'"; }

WORK="$(mktemp -d /tmp/osn.XXXXXX)" || exit 1
trap 'rm -rf "$WORK"' EXIT
for p in "Proj_Alpha" "proj-beta"; do
    mkdir -p "$WORK/$p"
    ( cd "$WORK/$p" && command git init -q && command git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
done
( cd "$WORK/Proj_Alpha" && command git worktree add -q -b feat "$WORK/wt-feature" )

A="$(orch_session_name "$WORK/Proj_Alpha")"
B="$(orch_session_name "$WORK/proj-beta")"
eq "project alpha name" "$A" "dashboard-proj-alpha"
eq "project beta name" "$B" "dashboard-proj-beta"
[[ "$A" != "$B" ]] && pass "2 projects get different roster names" || fail "2 projects share a roster name"
eq "a linked worktree keeps its main repo's name" "$(orch_session_name "$WORK/wt-feature")" "$A"

# _build_launch_cmd: pull the function out of dispatch-task.sh (the script runs its main flow when sourced).
eval "$(sed -n '/^_sq_quote() {/,/^}/p;/^_build_launch_cmd() {/,/^}/p' "$REPO_DIR/orchestration/lib/dispatch-task.sh")"
cmd_for() { _build_launch_cmd lbl "$WORK" sonnet "" "$WORK/in" "$WORK/out" "" "$(orch_session_name "$1")"; }
CA="$(cmd_for "$WORK/Proj_Alpha")"
CB="$(cmd_for "$WORK/proj-beta")"
[[ "$CA" == *"peer roster is: dashboard-proj-alpha."* ]] && pass "alpha worker is told dashboard-proj-alpha" || fail "alpha worker cmd lacks its orchestrator name"
[[ "$CB" == *"peer roster is: dashboard-proj-beta."* ]] && pass "beta worker is told dashboard-proj-beta" || fail "beta worker cmd lacks its orchestrator name"
[[ "$CA" != *"dashboard-proj-beta"* ]] && pass "alpha worker is not told beta's name" || fail "alpha worker cmd names beta"
CN="$(_build_launch_cmd lbl "$WORK" sonnet "" "$WORK/in" "$WORK/out")"
[[ "$CN" != *"--append-system-prompt '"* ]] && pass "no orch name -> no extra prompt flag" || fail "extra prompt flag without a name"

# Static wiring.
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
grep -qE -- '--name \$ORCH_NAME ' "$LAUNCHER" && pass "launcher passes --name \$ORCH_NAME" || fail "launcher still uses a fixed --name"
grep -qE -- '--name dashboard( |")' "$LAUNCHER" && fail "launcher still has --name dashboard" || pass "launcher has no bare --name dashboard"
grep -q 'session_state_write "dashboard"' "$LAUNCHER" && pass "state-store row id dashboard unchanged" || fail "state-store row id changed"
grep -qF "## Your Orchestrator's Name" "$REPO_DIR/orchestration/prompts/worker-dependency-awareness.md" && pass "worker prompt has the orchestrator-name section" || fail "worker prompt lacks the section"

[[ "$FAILS" -eq 0 ]] && { echo "All passed"; exit 0; } || { echo "$FAILS failed"; exit 1; }
