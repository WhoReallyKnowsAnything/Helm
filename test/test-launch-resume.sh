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


# ---- resume: first launch pins a session id, relaunch resumes it ----------
slug="$(cd "$FIX" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
arg_lines() { tr '\0' '\n' <"$(ls "$CLAUDELOG"/args.* | head -1)"; }
INBOX="$FIX/.claude/sessions/dashboard/inbox.jsonl"
SEED="Show my open Notion tasks for this project."
# exactly one inbox line that jq parses with the seed as content
seed_only() { [[ "$(wc -l <"$INBOX" | tr -d ' ')" == 1 && "$(jq -r '.message.content' "$INBOX" 2>/dev/null)" == "$SEED" ]]; }
# Notion IDs come from the local config, never the repo: scratch IDs for the seeded runs
NCFG="$HOME/Library/Application Support/Helm/notion.env"
P_ID="aaaaaaaa-1111-2222-3333-444444444444"; T_ID="bbbbbbbb-5555-6666-7777-888888888888"
mkdir -p "$(dirname "$NCFG")"
printf 'HELM_NOTION_PROJECTS_DS_ID=%s\nHELM_NOTION_TASKS_DS_ID=%s\n' "$P_ID" "$T_ID" >"$NCFG"
reset_all; write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"; wait_claude
SIDF="$FIX/.claude/orchestrator-session-id"
sid="$(cat "$SIDF" 2>/dev/null)"
A="$(arg_lines)"
[[ "$sid" =~ ^[0-9a-f-]{36}$ ]] && pass "new: session id stored" || fail "new: no stored id"
[[ "$A" == *$'--session-id\n'"$sid"* && "$A" != *"Show my open Notion tasks"* && "$A" != *--resume* ]] && seed_only && pass "new: --session-id, seed as the one inbox line" || fail "new: args $(echo "$A" | tr '\n' ' ')"

# stored id but no transcript -> still new (broken/missing conversation)
reset_all; write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"; wait_claude
A="$(arg_lines)"
[[ "$A" != *--resume* && "$A" != *"Show my open Notion tasks"* ]] && seed_only && pass "no transcript: starts new with seed in the inbox" || fail "no transcript: $(echo "$A" | tr '\n' ' ')"
NOTION_BLOCK="$(echo "$A" | grep -A1 -x -- '--append-system-prompt' | tail -n 1)"
[[ "$NOTION_BLOCK" == *"$P_ID"* && "$NOTION_BLOCK" == *"$T_ID"* && "$NOTION_BLOCK" == *"Helm Notion config"* ]] && pass "config: the prompt block holds the scratch IDs" || fail "config: block '$NOTION_BLOCK'"

# no config: no IDs in the args, no seed, no Notion block
rm -f "$NCFG" "$INBOX"
reset_all; write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"; wait_claude
A="$(arg_lines)"
if ! echo "$A" | grep -qx -- '--append-system-prompt' && [[ "$A" != *"$P_ID"* && "$A" != *"Helm Notion config"* && ! -s "$INBOX" ]]; then
    pass "no config: no IDs, no Notion block, no seed"
else
    fail "no config: $(echo "$A" | tr '\n' ' ') inbox=$(cat "$INBOX" 2>/dev/null)"
fi
printf 'HELM_NOTION_PROJECTS_DS_ID=%s\nHELM_NOTION_TASKS_DS_ID=%s\n' "$P_ID" "$T_ID" >"$NCFG"

# stored id + transcript -> resume
sid="$(cat "$SIDF")"
mkdir -p "$HOME/.claude/projects/$slug"; echo '{}' >"$HOME/.claude/projects/$slug/$sid.jsonl"
reset_all; write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"; wait_claude
A="$(arg_lines)"
[[ "$A" == *$'--resume\n'"$sid"* && ! -s "$INBOX" ]] && pass "existing: --resume <id>, zero-byte inbox" || fail "existing: $(echo "$A" | tr '\n' ' ')"

SJ="$(arg_lines | grep -A1 -x -- '--settings' | tail -n 1)"
[[ "$(printf '%s' "$SJ" | jq -r '.hooks.SessionStart[0].matcher' 2>/dev/null)" == clear ]] && pass "launch: --settings clear hook JSON intact" || fail "launch: --settings JSON bad: $SJ"
claude_has_env ORCH_SESSION1=1 && pass "launch: ORCH_SESSION1 marker set" || fail "launch: no ORCH_SESSION1 marker"

# ---- close (teardown) -> next launch is a NEW conversation ------------------
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
reset_all
( cd / && timeout 60 bash "$DISPATCH" --teardown-project "$FIX" ) >/dev/null 2>&1
[[ ! -e "$SIDF" && -s "$HOME/.claude/projects/$slug/$sid.jsonl" ]] && pass "teardown: id file gone, transcript kept" || fail "teardown: id file/transcript state wrong"
write_envfile
run_launcher --gui-folder "$FIX" --env-file "$ENVFILE"; wait_claude
A="$(arg_lines)"; new="$(cat "$SIDF" 2>/dev/null)"
[[ "$A" == *$'--session-id\n'"$new"* && "$new" != "$sid" && "$A" != *"Show my open Notion tasks"* && "$A" != *--resume* ]] && seed_only && pass "after close: new --session-id, seed in the inbox" || fail "after close: $(echo "$A" | tr '\n' ' ')"

# ---- /clear hook: writes the id only for Session 1 with source=clear ---------
HOOK="$REPO_DIR/orchestration/hooks/orchestrator-clear.sh"
cid="11111111-2222-3333-4444-555555555555"
payload() { printf '{"source":"%s","session_id":"%s"}' "$1" "$2"; }
run_hook() { # marker source id
    ( cd "$FIX" && env -u ORCH_SESSION1 ${1:+ORCH_SESSION1=$1} bash "$HOOK" <<<"$(payload "$2" "$3")" ) >/dev/null 2>&1
}
run_hook "" clear "$cid"; [[ "$(cat "$SIDF")" != "$cid" ]] && pass "hook: no marker, no write" || fail "hook: wrote without marker"
run_hook 1 startup "$cid"; [[ "$(cat "$SIDF")" != "$cid" ]] && pass "hook: source=startup, no write" || fail "hook: wrote on startup"
run_hook 1 clear "not-a-uuid"; [[ "$(cat "$SIDF")" != "not-a-uuid" ]] && pass "hook: bad id rejected" || fail "hook: wrote bad id"
run_hook 1 clear "$cid"; [[ "$(cat "$SIDF")" == "$cid" ]] && pass "hook: marker+clear writes id" || fail "hook: did not write"

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
