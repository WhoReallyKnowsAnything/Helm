#!/bin/bash
# test/test-launch-gui-worktree.sh
# launch-claude.sh --gui-folder with a LINKED WORKTREE folder (D-01, AC9): the
# session is the main repository's, and every project-scoped write (the
# orchestrator-root pointer, the state store, the dashboard row) lands in the
# MAIN repository. Same private-server and stub setup as test-launch-gui-mode.sh
# (copied, not sourced): TMUX_TMPDIR in a scratch dir, never the default server;
# HOME is a scratch dir for every launcher run.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
command -v perl >/dev/null || { echo "SKIP: perl not installed"; exit 0; }
command -v timeout >/dev/null || { echo "SKIP: timeout not installed"; exit 0; }
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 not installed"; exit 0; }

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/lgw.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
STUB="$SCRATCH/stub"
CALLS="$SCRATCH/calls.log"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$STUB"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- stubs -----------------------------------------------------------------
printf '#!/bin/bash\n[[ "${1-}" == update ]] && exit 0\nsleep 300\n' >"$STUB/claude"
for s in lean-ctx headroom repowire; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
for s in osascript nohup pgrep; do printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 0\n' "$s" "$CALLS" >"$STUB/$s"; done
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"
ENVFILE="$SCRATCH/app.env"
printf 'PATH=%s\nHOME=%s\n' "$TOOLPATH" "$HOME" >"$ENVFILE"

RC=0
run_launcher() {
    RC=0
    timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" "$@" </dev/null >"$OUT" 2>"$ERR" || RC=$?
}
last_line() { tail -n 1 "$OUT"; }

# ---- fixture: a main repository and a linked worktree of it ---------------
MAIN="$SCRATCH/Main_Repo"
WT="$SCRATCH/wt-feature"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main 2>/dev/null
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
git -C "$MAIN" commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b feat "$WT"
WANT="$(basename "$MAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
MAIN_REAL="$(cd "$MAIN" && pwd -P)"
WT_REAL="$(cd "$WT" && pwd -P)"

# ---- start from the worktree folder ---------------------------------------
run_launcher --gui-folder "$WT" --env-file "$ENVFILE"
BASE="$(tmux_base_session_name "$WT")"
if [[ "$RC" -eq 0 && "$(last_line)" == "$BASE" && "$BASE" == "$WANT" ]]; then
    pass "AC9: a worktree folder starts (exit 0); the last line equals tmux_base_session_name and the main repository's slug"
else
    fail "AC9: rc=$RC last='$(last_line)' base='$BASE' want='$WANT' stderr: $(head -c 200 "$ERR")"
fi
T has-session -t "=$BASE" 2>/dev/null && pass "AC9: the session exists" || fail "AC9: no session '$BASE'"
[[ "$(T list-panes -t "=$BASE:=dashboard" -F '#{pane_current_path}' 2>/dev/null | head -1)" == "$WT_REAL" ]] && pass "AC9: the dashboard pane directory is the worktree folder" || fail "AC9: pane path '$(T list-panes -t "=$BASE:=dashboard" -F '#{pane_current_path}' 2>&1 | head -1)'"
if [[ -s "$MAIN/.claude/orchestrator-root" && ! -e "$WT/.claude/orchestrator-root" ]]; then pass "AC9: .claude/orchestrator-root is in the MAIN repository and not in the worktree"; else fail "AC9: orchestrator-root main=$([[ -e "$MAIN/.claude/orchestrator-root" ]] && echo yes || echo no) worktree=$([[ -e "$WT/.claude/orchestrator-root" ]] && echo yes || echo no)"; fi
DB="$MAIN/.claude/session-state.db"
row="$(sqlite3 "$DB" "SELECT status || '|' || worktree_path FROM sessions WHERE agent_id='dashboard';" 2>/dev/null)"
if [[ "$row" == "running|$WT" ]]; then pass "AC9: the dashboard row is in the main repository's state database (its path field is the worktree folder)"; else fail "AC9: dashboard row '$row'"; fi
if [[ -z "$(find "$WT" -maxdepth 3 -name '*.db' 2>/dev/null)" && ! -d "$WT/.claude" ]]; then pass "AC9: no state database and no .claude directory in the worktree"; else fail "AC9: the worktree was written to: $(ls -A "$WT" | tr '\n' ' ')"; fi

# ---- one shared session -----------------------------------------------------
run_launcher --gui-folder "$MAIN" --env-file "$ENVFILE"
if [[ "$RC" -eq 3 && "$(last_line)" == "$BASE" ]]; then pass "AC9: a later launch for the main folder reuses the same session (exit 3)"; else fail "AC9: main launch rc=$RC last='$(last_line)' stderr: $(head -c 200 "$ERR")"; fi

# ---- dispatch-task.sh --kill and --resume from the worktree folder ---------
# a worker made the way test-worker-resume.sh makes one: worktree, branch, state row, window
git -C "$MAIN" worktree add -q -b session/alpha "$MAIN/.claude/worktrees/alpha" main
echo work >"$MAIN/.claude/worktrees/alpha/alpha.txt"
git -C "$MAIN/.claude/worktrees/alpha" add alpha.txt
git -C "$MAIN/.claude/worktrees/alpha" commit -q -m "work on alpha"
sqlite3 "$DB" "INSERT INTO sessions (agent_id, worktree_path, status) VALUES ('alpha', '$MAIN/.claude/worktrees/alpha', 'running');"
T new-window -t "=$BASE:" -n alpha 'sleep 300'
T list-windows -t "=$BASE" -F '#{window_name}' | grep -qx alpha || fail "fixture: the worker window was not created"
( cd "$WT" && bash "$DISPATCH" --kill alpha ) >/dev/null 2>&1
if T list-windows -t "=$BASE" -F '#{window_name}' 2>/dev/null | grep -qx alpha; then fail "--kill from the worktree folder left the worker window"; else pass "AC9: --kill run from the worktree folder removes the window in that session"; fi
res="$(cd "$WT" && bash "$DISPATCH" --resume 2>&1)"; rrc=$?
if [[ "$rrc" -eq 0 ]] && ! grep -q 'does not exist' <<<"$res"; then pass "AC9: --resume run from the worktree folder exits 0 without the missing-session error"; else fail "--resume: rc=$rrc: $(head -c 200 <<<"$res")"; fi

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
