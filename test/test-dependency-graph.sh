#!/bin/bash
# test/test-dependency-graph.sh
# Exercises session_state_add_dependency / list_pending_dependents /
# mark_dependency_notified / cycle-refusal / death-teardown against the real
# .claude/session-state.db, using disposable test-dep-* fixture rows.
# Plain bash, no framework. Safe to re-run: cleans up its own fixtures.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/session-state.sh
source "$SCRIPT_DIR/../orchestration/lib/session-state.sh"

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

cleanup() {
    [ -n "${TMP_MAIN:-}" ] && rm -rf "$TMP_MAIN"
    local db_path
    db_path=$(session_state_db_path) || return 0
    sqlite3 "$db_path" "DELETE FROM dependencies WHERE dependent_agent_id LIKE 'test-dep-%' OR upstream_agent_id LIKE 'test-dep-%';" 2>/dev/null
    sqlite3 "$db_path" "DELETE FROM sessions WHERE agent_id LIKE 'test-dep-%';" 2>/dev/null
}
trap cleanup EXIT

DB_PATH=$(session_state_db_path) || { echo "FAIL: could not resolve db_path"; exit 1; }
# A fresh checkout (CI) has no .claude/session-state.db; the init script is idempotent.
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$SCRIPT_DIR/.." >/dev/null 2>&1

# Seed fixture sessions
session_state_write "test-dep-a" "/tmp/test-dep-a-worktree" "running" >/dev/null
session_state_write "test-dep-b" "/tmp/test-dep-b-worktree" "running" >/dev/null
session_state_write "test-dep-c" "/tmp/test-dep-c-worktree" "running" >/dev/null

# 1. add_dependency succeeds, row exists
if session_state_add_dependency "test-dep-a" "test-dep-b" "some/artifact.txt" >/dev/null; then
    ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM dependencies WHERE dependent_agent_id='test-dep-a' AND upstream_agent_id='test-dep-b';")
    if [ "$ROW_COUNT" = "1" ]; then
        pass "add_dependency test-dep-a -> test-dep-b inserts one row"
    else
        fail "add_dependency test-dep-a -> test-dep-b did not insert exactly one row (got $ROW_COUNT)"
    fi
else
    fail "add_dependency test-dep-a -> test-dep-b returned non-zero"
fi

# 2. list_pending_dependents includes test-dep-a
PENDING=$(session_state_list_pending_dependents "test-dep-b")
if echo "$PENDING" | grep -q "test-dep-a"; then
    pass "list_pending_dependents test-dep-b includes test-dep-a"
else
    fail "list_pending_dependents test-dep-b did not include test-dep-a (got: $PENDING)"
fi

# 3. mark_dependency_notified sets notified_at
if session_state_mark_dependency_notified "test-dep-a" "test-dep-b"; then
    NOTIFIED_AT=$(sqlite3 "$DB_PATH" "SELECT notified_at FROM dependencies WHERE dependent_agent_id='test-dep-a' AND upstream_agent_id='test-dep-b';")
    if [ -n "$NOTIFIED_AT" ]; then
        pass "mark_dependency_notified sets notified_at"
    else
        fail "mark_dependency_notified did not set notified_at"
    fi
else
    fail "mark_dependency_notified returned non-zero"
fi

# 4. direct 2-cycle refused (reverse of step 1)
if session_state_add_dependency "test-dep-b" "test-dep-a" "cycle" >/dev/null 2>&1; then
    fail "add_dependency test-dep-b -> test-dep-a (direct 2-cycle) should have been refused"
else
    PAIR_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM dependencies WHERE (dependent_agent_id='test-dep-a' AND upstream_agent_id='test-dep-b') OR (dependent_agent_id='test-dep-b' AND upstream_agent_id='test-dep-a');")
    if [ "$PAIR_COUNT" = "1" ]; then
        pass "add_dependency test-dep-b -> test-dep-a (direct 2-cycle) refused, no second row added"
    else
        fail "add_dependency test-dep-b -> test-dep-a (direct 2-cycle) refused but row count is $PAIR_COUNT (expected 1)"
    fi
fi

# 5. self-dependency refused
if session_state_add_dependency "test-dep-c" "test-dep-c" "self" >/dev/null 2>&1; then
    fail "add_dependency test-dep-c -> test-dep-c (self-dependency) should have been refused"
else
    SELF_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM dependencies WHERE dependent_agent_id='test-dep-c' AND upstream_agent_id='test-dep-c';")
    if [ "$SELF_COUNT" = "0" ]; then
        pass "add_dependency test-dep-c -> test-dep-c (self-dependency) refused, no row added"
    else
        fail "add_dependency test-dep-c -> test-dep-c (self-dependency) refused but a row exists"
    fi
fi

# 6. death teardown removes outgoing edges
if session_state_update_status "test-dep-b" "dead" >/dev/null 2>&1; then
    REMAINING=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM dependencies WHERE upstream_agent_id='test-dep-b';")
    if [ "$REMAINING" = "0" ]; then
        pass "update_status test-dep-b dead tears down outgoing dependency edges"
    else
        fail "update_status test-dep-b dead left $REMAINING outgoing edge(s) behind"
    fi
else
    fail "update_status test-dep-b dead returned non-zero"
fi

# 6b. update_status running/blocked never resurrects a merged or dead row
for st in merged dead; do
    session_state_write "test-dep-c" "/tmp/test-dep-c-worktree" "$st" >/dev/null
    session_state_update_status "test-dep-c" "running" >/dev/null 2>&1
    session_state_update_status "test-dep-c" "blocked" >/dev/null 2>&1
    GOT=$(sqlite3 "$DB_PATH" "SELECT status FROM sessions WHERE agent_id='test-dep-c';")
    if [ "$GOT" = "$st" ]; then
        pass "update_status running/blocked leaves a $st row $st"
    else
        fail "update_status running/blocked flipped a $st row to $GOT"
    fi
done

# 6c. merged upstream keeps its dependency edges
session_state_write "test-dep-c" "/tmp/test-dep-c-worktree" "running" >/dev/null
session_state_add_dependency "test-dep-a" "test-dep-c" "merged/artifact.txt" >/dev/null 2>&1
session_state_update_status "test-dep-c" "merged" >/dev/null 2>&1
KEPT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM dependencies WHERE upstream_agent_id='test-dep-c';")
if [ "$KEPT" = "1" ]; then
    pass "update_status merged keeps outgoing dependency edges"
else
    fail "update_status merged left $KEPT edge(s) for test-dep-c (expected 1)"
fi

# --- disposable git fixture: never touches the real .claude/session-state.db ---
TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "test"
echo seed > "$TMP_MAIN/seed.txt"
git -C "$TMP_MAIN" add seed.txt
git -C "$TMP_MAIN" commit -qm "seed"
"$SCRIPT_DIR/../orchestration/init/init-state-store.sh" "$TMP_MAIN" >/dev/null 2>&1
sqlite3 "$TMP_MAIN/.claude/session-state.db" "INSERT INTO dependencies (dependent_agent_id, upstream_agent_id, artifact) VALUES ('test-dep-down','test-dep-demo','shared/schema.sql');" 2>/dev/null
git -C "$TMP_MAIN" worktree add -q -b session/test-dep-demo "$TMP_MAIN/.claude/worktrees/demo" >/dev/null 2>&1
DISPATCH="$SCRIPT_DIR/../orchestration/lib/dispatch-task.sh"

# 7. --pending-dependents run from inside a linked worktree reads the MAIN db
WT_ROWS=$(cd "$TMP_MAIN/.claude/worktrees/demo" && "$DISPATCH" --pending-dependents test-dep-demo 2>/dev/null)
if echo "$WT_ROWS" | grep -q 'test-dep-down|shared/schema.sql'; then
    pass "--pending-dependents inside a worktree reads the main repo's db"
else
    fail "--pending-dependents inside a worktree returned no seeded row (got: $WT_ROWS)"
fi

# 8. plain checkout: the relative ".git" shape still resolves to the repo root
PLAIN_DB=$(cd "$TMP_MAIN" && session_state_db_path)
if [ "$PLAIN_DB" = "$TMP_MAIN/.claude/session-state.db" ]; then
    pass "session_state_db_path resolves the relative .git shape in a plain checkout"
else
    fail "session_state_db_path in a plain checkout returned '$PLAIN_DB' (expected '$TMP_MAIN/.claude/session-state.db')"
fi

# 9. a worker reaches .claude/orchestrator-root even though .claude is absent
#    from its own checkout (P-2 idiom used by the plan 21-02 worker prompt)
echo "/orchestrator/root/marker" > "$TMP_MAIN/.claude/orchestrator-root"
ORCH_ROOT=$(cd "$TMP_MAIN/.claude/worktrees/demo" && cat "$(dirname "$(git rev-parse --git-common-dir)")/.claude/orchestrator-root" 2>/dev/null)
if [ "$ORCH_ROOT" = "/orchestrator/root/marker" ]; then
    pass "worker resolves orchestrator-root from inside its worktree"
else
    fail "worker could not resolve orchestrator-root from inside its worktree (got: '$ORCH_ROOT')"
fi

# 10. no empty state db is silently auto-created inside the worktree
if [ ! -e "$TMP_MAIN/.claude/worktrees/demo/.claude/session-state.db" ]; then
    pass "no stray session-state.db created inside the worktree"
else
    fail "a stray session-state.db was created inside the worktree"
fi

# --- --artifact-exists: probes the upstream's unmerged branch, not the checkout ---
# The subcommand resolves PROJECT_ROOT from ORCH_PROJECT_ROOT, so point that
# at the fixture for these cases.
WORKTREE_DEMO="$TMP_MAIN/.claude/worktrees/demo"
mkdir -p "$WORKTREE_DEMO/shared"
echo "schema" > "$WORKTREE_DEMO/shared/schema.sql"
git -C "$WORKTREE_DEMO" add shared/schema.sql
git -C "$WORKTREE_DEMO" commit -qm "add schema on the session branch only"
export ORCH_PROJECT_ROOT="$TMP_MAIN"

# 11. a file committed only on session/<upstream>, absent from the main checkout
if [ -e "$TMP_MAIN/shared/schema.sql" ]; then
    fail "fixture is wrong: shared/schema.sql leaked into the main checkout"
elif "$DISPATCH" --artifact-exists test-dep-demo "shared/schema.sql"; then
    pass "--artifact-exists finds a file committed only on session/<upstream>"
else
    fail "--artifact-exists missed a file committed only on session/<upstream>"
fi

# 12. the artifact names a branch
if "$DISPATCH" --artifact-exists test-dep-demo "session/test-dep-demo"; then
    pass "--artifact-exists resolves an artifact that names a branch"
else
    fail "--artifact-exists did not resolve an artifact that names a branch"
fi

# 13. an artifact that exists nowhere
if "$DISPATCH" --artifact-exists test-dep-demo "nowhere/absent.txt"; then
    fail "--artifact-exists returned 0 for an artifact that exists nowhere"
else
    pass "--artifact-exists returns non-zero for an artifact that exists nowhere"
fi

# 14. a freshly dispatched session branch (no commits ahead of base) is not an artifact
git -C "$TMP_MAIN" branch -q session/test-dep-fresh
if "$DISPATCH" --artifact-exists test-dep-fresh "session/test-dep-fresh"; then
    fail "--artifact-exists returned 0 for a session branch with no commits ahead of base"
else
    pass "--artifact-exists returns non-zero for a session branch with no commits ahead of base"
fi

# 15. the same branch once merged with a merge commit is satisfied
WORKTREE_MERGED="$TMP_MAIN/.claude/worktrees/merged"
git -C "$TMP_MAIN" worktree add -q -b session/test-dep-merged "$WORKTREE_MERGED" >/dev/null 2>&1
echo m > "$WORKTREE_MERGED/merged.txt"
git -C "$WORKTREE_MERGED" add merged.txt
git -C "$WORKTREE_MERGED" commit -qm "work on merged branch"
git -C "$TMP_MAIN" merge -q --no-ff -m "merge test-dep-merged" session/test-dep-merged >/dev/null 2>&1
if "$DISPATCH" --artifact-exists test-dep-merged "session/test-dep-merged"; then
    pass "--artifact-exists returns 0 for a merged session branch"
else
    fail "--artifact-exists returned non-zero for a merged session branch"
fi

# 16. a merge SHA still resolves
MERGE_SHA=$(git -C "$TMP_MAIN" rev-parse HEAD)
if "$DISPATCH" --artifact-exists test-dep-merged "$MERGE_SHA"; then
    pass "--artifact-exists returns 0 for a merge SHA"
else
    fail "--artifact-exists returned non-zero for a merge SHA"
fi

# --- read/write split: --pending-dependents never stamps notified_at ---
FIXTURE_DB="$TMP_MAIN/.claude/session-state.db"
DEP_NOTIFIED_SQL="SELECT ifnull(notified_at,'') FROM dependencies WHERE dependent_agent_id='test-dep-down' AND upstream_agent_id='test-dep-demo';"

# 14. the sweep in case 7 left notified_at NULL
if [ -z "$(sqlite3 "$FIXTURE_DB" "$DEP_NOTIFIED_SQL")" ]; then
    pass "--pending-dependents does not stamp notified_at"
else
    fail "--pending-dependents stamped notified_at"
fi

# 15. so a second sweep still returns the same row
WT_ROWS2=$(cd "$WORKTREE_DEMO" && "$DISPATCH" --pending-dependents test-dep-demo 2>/dev/null)
if echo "$WT_ROWS2" | grep -q 'test-dep-down|shared/schema.sql'; then
    pass "a second --pending-dependents sweep returns the same row"
else
    fail "a second --pending-dependents sweep lost the row (got: $WT_ROWS2)"
fi

# 16. only --mark-notified stamps it and drops it from the sweep
if (cd "$WORKTREE_DEMO" && "$DISPATCH" --mark-notified test-dep-down test-dep-demo); then
    NOTIFIED_AFTER=$(sqlite3 "$FIXTURE_DB" "$DEP_NOTIFIED_SQL")
    WT_ROWS3=$(cd "$WORKTREE_DEMO" && "$DISPATCH" --pending-dependents test-dep-demo 2>/dev/null)
    if [ -n "$NOTIFIED_AFTER" ] && ! echo "$WT_ROWS3" | grep -q 'test-dep-down'; then
        pass "--mark-notified stamps notified_at and drops the edge from the sweep"
    else
        fail "--mark-notified left notified_at='$NOTIFIED_AFTER' and sweep='$WT_ROWS3'"
    fi
else
    fail "--mark-notified returned non-zero"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
