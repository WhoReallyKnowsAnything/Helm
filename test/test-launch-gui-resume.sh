#!/bin/bash
# test/test-launch-gui-resume.sh
# launch-claude.sh --gui-root|--gui-folder ... --resume <id> (Phase 7 Plan 3):
# the id check, the resumed claude argv, the out log history seed and the
# dashboard-only restart of a running base session. Runs the REAL launcher
# against a PRIVATE tmux server (TMUX_TMPDIR in a scratch dir, exported before
# any tmux call) with a stub claude first on PATH, HOME a scratch dir, stdin
# from /dev/null, no controlling terminal, under a timeout. Never the default
# tmux server, never the real claude.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
for tool in perl timeout jq; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/lgr.XXXXXX)" || exit 1
SCRATCH="$(cd "$SCRATCH" && pwd -P)"
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
STUB="$SCRATCH/stub"
CLAUDELOG="$SCRATCH/claudelog"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$STUB" "$CLAUDELOG"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT ORCH_TMUX_SOCKET CLAUDE_CONFIG_DIR
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- stubs -----------------------------------------------------------------
cat >"$STUB/claude" <<STUBCLAUDE
#!/bin/bash
if [[ "\${1-}" == update ]]; then exit 0; fi
printf '%s\0' "\$@" >"$CLAUDELOG/.args.\$\$" && mv "$CLAUDELOG/.args.\$\$" "$CLAUDELOG/args.\$\$"
env >"$CLAUDELOG/.env.\$\$" && mv "$CLAUDELOG/.env.\$\$" "$CLAUDELOG/env.\$\$"
sleep 300
STUBCLAUDE
for s in lean-ctx headroom repowire osascript nohup pgrep; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl jq; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"

ENVFILE="$SCRATCH/app.env"
FILE_SENTINEL="file-sentinel-$$-secret"
printf 'PATH=%s\nFILE_SENTINEL=%s\nTERM=dumb\nHOME=%s\n' "$TOOLPATH" "$FILE_SENTINEL" "$HOME" >"$ENVFILE"

# ---- helpers ---------------------------------------------------------------
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
    rm -f "$CLAUDELOG"/*
}
mkgit() { # dir
    mkdir -p "$1"
    ( cd "$1" && command git init -q 2>/dev/null && command git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
}
args_file_with() { # id: the stub argv file whose last two args are --resume <id>
    local f
    for f in "$CLAUDELOG"/args.*; do
        [[ -e "$f" ]] || continue
        [[ "$(tr '\0' '\n' <"$f" | tail -n 2 | paste -sd' ' -)" == "--resume $1" ]] && { echo "$f"; return 0; }
    done
    return 1
}
wait_args() { # id
    local i
    for ((i = 0; i < 150; i++)); do args_file_with "$1" >/dev/null && return 0; sleep 0.1; done
    return 1
}
stub_count() { compgen -G "$CLAUDELOG/args.*" | wc -l | tr -d ' '; }
transcript() { # folder id text: a transcript with every record kind the seed filters
    local dir
    dir="$HOME/.claude/projects/$(cd "$1" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$dir"
    jq -cn --arg t "$3" --arg c "$(cd "$1" && pwd -P)" '
        {type: "user", isMeta: true, cwd: $c, message: {role: "user", content: "meta-skip"}},
        {type: "assistant", isSidechain: true, message: {role: "assistant", content: "side-skip"}},
        {type: "ai-title", title: "title-skip"},
        {type: "user", message: {role: "user", content: $t}},
        {type: "assistant", message: {role: "assistant", content: [{type: "text", text: ("answer " + $t)}]}},
        {type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t1", name: "Bash", input: {}}]}},
        {type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: "ok"}]}}' \
        >"$dir/$2.jsonl"
}
expected_seed() { # folder id: the out log lines a --resume start must write
    local dir
    dir="$HOME/.claude/projects/$(cd "$1" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
    jq -cn --arg s "$2" --arg c "$(cd "$1" && pwd -P)" '{type: "system", subtype: "init", session_id: $s, cwd: $c}'
    jq -c --arg s "$2" 'select(.type == "user" or .type == "assistant") | select((.isMeta or .isSidechain) | not)
        | if .type == "user" then {type, isReplay: true, session_id: $s, message} else {type, session_id: $s, message} end' "$dir/$2.jsonl"
    jq -cn --arg s "$2" '{type: "result", subtype: "success", session_id: $s}'
}

A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
ROOT_BASE="$(tmux_base_session_name "$HOME")"
ROOT_OUT="$HOME/.claude/sessions/dashboard/out.jsonl"
ROOT_INBOX="$HOME/.claude/sessions/dashboard/inbox.jsonl"
TEXT_A='A says "hi" \ back'$'\n''second line'
transcript "$HOME" "$A" "$TEXT_A"
transcript "$HOME" "$B" "B-text"

# ---- Task 1: bad input exits 1, starts nothing -----------------------------
check_rejected() { # name args...
    local name="$1"; shift
    reset_all
    run_launcher "$@"
    sleep 0.3
    if [[ "$RC" -eq 1 && -s "$ERR" && "$(stub_count)" == 0 && -z "$(sessions)" ]]; then
        pass "T1: $name exits 1, no claude, no session"
    else
        fail "T1: $name rc=$RC claudes=$(stub_count) sessions='$(sessions)' stderr: $(head -2 "$ERR")"
    fi
}
check_rejected "an id with a capital letter" --gui-root --resume "Aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" --env-file "$ENVFILE"
check_rejected "an id with no transcript" --gui-root --resume "cccccccc-cccc-cccc-cccc-cccccccccccc" --env-file "$ENVFILE"
check_rejected "--resume with --gui-new" --gui-new newproj --github skip --resume "$A" --env-file "$ENVFILE"
check_rejected "--resume with no value" --gui-root --env-file "$ENVFILE" --resume
[[ ! -e "$SCRATCH/home/Documents/Projects/newproj" ]] && pass "T1: --gui-new with --resume created no folder" \
    || fail "T1: --gui-new with --resume created the folder"

# ---- Tasks 2 and 3: root start on A ----------------------------------------
reset_all
mkdir -p "$(dirname "$ROOT_OUT")"
printf 'stale-out-line\n' >"$ROOT_OUT"
printf 'stale-inbox-line\n' >"$ROOT_INBOX"
run_launcher --gui-root --resume "$A" --env-file "$ENVFILE"
wait_args "$A"
if [[ "$RC" -eq 0 && "$(last_line)" == "$ROOT_BASE" ]]; then pass "T2: root --resume exits 0, base name last"; else fail "T2: root rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"; fi
args_file_with "$A" >/dev/null && pass "T2: the stub argv ends with --resume $A" || fail "T2: no stub argv ends with --resume $A"
[[ ! -s "$ROOT_INBOX" ]] && pass "T2: the inbox holds no seed line" || fail "T2: inbox: $(head -2 "$ROOT_INBOX")"
grep -q stale-out-line "$ROOT_OUT" && fail "T2: the out log kept an old line" || pass "T2: the out log holds none of its old lines"
if [[ "$(cat "$ROOT_OUT")" == "$(expected_seed "$HOME" "$A")" ]]; then
    pass "T3: the out log is exactly the 4 kept records, then the result line"
else
    fail "T3: out log: $(head -c 600 "$ROOT_OUT")"
fi
[[ "$(sed -n 2p "$ROOT_OUT" | jq -r .message.content)" == "$TEXT_A" ]] \
    && pass "T3: quotes, a backslash and a newline survive" || fail "T3: user text changed"
[[ "$(sed -n 1p "$ROOT_OUT" | jq -c '[.type, .subtype, .session_id, .cwd]')" == "[\"system\",\"init\",\"$A\",\"$HOME\"]" ]] \
    && pass "T3: the first out log line is a system init with the transcript cwd and the id" \
    || fail "T3: first line: $(sed -n 1p "$ROOT_OUT")"
[[ "$(jq -r .session_id "$ROOT_OUT" | sort -u)" == "$A" ]] && pass "T3: every line has session_id $A" || fail "T3: session ids differ"

# ---- Task 4: restart the running root dashboard on B ----------------------
printf 'old-inbox-line\n' >>"$ROOT_INBOX"
run_launcher --gui-root --resume "$B" --env-file "$ENVFILE"
wait_args "$B"
if [[ "$RC" -eq 0 && "$(last_line)" == "$ROOT_BASE" ]]; then pass "T4: restart exits 0, base name last"; else fail "T4: restart rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"; fi
T has-session -t "=$ROOT_BASE" 2>/dev/null && pass "T4: the session still exists" || fail "T4: the session is gone"
if f="$(args_file_with "$B")"; then
    pass "T4: a second stub claude ran with --resume $B"
    if grep -qxF "FILE_SENTINEL=$FILE_SENTINEL" "${f/args./env.}" && grep -qxF CLAUDE_GUI=1 "${f/args./env.}"; then
        pass "T4: the restarted claude sees the env file and CLAUDE_GUI=1"
    else
        fail "T4: the restarted claude lacks the env file marker or CLAUDE_GUI=1"
    fi
else
    fail "T4: no stub claude ran with --resume $B"
fi
[[ "$(cat "$ROOT_OUT")" == "$(expected_seed "$HOME" "$B")" ]] && pass "T4: the out log holds B's seed and no line of A" \
    || fail "T4: out log: $(head -c 600 "$ROOT_OUT")"
[[ ! -s "$ROOT_INBOX" ]] && pass "T4: the inbox holds no line written before the restart" || fail "T4: inbox: $(head -2 "$ROOT_INBOX")"

# without --resume, a running session is reused: exit 3, nothing starts
n="$(stub_count)"
run_launcher --gui-root --env-file "$ENVFILE"
sleep 0.5
[[ "$RC" -eq 3 && "$(stub_count)" == "$n" ]] && pass "T4: without --resume the reuse branch exits 3, starts nothing" \
    || fail "T4: reuse rc=$RC claudes $n -> $(stub_count)"

# ---- Tasks 2 and 4: folder session ---------------------------------------
reset_all
FIX="$SCRATCH/proj-resume"
mkgit "$FIX"
FIX_BASE="$(tmux_base_session_name "$FIX")"
transcript "$FIX" "$A" "folder-A"
transcript "$FIX" "$B" "folder-B"
run_launcher --gui-folder "$FIX" --resume "$A" --env-file "$ENVFILE"
wait_args "$A"
[[ "$RC" -eq 0 && "$(last_line)" == "$FIX_BASE" ]] && pass "T2: folder --resume exits 0, base name last" \
    || fail "T2: folder rc=$RC last='$(last_line)' stderr: $(head -3 "$ERR")"
[[ "$(cat "$FIX/.claude/orchestrator-session-id" 2>/dev/null)" == "$A" ]] && pass "T2: orchestrator-session-id holds the id" \
    || fail "T2: orchestrator-session-id: $(cat "$FIX/.claude/orchestrator-session-id" 2>/dev/null)"
args_file_with "$A" >/dev/null && pass "T2: the folder stub argv has --resume $A" || fail "T2: no folder stub argv with --resume $A"
T new-window -d -t "=$FIX_BASE" -n w1 'sleep 300'
run_launcher --gui-folder "$FIX" --resume "$B" --env-file "$ENVFILE"
wait_args "$B"
[[ "$RC" -eq 0 ]] && args_file_with "$B" >/dev/null && pass "T4: folder restart runs claude with --resume $B" \
    || fail "T4: folder restart rc=$RC stderr: $(head -3 "$ERR")"
T list-windows -t "=$FIX_BASE" -F '#{window_name}' 2>/dev/null | grep -qx w1 && pass "T4: window w1 keeps running" \
    || fail "T4: window w1 is gone"
[[ "$(cat "$FIX/.claude/orchestrator-session-id" 2>/dev/null)" == "$B" ]] && pass "T4: orchestrator-session-id holds $B" \
    || fail "T4: orchestrator-session-id not updated"

echo ""
if [[ "$FAILS" -eq 0 ]]; then echo "ALL PASS"; exit 0; fi
echo "$FAILS FAILED"
exit 1
