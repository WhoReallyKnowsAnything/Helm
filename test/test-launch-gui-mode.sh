#!/bin/bash
# test/test-launch-gui-mode.sh
# launch-claude.sh --gui-folder <abs folder> --env-file <file> (Phase 2, D-16):
# the non-interactive start used by the GUI app. Runs the REAL launcher against a
# PRIVATE tmux server (TMUX_TMPDIR in a scratch dir, exported before any tmux
# call, never the default server) with stub claude/lean-ctx/headroom/repowire/
# osascript/pgrep/nohup first on PATH. The launcher runs with stdin from
# /dev/null and no controlling terminal (setsid), under a timeout.
# HOME is a scratch directory for every launcher run, so nothing is written
# under the real home.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
command -v perl >/dev/null || { echo "SKIP: perl not installed"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/lgm.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
STUB="$SCRATCH/stub"
CLAUDELOG="$SCRATCH/claudelog"
CALLS="$SCRATCH/calls.log"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$STUB" "$CLAUDELOG"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT
export LAUNCHER_ONLY_SENTINEL="launcher-only-$$-secret"
T() { "$REAL_TMUX" "$@"; }
cleanup() { touch "$SCRATCH/stop"; T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- stubs -----------------------------------------------------------------
cat >"$STUB/claude" <<STUBCLAUDE
#!/bin/bash
if [[ "\${1-}" == update ]]; then exit 0; fi
echo \$\$ >"$SCRATCH/claude.pid"
printf '%s\0' "\$@" >"$CLAUDELOG/.args.\$\$" && mv "$CLAUDELOG/.args.\$\$" "$CLAUDELOG/args.\$\$"
env >"$CLAUDELOG/.env.\$\$" && mv "$CLAUDELOG/.env.\$\$" "$CLAUDELOG/env.\$\$"
sleep 300
STUBCLAUDE
for s in lean-ctx headroom repowire; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
for s in osascript nohup; do # log the call; nohup never runs its command
    printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 0\n' "$s" "$CALLS" >"$STUB/$s"
done
printf '#!/bin/bash\necho "pgrep $*" >>"%s"\nexit "$(cat "%s/pgrep.rc" 2>/dev/null || echo 0)"\n' "$CALLS" "$SCRATCH" >"$STUB/pgrep"
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# PATH written into env files: stubs first, then the directories the launcher needs.
TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"

# ---- helpers ---------------------------------------------------------------
mkgit() { # dir
    mkdir -p "$1"
    ( cd "$1" && command git init -q 2>/dev/null && command git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
}
ENVFILE="$SCRATCH/app.env"
FILE_SENTINEL="file-sentinel-$$-secret"
write_envfile() { # [PATH value]
    {
        printf 'PATH=%s\n' "${1:-$TOOLPATH}"
        printf 'FILE_SENTINEL=%s\n' "$FILE_SENTINEL"
        printf 'TERM=dumb\nCLAUDE_IN_TMUX=0\nHOME=%s\n' "$HOME"
    } >"$ENVFILE"
}
RC=0
run_launcher() { # args...
    RC=0
    timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" "$@" </dev/null >"$OUT" 2>"$ERR" || RC=$?
}
last_line() { tail -n 1 "$OUT"; }
sessions() { T ls -F '#{session_name}' 2>/dev/null; }
reset_all() {
    T kill-server 2>/dev/null
    while T ls &>/dev/null; do sleep 0.05; done
    rm -f "$CLAUDELOG"/* "$CALLS" "$SCRATCH/pgrep.rc"
    : >"$CALLS"
}
wait_claude() { # wait for the stub claude to have written its environment
    local i
    for ((i = 0; i < 150; i++)); do
        compgen -G "$CLAUDELOG/env.*" >/dev/null && return 0
        sleep 0.1
    done
    return 1
}
claude_env() { cat "$CLAUDELOG"/env.* 2>/dev/null | head -n 400; }
claude_has_env() { claude_env | grep -qxF -- "$1"; }

# the runner has no controlling terminal
if perl -MPOSIX -e 'POSIX::setsid(); exit(open(my $t, "<", "/dev/tty") ? 1 : 0)'; then
    pass "runner has no controlling terminal"
else
    fail "runner still has a controlling terminal"
fi

FIX="$SCRATCH/proj-alpha"
mkgit "$FIX"
BASE="$(tmux_base_session_name "$FIX")"
FOLDER_REAL="$(cd "$FIX" && pwd -P)"

# ---- AC1 + AC8: a fresh start ---------------------------------------------
reset_all
write_envfile
: >"$SCRATCH/ps.log"; rm -f "$SCRATCH/stop"
( while [[ ! -e "$SCRATCH/stop" ]]; do ps -wwAo args >>"$SCRATCH/ps.log"; sleep 0.03; done ) &
sampler=$!
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"
wait_claude
touch "$SCRATCH/stop"; wait "$sampler" 2>/dev/null; rm -f "$SCRATCH/stop"
if [[ "$RC" -eq 0 && "$(last_line)" == "$BASE" ]]; then pass "AC1: exit 0 and the base name is the last stdout line"; else fail "AC1: rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"; fi
if T has-session -t "=$BASE" 2>/dev/null; then pass "AC1: the session exists on the private server"; else fail "AC1: no session '$BASE'"; fi
[[ "$(T list-windows -t "=$BASE" -F '#{window_name}' 2>/dev/null | tr '\n' ' ')" == "dashboard " ]] && pass "AC1: one window, named dashboard" || fail "AC1: windows: $(T list-windows -t "=$BASE" -F '#{window_name}' 2>&1 | tr '\n' ' ')"
[[ "$(T list-panes -t "=$BASE:=dashboard" -F '#{pane_current_path}' 2>/dev/null | head -1)" == "$FOLDER_REAL" ]] && pass "AC1: the dashboard pane directory is the folder" || fail "AC1: pane path '$(T list-panes -t "=$BASE:=dashboard" -F '#{pane_current_path}' 2>&1 | head -1)'"
if ! grep -q '^pgrep\|^nohup\|^osascript' "$CALLS"; then pass "AC1: no watchdog start (pgrep, nohup) and no osascript call"; else fail "AC1: stub calls: $(cat "$CALLS" | tr '\n' '|')"; fi
if wait_claude; then
    ARGS="$(tr '\0' '\n' <"$(ls "$CLAUDELOG"/args.* | head -1)")"
    want=$'-p\n--input-format\nstream-json\n--output-format\nstream-json\n--verbose\n--include-partial-messages\n--replay-user-messages\n--name\ndashboard-proj-alpha\n--model\nopus[1m]\n--permission-prompt-tool\nstdio\n--append-system-prompt-file\n'"$REPO_DIR/orchestration/prompts/task-drafting-mode.md"
    ARGS="$(echo "$ARGS" | sed -E '/^--session-id$/{N;d;}')" # fresh launch pins a random session id (see test-launch-resume.sh)
    ARGS="$(echo "$ARGS" | sed -E '/^--settings$/{N;d;}')" # Session 1 /clear hook registration (see test-launch-resume.sh)
    [[ "$ARGS" == "$want" ]] && pass "AC1: claude gets the headless flags, --name dashboard-proj-alpha, the opus model, the drafting prompt file and no positional prompt" || fail "AC1: claude args: $(echo "$ARGS" | tr '\n' ' ')"
    claude_has_env 'CLAUDE_GUI=1' && ! claude_env | grep -q '^CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=' && pass "AC1: the dashboard process holds the marker and not the alternate-screen flag" || fail "AC1: markers missing from the claude environment"
    # the launcher's additions win over the file's TERM and CLAUDE_IN_TMUX
    if claude_has_env 'TERM=xterm-256color' && claude_has_env 'CLAUDE_IN_TMUX=1' && claude_has_env 'ANTHROPIC_BASE_URL=http://localhost:4444' && ! claude_env | grep -q '^TMUX='; then
        pass "launcher additions win: TERM, CLAUDE_IN_TMUX, ANTHROPIC_BASE_URL set and no TMUX"
    else
        fail "launcher additions: $(claude_env | grep -E '^(TERM|CLAUDE_IN_TMUX|ANTHROPIC_BASE_URL|TMUX)=' | tr '\n' ' ')"
    fi
    claude_has_env "FILE_SENTINEL=$FILE_SENTINEL" && pass "AC8: the env-file sentinel reaches the dashboard pane" || fail "AC8: sentinel missing from the dashboard pane"
    claude_env | grep -q '^LAUNCHER_ONLY_SENTINEL=' && fail "AC8: a launcher-only variable reached the dashboard pane" || pass "AC8: no launcher-only variable in the dashboard pane"
else
    fail "AC1: the stub claude never started"
fi
cat >"$SCRATCH/dump.sh" <<DUMP
#!/bin/bash
printf '%s' "\${FILE_SENTINEL-__UNSET__}" >"$SCRATCH/worker.sentinel"
sleep 300
DUMP
T new-window -t "=$BASE:" -n later "/bin/bash $SCRATCH/dump.sh"
for ((i = 0; i < 50; i++)); do [[ -e "$SCRATCH/worker.sentinel" ]] && break; sleep 0.1; done
[[ "$(cat "$SCRATCH/worker.sentinel" 2>/dev/null)" == "$FILE_SENTINEL" ]] && pass "AC8: a worker window made later inherits the sentinel" || fail "AC8: worker window sentinel '$(cat "$SCRATCH/worker.sentinel" 2>/dev/null)'"
if grep -qF -- "$FILE_SENTINEL" "$SCRATCH/ps.log" || grep -qF -- "$LAUNCHER_ONLY_SENTINEL" "$SCRATCH/ps.log"; then fail "AC8: a value showed in a sampled argv"; else pass "AC8: no sampled argv holds a value"; fi
genv="$(T show-environment -g)"
if grep -q "^FILE_SENTINEL=" <<<"$genv" && ! grep -q "^LAUNCHER_ONLY_SENTINEL=\|^CLAUDE_GUI=" <<<"$genv"; then
    pass "AC8: a server this launch started has the file's variables, no launcher-only variable and no marker in -g"
else
    fail "AC8: show-environment -g: $(grep -E 'SENTINEL|CLAUDE_GUI|ALTERNATE' <<<"$genv" | cut -d= -f1 | tr '\n' ' ')"
fi
[[ -e "$ENVFILE" && -z "$(grep -rl -- "$FILE_SENTINEL" "$TMPDIR" 2>/dev/null)" ]] && pass "the env file is kept and no copy of it is left under TMPDIR" || fail "env file deleted, or a copy under TMPDIR"

# AC8 again with a server that already runs: its global environment is untouched
reset_all
env -i PATH=/usr/bin:/bin TMUX_TMPDIR="$TMUX_TMPDIR" "$REAL_TMUX" new-session -d -s keeper 'sleep 300'
T set-environment -g ITERM_PROFILE prof; T set-environment -g ITERM_SESSION_ID sid
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"
wait_claude
genv="$(T show-environment -g)"
if [[ "$RC" -eq 0 ]] && ! grep -q "^FILE_SENTINEL=\|^LAUNCHER_ONLY_SENTINEL=\|^CLAUDE_GUI=" <<<"$genv"; then pass "AC8: a running server's -g environment is untouched"; else fail "AC8 running server: rc=$RC -g: $(grep -E 'SENTINEL|CLAUDE_GUI|ALTERNATE' <<<"$genv" | cut -d= -f1 | tr '\n' ' ')"; fi
if ! claude_env | grep -q '^ITERM_' && grep -q '^ITERM_PROFILE=prof$' <<<"$genv" && grep -q '^ITERM_SESSION_ID=sid$' <<<"$genv"; then pass "AC8: no ITERM_* in the dashboard pane, -g still holds them"; else fail "AC8: ITERM_* leaked to the pane or left -g"; fi
claude_has_env "FILE_SENTINEL=$FILE_SENTINEL" && pass "AC8: the sentinel still reaches the dashboard pane on a running server" || fail "AC8: running-server pane lacks the sentinel"

# ---- AC2: every failure exits 1 with a reason and creates no session ------
expect_fail() { # label args...
    local label="$1"; shift
    reset_all
    run_launcher "$@"
    if [[ "$RC" -eq 1 && -s "$ERR" && -z "$(sessions)" ]]; then pass "AC2: $label -> exit 1, stderr text, no session"; else fail "AC2: $label: rc=$RC stderr='$(head -c 120 "$ERR")' sessions='$(sessions | tr '\n' ' ')'"; fi
}
write_envfile
NONREPO="$SCRATCH/not-a-repo"; mkdir -p "$NONREPO"
mkdir -p "$FIX/sub"
expect_fail "relative path" --gui-folder "proj-alpha" --env-file "$ENVFILE"
expect_fail "missing folder" --gui-folder "$SCRATCH/nope" --env-file "$ENVFILE"
expect_fail "non-repo folder" --gui-folder "$NONREPO" --env-file "$ENVFILE"
[[ ! -e "$NONREPO/.claude" ]] && pass "AC2: a refused folder gets no .claude directory" || fail "AC2: a refused folder was written to"
expect_fail "folder inside another repo" --gui-folder "$FIX/sub" --env-file "$ENVFILE"
expect_fail "missing env file" --gui-folder "$FIX" --env-file "$SCRATCH/nope.env"
expect_fail "only --gui-folder" --gui-folder "$FIX"
expect_fail "only --env-file" --env-file "$ENVFILE"
# a PATH with every tool but tmux, built from symlinks, so the failure is tmux-specific
NOTMUX="$SCRATCH/notmux"; mkdir -p "$NOTMUX"
for tool in bash git sqlite3 basename dirname tr sed mktemp chmod cat rm env grep sleep mkdir ps stat uname date head tail sort find wc perl dirname; do
    p="$(command -v "$tool" 2>/dev/null)" && ln -sf "$p" "$NOTMUX/$tool"
done
for s in claude lean-ctx headroom repowire osascript pgrep nohup; do ln -sf "$STUB/$s" "$NOTMUX/$s"; done
[[ ! -e "$NOTMUX/tmux" ]] && write_envfile "$NOTMUX" || fail "test setup: tmux is in the tmux-less dir"
expect_fail "no tmux on the env file's PATH" --gui-folder "$FIX" --env-file "$ENVFILE"
grep -qi tmux "$ERR" && pass "AC2: the tmux-less failure names tmux" || fail "AC2: stderr does not name tmux: $(head -c 120 "$ERR")"
write_envfile
# R1: a folder name with no [a-z0-9] gives an empty base name
NONASCII="$SCRATCH/$(printf '\xe6\x97\xa5\xe6\x9c\xac')"
mkgit "$NONASCII"
expect_fail "empty base name (non-ASCII folder name)" --gui-folder "$NONASCII" --env-file "$ENVFILE"

# ---- R5: a folder named like a command substitution is never executed ------
reset_all
MARK="$SCRATCH/r5-marker"
EVIL="$SCRATCH/a\$(touch $MARK)"
mkgit "$EVIL"
run_launcher --gui-folder "$EVIL" --env-file "$ENVFILE"
wait_claude
EVIL_BASE="$(tmux_base_session_name "$EVIL")"
if [[ "$RC" -eq 0 && ! -e "$MARK" ]] && wait_claude && [[ "$(T list-panes -t "=$EVIL_BASE:=dashboard" -F '#{pane_current_path}' 2>/dev/null | head -1)" == "$(cd "$EVIL" && pwd -P)" ]]; then
    pass "R5: a folder named a\$(touch ...) starts the dashboard and runs nothing"
else
    fail "R5: rc=$RC marker=$([[ -e "$MARK" ]] && echo created || echo absent) stderr: $(head -c 200 "$ERR")"
fi

# ---- default path characterization (no flag, answers on stdin) -------------
reset_all
echo 1 >"$SCRATCH/pgrep.rc" # no watchdog running, so the launcher reaches nohup (R7)
mkdir -p "$HOME/Documents/Projects"
mkgit "$HOME/Documents/Projects/dflt-proj"
DBASE="$(tmux_base_session_name "$HOME/Documents/Projects/dflt-proj")"
RC=0
printf '2\n2\n1\n1\n' | timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" >"$OUT" 2>"$ERR" || RC=$?
wait_claude
if T has-session -t "=$DBASE" 2>/dev/null; then pass "default path: the session exists"; else fail "default path: no session '$DBASE' (rc=$RC) $(head -c 200 "$ERR")"; fi
T show-environment -t "=$DBASE" 2>/dev/null | grep -q '^CLAUDE_GUI=' && fail "default path: the session has CLAUDE_GUI" || pass "default path: the session has no CLAUDE_GUI"
if [[ "$(grep -c '^nohup .*orchestrator-iterm-watchdog' "$CALLS")" -eq 1 ]]; then pass "default path: the watchdog nohup stub was called once"; else fail "default path: nohup calls: $(cat "$CALLS" | tr '\n' '|')"; fi

# ---- reuse: exit 3 and the markers (D-09) ----------------------------------
state() { # dir fn args... : run a session-state.sh function from a project dir
    local dir="$1"; shift
    ( cd "$dir" && source "$REPO_DIR/orchestration/lib/session-state.sh" && "$@" )
}

# (a) a second app launch for the same folder
reset_all
write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"
first_rc=$RC
wait_claude
printf 'marker-line\n' >>"$FIX/.claude/sessions/dashboard/inbox.jsonl"
INBOX_BEFORE="$(cat "$FIX/.claude/sessions/dashboard/inbox.jsonl")"
: >"$CALLS"
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"
if [[ "$first_rc" -eq 0 && "$RC" -eq 3 && "$(last_line)" == "$BASE" ]]; then pass "reuse (a): the second launch exits 3 with the base name last"; else fail "reuse (a): first=$first_rc second=$RC last='$(last_line)' stderr: $(head -c 200 "$ERR")"; fi
[[ "$(T list-windows -t "=$BASE" -F '#{window_name}' | tr '\n' ' ')" == "dashboard " ]] && pass "reuse (a): still exactly one dashboard window" || fail "reuse (a): windows: $(T list-windows -t "=$BASE" -F '#{window_name}' | tr '\n' ' ')"
grep -q '^pgrep\|^nohup\|^osascript' "$CALLS" && fail "reuse (a): a watchdog or osascript stub was called" || pass "reuse (a): no watchdog start"
SFDIR="$FOLDER_REAL/.claude/sessions/dashboard"
[[ -f "$SFDIR/inbox.jsonl" && -f "$SFDIR/out.jsonl" ]] && pass "headless: inbox.jsonl and out.jsonl exist under .claude/sessions/dashboard" || fail "headless: session files missing in $SFDIR"
[[ "$(cat "$SFDIR/inbox.jsonl")" == "$INBOX_BEFORE" ]] && pass "headless: a second launch against the live session leaves the inbox unchanged" || fail "headless: the inbox changed on reuse"
DBP="$(cd "$FIX" && source "$REPO_DIR/orchestration/lib/session-state.sh" && session_state_db_path)"
ROWPATHS="$(sqlite3 "$DBP" "SELECT inbox_path || '|' || out_path FROM sessions WHERE agent_id = 'dashboard';" 2>&1)"
[[ "$ROWPATHS" == "$FIX/.claude/sessions/dashboard/inbox.jsonl|$FIX/.claude/sessions/dashboard/out.jsonl" ]] && pass "headless: the dashboard row holds both paths" || fail "headless: dashboard row paths '$ROWPATHS'"
if [[ -s "$SCRATCH/claude.pid" ]]; then
    kill "$(cat "$SCRATCH/claude.pid")" 2>/dev/null
    gone=0
    for ((i = 0; i < 50; i++)); do T has-session -t "=$BASE" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
    [[ $gone -eq 1 ]] && pass "headless: the orchestrator window is gone within 5 seconds of the claude kill" || fail "headless: the window outlived its claude"
else
    fail "headless: the stub recorded no pid"
fi

# (b) an iTerm-style session without markers is reused and gets both markers
reset_all
BETA="$SCRATCH/proj-beta"
mkgit "$BETA"
BB="$(tmux_base_session_name "$BETA")"
"$REPO_DIR/orchestration/init/init-state-store.sh" "$BETA" >/dev/null 2>&1
state "$BETA" session_state_write "stale-blocked" "/tmp/none" "blocked" >/dev/null 2>&1
state "$BETA" session_state_set_pending_operation "stale-blocked" "git push origin main" >/dev/null 2>&1
T new-session -d -s "$BB" -n dashboard 'sleep 300'
run_launcher --gui-folder "$BETA" --env-file "$ENVFILE"
if [[ "$RC" -eq 3 && "$(last_line)" == "$BB" ]]; then pass "reuse (b): an unmarked session is reused, exit 3, base name last"; else fail "reuse (b): rc=$RC last='$(last_line)' stderr: $(head -c 200 "$ERR")"; fi
senv="$(T show-environment -t "=$BB" 2>/dev/null)"
if grep -qx 'CLAUDE_GUI=1' <<<"$senv" && ! grep -q '^CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=' <<<"$senv"; then pass "reuse (b): the reused session now holds the marker"; else fail "reuse (b): session env: $(cut -d= -f1 <<<"$senv" | grep -E 'CLAUDE|SENTINEL' | tr '\n' ' ')"; fi
grep -q '^FILE_SENTINEL=' <<<"$senv" && fail "reuse (b): the env file was applied to a reused session" || pass "reuse (b): the env file is not applied on reuse"
[[ "$(state "$BETA" session_state_read dashboard 2>/dev/null)" == "running" ]] && pass "reuse (b): the dashboard row is written" || fail "reuse (b): dashboard row '$(state "$BETA" session_state_read dashboard 2>&1)'"
[[ -z "$(state "$BETA" session_state_get_pending_operation stale-blocked 2>/dev/null)" ]] && pass "reuse (b): the launch sweep ran (a stale blocked row is cleared)" || fail "reuse (b): the launch sweep did not run"
grep -q '^pgrep\|^nohup\|^osascript' "$CALLS" && fail "reuse (b): a watchdog or osascript stub was called" || pass "reuse (b): no watchdog start"

# R4: a tmux stub first on the env file's PATH plays the concurrent actor
mk_tmux_stub() { # dir  hook-arg  hook-command...   (runs the hook before the real tmux when arg 1 matches)
    local dir="$1" arg="$2"; shift 2
    mkdir -p "$dir"
    printf '#!/bin/bash\nif [[ "${1-}" == %s ]]; then %s; fi\nexec "%s" "$@"\n' "$arg" "$*" "$REAL_TMUX" >"$dir/tmux"
    chmod +x "$dir/tmux"
}
# (c) the create loses a race: another start makes the session first -> reuse path, exit 3
reset_all
GAMMA="$SCRATCH/proj-gamma"; mkgit "$GAMMA"
GB="$(tmux_base_session_name "$GAMMA")"
mk_tmux_stub "$SCRATCH/race" start-server "\"$REAL_TMUX\" new-session -d -s $GB -n dashboard 'sleep 300' 2>/dev/null"
write_envfile "$SCRATCH/race:$TOOLPATH"
run_launcher --gui-folder "$GAMMA" --env-file "$ENVFILE"
senv="$(T show-environment -t "=$GB" 2>/dev/null)"
if [[ "$RC" -eq 3 && "$(last_line)" == "$GB" ]] && grep -qx 'CLAUDE_GUI=1' <<<"$senv"; then
    pass "R4: a lost create race takes the reuse path (exit 3, marker set)"
else
    fail "R4 lost race: rc=$RC last='$(last_line)' stderr: $(head -c 200 "$ERR")"
fi
# (d) the reused session vanishes before the markers are set -> exit 1 with a reason
reset_all
mk_tmux_stub "$SCRATCH/vanish" set-environment "\"$REAL_TMUX\" kill-session -t =$GB 2>/dev/null"
write_envfile "$SCRATCH/vanish:$TOOLPATH"
T new-session -d -s "$GB" -n dashboard 'sleep 300'
run_launcher --gui-folder "$GAMMA" --env-file "$ENVFILE"
if [[ "$RC" -eq 1 && -s "$ERR" ]]; then pass "R4: a session that vanishes under the marker write exits 1 with stderr text"; else fail "R4 vanish: rc=$RC stderr='$(head -c 200 "$ERR")'"; fi
write_envfile

# ---- --gui-root: the plain solo session in ~ (interactive option 1) --------
# HOME is a scratch directory and no git repository here.
RBASE="$(tmux_base_session_name "$HOME")"
HOME_REAL="$(cd "$HOME" && pwd -P)"
reset_all
write_envfile
run_launcher --gui-root --env-file "$ENVFILE"
wait_claude
if [[ "$RC" -eq 0 && "$(last_line)" == "$RBASE" ]] && T has-session -t "=$RBASE" 2>/dev/null; then pass "ROOT: exit 0, base name last, session exists"; else fail "ROOT start: rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"; fi
[[ "$(T list-panes -t "=$RBASE:=dashboard" -F '#{pane_current_path}' 2>/dev/null | head -1)" == "$HOME_REAL" ]] && pass "ROOT: the dashboard pane directory is ~" || fail "ROOT: pane path '$(T list-panes -t "=$RBASE:=dashboard" -F '#{pane_current_path}' 2>&1 | head -1)'"
if wait_claude && [[ "$(tr '\0' ' ' <"$(ls "$CLAUDELOG"/args.* | head -1)")" == "-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --permission-prompt-tool stdio " ]]; then pass "ROOT: claude runs with only the headless flags and the stdio permission tool (default model, no orchestration prompt)"; else fail "ROOT: claude args: $(tr '\0' ' ' <"$(ls "$CLAUDELOG"/args.* 2>/dev/null | head -1)")"; fi
senv="$(T show-environment -t "=$RBASE" 2>/dev/null)"
if grep -qx 'CLAUDE_GUI=1' <<<"$senv" && ! grep -q '^CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=' <<<"$senv"; then pass "ROOT: the session carries CLAUDE_GUI=1 and no alternate-screen flag"; else fail "ROOT: session env: $senv"; fi
[[ ! -e "$HOME/.claude/orchestrator-root" && ! -e "$HOME/.claude/state" ]] && pass "ROOT: no orchestration state written under ~" || fail "ROOT: state written under ~: $(ls -A "$HOME/.claude" 2>&1 | tr '\n' ' ')"
if ! grep -q '^pgrep\|^nohup\|^osascript' "$CALLS"; then pass "ROOT: no watchdog start and no osascript call"; else fail "ROOT: stub calls: $(tr '\n' '|' <"$CALLS")"; fi
run_launcher --gui-root --env-file "$ENVFILE"
if [[ "$RC" -eq 3 && "$(last_line)" == "$RBASE" ]]; then pass "ROOT: a second start reuses the session (exit 3)"; else fail "ROOT reuse: rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"; fi
expect_fail "--gui-root without --env-file" --gui-root
expect_fail "--gui-root with --gui-folder" --gui-root --gui-folder "$FIX" --env-file "$ENVFILE"
expect_fail "--gui-root with a missing env file" --gui-root --env-file "$SCRATCH/nope.env"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
