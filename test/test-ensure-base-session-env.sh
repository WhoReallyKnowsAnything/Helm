#!/bin/bash
# test/test-ensure-base-session-env.sh
# tmux_ensure_base_session with the optional folder / env-file / session
# variables (D-06, D-10, AC8). Runs on a PRIVATE tmux server (TMUX_TMPDIR in a
# scratch dir, exported before the first tmux call), never the default one.
# A stub `tmux` first on PATH records every call's argument list, then runs the
# real tmux by absolute path.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$SCRIPT_DIR/../orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/ebse.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$SCRATCH/bin"
unset TMUX TMUX_PANE
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
reset_server() { T kill-server 2>/dev/null; while T ls &>/dev/null; do sleep 0.05; done; }

# Stub: log the argument list (one line, tab separated), widen the window a
# `ps` sampler sees, then run the real tmux.
CALLS="$SCRATCH/calls.log"
cat >"$SCRATCH/bin/tmux" <<STUB
#!/bin/bash
printf '%s\t' "\$@" >>"$CALLS"; echo >>"$CALLS"
sleep 0.4
exec "$REAL_TMUX" "\$@"
STUB
chmod +x "$SCRATCH/bin/tmux"
export PATH="$SCRATCH/bin:$PATH"

# Pane program: dump selected variables and the cwd, then idle.
NAMES="V_SPACE V_DOLLAR V_HASH V_SEMI V_BSLASH V_DQ V_SQ V_TILDE V_CMD V_NL V_PCT CLAUDE_GUI FILE_SENTINEL ITERM_PROFILE ITERM_SESSION_ID ITERM_EXTRA_X GLOBAL_KEEP"
cat >"$SCRATCH/dump.sh" <<DUMP
#!/bin/bash
out="\$1"; mkdir -p "\$out"
for v in $NAMES; do printf '%s' "\${!v-__UNSET__}" >"\$out/\$v"; done
printf '%s' "\$PWD" >"\$out/_pwd"; printf '%s' "\$PATH" >"\$out/_path"
sleep 300
DUMP

# Torture values. Continuation lines of V_NL never look like NAME=...
V_SPACE='a b  c'
V_DOLLAR='$HOME ${X} $(echo hi)'
V_HASH="# #{pane_id} #(touch $SCRATCH/hashmark) ##"
V_SEMI='a;b ; c'
V_BSLASH='a\b\\n\'
V_DQ='say "hi"'
V_SQ="it's 'q'"
V_TILDE='~ ~/x'
V_CMD="\$(touch $SCRATCH/m1) \`touch $SCRATCH/m2\`"
V_NL=$'line1\n  line2 indented\n#line3\n\tline4'
V_PCT='%if 1 %s'
FILE_SENTINEL="file-sentinel-$$-secret"
ENVFILE="$SCRATCH/app.env"
write_envfile() { # extra lines on stdin-less args: write_envfile [extra-record...]
    {
        for n in V_SPACE V_DOLLAR V_HASH V_SEMI V_BSLASH V_DQ V_SQ V_TILDE V_CMD V_NL V_PCT FILE_SENTINEL; do
            printf '%s=%s\n' "$n" "${!n}"
        done
        printf 'PATH=/sentinel/bin:/usr/bin:/bin\n'
        for extra in "$@"; do printf '%s\n' "$extra"; done
    } >"$ENVFILE"
}

wait_for() { # file
    local i
    for ((i = 0; i < 100; i++)); do [[ -e "$1" ]] && return 0; sleep 0.1; done
    return 1
}
same() { [[ -e "$2/$1" && "$(cat "$2/$1"; printf x)" == "${!1}"x ]]; } # same VAR outdir
group_check() { # label outdir
    local n bad=""
    for n in V_SPACE V_DOLLAR V_HASH V_SEMI V_BSLASH V_DQ V_SQ V_TILDE V_CMD V_NL V_PCT FILE_SENTINEL; do
        same "$n" "$2" || bad="$bad $n"
    done
    if [[ -z "$bad" ]]; then pass "$1: every torture value is byte exact"; else fail "$1: differing values:$bad"; fi
}

# ---- Case 1: 3-argument call is byte for byte today's call -----------------
reset_server
: >"$CALLS"
tmux_ensure_base_session s1 win 'sleep 300'
rc=$?
expected_calls=$'has-session\t-t\t=s1\t\nnew-session\t-d\t-s\ts1\t-n\twin\tsleep 300\t'
if [[ "$rc" -eq 0 && "$(cat "$CALLS")" == "$expected_calls" ]]; then
    pass "3-arg call: exactly has-session + one plain new-session (no -c, -e, source-file)"
else
    fail "3-arg call: rc=$rc calls: $(tr '\t\n' ' |' <"$CALLS")"
fi
if T show-environment -t =s1 2>/dev/null | grep -q '^CLAUDE_GUI='; then fail "3-arg call: session has CLAUDE_GUI"; else pass "3-arg call: session has no CLAUDE_GUI"; fi

# ---- Case 2: -c folder (odd name: format characters stay literal) ----------
reset_server
FOLDER="$SCRATCH/dir #(touch $SCRATCH/foldermark) #{pane_id} \$x"
mkdir -p "$FOLDER"
write_envfile
tmux_ensure_base_session s2 'w #(touch '"$SCRATCH"'/namemark)' "/bin/bash $SCRATCH/dump.sh $SCRATCH/o2" "$FOLDER" "$ENVFILE" CLAUDE_GUI=1
rc=$?
wait_for "$SCRATCH/o2/_pwd"
path="$(T list-panes -t =s2: -F '#{pane_current_path}' | head -1)"
if [[ "$rc" -eq 0 && "$path" == "$(cd "$FOLDER" && pwd -P)" ]]; then pass "-c folder equals #{pane_current_path}"; else fail "-c folder: rc=$rc path='$path'"; fi
if [[ ! -e "$SCRATCH/foldermark" && ! -e "$SCRATCH/namemark" ]]; then pass "folder and window name are not format-expanded"; else fail "a format string in the folder or window name ran"; fi

# ---- Case 3: env-file values reach the first pane and a later window -------
group_check "first pane" "$SCRATCH/o2"
T new-window -t =s2: -n later "/bin/bash $SCRATCH/dump.sh $SCRATCH/o3"
wait_for "$SCRATCH/o3/_pwd"
group_check "later window" "$SCRATCH/o3"
if [[ ! -e "$SCRATCH/m1" && ! -e "$SCRATCH/m2" && ! -e "$SCRATCH/hashmark" ]]; then pass "no value was executed"; else fail "a value was executed"; fi

# ---- Case 4: a marker overrides a same-named file record -------------------
reset_server
write_envfile 'CLAUDE_GUI=0'
tmux_ensure_base_session s4 win "/bin/bash $SCRATCH/dump.sh $SCRATCH/o4" "$SCRATCH" "$ENVFILE" CLAUDE_GUI=1
wait_for "$SCRATCH/o4/_pwd"
[[ "$(cat "$SCRATCH/o4/CLAUDE_GUI")" == "1" ]] && pass "marker overrides the file record" || fail "marker: CLAUDE_GUI='$(cat "$SCRATCH/o4/CLAUDE_GUI")'"

# ---- Case 5: global environment, server started by this call (R3) ----------
# The server's global environment is the env file's variables, never the
# launcher's own, never the markers.
reset_server
export LAUNCHER_ONLY_SENTINEL="launcher-only-$$-secret"
write_envfile
ps_log="$SCRATCH/ps.log"; : >"$ps_log"
( for ((i = 0; i < 40; i++)); do ps -wwAo args >>"$ps_log"; sleep 0.05; done ) &
sampler=$!
tmux_ensure_base_session s5 win "/bin/bash $SCRATCH/dump.sh $SCRATCH/o5" "$SCRATCH" "$ENVFILE" CLAUDE_GUI=1
wait_for "$SCRATCH/o5/_pwd"
wait "$sampler"
genv="$(T show-environment -g)"
if grep -q "^FILE_SENTINEL=" <<<"$genv"; then pass "server started by the call: global env holds the file variables"; else fail "global env lacks FILE_SENTINEL"; fi
if grep -q "^LAUNCHER_ONLY_SENTINEL=" <<<"$genv"; then fail "global env holds a launcher-only variable"; else pass "server started by the call: global env holds no launcher-only variable"; fi
if grep -q "^CLAUDE_GUI=" <<<"$genv"; then fail "global env holds a marker"; else pass "global env holds no marker"; fi
# a plain (iTerm-style) client on that server still sees the file's PATH, and no
# marker (the client has no PATH of its own: tmux takes a client's PATH over the global one)
env -i TMUX_TMPDIR="$TMUX_TMPDIR" "$REAL_TMUX" new-session -d -s plain "/bin/bash $SCRATCH/dump.sh $SCRATCH/oplain"
wait_for "$SCRATCH/oplain/_pwd"
if [[ "$(cat "$SCRATCH/oplain/_path")" == /sentinel/bin:* ]]; then pass "iTerm-style session sees the file's PATH"; else fail "iTerm-style PATH: $(cat "$SCRATCH/oplain/_path")"; fi
[[ "$(cat "$SCRATCH/oplain/CLAUDE_GUI")" == "__UNSET__" ]] && pass "iTerm-style session has no CLAUDE_GUI" || fail "iTerm-style session has CLAUDE_GUI"

# ---- Case 6: no argv, no leftover file holds a value -----------------------
leak=0
for secret in "$FILE_SENTINEL" "$V_DOLLAR" "$V_SQ" "$LAUNCHER_ONLY_SENTINEL"; do
    if grep -qF -- "$secret" "$CALLS" || grep -qF -- "$secret" "$ps_log"; then leak=1; echo "  leaked: $secret"; fi
done
[[ "$leak" -eq 0 ]] && pass "no recorded argv and no ps sample holds a value" || fail "a value reached an argv"
if [[ -z "$(find "$TMPDIR" -type f 2>/dev/null)" ]]; then pass "no file is left under TMPDIR"; else fail "files left under TMPDIR: $(find "$TMPDIR" -type f)"; fi

# ---- Case 7: server already running: global env untouched ------------------
reset_server
env -i PATH=/usr/bin:/bin TMUX_TMPDIR="$TMUX_TMPDIR" "$REAL_TMUX" new-session -d -s keeper 'sleep 300'
write_envfile
tmux_ensure_base_session s7 win "/bin/bash $SCRATCH/dump.sh $SCRATCH/o7" "$SCRATCH" "$ENVFILE" CLAUDE_GUI=1
wait_for "$SCRATCH/o7/_pwd"
genv="$(T show-environment -g)"
if grep -q "^FILE_SENTINEL=\|^V_\|^LAUNCHER_ONLY_SENTINEL=\|^CLAUDE_GUI=" <<<"$genv"; then fail "running server: global env changed"; else pass "running server: global env untouched"; fi
group_check "running server, first pane" "$SCRATCH/o7"
unset LAUNCHER_ONLY_SENTINEL

# ---- Case 8: no ITERM_* reaches the session; the global env keeps them ------
no_iterm() { # label outdir
    local n bad=""
    for n in ITERM_PROFILE ITERM_SESSION_ID ITERM_EXTRA_X; do
        [[ "$(cat "$2/$n" 2>/dev/null)" == "__UNSET__" ]] || bad="$bad $n"
    done
    if [[ -z "$bad" ]]; then pass "$1: no ITERM_* variable"; else fail "$1: ITERM_* present:$bad"; fi
}
reset_server
T new-session -d -s keep 'sleep 300'
for n in ITERM_PROFILE ITERM_SESSION_ID ITERM_EXTRA_X; do T set-environment -g "$n" "seed-$n"; done
T set-environment -g GLOBAL_KEEP 1
write_envfile
tmux_ensure_base_session s8 win "/bin/bash $SCRATCH/dump.sh $SCRATCH/o8" "$SCRATCH" "$ENVFILE" CLAUDE_GUI=1
wait_for "$SCRATCH/o8/_pwd"
no_iterm "running server, first pane" "$SCRATCH/o8"
[[ "$(cat "$SCRATCH/o8/GLOBAL_KEEP")" == "1" ]] && pass "non-ITERM global variable still inherited" || fail "GLOBAL_KEEP='$(cat "$SCRATCH/o8/GLOBAL_KEEP")'"
T new-window -t =s8: -n later "/bin/bash $SCRATCH/dump.sh $SCRATCH/o8b"
wait_for "$SCRATCH/o8b/_pwd"
no_iterm "running server, later window" "$SCRATCH/o8b"
genv="$(T show-environment -g)"
if grep -q '^ITERM_PROFILE=seed-ITERM_PROFILE$' <<<"$genv" && grep -q '^ITERM_SESSION_ID=seed-ITERM_SESSION_ID$' <<<"$genv" && grep -q '^ITERM_EXTRA_X=seed-ITERM_EXTRA_X$' <<<"$genv"; then pass "global env still holds the ITERM_* values"; else fail "global env lost an ITERM_* value"; fi

# ---- Case 9: an ITERM_* record in the env file is dropped too ---------------
reset_server
write_envfile 'ITERM_PROFILE=x'
tmux_ensure_base_session s9 win "/bin/bash $SCRATCH/dump.sh $SCRATCH/o9" "$SCRATCH" "$ENVFILE" CLAUDE_GUI=1
wait_for "$SCRATCH/o9/_pwd"
no_iterm "env file record, first pane" "$SCRATCH/o9"
T new-window -t =s9: -n later "/bin/bash $SCRATCH/dump.sh $SCRATCH/o9b"
wait_for "$SCRATCH/o9b/_pwd"
no_iterm "env file record, later window" "$SCRATCH/o9b"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
