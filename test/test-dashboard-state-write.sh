#!/bin/bash
# test/test-dashboard-state-write.sh
# Regression: the dashboard session record must be written when launch-claude.sh
# runs from a non-git cwd (e.g. ~), and init-state-store.sh must stay silent on
# stdout. session_state_db_path resolves the db from the caller's cwd, so the
# test runs the real dashboard-write line from launch-claude.sh, from a non-git cwd.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARGET="$TMP/target"
NON_GIT="$TMP/home"
mkdir -p "$TARGET" "$NON_GIT"
git -C "$TARGET" init -q

source "$REPO_ROOT/orchestration/lib/session-state.sh"

echo "test-dashboard-state-write"

# init creates the db; its stdout is checked in (b), so discard it here
"$REPO_ROOT/orchestration/init/init-state-store.sh" "$TARGET" >/dev/null 2>&1

# (a) run launch-claude.sh's dashboard write line, from a non-git cwd
WRITE_LINE="$(grep -m1 'session_state_write "dashboard"' "$REPO_ROOT/orchestration/launch-claude.sh")"
WRITE_CMD="$(printf '%s' "$WRITE_LINE" | sed -e 's/^ *if ! //' -e 's/; then$//')"
err="$(cd "$NON_GIT" && TARGET_DIR="$TARGET" eval "$WRITE_CMD" 2>&1)"; rc=$?
[[ -n "$WRITE_CMD" && "$rc" -eq 0 ]] && pass "(a) dashboard write from non-git cwd succeeds" || fail "(a) write failed rc=$rc cmd=[$WRITE_CMD]: $err"

# (b) init-state-store.sh prints nothing on stdout on success
out="$("$REPO_ROOT/orchestration/init/init-state-store.sh" "$TARGET" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "(b) init exits 0" || fail "(b) init exit $rc"
[[ -z "$out" ]] && pass "(b) init prints nothing to stdout" || fail "(b) init stdout: $out"

# (c) run promote-session.sh's dashboard write line (subshell cd'd to TARGET_DIR), from a non-git cwd
PROMOTE_LINE="$(grep -m1 'session_state_write "dashboard"' "$REPO_ROOT/orchestration/promote-session.sh")"
PROMOTE_CMD="$(printf '%s' "$PROMOTE_LINE" | sed -e 's/^ *if //' -e 's/; then$//')"
err="$(cd "$NON_GIT" && TARGET_DIR="$TARGET" eval "$PROMOTE_CMD" 2>&1)"; rc=$?
[[ -n "$PROMOTE_CMD" && "$rc" -eq 0 ]] && pass "(c) promote-session dashboard write from non-git cwd succeeds" || fail "(c) promote write failed rc=$rc cmd=[$PROMOTE_CMD]: $err"

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
