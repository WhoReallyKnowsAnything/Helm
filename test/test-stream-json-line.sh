#!/bin/bash
# test/test-stream-json-line.sh
# stream_json_user_line (phase 1, plan 2, task 1). Offline checks always run.
# With ORCH_REAL_CLAUDE=1 the helper's line is also fed to a real claude -p on a
# PRIVATE tmux socket (haiku, scratch inbox) and a `result` event must arrive.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../orchestration/lib/stream-json.sh
source "$REPO_DIR/orchestration/lib/stream-json.sh"
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/sjl.XXXXXX)" || exit 1
SOCK="sjl-$$"
t() { tmux -L "$SOCK" "$@"; }
cleanup() { t kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
unset TMUX

TEXT=$'say "hi" \\ back\nnext\tline'
LINE="$(stream_json_user_line "$TEXT")"
if printf '%s\n' "$LINE" | jq -e '.type == "user" and .message.role == "user"' >/dev/null; then
    pass "output parses and has type user, role user"
else
    fail "output is not a valid user line: $LINE"
fi
if [ "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" = 1 ]; then pass "exactly one line"; else fail "not one line"; fi
if [ "$(printf '%s' "$LINE" | jq -r .message.content)" = "$TEXT" ]; then
    pass "quote, backslash, newline and tab round-trip"
else
    fail "text did not round-trip"
fi
if stream_json_user_line "" >/dev/null 2>"$SCRATCH/err"; then
    fail "empty text exited 0"
else
    grep -q '^Error:' "$SCRATCH/err" && pass "empty text exits non-zero with an Error: line" || fail "no Error: line for empty text"
fi

if [ "${ORCH_REAL_CLAUDE:-}" = 1 ]; then
    command -v claude >/dev/null && command -v tmux >/dev/null || { fail "claude or tmux missing"; exit 1; }
    IN="$SCRATCH/inbox.jsonl"; OUT="$SCRATCH/out.jsonl"; : > "$IN"; : > "$OUT"
    mkdir -p "$SCRATCH/work"
    stream_json_user_line "Reply with the single word OK." >> "$IN"
    t new-session -d -s sjl -n w "cd '$SCRATCH/work' && tail -n +1 -f '$IN' | claude -p --input-format stream-json --output-format stream-json --verbose --model haiku >> '$OUT'"
    got=0
    for _ in $(seq 1 120); do
        if jq -e 'select(.type == "result")' "$OUT" >/dev/null 2>&1; then got=1; break; fi
        sleep 0.5
    done
    [ $got -eq 1 ] && pass "real claude answered the helper line with a result event" || fail "no result event within 60s"
else
    echo "SKIP: real-claude check (set ORCH_REAL_CLAUDE=1)"
fi

[ $FAILS -eq 0 ]
