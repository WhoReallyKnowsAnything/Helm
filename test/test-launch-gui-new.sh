#!/bin/bash
# test/test-launch-gui-new.sh
# launch-claude.sh --gui-new <name> --github private|public|skip --env-file <file>:
# creates a project folder under PROJECTS_DIR (scaffold, one commit, optional GitHub
# repo and Notion row), then continues as --gui-folder. Runs the REAL launcher against
# a PRIVATE tmux server (TMUX_TMPDIR in a scratch dir, never the default server) with
# stub claude/lean-ctx/headroom/repowire/osascript/pgrep/nohup/gh first on
# PATH. PROJECTS_DIR, HOME and TMPDIR are scratch directories and NO_NOTION=1 is
# set by default, so nothing touches the real projects folder,
# GitHub or Notion. The launcher runs with no controlling terminal (setsid).

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

SCRATCH="$(mktemp -d /tmp/lgn.XXXXXX)" || exit 1
export TMUX_TMPDIR="$SCRATCH/t"
export TMPDIR="$SCRATCH/tmp"
export HOME="$SCRATCH/home"
export PROJECTS_DIR="$SCRATCH/projects"
export NO_NOTION=1
STUB="$SCRATCH/stub"
GHSTUB="$SCRATCH/ghstub"
CALLS="$SCRATCH/calls.log"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
ENVFILE="$SCRATCH/app.env"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR" "$HOME" "$STUB" "$GHSTUB" "$PROJECTS_DIR"
printf '[user]\n\tname = t\n\temail = t@t\n' >"$HOME/.gitconfig"
unset TMUX TMUX_PANE ORCH_PROJECT_ROOT GIT_CONFIG_COUNT
T() { "$REAL_TMUX" "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- stubs -----------------------------------------------------------------
printf '#!/bin/bash\nif [[ "${1-}" == update ]]; then exit 0; fi\nsleep 300\n' >"$STUB/claude"
for s in lean-ctx headroom repowire; do printf '#!/bin/bash\nexit 0\n' >"$STUB/$s"; done
for s in osascript nohup; do
    printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit 0\n' "$s" "$CALLS" >"$STUB/$s"
done
printf '#!/bin/bash\necho "pgrep $*" >>"%s"\nexit 0\n' "$CALLS" >"$STUB/pgrep"
# gh: log the call and add the remote the real gh adds; it fails while $SCRATCH/gh.fail exists
printf '#!/bin/bash\necho "gh $*" >>"%s"\n[[ -e "%s/gh.fail" ]] && exit 1\ngit remote add origin "https://github.com/t/$3.git"\nexit 0\n' "$CALLS" "$SCRATCH" >"$GHSTUB/gh"
chmod +x "$STUB"/* "$GHSTUB"/*

# PATH written into env files: stubs first, then the directories the launcher needs.
TOOLPATH="$STUB"
for tool in tmux git sqlite3 perl; do
    d="$(dirname "$(command -v "$tool")")"
    case ":$TOOLPATH:" in *":$d:"*) ;; *) TOOLPATH="$TOOLPATH:$d" ;; esac
done
TOOLPATH="$TOOLPATH:/usr/bin:/bin"

# mkbox dir tool...: a directory that holds the stubs, the base utilities and only the named tools
BASEUTILS="bash sh basename dirname sed tr cat cp mv rm mkdir chmod mktemp grep awk head tail sort find ls env uname wc cut touch ps sleep readlink id date sqlite3 perl uuidgen jq"
mkbox() {
    local d="$1" t; shift
    rm -rf "$d"; mkdir -p "$d"
    for t in $BASEUTILS "$@"; do ln -s "$(command -v "$t")" "$d/$t"; done
    cp "$STUB"/* "$d/"
}
BOX_FULL="$SCRATCH/box-full"; mkbox "$BOX_FULL" tmux git
BOX_NOTMUX="$SCRATCH/box-notmux"; mkbox "$BOX_NOTMUX" git
BOX_NOGIT="$SCRATCH/box-nogit"; mkbox "$BOX_NOGIT" tmux

# ---- helpers ---------------------------------------------------------------
write_envfile() { # [PATH value]
    {
        printf 'PATH=%s\n' "${1:-$TOOLPATH}"
        printf 'TERM=dumb\nCLAUDE_IN_TMUX=0\nHOME=%s\n' "$HOME"
    } >"$ENVFILE"
}
RC=0
run_launcher() { # args...
    RC=0
    timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" "$@" </dev/null >"$OUT" 2>"$ERR" || RC=$?
}
last_line() { grep . "$OUT" | tail -n 1; }
sessions() { T ls -F '#{session_name}' 2>/dev/null; }
listing() { ls -A "$PROJECTS_DIR" | tr '\n' ' '; }
reset_all() {
    T kill-server 2>/dev/null
    while T ls &>/dev/null; do sleep 0.05; done
    : >"$CALLS"
    rm -f "$SCRATCH/gh.fail"
}
expect_fail() { # label args...
    local label="$1" before; shift
    reset_all
    before="$(listing)"
    run_launcher "$@"
    if [[ "$RC" -eq 1 && -s "$ERR" && -z "$(sessions)" && "$(listing)" == "$before" ]]; then pass "$label -> exit 1, stderr text, no folder, no session"; else fail "$label: rc=$RC stderr='$(head -c 150 "$ERR")' sessions='$(sessions | tr '\n' ' ')' listing='$(listing)'"; fi
}

write_envfile
mkdir -p "$PROJECTS_DIR/keep-me"

# ---- validation: exit 1, nothing created -----------------------------------
expect_fail "bad name (leading dot)" --gui-new .hidden --github skip --env-file "$ENVFILE"
expect_fail "bad name (leading dash)" --gui-new -x --github skip --env-file "$ENVFILE"
expect_fail "bad name (slash)" --gui-new a/b --github skip --env-file "$ENVFILE"
expect_fail "bad name (space)" --gui-new "a b" --github skip --env-file "$ENVFILE"
expect_fail "bad name (65 chars)" --gui-new "$(printf 'a%.0s' {1..65})" --github skip --env-file "$ENVFILE"
expect_fail "empty name" --gui-new "" --github skip --env-file "$ENVFILE"
expect_fail "bad --github value" --gui-new okname --github maybe --env-file "$ENVFILE"
expect_fail "--github in upper case" --gui-new okname --github Private --env-file "$ENVFILE"
expect_fail "missing --github" --gui-new okname --env-file "$ENVFILE"
expect_fail "--github without a value" --gui-new okname --env-file "$ENVFILE" --github
expect_fail "missing --env-file" --gui-new okname --github skip
expect_fail "--env-file without a value" --gui-new okname --github skip --env-file
expect_fail "--gui-new without a value" --env-file "$ENVFILE" --github skip --gui-new
expect_fail "missing env file" --gui-new okname --github skip --env-file "$SCRATCH/nope.env"
touch "$SCRATCH/locked.env"; chmod 000 "$SCRATCH/locked.env"
expect_fail "unreadable env file" --gui-new okname --github skip --env-file "$SCRATCH/locked.env"
expect_fail "with --gui-folder" --gui-new okname --github skip --gui-folder "$SCRATCH" --env-file "$ENVFILE"
expect_fail "with --gui-root" --gui-new okname --github skip --gui-root --env-file "$ENVFILE"
write_envfile "$BOX_NOTMUX"
expect_fail "tmux not on the env file PATH" --gui-new okname --github skip --env-file "$ENVFILE"
write_envfile "$BOX_NOGIT"
expect_fail "git not on the env file PATH" --gui-new okname --github skip --env-file "$ENVFILE"
write_envfile "$BOX_FULL"
expect_fail "gh not on the env file PATH (private)" --gui-new okname --github private --env-file "$ENVFILE"
expect_fail "gh not on the env file PATH (public)" --gui-new okname --github public --env-file "$ENVFILE"

# ---- exit 4: the path exists -----------------------------------------------
write_envfile
mkdir -p "$PROJECTS_DIR/exists-dir"; echo keep >"$PROJECTS_DIR/exists-file"
for n in exists-dir exists-file; do
    reset_all
    before="$(listing)"
    run_launcher --gui-new "$n" --github skip --env-file "$ENVFILE"
    if [[ "$RC" -eq 4 && "$(cat "$ERR")" == "Error: $PROJECTS_DIR/$n already exists" && -z "$(sessions)" && "$(listing)" == "$before" ]]; then pass "exit 4 when $n exists"; else fail "exit 4 ($n): rc=$RC stderr='$(head -c 150 "$ERR")' listing='$(listing)'"; fi
done
[[ -z "$(ls -A "$PROJECTS_DIR/exists-dir")" && "$(cat "$PROJECTS_DIR/exists-file")" == keep ]] && pass "exit 4 leaves the existing path untouched" || fail "exit 4 changed the existing path"

# ---- success: skip GitHub, no gh on PATH, stdin closed ---------------------
write_envfile "$BOX_FULL"
reset_all
N=proj-new; F="$PROJECTS_DIR/$N"
RC=0
timeout 90 perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$LAUNCHER" --gui-new "$N" --github skip --env-file "$ENVFILE" <&- >"$OUT" 2>"$ERR" || RC=$?
BASE="$(tmux_base_session_name "$F")"
if [[ "$RC" -eq 0 && "$(last_line)" == "$BASE" ]]; then pass "success: exit 0, base name is the last stdout line (stdin closed, no gh)"; else fail "success: rc=$RC last='$(last_line)' stderr: $(head -c 300 "$ERR")"; fi
grep -qx "folder=$F" "$OUT" && pass "success: folder= line" || fail "success: no folder= line: $(cat "$OUT")"
grep -qx "repo=none" "$OUT" && pass "success: repo=none line" || fail "success: no repo=none line"
awk -v b="$BASE" '/^folder=/{a=NR} /^repo=/{r=NR} $0==b{c=NR} END{exit !(a && r && a<c && r<c)}' "$OUT" && pass "success: folder= and repo= come before the last line" || fail "success: line order: $(cat "$OUT")"
T has-session -t "=$BASE" 2>/dev/null && pass "success: the session exists on the private server" || fail "success: no session '$BASE'"
[[ "$(T list-panes -t "=$BASE:=dashboard" -F '#{pane_current_path}' 2>/dev/null | head -1)" == "$(cd "$F" && pwd -P)" ]] && pass "success: the dashboard pane directory is the new folder" || fail "success: pane path"
ok=true
for f in .git README.md .env.example .claude/settings.json .gitignore; do [[ -e "$F/$f" ]] || { ok=false; fail "success: missing $f"; }; done
$ok && pass "success: scaffold files exist"
[[ "$(cat "$F/README.md")" == "# $N" ]] && pass "success: README.md is '# name'" || fail "success: README.md: $(cat "$F/README.md")"
grep -qx '\.symdex/' "$F/.gitignore" && grep -qx '\.env' "$F/.gitignore" && pass "success: default .gitignore plus .symdex/" || fail "success: .gitignore: $(cat "$F/.gitignore")"
grep -q '"permissions"' "$F/.claude/settings.json" && pass "success: .claude/settings.json" || fail "success: settings.json"
[[ ! -e "$F/.claudeignore" ]] && pass "success: no .claudeignore without a template" || fail "success: unexpected .claudeignore"
[[ "$(git -C "$F" rev-list --count HEAD)" == 1 && "$(git -C "$F" log -1 --format=%s)" == "chore: initial project scaffold" ]] && pass "success: exactly 1 commit with the scaffold message" || fail "success: commits: $(git -C "$F" log --format=%s | tr '\n' '|')"
[[ "$(git -C "$F" ls-files | sort | tr '\n' ' ')" == ".claude/settings.json .env.example .gitignore README.md " ]] && git -C "$F" diff HEAD --quiet && pass "success: the whole scaffold is committed" || fail "success: tracked files: $(git -C "$F" ls-files | tr '\n' ' ')"
[[ ! -s "$CALLS" ]] && pass "success: no gh, watchdog or osascript call" || fail "success: calls: $(tr '\n' '|' <"$CALLS")"

# ---- templates, and reuse of a running session -----------------------------
mkdir -p "$HOME/.claude/templates"
printf 'TEMPLATE_MARK\n' >"$HOME/.claude/templates/gitignore"
printf 'CLAUDEIGNORE_MARK\n' >"$HOME/.claude/templates/claudeignore"
write_envfile
reset_all
N=Reuse.Proj; F="$PROJECTS_DIR/$N"; BASE="$(tmux_base_session_name "$F")"
T new-session -d -s "$BASE" "sleep 300"
run_launcher --gui-new "$N" --github skip --env-file "$ENVFILE"
if [[ "$RC" -eq 3 && "$(last_line)" == "$BASE" ]]; then pass "reuse: exit 3 and the base name last when the session already runs"; else fail "reuse: rc=$RC last='$(last_line)' stderr: $(head -c 300 "$ERR")"; fi
grep -qx 'TEMPLATE_MARK' "$F/.gitignore" && grep -qx '\.symdex/' "$F/.gitignore" && pass "template: .gitignore template plus .symdex/" || fail "template: .gitignore: $(cat "$F/.gitignore")"
grep -qx 'CLAUDEIGNORE_MARK' "$F/.claudeignore" && pass "template: .claudeignore copied" || fail "template: .claudeignore"
[[ "$(git -C "$F" ls-files | grep -c '^\.claudeignore$')" == 1 ]] && pass "template: .claudeignore is committed" || fail "template: .claudeignore not committed"

# ---- PROJECTS_DIR from the env file ----------------------------------------
write_envfile; printf 'PROJECTS_DIR=%s\n' "$SCRATCH/other-projects" >>"$ENVFILE"
mkdir -p "$SCRATCH/other-projects"
reset_all
run_launcher --gui-new viaenv --github skip --env-file "$ENVFILE"
if [[ "$RC" -eq 0 && -d "$SCRATCH/other-projects/viaenv/.git" && ! -e "$PROJECTS_DIR/viaenv" ]] && grep -qx "folder=$SCRATCH/other-projects/viaenv" "$OUT"; then pass "PROJECTS_DIR: the env file value is used"; else fail "PROJECTS_DIR from env file: rc=$RC out=$(head -c 200 "$OUT") err=$(head -c 200 "$ERR")"; fi

# ---- GitHub and Notion steps (stubs only) ------------------------
write_envfile "$GHSTUB:$TOOLPATH"
reset_all
run_launcher --gui-new ghpriv --github private --env-file "$ENVFILE"
F="$PROJECTS_DIR/ghpriv"
if [[ "$RC" -eq 0 ]] && grep -qx "repo=https://github.com/t/ghpriv.git" "$OUT" && grep -qx "gh repo create ghpriv --private --source=. --remote=origin --push" "$CALLS"; then pass "private: gh repo create called, repo= holds the URL"; else fail "private: rc=$RC out=$(head -c 200 "$OUT") calls=$(tr '\n' '|' <"$CALLS") err=$(head -c 200 "$ERR")"; fi
reset_all
run_launcher --gui-new ghpub --github public --env-file "$ENVFILE"
grep -qx "gh repo create ghpub --public --source=. --remote=origin --push" "$CALLS" && [[ "$RC" -eq 0 ]] && pass "public: gh repo create --public" || fail "public: rc=$RC calls=$(tr '\n' '|' <"$CALLS")"
reset_all
touch "$SCRATCH/gh.fail"
run_launcher --gui-new ghfail --github private --env-file "$ENVFILE"
if [[ "$RC" -eq 0 ]] && grep -q '^warning: github: ' "$ERR" && grep -qx "repo=none" "$OUT" && [[ "$(git -C "$PROJECTS_DIR/ghfail" rev-list --count HEAD)" == 1 ]]; then pass "gh failure: warning, repo=none, exit 0"; else fail "gh failure: rc=$RC err=$(head -c 200 "$ERR") out=$(head -c 200 "$OUT")"; fi
write_envfile
reset_all
NO_NOTION= run_launcher --gui-new nonotion --github skip --env-file "$ENVFILE"
if [[ "$RC" -eq 0 ]] && grep -q '^warning: notion: ' "$ERR"; then pass "notion failure: warning, exit 0"; else fail "notion failure: rc=$RC err=$(head -c 200 "$ERR")"; fi

# ---- exit 5: a required step fails, the folder stays ------------------------
write_envfile
reset_all
printf 'x\n' >"$HOME/.claude/templates/gitignore"; chmod 000 "$HOME/.claude/templates/gitignore"
run_launcher --gui-new fail-scaffold --github skip --env-file "$ENVFILE"
F="$PROJECTS_DIR/fail-scaffold"
if [[ "$RC" -eq 5 && -d "$F/.git" && -z "$(sessions)" ]] && grep -q 'step 2' "$ERR" && grep -qF "$F" "$ERR"; then pass "exit 5 when the scaffold fails, folder kept, stderr names step and folder"; else fail "exit 5 scaffold: rc=$RC err=$(head -c 300 "$ERR")"; fi
chmod 644 "$HOME/.claude/templates/gitignore"; printf 'TEMPLATE_MARK\n' >"$HOME/.claude/templates/gitignore"
reset_all
mkdir -p "$SCRATCH/hooks"; printf '#!/bin/sh\nexit 1\n' >"$SCRATCH/hooks/pre-commit"; chmod +x "$SCRATCH/hooks/pre-commit"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$SCRATCH/hooks" run_launcher --gui-new fail-commit --github skip --env-file "$ENVFILE"
F="$PROJECTS_DIR/fail-commit"
if [[ "$RC" -eq 5 && -f "$F/README.md" && -z "$(sessions)" ]] && grep -q 'step 4' "$ERR" && grep -qF "$F" "$ERR"; then pass "exit 5 when the commit fails, folder kept, stderr names step and folder"; else fail "exit 5 commit: rc=$RC err=$(head -c 300 "$ERR")"; fi

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
