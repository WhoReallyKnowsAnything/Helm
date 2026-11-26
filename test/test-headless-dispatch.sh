#!/bin/bash
# test/test-headless-dispatch.sh
# Headless dispatch (Phase 2, plan 4): the worker command comes from one shared
# builder, dispatch creates a tmux window and never an iTerm tab, and the row
# is stored with model and effort. tmux, claude and osascript are stubbed on
# PATH and ORCH_PROJECT_ROOT points at a disposable fixture repo (same idiom as
# test-dispatch-guard.sh), so no real worker or tab is ever created.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_MAIN=""
STUB_BIN=""
cleanup() {
    [ -n "$TMP_MAIN" ] && rm -rf "$TMP_MAIN"
    [ -n "$STUB_BIN" ] && rm -rf "$STUB_BIN"
}
trap cleanup EXIT

TMP_MAIN=$(mktemp -d)
git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email "test@example.com"
git -C "$TMP_MAIN" config user.name "Test"
echo "root" > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" commit -q -m "initial"
"$REPO_DIR/orchestration/init/init-state-store.sh" "$TMP_MAIN" >/dev/null 2>&1
DB="$TMP_MAIN/.claude/session-state.db"
BASE="$(basename "$TMP_MAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

export ORCH_PROJECT_ROOT="$TMP_MAIN"
# The ready wait is covered by test-dispatch-ready-wait.sh; stubs never write a log.
export DISPATCH_READY_TIMEOUT="${DISPATCH_READY_TIMEOUT:-0}"

# Stubs. tmux logs every call to $STUB_TMUX_LOG and keeps the last argument of
# new-window (the worker command) in $STUB_NW_FILE. STUB_TMUX_FAIL makes
# new-window fail. STUB_NW_RELEASE makes new-window wait until that file exists.
# list-windows prints $STUB_WINDOWS; has-session succeeds for a name found in
# $STUB_SESSIONS. osascript logs every call to $STUB_OSA_LOG and prints
# $STUB_OSA_ID when it is set (its stdin script is kept in $STUB_OSA_STDIN).
STUB_BIN=$(mktemp -d)
export STUB_TMUX_LOG="$STUB_BIN/tmux.log"
export STUB_NW_FILE="$STUB_BIN/new-window.cmd"
export STUB_WINDOWS="$STUB_BIN/windows"
export STUB_SESSIONS="$STUB_BIN/sessions"
export STUB_OSA_LOG="$STUB_BIN/osascript.log"
export STUB_OSA_STDIN="$STUB_BIN/osascript.stdin"
export STUB_DB="$DB"
cat > "$STUB_BIN/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_TMUX_LOG"
case "$1" in
    new-window)
        printf '%s' "${@: -1}" > "$STUB_NW_FILE"
        # the row must exist by now: record what the worker's hook would find
        sqlite3 "$STUB_DB" "SELECT status FROM sessions WHERE agent_id = '$5';" > "$STUB_NW_FILE.row" 2>/dev/null
        [ -n "${STUB_NW_REGISTER:-}" ] && echo "$5" >> "$STUB_WINDOWS"
        if [ -n "${STUB_NW_RELEASE:-}" ]; then
            while [ ! -e "$STUB_NW_RELEASE" ]; do sleep 0.1; done
        fi
        [ -z "${STUB_TMUX_FAIL:-}" ] ;;
    list-windows) [ -f "$STUB_WINDOWS" ] && cat "$STUB_WINDOWS"; exit 0 ;;
    has-session)
        [ -f "$STUB_SESSIONS" ] && grep -qxF -- "${3#=}" "$STUB_SESSIONS" ;;
    *) exit 0 ;;
esac
EOF
cat > "$STUB_BIN/osascript" <<'EOF'
#!/bin/bash
echo "call $*" >> "$STUB_OSA_LOG"
cat > "$STUB_OSA_STDIN"
[ -n "${STUB_OSA_ID:-}" ] && echo "$STUB_OSA_ID"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"
chmod +x "$STUB_BIN/tmux" "$STUB_BIN/osascript" "$STUB_BIN/claude"
# tmux_close_terminal_tab skips osascript when iTerm2 is not running: show one iTerm2
# process for `ps -Ao comm=` so the sweep's tab-close assertion holds on any host; every
# other ps call goes to the real ps.
cat > "$STUB_BIN/ps" <<'EOF'
#!/bin/bash
if [ "$*" = "-Ao comm=" ]; then echo /Applications/iTerm.app/Contents/MacOS/iTerm2; exit 0; fi
exec /bin/ps "$@"
EOF
chmod +x "$STUB_BIN/ps"

# dispatch <env assignments...> -- <args>: runs from the fixture root with the stubs
dispatch() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$TMP_MAIN" && env ${envs[@]+"${envs[@]}"} PATH="$STUB_BIN:$PATH" "$DISPATCH" "$@")
}
sql() { sqlite3 "$DB" "$1"; }

# --- Task 1: one launch-command builder -------------------------------------
# Expected strings were captured from the dispatch-task.sh that existed before
# the builder (stub tmux logging the new-window command); @DIR@ is the worktree,
# @ROOT@ the checkout holding orchestration/.
EXPECT_DEFAULT="cd '@DIR@' && command -v lean-ctx &>/dev/null && lean-ctx session task '@LABEL@'; claude update >/dev/null 2>&1 || true; tail -n +1 -f '@INBOX@' | { env -u TMUX CLAUDE_IN_TMUX=1 claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --model 'sonnet[1m]' --permission-mode auto --permission-prompt-tool stdio --name '@LABEL@' --append-system-prompt-file '@ROOT@/orchestration/prompts/worker-dependency-awareness.md'@ORCH@ >> '@OUT@'; kill 0; }"
EXPECT_OPUS="cd '@DIR@' && command -v lean-ctx &>/dev/null && lean-ctx session task '@LABEL@'; claude update >/dev/null 2>&1 || true; tail -n +1 -f '@INBOX@' | { env -u TMUX CLAUDE_IN_TMUX=1 claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --model 'opus' --effort 'high' --permission-mode auto --permission-prompt-tool stdio --name '@LABEL@' --append-system-prompt-file '@ROOT@/orchestration/prompts/worker-dependency-awareness.md'@ORCH@ >> '@OUT@'; kill 0; }"
source "$REPO_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null
# The worker is told its orchestrator's roster name (dashboard-<project>).
orch_flag() { printf " --append-system-prompt 'Your orchestrator session name in the peer roster is: %s. Use exactly this name as the SendMessage target for the orchestrator. Never use the bare name dashboard.'" "$(orch_session_name "$TMP_MAIN")"; }
expect() { # template label
    local s="$1"
    s="${s//@ORCH@/$(orch_flag)}"
    s="${s//@DIR@/$TMP_MAIN/.claude/worktrees/$2}"
    s="${s//@LABEL@/$2}"
    s="${s//@INBOX@/$TMP_MAIN/.claude/sessions/$2/inbox.jsonl}"
    s="${s//@OUT@/$TMP_MAIN/.claude/sessions/$2/out.jsonl}"
    printf '%s' "${s//@ROOT@/$REPO_DIR}"
}

dispatch -- hl-default "Default task" >/dev/null 2>&1
if [ "$(cat "$STUB_NW_FILE")" = "$(expect "$EXPECT_DEFAULT" hl-default)" ]; then
    pass "default dispatch gives tmux the saved command string"
else
    fail "default command differs: $(cat "$STUB_NW_FILE")"
fi
if [ "$(grep -o -- '--permission-prompt-tool stdio' "$STUB_NW_FILE" | wc -l | tr -d ' ')" = "1" ]; then
    pass "default dispatch command holds --permission-prompt-tool stdio once"
else
    fail "stdio flag count in default command: $(grep -o -- '--permission-prompt-tool stdio' "$STUB_NW_FILE" | wc -l)"
fi
if [ "$(sql "SELECT model || '|' || effort FROM sessions WHERE agent_id='hl-default'")" = "sonnet[1m]|" ]; then
    pass "default dispatch stores model sonnet[1m] and an empty effort"
else
    fail "default model/effort row: $(sql "SELECT model, effort FROM sessions WHERE agent_id='hl-default'")"
fi

dispatch DISPATCH_MODEL=opus DISPATCH_EFFORT=high -- hl-opus "Opus task" >/dev/null 2>&1
if [ "$(cat "$STUB_NW_FILE")" = "$(expect "$EXPECT_OPUS" hl-opus)" ]; then
    pass "opus/high dispatch gives tmux the saved command string"
else
    fail "opus/high command differs: $(cat "$STUB_NW_FILE")"
fi
if [ "$(sql "SELECT model || '|' || effort FROM sessions WHERE agent_id='hl-opus'")" = "opus|high" ]; then
    pass "opus/high dispatch stores model opus and effort high"
else
    fail "opus/high row: $(sql "SELECT model, effort FROM sessions WHERE agent_id='hl-opus'")"
fi

# The builder, extracted by name from the real file (not copied). Extracted, it
# resolves its prompt-file root from this test file's location, so the expected
# root for the two direct calls below is that, not the checkout.
eval "$(sed -n '/^_sq_quote() {/,/^}/p; /^_build_launch_cmd() {/,/^}/p' "$DISPATCH")"
DEF_DIR="$TMP_MAIN/.claude/worktrees/hl-r"
EXTRACTED_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null
SF="$TMP_MAIN/.claude/sessions/hl-r"
ORCH="$(orch_session_name "$TMP_MAIN")"
PLAIN_CMD="$(_build_launch_cmd hl-r "$DEF_DIR" 'sonnet[1m]' '' "$SF/inbox.jsonl" "$SF/out.jsonl")"
BASE_CMD="$(_build_launch_cmd hl-r "$DEF_DIR" 'sonnet[1m]' '' "$SF/inbox.jsonl" "$SF/out.jsonl" '' "$ORCH")"
RESUME_CMD="$(_build_launch_cmd hl-r "$DEF_DIR" 'sonnet[1m]' '' "$SF/inbox.jsonl" "$SF/out.jsonl" 'abc-123_DEF' "$ORCH")"
EXPECT_BASE="$(REPO_DIR="$EXTRACTED_ROOT"; expect "$EXPECT_DEFAULT" hl-r)"
# Quotes go through variables: bash 3.2 (macOS /bin/bash) keeps the backslash of \' inside ${var/pat/rep}.
SQ="'"; RESUME_FROM=" >> $SQ"; RESUME_TO=" --resume ${SQ}abc-123_DEF${SQ} >> $SQ"
EXPECT_RESUME="${EXPECT_BASE%%"$RESUME_FROM"*}${RESUME_TO}${EXPECT_BASE#*"$RESUME_FROM"}"
if [ "$BASE_CMD" = "$EXPECT_BASE" ] && [ "$RESUME_CMD" = "$EXPECT_RESUME" ]; then
    pass "a resume id adds only the --resume part, after the other flags"
else
    fail "resume command: $RESUME_CMD"
fi
PRE_CHANGE_FLAG=" --append-system-prompt-file '$EXTRACTED_ROOT/orchestration/prompts/worker-dependency-awareness.md'"
case "$PLAIN_CMD" in
    *"$PRE_CHANGE_FLAG >> "*) pass "--append-system-prompt-file text is byte-identical to the pre-change form" ;;
    *) fail "caller-check flag text changed: $PLAIN_CMD" ;;
esac
if BAD_OUT="$(_build_launch_cmd hl-r "$DEF_DIR" opus high "$SF/inbox.jsonl" "$SF/out.jsonl" "x'; touch $STUB_BIN/pwned; '" 2>/dev/null)"; then
    fail "a resume id with a quote and a semicolon was accepted"
elif [ -z "$BAD_OUT" ] && [ ! -e "$STUB_BIN/pwned" ]; then
    pass "a resume id with shell characters is refused and prints no command"
else
    fail "bad resume id printed output: $BAD_OUT"
fi
QUOTED="$(_sq_quote "it's a \$(x) dir")"
if [ "$(eval "printf %s $QUOTED")" = "it's a \$(x) dir" ]; then
    pass "a single quote in a value round-trips through the shell unchanged"
else
    fail "quote handling: $QUOTED"
fi

# --- Task 2: no iTerm tab, row first, dead on failure -------------------------
: > "$STUB_TMUX_LOG"; rm -f "$STUB_OSA_LOG" "$STUB_NW_FILE" "$STUB_NW_FILE.row"
ERR_OUT="$(dispatch -- hl-quiet "Quiet task" 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$STUB_OSA_LOG" ] && ! echo "$ERR_OUT" | grep -qi iterm \
    && grep -q '^new-window ' "$STUB_TMUX_LOG"; then
    pass "default dispatch: exit 0, tmux new-window ran, osascript never called, no iTerm warning"
else
    fail "headless dispatch: rc=$RC osascript-log=$(cat "$STUB_OSA_LOG" 2>/dev/null) stderr=$ERR_OUT"
fi
ROW="$(sql "SELECT status || '|' || ifnull(iterm_session_id,'NULL') || '|' || task_title || '|' || model FROM sessions WHERE agent_id='hl-quiet'")"
if [ "$ROW" = "running|NULL|Quiet task|sonnet[1m]" ]; then
    pass "default dispatch row: running, NULL iterm_session_id, the task title, the model"
else
    fail "default row: $ROW"
fi
if [ "$(cat "$STUB_NW_FILE.row")" = "running" ]; then
    pass "the row already existed (running) when tmux new-window ran"
else
    fail "row at new-window time: '$(cat "$STUB_NW_FILE.row" 2>/dev/null)'"
fi

# tmux window creation fails: exit 1, no worktree, no branch, row dead
ERR_OUT="$(dispatch STUB_TMUX_FAIL=1 -- hl-fail "Fail task" 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] && echo "$ERR_OUT" | grep -q "failed to create tmux window"; then
    pass "tmux window creation failure exits 1 with its error"
else
    fail "tmux failure: rc=$RC stderr=$ERR_OUT"
fi
if [ ! -e "$TMP_MAIN/.claude/worktrees/hl-fail" ] && [ -z "$(git -C "$TMP_MAIN" branch --list session/hl-fail)" ] \
    && [ "$(sql "SELECT status FROM sessions WHERE agent_id='hl-fail'")" = "dead" ]; then
    pass "a failed window leaves no worktree or branch and the row dead"
else
    fail "failed-window residue: wt=$(ls "$TMP_MAIN/.claude/worktrees" 2>/dev/null | tr '\n' ' ') branch=$(git -C "$TMP_MAIN" branch --list 'session/hl-fail') row=$(sql "SELECT status FROM sessions WHERE agent_id='hl-fail'")"
fi

# A worktree or branch that existed before this run is not this run's to delete.
git -C "$TMP_MAIN" worktree add -q -b session/hl-old "$TMP_MAIN/.claude/worktrees/hl-old" >/dev/null 2>&1
dispatch STUB_TMUX_FAIL=1 -- hl-old "Old work" >/dev/null 2>&1
if [ -d "$TMP_MAIN/.claude/worktrees/hl-old" ] && [ -n "$(git -C "$TMP_MAIN" branch --list session/hl-old)" ]; then
    pass "a failed dispatch leaves a worktree and branch it did not create"
else
    fail "a failed dispatch removed earlier work under hl-old"
fi

# A window with that exact name is a live worker: refuse, touch nothing.
echo "hl-quiet" > "$STUB_WINDOWS"
: > "$STUB_TMUX_LOG"
ROW_BEFORE="$(sql "SELECT * FROM sessions WHERE agent_id='hl-quiet'")"
ERR_OUT="$(dispatch -- hl-quiet "Quiet task" 2>&1 1>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ] && echo "$ERR_OUT" | grep -q "already exists" \
    && [ "$(sql "SELECT * FROM sessions WHERE agent_id='hl-quiet'")" = "$ROW_BEFORE" ] \
    && [ -d "$TMP_MAIN/.claude/worktrees/hl-quiet" ] && ! grep -q 'kill-' "$STUB_TMUX_LOG" \
    && ! grep -q '^new-window ' "$STUB_TMUX_LOG"; then
    pass "dispatch under a label with a live window exits 1 and changes nothing"
else
    fail "live-window guard: rc=$RC stderr=$ERR_OUT tmux-log=$(cat "$STUB_TMUX_LOG")"
fi
rm -f "$STUB_WINDOWS"

# --- Task 4: --launch-sweep removes the window of a dead or merged row, with or without a tab id; --kill too ---
mkrow() { # label status [iterm_id]
    sql "INSERT OR REPLACE INTO sessions (agent_id, worktree_path, status, iterm_session_id, task_title)
         VALUES ('$1', '/wt/$1', '$2', $( [ -n "${3:-}" ] && echo "'$3'" || echo NULL ), 'T $1');"
}
mkrow ls-dead dead
mkrow ls-merged merged
mkrow ls-run running
mkrow ls-deadid dead "w0t1p0:SW1"
mkrow ls-sib dead
mkrow ls-kill running
printf '%s\n' ls-dead ls-merged ls-run ls-deadid ls-sib-2 ls-kill > "$STUB_WINDOWS"
: > "$STUB_TMUX_LOG"; rm -f "$STUB_OSA_LOG" "$STUB_OSA_STDIN"
dispatch -- --launch-sweep >/dev/null 2>&1; RC=$?
has() { grep -qxF -- "$1" "$STUB_TMUX_LOG"; }
if [ "$RC" -eq 0 ] && has "kill-window -t =$BASE:=ls-dead" && has "kill-window -t =$BASE:=ls-merged" \
    && has "kill-window -t =$BASE:=ls-deadid"; then
    pass "--launch-sweep kills the window of a dead row, a merged row and a dead row with a tab id"
else
    fail "sweep kills: rc=$RC log=$(cat "$STUB_TMUX_LOG")"
fi
if ! grep -Eq '^kill-(window|session) .*ls-run' "$STUB_TMUX_LOG"; then
    pass "--launch-sweep leaves a running row's window alone"
else
    fail "sweep touched a running row: $(cat "$STUB_TMUX_LOG")"
fi
if ! grep -Eq '^kill-(window|session) .*ls-sib( |$)' "$STUB_TMUX_LOG"; then
    pass "--launch-sweep does not call the teardown for a dead row whose only look-alike window is ls-sib-2"
else
    fail "sweep reached a sibling's window: $(cat "$STUB_TMUX_LOG")"
fi
if [ "$(grep -c call "$STUB_OSA_LOG" 2>/dev/null)" = 1 ] && grep -q 'w0t1p0:SW1' "$STUB_OSA_STDIN"; then
    pass "--launch-sweep still closes the tab of the dead row that has an id, and only that one"
else
    fail "sweep tab close: calls=$(cat "$STUB_OSA_LOG" 2>/dev/null) stdin=$(cat "$STUB_OSA_STDIN" 2>/dev/null | head -3)"
fi

# --- Phase 6: --launch-sweep keeps a blocked row only while a live gate hold waits for it ---
mkrow ls-held blocked
mkrow ls-stale blocked
sleep 30 & HOLD_PID=$!
HOLD_DIR="$TMP_MAIN/.claude/gate-holds"; mkdir -p "$HOLD_DIR"
HOLD_START="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$HOLD_PID" | awk '{$1=$1; print}')"
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' ls-held "$(printf '%064d' 0)" "$HOLD_PID" "$(date +%s)" "/wt/ls-held" "$HOLD_START" "Bash: git push" > "$HOLD_DIR/toolu_held.pending"
dispatch -- --launch-sweep >/dev/null 2>&1; RC=$?
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
rm -f "$HOLD_DIR/toolu_held.pending"
if [ "$RC" -eq 0 ] && [ "$(sql "SELECT status FROM sessions WHERE agent_id='ls-held'")" = "blocked" ] \
    && [ "$(sql "SELECT status FROM sessions WHERE agent_id='ls-stale'")" = "running" ]; then
    pass "--launch-sweep keeps a blocked row with a live gate hold and resets one without a hold to running"
else
    fail "launch-sweep hold check: rc=$RC held=$(sql "SELECT status FROM sessions WHERE agent_id='ls-held'") stale=$(sql "SELECT status FROM sessions WHERE agent_id='ls-stale'")"
fi

: > "$STUB_TMUX_LOG"
dispatch -- --kill ls-kill >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && has "kill-window -t =$BASE:=ls-kill" \
    && [ "$(sql "SELECT status FROM sessions WHERE agent_id='ls-kill'")" = "dead" ]; then
    pass "--kill on a headless row (no tab id) kills its window and marks it dead"
else
    fail "kill headless: rc=$RC log=$(cat "$STUB_TMUX_LOG")"
fi
rm -f "$STUB_WINDOWS"

# --- Task 5: an interrupt between the row write and the window undoes the dispatch ---
# The stub's new-window registers the window, then blocks on a release file, so
# the signal lands exactly in that gap. perl resets the signal first: a job
# started with & has SIGINT ignored, and an ignored signal cannot be trapped.
sig_case() { # SIGNAL label
    local sig="$1" lbl="$2" rel="$STUB_BIN/release-$2" pid rc i here="$PWD"
    rm -f "$rel" "$STUB_WINDOWS" "$STUB_NW_FILE.row"; : > "$STUB_TMUX_LOG"
    # backgrounded directly (no wrapper subshell) so $! is the dispatch process itself
    cd "$TMP_MAIN"
    STUB_NW_RELEASE="$rel" STUB_NW_REGISTER=1 PATH="$STUB_BIN:$PATH" \
        perl -e '$SIG{$_}="DEFAULT" for qw(INT TERM HUP); exec @ARGV' "$DISPATCH" "$lbl" "Signal task" >/dev/null 2>"$STUB_BIN/sig.err" &
    pid=$!
    cd "$here"
    for i in $(seq 1 100); do
        [ -e "$STUB_NW_FILE.row" ] && [ "$(sql "SELECT status FROM sessions WHERE agent_id='$lbl'")" = "running" ] && break
        sleep 0.1
    done
    kill -s "$sig" "$pid"; touch "$rel"
    wait "$pid"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$(sql "SELECT status FROM sessions WHERE agent_id='$lbl'")" = "dead" ] \
        && [ ! -e "$TMP_MAIN/.claude/worktrees/$lbl" ] && [ -z "$(git -C "$TMP_MAIN" branch --list "session/$lbl")" ] \
        && grep -qxF "kill-window -t =$BASE:=$lbl" "$STUB_TMUX_LOG" && grep -q 'interrupted' "$STUB_BIN/sig.err"; then
        pass "$sig between the row write and the window: exit non-zero, row dead, no worktree or branch, window killed"
    else
        fail "$sig case: rc=$rc row=$(sql "SELECT status FROM sessions WHERE agent_id='$lbl'") wt=$(ls "$TMP_MAIN/.claude/worktrees" | tr '\n' ' ') tmux=$(cat "$STUB_TMUX_LOG") err=$(cat "$STUB_BIN/sig.err")"
    fi
}
sig_case TERM hl-sig-term
sig_case INT hl-sig-int
sig_case HUP hl-sig-hup
rm -f "$STUB_WINDOWS"

# After all that, a normal dispatch in the same fixture still ends running with a live worktree.
dispatch -- hl-after "After task" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && [ "$(sql "SELECT status FROM sessions WHERE agent_id='hl-after'")" = "running" ] \
    && [ -d "$TMP_MAIN/.claude/worktrees/hl-after" ]; then
    pass "a normal dispatch after the interrupted ones exits 0 with a running row and a live worktree"
else
    fail "dispatch after interrupts: rc=$RC row=$(sql "SELECT status FROM sessions WHERE agent_id='hl-after'")"
fi
# The trap must be gone once the window exists: it is cleared after the
# tmux_ensure_window call and set after the row write, in that order.
TRAP_SET="$(grep -n '^trap _dispatch_interrupted INT TERM HUP' "$DISPATCH" | cut -d: -f1)"
WIN_MK="$(grep -n 'tmux_ensure_window "\$BASE_SESSION" "\$_label" "\$_worker_cmd"' "$DISPATCH" | cut -d: -f1)"
TRAP_CLR="$(grep -n '^trap - INT TERM HUP' "$DISPATCH" | cut -d: -f1)"
if [ -n "$TRAP_SET" ] && [ -n "$WIN_MK" ] && [ -n "$TRAP_CLR" ] && [ "$TRAP_SET" -lt "$WIN_MK" ] && [ "$WIN_MK" -lt "$TRAP_CLR" ]; then
    pass "the trap is set before the window call and cleared right after it"
else
    fail "trap order: set=$TRAP_SET window=$WIN_MK clear=$TRAP_CLR"
fi

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
