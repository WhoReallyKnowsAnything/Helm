#!/bin/bash
# test/test-teardown-mode.sh
# dispatch-task.sh --teardown-project <absolute-folder> (Phase 2 plan 2; AC3, AC9,
# AC10; CONTEXT D-05, D-13, D-14): stops one project's orchestrator by folder, from
# any working directory, and leaves its state alone so a launch plus --resume brings
# the workers back. Runs the REAL launcher and dispatch-task.sh against a PRIVATE
# tmux server (TMUX_TMPDIR in a scratch dir, exported before any tmux call, never the
# default server) with stub claude/lean-ctx/headroom/repowire/osascript/pgrep/nohup
# first on PATH. HOME is a scratch directory for every launcher run. The setup is
# copied from test-launch-gui-mode.sh, not sourced.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
# shellcheck source=../orchestration/lib/tmux-session.sh
source "$REPO_DIR/orchestration/lib/tmux-session.sh"

REAL_TMUX="$(command -v tmux)" || { echo "SKIP: tmux not installed"; exit 0; }
# Private tmux server by socket name. Set after REAL_TMUX: with it set, sourcing
# tmux-session.sh defines a tmux() function and command -v would return its name.
# The launcher and dispatch run as child processes and read it from the environment.
export ORCH_TMUX_SOCKET="tdm-$$"
for tool in perl timeout sqlite3 git; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/tdm.XXXXXX)" || exit 1
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
T() { "$REAL_TMUX" -L "$ORCH_TMUX_SOCKET" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- stubs -----------------------------------------------------------------
cat >"$STUB/claude" <<STUBCLAUDE
#!/bin/bash
if [[ "\${1-}" == update ]]; then exit 0; fi
printf '%s\0' "\$@" >"$CLAUDELOG/.args.\$\$" && mv "$CLAUDELOG/.args.\$\$" "$CLAUDELOG/args.\$\$"
sleep 300
STUBCLAUDE
for s in lean-ctx headroom repowire; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
for s in osascript nohup pgrep; do
    printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 0\n' "$s" "$CALLS" >"$STUB/$s"
done
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"
ENVFILE="$SCRATCH/app.env"
printf 'PATH=%s\nTERM=dumb\nCLAUDE_IN_TMUX=0\nHOME=%s\n' "$TOOLPATH" "$HOME" >"$ENVFILE"

# ---- helpers ---------------------------------------------------------------
RC=0
run_launcher() { # args...
    RC=0
    timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" "$@" </dev/null >"$OUT" 2>"$ERR" || RC=$?
}
launch() { run_launcher --gui-folder "$1" --env-file "$ENVFILE"; }
# teardown folder [ORCH_PROJECT_ROOT value]: always from /, ORCH_PROJECT_ROOT unset unless given
run_teardown() {
    RC=0
    local -a e=(env -u ORCH_PROJECT_ROOT)
    if [[ -n "${2-}" ]]; then e=(env "ORCH_PROJECT_ROOT=$2"); fi
    ( cd / && "${e[@]}" timeout 60 bash "$DISPATCH" --teardown-project "$1" ) >"$OUT" 2>"$ERR" || RC=$?
}
all_sessions() { T ls -F '#{session_name}' 2>/dev/null | sort; }
group_members() { # base: the base and every session of its group
    T ls -F '#{session_name}:#{session_group}' 2>/dev/null | awk -F: -v b="$1" '$1 == b || $2 == b { print $1 }' | sort
}
mkgit() { # dir
    mkdir -p "$1"
    ( cd "$1" && command git init -q -b main 2>/dev/null && command git config user.email t@t && command git config user.name t \
        && command git commit -q --allow-empty -m init )
}
slug_of() { basename "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
# the state teardown must not change: rows, worktrees, branches, the worktree directory
snap() { # project folder
    sqlite3 "$1/.claude/session-state.db" "SELECT * FROM sessions ORDER BY agent_id;" 2>&1
    git -C "$1" worktree list
    git -C "$1" branch --list
    ls "$1/.claude/worktrees" 2>&1
}
add_worker() { # project label session-id: worktree on session/<label> with a commit, a row, a window
    local p="$1" l="$2" sid="$3" base
    base="$(tmux_base_session_name "$p")"
    git -C "$p" worktree add -q -b "session/$l" "$p/.claude/worktrees/$l" main
    echo "work $l" >"$p/.claude/worktrees/$l/$l.txt"
    git -C "$p/.claude/worktrees/$l" add "$l.txt"
    git -C "$p/.claude/worktrees/$l" -c user.email=t@e.com -c user.name=T commit -q -m "work on $l"
    "$REPO_DIR/orchestration/init/init-state-store.sh" "$p" >/dev/null 2>&1
    sqlite3 "$p/.claude/session-state.db" "INSERT INTO sessions (agent_id, worktree_path, status, claude_session_id) VALUES ('$l', '$p/.claude/worktrees/$l', 'running', '$sid');"
    T new-window -t "=$base:" -n "$l" 'sleep 300'
}
add_clients() { # base
    T new-session -d -t "=$1" -s "$1-one"
    T new-session -d -t "=$1" -s "$1-two"
}

# ---- fixture: projects A and B (B's name is A's plus a dash) and a third ----
A="$SCRATCH/proj-alpha"; B="$SCRATCH/proj-alpha-2"
mkgit "$A"; mkgit "$B"
A_BASE="$(tmux_base_session_name "$A")"; B_BASE="$(tmux_base_session_name "$B")"
launch "$A"; [[ "$RC" -eq 0 ]] || fail "fixture: launching A failed rc=$RC: $(head -c 200 "$ERR")"
launch "$B"; [[ "$RC" -eq 0 ]] || fail "fixture: launching B failed rc=$RC: $(head -c 200 "$ERR")"
add_clients "$A_BASE"
T new-session -d -t "=$B_BASE" -s "$B_BASE-dashboard"
add_worker "$A" alpha sid-alpha
mkdir -p "$A/.claude/sessions/alpha"
printf 'queued\n' > "$A/.claude/sessions/alpha/inbox.jsonl"
printf 'history\n' > "$A/.claude/sessions/alpha/out.jsonl"
B_BEFORE="$(group_members "$B_BASE")"
[[ -n "$(group_members "$A_BASE")" && -n "$B_BEFORE" ]] && pass "fixture: A and B both have sessions" || fail "fixture: A or B has no session"

# ---- AC3 + AC10: from /, no ORCH_PROJECT_ROOT ----
A_STATE="$(snap "$A")"
run_teardown "$A"
[[ "$RC" -eq 0 ]] && pass "AC3: teardown from / with ORCH_PROJECT_ROOT unset exits 0" || fail "AC3: rc=$RC stderr: $(head -c 200 "$ERR")"
[[ -z "$(group_members "$A_BASE")" ]] && pass "AC3: no session of A's group remains" || fail "AC3: A sessions remain: $(group_members "$A_BASE" | tr '\n' ' ')"
[[ "$(group_members "$B_BASE")" == "$B_BEFORE" ]] && pass "AC10: every session of B is alive" || fail "AC10: B changed: $(group_members "$B_BASE" | tr '\n' ' ')"
T ls >/dev/null 2>&1 && pass "AC10: tmux ls still answers" || fail "AC10: the tmux server is gone"
[[ "$(snap "$A")" == "$A_STATE" ]] && pass "AC3: A's rows, worktrees, branches and directory are unchanged" || fail "AC3: A's state changed"
[[ "$(cat "$A/.claude/sessions/alpha/out.jsonl")" == history && -f "$A/.claude/sessions/alpha/inbox.jsonl" && ! -s "$A/.claude/sessions/alpha/inbox.jsonl" ]] \
    && pass "D-03: teardown keeps the out log and empties the inbox" || fail "D-03: session files after teardown are wrong"

# ---- AC3: a new launch plus --resume brings the worker back ----
rm -f "$CLAUDELOG"/*
launch "$A"
[[ "$RC" -eq 0 ]] && pass "AC3: a new launch of A exits 0" || fail "AC3: relaunch rc=$RC: $(head -c 200 "$ERR")"
RES="$(cd "$A" && env -u ORCH_PROJECT_ROOT timeout 60 bash "$DISPATCH" --resume 2>&1)"
echo "$RES" | grep -qxF "resumed alpha" && pass "AC3: --resume prints 'resumed alpha'" || fail "AC3: --resume output: $RES"
got=1
for _ in $(seq 1 50); do
    if cat "$CLAUDELOG"/args.* 2>/dev/null | tr '\0' ' ' | grep -q -- '--resume sid-alpha'; then got=0; break; fi
    sleep 0.2
done
[[ "$got" -eq 0 ]] && pass "AC3: claude was started with --resume sid-alpha" || fail "AC3: claude never got --resume sid-alpha"

# ---- AC10: a second run with ORCH_PROJECT_ROOT pointing at B is ignored ----
add_clients "$A_BASE"
A_STATE="$(snap "$A")"
run_teardown "$A" "$B"
[[ "$RC" -eq 0 ]] && pass "AC10: teardown with ORCH_PROJECT_ROOT=B exits 0" || fail "AC10: rc=$RC stderr: $(head -c 200 "$ERR")"
[[ -z "$(group_members "$A_BASE")" ]] && pass "AC10: A is gone though ORCH_PROJECT_ROOT named B" || fail "AC10: A sessions remain"
[[ "$(group_members "$B_BASE")" == "$B_BEFORE" ]] && pass "AC10: B untouched though ORCH_PROJECT_ROOT named B" || fail "AC10: B changed"
[[ "$(snap "$A")" == "$A_STATE" ]] && pass "AC10: A's state unchanged" || fail "AC10: A's state changed"

# ---- AC9: a linked worktree folder names the main repository's session ----
MAIN="$SCRATCH/Main_Repo"; WT="$SCRATCH/wt-feature"
mkgit "$MAIN"
command git -C "$MAIN" worktree add -q -b feat "$WT"
C_BASE="$(tmux_base_session_name "$WT")"
launch "$WT"
[[ "$C_BASE" == "$(slug_of "$MAIN")" ]] && T has-session -t "=$C_BASE" 2>/dev/null \
    && pass "AC9: fixture session is named after the main repository" || fail "AC9: fixture base '$C_BASE'"
run_teardown "$WT"
[[ "$RC" -eq 0 ]] && ! T has-session -t "=$C_BASE" 2>/dev/null \
    && pass "AC9: teardown of the worktree folder removes the main repository's session" || fail "AC9: rc=$RC session still there"
[[ "$(group_members "$B_BASE")" == "$B_BEFORE" ]] && pass "AC9: B still untouched" || fail "AC9: B changed"

# ---- no session for the folder: exit 0 with a message ----
LONELY="$SCRATCH/lonely"; mkgit "$LONELY"
BEFORE="$(all_sessions)"
run_teardown "$LONELY"
[[ "$RC" -eq 0 ]] && grep -qi 'no session' "$OUT" && pass "no session: exit 0 with a message" || fail "no session: rc=$RC out: $(head -c 200 "$OUT")"
[[ "$(all_sessions)" == "$BEFORE" ]] && pass "no session: nothing else changed" || fail "no session: sessions changed"

# ---- refusals: relative path, missing folder, empty base name ----
run_teardown "proj-alpha-2"
[[ "$RC" -eq 1 && -s "$ERR" ]] && pass "a relative path exits 1 with a stderr reason" || fail "relative: rc=$RC err: $(head -c 200 "$ERR")"
run_teardown "$SCRATCH/does-not-exist"
[[ "$RC" -eq 1 && -s "$ERR" ]] && pass "a missing folder exits 1 with a stderr reason" || fail "missing: rc=$RC err: $(head -c 200 "$ERR")"
run_teardown ""
[[ "$RC" -eq 1 && -s "$ERR" ]] && pass "an empty folder argument exits 1 with a stderr reason" || fail "empty arg: rc=$RC err: $(head -c 200 "$ERR")"
BEFORE="$(all_sessions)"
run_teardown "/"
[[ "$RC" -eq 1 && -s "$ERR" ]] && pass "R1: a folder with an empty base name exits 1 with a stderr reason" || fail "R1: rc=$RC err: $(head -c 200 "$ERR")"
[[ "$(all_sessions)" == "$BEFORE" ]] && pass "R1: no session was killed" || fail "R1: sessions changed"

# ---- R2: no tmux server running ----
T kill-server 2>/dev/null
while T ls &>/dev/null; do sleep 0.05; done
run_teardown "$A"
[[ "$RC" -eq 0 ]] && grep -qi 'no session' "$OUT" && pass "R2: no server exits 0 with the no-session message" || fail "R2: rc=$RC out: $(head -c 200 "$OUT") err: $(head -c 200 "$ERR")"
T ls &>/dev/null && fail "R2: teardown started a tmux server" || pass "R2: teardown did not start a tmux server"

# ---- no kill-server in the mode ----
[[ "$(grep -c 'kill-server' "$DISPATCH")" -eq 0 ]] && pass "dispatch-task.sh has no kill-server" || fail "dispatch-task.sh contains kill-server"

[[ "$FAILS" -eq 0 ]] && echo "ALL PASSED" || echo "$FAILS FAILED"
[[ "$FAILS" -eq 0 ]]
