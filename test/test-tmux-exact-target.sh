#!/bin/bash
# test/test-tmux-exact-target.sh
# tmux resolves a bare -t target by prefix, so acting on "foo" could hit "foo-2".
# Every helper must use an exact (=) target. Runs against a real tmux server on a
# private socket, with sibling labels foo / foo-2 and sibling sessions base / ba.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v tmux &>/dev/null; then echo "SKIP: tmux not installed"; exit 0; fi

# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

SOCK="exact-target-test-$$"
tmux() { command tmux -L "$SOCK" "$@"; }
trap 'tmux kill-server 2>/dev/null' EXIT

FAILS=0
check() { # name, 0 = pass
    if [[ "$2" -eq 0 ]]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi
}
windows() { tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '; }
has_session() { tmux has-session -t "=$1" 2>/dev/null; }
reset() { tmux kill-server 2>/dev/null; while tmux ls &>/dev/null; do sleep 0.05; done; }

# --- teardown: only the exact window and grouped session go ---
reset
tmux new-session -d -s base -n foo-2 'sleep 300'
tmux new-session -d -s base-foo-2 -t '=base'
tmux_teardown_worker base foo
check "teardown: absent 'foo' leaves window 'foo-2'" $([[ "$(windows base)" == "foo-2 " ]] && echo 0 || echo 1)
check "teardown: absent 'foo' leaves session 'base-foo-2'" $(has_session base-foo-2 && echo 0 || echo 1)

reset
tmux new-session -d -s base -n foo 'sleep 300'
tmux new-window -t '=base:' -n foo-2 'sleep 300'
tmux new-session -d -s base-foo -t '=base'
tmux new-session -d -s base-foo-2 -t '=base'
tmux_teardown_worker base foo
check "teardown: kills window 'foo' only" $([[ "$(windows base)" == "foo-2 " ]] && echo 0 || echo 1)
check "teardown: kills session 'base-foo'" $(has_session base-foo && echo 1 || echo 0)
check "teardown: keeps session 'base-foo-2'" $(has_session base-foo-2 && echo 0 || echo 1)

# --- session name prefix: base "ba" must not resolve to session "base" ---
reset
tmux new-session -d -s base -n main 'sleep 300'
tmux_ensure_window ba x 'sleep 300' 2>/dev/null
check "tmux_ensure_window: session 'ba' does not add a window to 'base'" $([[ "$(windows base)" == "main " ]] && echo 0 || echo 1)
tmux_ensure_base_session ba first 'sleep 300'
check "tmux_ensure_base_session: 'ba' is created, not mistaken for 'base'" $(has_session ba && echo 0 || echo 1)

# --- window label prefix: label "foo" must not resolve to window "foo-2" ---
reset
tmux new-session -d -s base -n foo-2 'sleep 300'
tmux_ensure_window base foo 'sleep 300' 2>/dev/null
check "tmux_ensure_window: creates 'foo' beside 'foo-2'" $([[ "$(windows base)" == "foo foo-2 " ]] && echo 0 || echo 1)

# --- attach command: grouped session of the exact base, selecting the exact window ---
reset
tmux new-session -d -s base -n foo-2 'sleep 300'
tmux new-window -t '=base:' -n foo 'sleep 300'
tmux new-session -d -s ba -n other 'sleep 300'
cmd="$(tmux_client_attach_cmd base foo)"
cmd="${cmd/#*tmux /command tmux -L $SOCK }"   # route to the test server
cmd="${cmd/new-session -A/new-session -d -A}" # no tty here
eval "$cmd" 2>/dev/null
active="$(tmux display-message -p -t '=base-foo:' '#{window_name}' 2>/dev/null)"
check "attach cmd: grouped session 'base-foo' selects window 'foo'" $([[ "$active" == "foo" ]] && echo 0 || echo 1)
check "attach cmd: 'ba' not grouped into 'base'" $([[ "$(windows ba)" == "other " ]] && echo 0 || echo 1)

# --- attach command typed into zsh: a word starting with = must not EQUALS-expand ---
if command -v zsh &>/dev/null; then
    tmux new-window -t '=base:' -n bar 'sleep 300'
    cmd="$(tmux_client_attach_cmd base bar)"
    cmd="${cmd/#*tmux /command tmux -L $SOCK }"
    cmd="${cmd/new-session -A/new-session -d -A}"
    zsh_script="$(mktemp)"
    printf '%s\n' "$cmd" >"$zsh_script"
    zsh "$zsh_script" 2>/dev/null
    rm -f "$zsh_script"
    active="$(tmux display-message -p -t '=base-bar:' '#{window_name}' 2>/dev/null)"
    check "attach cmd (zsh): grouped session 'base-bar' selects window 'bar'" $([[ "$active" == "bar" ]] && echo 0 || echo 1)
fi

exit $((FAILS > 0 ? 1 : 0))
