#!/usr/bin/env bash
# Run every test/test-*.sh in its own bash process, each with a time limit.
# Skips the 4 live-Claude tests (test-real-claude-*.sh). Runs all tests even after a failure.
# Exit 1 when any test failed. A failed test prints the last 25 lines of its output. Usage: bash test/run-all.sh   (any working directory)
# Env: TEST_TIMEOUT seconds per test (default 120)
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMIT="${TEST_TIMEOUT:-120}"
# Some tests need a git checkout as the working directory.
cd "$DIR/.." || exit 2

# run_limited FILE: run the test with a time limit; exit 124 on timeout.
run_limited() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$LIMIT" bash "$1" >"$OUT" 2>&1
    return $?
  fi
  # macOS has no timeout: a background sleep watchdog kills the test.
  bash "$1" >"$OUT" 2>&1 &
  local pid=$!
  ( sleep "$LIMIT"; kill -TERM "$pid" 2>/dev/null ) &
  local dog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  [[ $rc -eq 143 ]] && rc=124
  return $rc
}

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
pass=0 fail=0
for f in "$DIR"/test-*.sh; do
  name="$(basename "$f")"
  case "$name" in
    test-real-claude-control.sh|test-real-claude-messaging.sh|test-real-claude-permission.sh|test-real-claude-worker.sh) continue ;;
  esac
  run_limited "$f"; rc=$?
  if [[ $rc -eq 0 ]]; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name (exit $rc)"; tail -n 25 "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); fi
done
echo "Total: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
