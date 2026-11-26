#!/usr/bin/env bash
# Worker rules go to the system prompt (worker-rules.sh, dispatch-task.sh _build_launch_cmd).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude/rules/sub" "$T/proj/.claude"
printf 'global rule\n@IMP.md\n' > "$HOME/.claude/CLAUDE.md"
printf 'imported rule\n' > "$HOME/.claude/IMP.md"
printf 'b rule\n' > "$HOME/.claude/rules/sub/b.md"
printf 'a rule\n' > "$HOME/.claude/rules/a.md"
printf 'project rule\n' > "$T/proj/CLAUDE.md"
git -C "$T/proj" init -q
slug="$(printf '%s' "$T/proj" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$HOME/.claude/projects/$slug/memory"; printf -- '- memory line\n' > "$HOME/.claude/projects/$slug/memory/MEMORY.md"

# shellcheck source=/dev/null
. "$ROOT/orchestration/lib/worker-rules.sh"
f1="$(worker_rules_file "$T/proj" dashboard-x)"
txt="$(cat "$f1")"
ok "file lands in the project .claude dir" '[[ "$f1" == "$T/proj/.claude/worker-rules.md" ]]'
for s in "global rule" "imported rule" "a rule" "b rule" "project rule" "memory line" "dashboard-x"; do
    ok "text holds: $s" '[[ "$txt" == *"$s"* ]]'
done
ok "each source appears once" '[[ "$(grep -c "^imported rule$" "$f1")" == 1 ]]'
ok "rules sorted by path" '[[ "${txt%%a rule*}" != *"b rule"* ]]'
sum1="$(cksum < "$f1")"; f2="$(worker_rules_file "$T/proj" dashboard-x)"
ok "second build gives the same bytes" '[[ "$(cksum < "$f2")" == "$sum1" ]]'
ok "no temp file left behind" '[[ "$(ls "$T/proj/.claude" | wc -l | tr -d " ")" == 1 ]]'
ok "unwritable project dir fails (old launch path)" '! worker_rules_file "$T/proj/CLAUDE.md/x" x 2>/dev/null'

# Launch order: dispatch builds the command before the worktree exists, so the
# builder must find the project root without git -C "$session_dir".
# LAUNCH_SRC overrides the dispatch-task.sh under test.
_lc_src="${LAUNCH_SRC:-$ROOT/orchestration/lib/dispatch-task.sh}"
eval "$(sed -n '/^_sq_quote() {/,/^}/p;/^_build_launch_cmd() {/,/^}/p' "$_lc_src")"
tmux_headless_cmd() { printf '%s' "claude_cmd=$3"; }
cmd="$(PROJECT_ROOT="$T/proj" _build_launch_cmd lbl "$T/no-such-worktree" haiku "" "$T/in" "$T/out" "" dashboard-x 2>"$T/err")"
ok "missing worktree: launch has DISABLE_CLAUDE_MDS" '[[ "$cmd" == *CLAUDE_CODE_DISABLE_CLAUDE_MDS=1* ]]'
ok "missing worktree: launch reads the rules file" '[[ "$cmd" == *"worker-rules.md"* ]]'
cmd2="$(PROJECT_ROOT="$T/proj/CLAUDE.md/x" _build_launch_cmd lbl "$T/no-such-worktree" haiku "" "$T/in" "$T/out" "" dashboard-x 2>"$T/err")"
ok "failed rules build: old launch" '[[ "$cmd2" != *CLAUDE_CODE_DISABLE_CLAUDE_MDS* ]]'
ok "failed rules build: one stderr line" '[[ "$(wc -l < "$T/err" | tr -d " ")" == 1 ]]'

echo "Results: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
