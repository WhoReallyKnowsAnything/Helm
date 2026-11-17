#!/bin/bash
# test/test-headless-window.sh
# Headless window (phase 1, plan 1, task 3): the command printed by
# tmux_headless_cmd feeds claude from the inbox, and the window ends within 5
# seconds when claude is killed, leaving no tail on the inbox. Private tmux
# server only (-L via the t() wrapper); a stub claude on PATH; fixture dir.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

SCRATCH="$(mktemp -d /tmp/hwin.XXXXXX)"
SOCK="hwin-$$"
export ORCH_TMUX_SOCKET="$SOCK"
unset TMUX
t() { tmux -L "$SOCK" "$@"; }
cleanup() { t kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/s"
IN="$SCRATCH/s/it's inbox.jsonl"
OUT="$SCRATCH/s/out.jsonl"
: > "$IN"; : > "$OUT"
# Stub claude: records its pid, copies stdin lines to a file, stays alive.
cat > "$SCRATCH/bin/claude" <<EOF
#!/bin/bash
echo \$\$ > "$SCRATCH/claude.pid"
while IFS= read -r line; do echo "\$line" >> "$SCRATCH/received"; done
EOF
chmod +x "$SCRATCH/bin/claude"

# shellcheck disable=SC1090
source "$REPO_DIR/orchestration/lib/tmux-session.sh"
CMD="$(tmux_headless_cmd "$IN" "$OUT" "claude")"

t new-session -d -s base -n keep "sleep 600"
t new-window -t "=base:" -n w1 "PATH='$SCRATCH/bin':\$PATH; $CMD"

for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCRATCH/claude.pid" ] && break; sleep 0.3; done
echo '{"type":"user"}' >> "$IN"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$SCRATCH/received" ] && break; sleep 0.3; done
if [ "$(cat "$SCRATCH/received" 2>/dev/null)" = '{"type":"user"}' ]; then
    pass "the stub received the appended inbox line"
else
    fail "stub did not receive the line"
fi

kill "$(cat "$SCRATCH/claude.pid")" 2>/dev/null
GONE=0
for _ in $(seq 1 25); do
    t list-windows -t "=base" -F '#{window_name}' 2>/dev/null | grep -qx w1 || { GONE=1; break; }
    sleep 0.2
done
[ $GONE -eq 1 ] && pass "the window is absent within 5 seconds of the kill" || fail "window w1 still exists"

if ps -axo args= | grep '[t]ail' | grep -qF -- "$IN"; then
    fail "a tail on the inbox survived"
else
    pass "no tail on the inbox remains"
fi

echo "Passed: $PASS_COUNT Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
