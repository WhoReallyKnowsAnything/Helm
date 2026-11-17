#!/bin/bash
# test/test-sweep-stderr.sh
# Phase 4 (SWP-01): --blocked-sweep logs any stderr; a clean run logs nothing.
# Phase 6 removed the pane loop and with it the only grep a forced failure
# could reach, so only the clean-run cases remain. Runs against a throwaway
# copy of orchestration/ with a stub tmux on PATH, so no real tmux is touched.

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
LOG="$TMP/sweep-stderr.log"
DISPATCH="$TMP/orchestration/lib/dispatch-task.sh"

# Fixture project: its own git repo + state db, so the (non-quiet, state-writing)
# sweep never reads or writes the live repo's db, gate-holds or workers. The
# private TMUX_TMPDIR keeps a stray real tmux call off the default server.
FIXTURE="$TMP/proj"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q . || { echo "FAIL: could not create fixture repo" >&2; exit 1; }
bash "$REPO_ROOT/orchestration/init/init-state-store.sh" "$FIXTURE" >/dev/null \
    || { echo "FAIL: could not init fixture state db" >&2; exit 1; }
TMUX_TMPDIR="$(mktemp -d)"
if [ -z "$TMUX_TMPDIR" ] || [ ! -d "$TMUX_TMPDIR" ]; then
    echo "FAIL: could not create a private tmux dir; refusing to run" >&2
    exit 1
fi
export TMUX_TMPDIR ORCH_PROJECT_ROOT="$FIXTURE"
unset TMUX TMUX_PANE SWEEP_QUIET
trap 'rm -rf "$TMP" "$TMUX_TMPDIR"' EXIT

cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
case "$1" in
    list-windows)
        if [[ "$*" == *window_index* ]]; then echo "1:agent-a"; else echo "agent-a"; fi ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

run_sweep() { # $1 = bin dir to prepend; remaining env passed by caller
    PATH="$1:$PATH" SWEEP_STDERR_LOG="$LOG" bash "$DISPATCH" --blocked-sweep
}

echo "test-sweep-stderr"

# (b) clean run: log absent or empty
rm -f "$LOG"
out_clean="$(run_sweep "$BIN" 2>"$TMP/clean.err")"; rc_clean=$?
if [[ ! -s "$LOG" ]]; then pass "(b) clean run leaves log absent/empty"; else fail "(b) clean run wrote: $(cat "$LOG")"; fi
[[ "$rc_clean" -eq 0 ]] && pass "(b) clean run exits 0" || fail "(b) clean run exit $rc_clean"
[[ ! -s "$TMP/clean.err" ]] && pass "(b) clean run emits no stderr" || fail "(b) clean stderr: $(cat "$TMP/clean.err")"

# stdout and exit code unchanged by the capture (compare against clean run shape)
[[ -z "$out_clean" && "$rc_clean" -eq 0 ]] && pass "(a) clean stdout empty, exit 0 baseline" || fail "baseline mismatch"

echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
