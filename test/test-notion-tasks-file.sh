#!/bin/bash
# test/test-notion-tasks-file.sh
# dispatch-task.sh --write-notion-tasks writes <main repo>/.claude/notion-tasks.json
# from task rows (stdin or a rows file path), also from a linked worktree, and
# leaves the existing file byte-identical on every failure (phase 3, D-01/D-02/D-05).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../orchestration/lib/dispatch-task.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Exit before the trap is set: bash 3.2 `cd ""` succeeds, so a failed mktemp would make the cleanup rm -rf the cwd.
TMP_ROOT="$(mktemp -d)" || exit 1
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)" || exit 1
REPO="$TMP_ROOT/scratch-repo"
WT="$TMP_ROOT/scratch-wt"
OUT="$REPO/.claude/notion-tasks.json"
cleanup() {
    chmod u+w "$REPO/.claude" 2>/dev/null
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b wt "$WT"

ROWS_A="$TMP_ROOT/rows-a.json"
cat > "$ROWS_A" <<'EOF'
[{"id":"409e013e-a8ed-810b-9948-ff9cfa64f59f","title":"Fix: the \"quoted\" and it's done","status":"Not started","priority":null,"tags":["Ready","GUI"],"url":"https://app.notion.com/p/x-409e013ea8ed810b9948ff9cfa64f59f","parent_id":null},
 {"id":"509e013e-a8ed-810b-9948-ff9cfa64f59f","title":"Second task","status":"In progress","priority":"High","tags":[],"url":"https://app.notion.com/p/y-509e013ea8ed810b9948ff9cfa64f59f","parent_id":"409e013e-a8ed-810b-9948-ff9cfa64f59f"}]
EOF
KEYS='["id","title","status","priority","tags","url","parent_id"]'

# write_from dir [args...] < input: run the subcommand from dir with ORCH_PROJECT_ROOT unset.
write_from() {
    local dir="$1"; shift
    (cd "$dir" && env -u ORCH_PROJECT_ROOT bash "$DISPATCH" --write-notion-tasks "$@") 2>"$TMP_ROOT/err"
}
only_output_in_claude() { [ "$(ls -A "$1/.claude")" = "notion-tasks.json" ]; }

# (a) worktree, stdin, ORCH_PROJECT_ROOT unset
write_from "$WT" < "$ROWS_A"
check "(a) exits 0" "[ $? -eq 0 ]"
check "(a) writes the main repo file" "[ -f '$OUT' ]"
check "(a) no file under the worktree" "[ ! -e '$WT/.claude/notion-tasks.json' ]"
check "(a) schema is 1" "jq -e '.schema == 1' '$OUT' >/dev/null"
check "(a) project is the repo folder name" "jq -e --arg p scratch-repo '.project == \$p' '$OUT' >/dev/null"
check "(a) generated_at is UTC" "jq -r .generated_at '$OUT' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"
check "(a) 2 tasks with all 7 keys" "jq -e --argjson k '$KEYS' '(.tasks | length == 2) and all(.tasks[]; (\$k - keys) == [])' '$OUT' >/dev/null"
check "(a) titles identical to input" "jq -e --slurpfile in '$ROWS_A' '[.tasks[].title] == [\$in[0][].title]' '$OUT' >/dev/null"
check "(a) no temp file left in .claude" "only_output_in_claude '$REPO'"

# (b) ORCH_PROJECT_ROOT set, unrelated cwd
OTHER="$TMP_ROOT/other-project"; mkdir -p "$OTHER"
(cd "$TMP_ROOT" && ORCH_PROJECT_ROOT="$OTHER" bash "$DISPATCH" --write-notion-tasks < "$ROWS_A") 2>/dev/null
check "(b) exits 0" "[ $? -eq 0 ]"
check "(b) writes under ORCH_PROJECT_ROOT" "jq -e '.project == \"other-project\" and (.tasks | length == 2)' '$OTHER/.claude/notion-tasks.json' >/dev/null"
check "(b) no temp file left in .claude" "only_output_in_claude '$OTHER'"

# (c) empty row list
printf '[]' | write_from "$REPO"
check "(c) exits 0" "[ $? -eq 0 ]"
check "(c) tasks is []" "jq -e '.tasks == []' '$OUT' >/dev/null"

# Failure cases start from an existing file and must leave it byte-identical.
write_from "$REPO" < "$ROWS_A"
SNAP="$TMP_ROOT/snapshot.json"; cp "$OUT" "$SNAP"
expect_refused() {
    local name="$1" rc="$2"
    check "$name exits non-zero" "[ $rc -ne 0 ]"
    check "$name warns on stderr" "[ -s '$TMP_ROOT/err' ]"
    check "$name leaves the file byte-identical" "cmp -s '$SNAP' '$OUT'"
}

# (d) malformed JSON
printf '[{"id":' | write_from "$REPO"; expect_refused "(d) malformed" $?
# (e) empty stdin
write_from "$REPO" < /dev/null; expect_refused "(e) empty stdin" $?

# (f) no jq on PATH (/usr/bin/jq exists, so build a PATH without it)
STUB="$TMP_ROOT/stub-bin"; mkdir -p "$STUB"
for c in git dirname basename cat mktemp mv rm mkdir date env; do ln -s "$(command -v "$c")" "$STUB/$c"; done
check "(f) jq is absent from the stub PATH" "! (PATH='$STUB'; command -v jq >/dev/null 2>&1)"
(cd "$REPO" && PATH="$STUB" /bin/bash "$DISPATCH" --write-notion-tasks < "$ROWS_A") 2>"$TMP_ROOT/err"
expect_refused "(f) no jq" $?

# (g) read-only .claude
chmod a-w "$REPO/.claude"
write_from "$REPO" < "$ROWS_A"; expect_refused "(g) read-only .claude" $?
chmod u+w "$REPO/.claude"

# (h) rows passed by file path, outside .claude; the title would trip the git gate in a command line
ROWS_H="$TMP_ROOT/.notion-tasks-rows.json"
printf '[{"id":"a","title":"Fix git push verification","status":"Not started","priority":null,"tags":[],"url":"u","parent_id":null}]' > "$ROWS_H"
write_from "$REPO" "$ROWS_H" < /dev/null
check "(h) exits 0" "[ $? -eq 0 ]"
check "(h) title identical to input" "jq -e '.tasks[0].title == \"Fix git push verification\"' '$OUT' >/dev/null"
check "(h) rows file removed" "[ ! -e '$ROWS_H' ]"
check "(h) no temp file left in .claude" "only_output_in_claude '$REPO'"

# (i) rows file with a row missing a key
cp "$OUT" "$SNAP"
printf '[{"id":"a","title":"t","status":"Not started","priority":null,"tags":[],"url":"u"}]' > "$ROWS_H"
write_from "$REPO" "$ROWS_H" < /dev/null; expect_refused "(i) missing key" $?
check "(i) rows file removed" "[ ! -e '$ROWS_H' ]"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
