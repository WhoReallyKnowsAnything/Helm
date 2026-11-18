#!/bin/bash
# test/test-tmux-server-coalition.sh
# macOS only. A tmux server that tmux_ensure_base_session starts (env-file form,
# the --gui-folder / --gui-root path) must not share the caller's jetsam
# coalition: the Dock's "Stop running in background" and a force quit kill the
# app's whole coalition, and with it every session. Also checks that no launchd
# job or temp folder is left behind. Runs on a PRIVATE tmux server (TMUX_TMPDIR
# in a scratch dir), never the default one.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

[[ "$(uname)" == Darwin ]] || { echo "SKIP: not macOS"; exit 0; }
command -v tmux &>/dev/null || { echo "SKIP: tmux not installed"; exit 0; }
command -v cc &>/dev/null || { echo "SKIP: no C compiler for the coalition probe"; exit 0; }
/bin/launchctl print "gui/$UID" &>/dev/null || { echo "SKIP: no gui/$UID launchd domain"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/tsc.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR"
unset TMUX TMUX_PANE
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Probe: prints the jetsam coalition id of a pid (proc_pidinfo flavor 20,
# PROC_PIDCOALITIONINFO: two uint64 ids, resource then jetsam).
cat >"$SCRATCH/coal.c" <<'EOF'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(int argc, char **argv) {
    uint64_t c[5] = {0};
    if (argc < 2 || proc_pidinfo(atoi(argv[1]), 20, 0, c, sizeof c) != sizeof c) return 1;
    printf("%llu\n", (unsigned long long)c[1]);
    return 0;
}
EOF
cc -o "$SCRATCH/coal" "$SCRATCH/coal.c" 2>/dev/null || { echo "SKIP: coalition probe did not build"; exit 0; }

mine="$("$SCRATCH/coal" $$)"
job_labels() { /bin/launchctl list | grep -o 'io\.github\.whoreallyknowsanything\.helm\.tmux-client\.[0-9.]*' | sort; }

# check label: the session exists, its server outlives the job's bootout, is
# not in the caller's coalition, and nothing is left behind
check() {
    local server theirs
    server="$(tmux display -p -t =s1: '#{pid}' 2>/dev/null)"
    [[ -n "$server" ]] && pass "$1: the session exists" || fail "$1: no session s1"
    sleep 1 # the job is booted out by now: its server must still run
    if tmux has-session -t =s1 2>/dev/null && kill -0 "$server" 2>/dev/null; then
        pass "$1: server and session outlive the job"
    else
        fail "$1: server or session gone after the job ended"
    fi
    theirs="$("$SCRATCH/coal" "$server")"
    if [[ -n "$mine" && -n "$theirs" && "$mine" != "$theirs" ]]; then
        pass "$1: server is not in the caller's coalition ($theirs vs $mine)"
    else
        fail "$1: server shares the caller's coalition: caller='$mine' server='$theirs'"
    fi
    [[ "$(job_labels)" == "$before" ]] && pass "$1: no launchd job is left behind" || fail "$1: launchd jobs left: $(comm -13 <(echo "$before") <(job_labels))"
    [[ -z "$(ls -A "$TMPDIR")" ]] && pass "$1: no temp folder is left behind" || fail "$1: left under TMPDIR: $(ls -A "$TMPDIR")"
}

# ---- Case 1: plain env-file call --------------------------------------------
printf 'PATH=/usr/bin:/bin\nHOME=%s\nFILE_SENTINEL=x\n' "$HOME" >"$SCRATCH/app.env"
before="$(job_labels)"
tmux_ensure_base_session s1 win 'sleep 300' "$SCRATCH" "$SCRATCH/app.env" CLAUDE_GUI=1
rc=$?
[[ "$rc" -eq 0 ]] && pass "env-file form returns 0" || fail "env-file form: rc=$rc"
check "plain"
tmux show-environment -g 2>/dev/null | grep -q '^FILE_SENTINEL=x$' && pass "server global env holds the env file" || fail "server global env lacks FILE_SENTINEL"

# ---- Case 2: big command text and a slow tmux start --------------------------
# 200 KB of env file is more than a FIFO buffer holds, and the stub tmux waits
# 7 s before start-server reads it, past the 5 s start wait. The job has started,
# so the caller must not run the client a second time.
tmux kill-server 2>/dev/null; while tmux ls &>/dev/null; do sleep 0.05; done
REAL_TMUX="$(command -v tmux)"
mkdir -p "$SCRATCH/bin"
cat >"$SCRATCH/bin/tmux" <<STUB
#!/bin/bash
[[ "\$1" == start-server ]] && { echo start >>"$SCRATCH/starts"; /bin/sleep 7; }
exec "$REAL_TMUX" "\$@"
STUB
chmod +x "$SCRATCH/bin/tmux"
big="$(head -c 150000 /dev/zero | tr '\0' 'a')"
printf 'PATH=/usr/bin:/bin\nHOME=%s\nBIG=%s\n' "$HOME" "$big" >"$SCRATCH/app.env"
before="$(job_labels)"
# Set PATH around the call, not as a prefix: bash 3.2 (macOS /bin/bash) does not apply a prefix PATH to a function's command lookup.
OLD_PATH="$PATH"; PATH="$SCRATCH/bin:$PATH"
tmux_ensure_base_session s1 win 'sleep 300' "$SCRATCH" "$SCRATCH/app.env" CLAUDE_GUI=1
rc=$?
PATH="$OLD_PATH"
[[ "$rc" -eq 0 ]] && pass "slow start: returns 0" || fail "slow start: rc=$rc"
starts="$(wc -l <"$SCRATCH/starts" 2>/dev/null | tr -d ' ')"
[[ "$starts" == 1 ]] && pass "slow start: the client ran once" || fail "slow start: the client ran ${starts:-0} times"
check "slow start"
[[ "$(tmux show-environment -t =s1 BIG 2>/dev/null)" == "BIG=$big" ]] && pass "slow start: the big value arrived whole" || fail "slow start: the big value did not arrive whole"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
