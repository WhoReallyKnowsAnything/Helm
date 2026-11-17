#!/bin/bash
# test/test-sweep-all.sh
# --blocked-sweep-all discovers projects from tmux pane paths (worker panes
# inside .claude/worktrees/ map to their project root) and sweeps each project
# that has a session DB. Runs against a throwaway copy of orchestration/ with a
# stub tmux on PATH and fake git repos; only list-panes is answered.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -R "$REPO_ROOT/orchestration" "$TMP/orchestration"
BIN="$TMP/bin"
mkdir -p "$BIN"
TMUX_LOG="$TMP/tmux.log"
DISPATCH="$TMP/orchestration/lib/dispatch-task.sh"

for p in projA projB projC; do
    git init -q "$TMP/$p"
    mkdir -p "$TMP/$p/.claude"
done
for p in projA projB; do
    sqlite3 "$TMP/$p/.claude/session-state.db" "CREATE TABLE sessions (agent_id TEXT, worktree_path TEXT, task_title TEXT, pending_operation TEXT, updated_at TEXT, status TEXT);"
done
mkdir -p "$TMP/projB/.claude/worktrees/w1" "$TMP/notproj"

cat > "$BIN/tmux" <<EOF
#!/bin/bash
echo "\$*" >> "$TMUX_LOG"
case "\$1" in
    list-panes)
        printf '%s\n' "$TMP/projA" "$TMP/projB/.claude/worktrees/w1" "$TMP/projC" "$TMP/notproj" "$TMP/projA" ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

echo "test-sweep-all"

rc=0
( cd "$TMP/notproj" && PATH="$BIN:$PATH" bash "$DISPATCH" --blocked-sweep-all >/dev/null 2>&1 ) || rc=$?

[[ "$rc" -eq 0 ]] && pass "exits 0" || fail "exit $rc"
# A swept project gets its gate-holds folder (gate_hold_dir creates it); no pane is read.
for p in projA projB; do
    [[ -d "$TMP/$p/.claude/gate-holds" ]] && pass "$p swept" || fail "$p not swept"
done
[[ -d "$TMP/projC/.claude/gate-holds" ]] && fail "projC (no session DB) was swept" || pass "projC (no session DB) skipped"
[[ -d "$TMP/notproj/.claude/gate-holds" ]] && fail "non-project path was swept" || pass "non-project path skipped"
grep -q '^capture-pane' "$TMUX_LOG" 2>/dev/null && fail "sweep read a pane" || pass "no pane read"

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
