#!/bin/bash
# test/test-watchdog-kill.sh
# tmux_watchdog_kill (tmux-session.sh, Phase 2 D-04/D-15): what the iTerm watchdog runs
# when iTerm quits. It spares every project whose base session carries CLAUDE_GUI=1 and
# kills the rest; with no marked project it ends the tmux server as before.
# DESTRUCTIVE function: every tmux call here goes to a PRIVATE server (TMUX_TMPDIR in a
# scratch dir, exported before the first tmux call, TMUX unset), never the default one.
# HOME is a scratch directory for the launcher run in case (f).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
command -v perl >/dev/null || { echo "SKIP: perl not installed"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/wdk.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$SCRATCH/stub"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# Safety: the default server must never be reachable from here.
[[ "$TMUX_TMPDIR" == /tmp/wdk.* ]] || { echo "ABORT: TMUX_TMPDIR is not the private scratch dir"; exit 1; }

# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

sessions() { T ls -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
alive() { T has-session -t "=$1" 2>/dev/null; }
reset_all() {
    T kill-server 2>/dev/null
    while T ls &>/dev/null; do sleep 0.05; done
}
wait_server_gone() { # the server ends asynchronously after kill-server
    local i
    for ((i = 0; i < 100; i++)); do T ls &>/dev/null || return 0; sleep 0.05; done
    return 1
}
mk() { T new-session -d -s "$1" "${@:2}" 'sleep 300'; } # name [more new-session flags]
mk_client() { T new-session -d -t "$1" -s "$2"; } # base client-name (grouped session)
mark() { T set-environment -t "=$1" CLAUDE_GUI 1; }

# Everything below calls the function; before it exists this fails right here.
if ! declare -F tmux_watchdog_kill >/dev/null; then
    fail "tmux_watchdog_kill is not defined"
    echo "$FAILS test(s) failed"
    exit 1
fi

# ---- (a) marked project M, unmarked project U, unmarked lone session -------
reset_all
mk mproj; mk_client mproj mproj-a; mk_client mproj mproj-b; mark mproj
mk uproj; mk_client uproj uproj-a
mk lone
tmux_watchdog_kill; rc=$?
if [[ $rc -eq 0 ]] && alive mproj && alive mproj-a && alive mproj-b \
    && ! alive uproj && ! alive uproj-a && ! alive lone && T ls &>/dev/null; then
    pass "(a) the marked group's 3 sessions survive, the unmarked group and the lone session go, the server answers"
else
    fail "(a) rc=$rc sessions: $(sessions)"
fi

# ---- (b) unmarked projects only: the server ends ---------------------------
reset_all
mk uproj; mk_client uproj uproj-a; mk lone
tmux_watchdog_kill; rc=$?
if [[ $rc -eq 0 ]] && wait_server_gone; then
    pass "(b) with no marked project the tmux server ends"
else
    fail "(b) rc=$rc, server still answers: $(sessions)"
fi

# ---- (c) prefix siblings: marked "proj" with a client, unmarked "proj-2" ----
reset_all
mk proj; mk_client proj proj-a; mark proj
mk proj-2
tmux_watchdog_kill; rc=$?
if [[ $rc -eq 0 ]] && alive proj && alive proj-a && ! alive proj-2; then
    pass "(c) a marked project and its client survive, the unmarked prefix sibling goes"
else
    fail "(c) rc=$rc sessions: $(sessions)"
fi

# ---- (d) the marker is read at call time, not when the library loads --------
reset_all
mk late; mk other
# the library was sourced above, before this base was marked
mark late
tmux_watchdog_kill; rc=$?
if [[ $rc -eq 0 ]] && alive late && ! alive other; then
    pass "(d) a base marked after the library loaded is spared"
else
    fail "(d) rc=$rc sessions: $(sessions)"
fi

# ---- (e) no server running: quiet, status 0 --------------------------------
reset_all
out="$(tmux_watchdog_kill 2>&1)"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then pass "(e) no server: returns 0 and prints nothing"; else fail "(e) rc=$rc out='$out'"; fi

# ---- (g) a marked group whose base session is gone counts as unmarked -------
reset_all
mk gbase; mk_client gbase gbase-a; mark gbase
mk keep; mark keep
T kill-session -t "=gbase"
tmux_watchdog_kill; rc=$?
if [[ $rc -eq 0 ]] && alive keep && ! alive gbase-a; then
    pass "(g) a group whose base is gone counts as unmarked"
else
    fail "(g) rc=$rc sessions: $(sessions)"
fi

# ---- (h) R6: a marker that appears between the scan and the kill spares the server
# A stub tmux on PATH wraps the real one: after the first show-environment (the scan reads it unmarked) it marks the base,
# so the first scan sees no marked base and the re-check before kill-server sees one.
reset_all
mk racy
STUBDIR="$SCRATCH/racystub"; mkdir -p "$STUBDIR"
cat >"$STUBDIR/tmux" <<STUBTMUX
#!/bin/bash
"$REAL_TMUX" "\$@"; rc=\$?
if [[ "\${1-}" == show-environment && ! -e "$SCRATCH/racy.done" ]]; then
    touch "$SCRATCH/racy.done"
    "$REAL_TMUX" set-environment -t "=racy" CLAUDE_GUI 1
fi
exit \$rc
STUBTMUX
chmod +x "$STUBDIR/tmux"
rm -f "$SCRATCH/racy.done"
OLDPATH="$PATH"; PATH="$STUBDIR:$PATH"
tmux_watchdog_kill; rc=$?
PATH="$OLDPATH"
if [[ $rc -eq 0 ]] && alive racy; then
    pass "(h) R6: a base marked just before kill-server is re-checked and the server is kept"
else
    fail "(h) rc=$rc sessions: $(sessions)"
fi

# ---- (f) AC11: an iTerm-started session reused by the GUI launch survives ---
STUB="$SCRATCH/stub"
for s in claude lean-ctx headroom repowire; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
for s in osascript nohup pgrep; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"
ENVFILE="$SCRATCH/app.env"
printf 'PATH=%s\nTERM=dumb\nHOME=%s\n' "$TOOLPATH" "$HOME" >"$ENVFILE"

reset_all
REPO="$SCRATCH/proj-reuse"
mkdir -p "$REPO"
( cd "$REPO" && command git init -q 2>/dev/null && command git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
"$REPO_DIR/orchestration/init/init-state-store.sh" "$REPO" >/dev/null 2>&1
RBASE="$(tmux_base_session_name "$REPO")"
T new-session -d -s "$RBASE" -n dashboard 'sleep 300'
RC=0
timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" --gui-folder "$REPO" --env-file "$ENVFILE" \
    </dev/null >"$SCRATCH/out" 2>"$SCRATCH/err" || RC=$?
mk other-project
if [[ $RC -ne 3 ]]; then
    fail "(f) the launch did not reuse the session: rc=$RC stderr: $(head -c 200 "$SCRATCH/err")"
else
    tmux_watchdog_kill
    if alive "$RBASE" && ! alive other-project; then
        pass "(f) AC11: the reused iTerm-started session survives, the other project goes"
    else
        fail "(f) sessions: $(sessions)"
    fi
fi

if [[ $FAILS -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS test(s) failed"
exit 1
