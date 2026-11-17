#!/bin/bash
# test/test-literal-label.sh
# Window-existence checks must treat the label as a literal string, not a
# regex: label "[a]" must not match window "a", and a label with an unmatched
# bracket must not make grep print an error. tmux is stubbed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

FAILS=0
check() { # name, 0 = pass
    if [[ "$2" -eq 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi
}

# Stub: list-windows prints windows "a" and "b.c"; new-window succeeds.
tmux() {
    case "$1" in
        list-windows) printf '%s\n' "a" "b.c" ;;
        new-window) return 0 ;;
    esac
}

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

tmux_ensure_window base '[a]' 'true' 2>"$ERR"; rc=$?
check "tmux_ensure_window: '[a]' creates window, not 'already exists'" $((rc == 0 ? 0 : 1))

tmux_ensure_window base 'a[' 'true' 2>"$ERR"
check "tmux_ensure_window: 'a[' prints no stderr" $([[ ! -s "$ERR" ]] && echo 0 || echo 1)

exit $((FAILS > 0 ? 1 : 0))
