#!/bin/bash
# test/test-tab-close-helper.sh
# tmux_close_terminal_tab (tmux-session.sh, Phase 2 D-11): when iTerm2 is not running the
# helper makes no osascript call (a sweep started by the GUI app must not launch iTerm),
# prints not_found and returns 0; when iTerm2 runs it calls osascript exactly once, as
# before. osascript and ps are stubs first on PATH; nothing touches a real iTerm.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/tch.XXXXXX)" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
STUB="$SCRATCH/stub"; mkdir -p "$STUB"
OSA_LOG="$SCRATCH/osa.log"; OSA_STDIN="$SCRATCH/osa.stdin"
cat >"$STUB/osascript" <<STUBOSA
#!/bin/bash
echo "call \$*" >>"$OSA_LOG"
cat >>"$OSA_STDIN"
echo closed
STUBOSA
# stub ps: iTerm2 shown or hidden per $SCRATCH/ps.mode
cat >"$STUB/ps" <<STUBPS
#!/bin/bash
if [[ "\$(cat "$SCRATCH/ps.mode")" == running ]]; then echo /Applications/iTerm.app/Contents/MacOS/iTerm2; fi
echo /usr/libexec/launchd
STUBPS
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# ---- iTerm not running --------------------------------------------------------
echo hidden >"$SCRATCH/ps.mode"; : >"$OSA_LOG"; : >"$OSA_STDIN"
out="$(tmux_close_terminal_tab "w0t0p0:SESSION-ID-1")"; rc=$?
if [[ $rc -eq 0 && ! -s "$OSA_LOG" && "$out" == "not_found" ]]; then
    pass "iTerm not running: no osascript call, prints not_found, returns 0"
else
    fail "iTerm not running: rc=$rc out='$out' osascript calls: $(cat "$OSA_LOG")"
fi

# ---- iTerm running --------------------------------------------------------------
echo running >"$SCRATCH/ps.mode"; : >"$OSA_LOG"; : >"$OSA_STDIN"
out="$(tmux_close_terminal_tab "w0t0p0:SESSION-ID-2")"; rc=$?
if [[ $rc -eq 0 && "$(wc -l <"$OSA_LOG" | tr -d ' ')" == 1 && "$out" == "closed" ]] \
    && grep -qF 'tell app "iTerm2"' "$OSA_STDIN" && grep -qF 'w0t0p0:SESSION-ID-2' "$OSA_STDIN"; then
    pass "iTerm running: exactly one osascript call with the iTerm2 script and the session id, stdout is the stub's"
else
    fail "iTerm running: rc=$rc out='$out' calls: $(cat "$OSA_LOG") stdin: $(head -c 200 "$OSA_STDIN")"
fi

if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS test(s) failed"
exit 1
