#!/bin/bash
set -euo pipefail

# orchestration/lib/dispatch-task.sh
# Headless worker launcher: creates the worker's git worktree and tmux window,
# writes its session row first, and launches claude with a deterministic --name.
# It creates no iTerm tab.
# Args:
#   $1 = _label (agent label for this session; used to create worktree and claude --name)
# Exit codes:
#   0 = success (tmux worker started; no tab is created)
#   1 = worktree or tmux window creation failed (the row is left dead)

_slugify() {
    local raw="$1" slug
    slug=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')
    [[ -z "$slug" ]] && slug="task-$(date +%s)"
    printf '%s' "$slug"
}
# _sq_quote value: prints value single-quoted for a shell command line, each
# ' inside it written as '\'' (sed, not ${v//\'/...}: bash 3.2 mis-substitutes
# that idiom, see session-state.sh set_task_title).
_sq_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
# _build_launch_cmd label session_dir model effort inbox out [claude_session_id] [orch_name]
# Prints the command line a worker's tmux window runs. One builder for dispatch
# and resume (D-16). An empty effort leaves out --effort. A claude_session_id
# adds --resume after the other flags (the spike accepts either order); it ends
# up inside a shell command, so anything outside [A-Za-z0-9_-]{1,128} is refused.
# orch_name is the orchestrator's roster name; it is told to the worker through
# --append-system-prompt so SendMessage reaches its own project's orchestrator.
# The headless pipeline (inbox in, out log out) comes from tmux_headless_cmd.
_build_launch_cmd() {
    local label="$1" session_dir="$2" model="$3" effort="$4" inbox="$5" out="$6" resume_id="${7:-}" orch_name="${8:-}"
    local script_dir effort_flag="" resume_flag="" orch_flag="" resume_re='^[A-Za-z0-9_-]{1,128}$'
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [[ -n "$effort" ]]; then
        effort_flag=" --effort $(_sq_quote "$effort")"
    fi
    if [[ -n "$resume_id" ]]; then
        if ! [[ "$resume_id" =~ $resume_re ]]; then
            echo "dispatch-task.sh: refusing a Claude session id with unexpected characters" >&2
            return 1
        fi
        resume_flag=" --resume $(_sq_quote "$resume_id")"
    fi
    if [[ -n "$orch_name" ]]; then
        orch_flag=" --append-system-prompt $(_sq_quote "Your orchestrator session name in the peer roster is: $orch_name. Use exactly this name as the SendMessage target for the orchestrator. Never use the bare name dashboard.")"
    fi
    # Rules in the system prompt, not in message 0 (worker-rules.sh): the window shell
    # reads the file at start, so the tmux command stays short. Only one inline
    # --append-system-prompt is honoured, so the orchestrator-name line goes in the
    # same file. On any failure the worker launches the old way.
    local rules_file="" rules_root env_rules=""
    source "$script_dir/orchestration/lib/worker-rules.sh" 2>/dev/null || true
    # PROJECT_ROOT first: at dispatch the worktree does not exist yet, so a git lookup
    # from session_dir fails (that silently dropped every fresh worker to the old launch).
    rules_root="${PROJECT_ROOT:-}"
    if [[ -z "$rules_root" ]]; then
        rules_root="$(git -C "$session_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
            && rules_root="$(cd "$rules_root/.." && pwd)" || rules_root=""
    fi
    if [[ -n "$rules_root" ]] && declare -F worker_rules_file >/dev/null \
        && rules_file="$(worker_rules_file "$rules_root" "$orch_name" 2>/dev/null)"; then
        orch_flag=" --append-system-prompt \"\$(cat $(_sq_quote "$rules_file"))\""
        env_rules=" CLAUDE_CODE_DISABLE_CLAUDE_MDS=1"
    else
        echo "dispatch-task.sh: worker rules file not built for '$label'; launching without the rules-in-system-prompt setup" >&2
    fi
    # env -u TMUX: see launch-claude.sh -- Claude Code drops to 256-colour with TMUX set
    local claude_cmd pipeline
    claude_cmd="env -u TMUX CLAUDE_IN_TMUX=1${env_rules} claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages --model $(_sq_quote "$model")${effort_flag} --permission-mode auto --permission-prompt-tool stdio --name $(_sq_quote "$label") --append-system-prompt-file $(_sq_quote "$script_dir/orchestration/prompts/worker-dependency-awareness.md")${orch_flag}${resume_flag}"
    pipeline="$(tmux_headless_cmd "$inbox" "$out" "$claude_cmd")" || return 1
    printf '%s' "cd $(_sq_quote "$session_dir") && command -v lean-ctx &>/dev/null && lean-ctx session task $(_sq_quote "$label"); claude update >/dev/null 2>&1 || true; ${pipeline}"
}
# _tmux_window_exists base label: succeeds when session base has a window named
# exactly label. The = prefix makes tmux match the session name exactly; the
# window names are compared here, so a window "foo-2" never counts as "foo".
_tmux_window_exists() {
    local wins
    [[ -n "$1" ]] || return 1
    wins="$(tmux list-windows -t "=$1" -F '#{window_name}' 2>/dev/null)" || return 1
    [[ $'\n'"$wins"$'\n' == *$'\n'"$2"$'\n'* ]]
}
# _teardown_if_present base label: tmux_teardown_worker, but only when a window
# or grouped session with exactly that name exists. The helper's own targets are
# prefix-matched by tmux, so on a label that is already gone it could kill a
# sibling such as "label-2"; this check keeps that case from being reached.
_teardown_if_present() {
    [[ -n "$1" ]] || return 0
    declare -f tmux_teardown_worker &>/dev/null || return 0
    if _tmux_window_exists "$1" "$2" || tmux has-session -t "=$1-$2" 2>/dev/null; then
        tmux_teardown_worker "$1" "$2"
    fi
}
# Target project: ORCH_PROJECT_ROOT, else the project containing the caller's cwd.
# --git-common-dir, not --show-toplevel: from inside a linked worktree the latter
# returns the worktree itself (see session-state.sh:8-14). No shared pointer file:
# with sessions in several projects, whichever launched last would win.
_resolve_project_root() {
    if [[ -n "${ORCH_PROJECT_ROOT:-}" ]]; then
        printf '%s' "$ORCH_PROJECT_ROOT"
        return 0
    fi
    local common
    if ! common="$(command git rev-parse --git-common-dir 2>/dev/null)"; then
        echo "dispatch-task.sh: cannot resolve the target project: not inside a git repository (cd into the project or set ORCH_PROJECT_ROOT)" >&2
        return 1
    fi
    (cd "$common/.." && pwd)
}
if [[ "${1:-}" == "--slugify" ]]; then
    _raw_title="${2:-}"
    _slug="$(_slugify "$_raw_title")"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    _base_slug="$_slug"
    _suffix=1
    while command git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/session/$_slug" 2>/dev/null; do
        _existing_status=$(session_state_read "$_slug" 2>/dev/null)
        if [[ "$_existing_status" != "running" && "$_existing_status" != "blocked" ]]; then
            break
        fi
        _suffix=$((_suffix + 1))
        _slug="${_base_slug}-${_suffix}"
    done
    echo "$_slug"
    exit 0
fi
if [[ "${1:-}" == "--add-dependency" ]]; then
    _dep_label="${2:?--add-dependency needs a dependent label}"
    _up_label="${3:?--add-dependency needs an upstream label}"
    _dep_artifact="${4:?--add-dependency needs an artifact}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    _add_dep_rc=0
    _add_dep_status="$(session_state_add_dependency "$_dep_label" "$_up_label" "$_dep_artifact")" || _add_dep_rc=$?
    echo "$_add_dep_status"
    exit "$_add_dep_rc"
fi
if [[ "${1:-}" == "--artifact-exists" ]]; then
    _ae_up="${2:?--artifact-exists needs an upstream label}"
    _ae_artifact="${3:?--artifact-exists needs an artifact}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    # T-21-01: <artifact> is untrusted free text. It stays a quoted positional
    # argv element here -- never eval'd, never composed into a shell string.
    # Probe order matters: a finished upstream commits to session/<label> and
    # never merges, so its file exists only on that branch and the plain
    # main-checkout test (last) returns false for it.
    # A session/* branch exists from dispatch time, so its mere existence proves
    # nothing. Satisfied only with commits ahead of HEAD, or once merged with a
    # merge commit; a fast-forward merge is indistinguishable from a fresh branch.
    # Decided here alone: the cat-file probe below would also resolve the name.
    if [[ "$_ae_artifact" == session/* ]] \
        && command git -C "$PROJECT_ROOT" show-ref --verify --quiet -- "refs/heads/$_ae_artifact" 2>/dev/null; then
        _ae_ahead="$(command git -C "$PROJECT_ROOT" rev-list --count "HEAD..refs/heads/$_ae_artifact" 2>/dev/null || echo 0)"
        _ae_tip="$(command git -C "$PROJECT_ROOT" rev-parse "refs/heads/$_ae_artifact" 2>/dev/null)"
        if [[ "$_ae_ahead" -gt 0 ]] \
            || command git -C "$PROJECT_ROOT" log --merges --format=%P HEAD 2>/dev/null | grep -q " $_ae_tip"; then
            exit 0
        fi
        exit 1
    fi
    if command git -C "$PROJECT_ROOT" show-ref --verify --quiet -- "refs/heads/$_ae_artifact" 2>/dev/null \
        || command git -C "$PROJECT_ROOT" cat-file -e "session/$_ae_up:$_ae_artifact" 2>/dev/null \
        || command git -C "$PROJECT_ROOT" cat-file -e "$_ae_artifact^{commit}" 2>/dev/null \
        || [[ -e "$PROJECT_ROOT/$_ae_artifact" ]]; then
        exit 0
    fi
    exit 1
fi
# --cycle-open: exit 0 = a cycle is open (roadmap holds >= 1 phase), 1 = none
# (0 phases, or no .planning/), 2 = script error. Reads no task text and takes
# no further arguments; every value stays a quoted argv element, never eval'd.
if [[ "${1:-}" == "--cycle-open" ]]; then
    _co_err() { echo "dispatch-task.sh: --cycle-open: $1" >&2; exit 2; }
    PROJECT_ROOT="$(_resolve_project_root)" || exit 2
    [[ -d "$PROJECT_ROOT/.planning" ]] || exit 1
    command -v jq >/dev/null 2>&1 || _co_err "jq not found"
    command -v node >/dev/null 2>&1 || _co_err "node not found"
    _co_plugins="$HOME/.claude/plugins/installed_plugins.json"
    [[ -f "$_co_plugins" ]] || _co_err "no plugins file at $_co_plugins"
    _co_install=""
    _co_install="$(jq -r '[.plugins["cadence@cadence"][]?.installPath // empty][0] // empty' "$_co_plugins" 2>/dev/null)" || _co_install=""
    [[ -n "$_co_install" ]] || _co_err "no cadence@cadence entry"
    _co_planning="$_co_install/cadence-core/bin/planning.mjs"
    [[ -f "$_co_planning" ]] || _co_err "planning.mjs not found"
    _co_out=""
    _co_rc=0
    _co_out="$(node "$_co_planning" status --dir "$PROJECT_ROOT/.planning" 2>/dev/null)" || _co_rc=$?
    [[ "$_co_rc" -eq 0 ]] || _co_err "status exited $_co_rc"
    _co_total=""
    _co_total="$(printf '%s' "$_co_out" | jq -r 'if .ok == true and ((.total | type) == "number") then .total else empty end' 2>/dev/null)" || _co_total=""
    [[ "$_co_total" =~ ^[0-9]+$ ]] || _co_err "unreadable status output"
    [[ "$_co_total" -ge 1 ]] && exit 0
    exit 1
fi
# Read-only. notified_at is stamped only by an explicit --mark-notified issued
# after a send actually succeeds, so a send that exhausts its retries stays
# visible to every later sweep instead of vanishing with no way back.
if [[ "${1:-}" == "--pending-dependents" ]]; then
    _pending_label="${2:?--pending-dependents needs a label}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    session_state_list_pending_dependents "$_pending_label"
    exit 0
fi
if [[ "${1:-}" == "--mark-notified" ]]; then
    _mn_dep="${2:?--mark-notified needs a dependent label}"
    _mn_up="${3:?--mark-notified needs an upstream label}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    _mn_rc=0
    session_state_mark_dependency_notified "$_mn_dep" "$_mn_up" || _mn_rc=$?
    exit "$_mn_rc"
fi
# --mark-done <label> [message]: the worker's final step, run after /om-wrap-up
# (D-02, prompt text in orchestration/prompts/worker-dependency-awareness.md).
# The ONLY writer of the `done` event: the Stop hook records idle, because Stop
# fires at the end of every turn, not at the end of the task. Writes last_event,
# last_message and last_activity_at only: never status or updated_at (the sweeps
# own those; merge-review still sets merged). Sends nothing to tmux, never calls
# osascript, never touches the hold directory.
# Two guards: the row must be live (running, blocked or stalled), and the label
# must be the worker whose worktree this command runs in, so one worker cannot
# mark another done. live_worker_agent resolves a subdirectory to its worktree
# root, so the worker may have cd'd; only the label argument must be right, and
# every refusal that knows this worktree's label says what it is.
if [[ "${1:-}" == "--mark-done" ]]; then
    _md_label="${2:-}"
    _md_msg="${3:-}"
    _md_label_re='^[A-Za-z0-9._][A-Za-z0-9._-]*$'
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || { echo "Error: --mark-done refused: session-state library missing" >&2; exit 1; }
    _md_self="$(live_worker_agent "$PWD" 2>/dev/null || true)"
    _md_hint=""
    [[ -z "$_md_self" ]] || _md_hint=" (the label of this worktree is '$_md_self')"
    _md_fail() { echo "Error: --mark-done refused: $1$_md_hint" >&2; exit 1; }
    [[ "$_md_label" =~ $_md_label_re ]] || _md_fail "bad label"
    _md_status="$(session_state_read "$_md_label")" || _md_fail "cannot read the state db"
    case "$_md_status" in
        running|blocked|stalled) ;;
        "") _md_fail "unknown label '$_md_label'" ;;
        *) _md_fail "'$_md_label' is $_md_status, not a live worker" ;;
    esac
    [[ "$_md_self" == "$_md_label" ]] || _md_fail "'$_md_label' is not the worker of this worktree"
    session_state_record_event "$_md_label" done "$_md_msg" || exit 1
    exit 0
fi
# --status-board: one record per live worker, for the workers Pane (D-13).
# Read-only: no tmux, no status write, no file created, and no output at all when
# the state db does not exist. Records end in \x1e, fields are \x1f-separated:
# label, task title, status, last event, event time (epoch seconds), last message,
# live hold count, op of the oldest live hold, the call running now (pending_operation,
# empty when none or the column is missing). \x1e and \x1f never survive in a
# value, as in the quiet sweep. A db without the relay columns (not yet migrated)
# still lists its workers with those fields empty and one stderr line.
if [[ "${1:-}" == "--status-board" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    _sb_db="$PROJECT_ROOT/.claude/session-state.db"
    [[ -f "$_sb_db" ]] || exit 0
    source "$SCRIPT_DIR/orchestration/lib/gate-hold.sh" 2>/dev/null || true
    _sb_us=$'\x1f'
    _sb_clean() { printf "replace(replace(replace(replace(COALESCE(%s,''),char(10),' '),char(13),' '),char(30),''),char(31),'')" "$1"; }
    _sb_cols="$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$_sb_db" "PRAGMA table_info(sessions);")" \
        || { echo "Error: --status-board cannot read $_sb_db" >&2; exit 1; }
    _sb_ev="''" _sb_at="''" _sb_msg="''" _sb_po="''" _sb_missing=""
    [[ "$_sb_cols" != *"|pending_operation|"* ]] || _sb_po="$(_sb_clean pending_operation)"
    if [[ "$_sb_cols" == *"|last_event|"* ]]; then
        _sb_ev="$(_sb_clean last_event)"
        _sb_at="COALESCE(CAST(strftime('%s', last_activity_at) AS TEXT),'')"
    else
        _sb_missing="last_event"
    fi
    if [[ "$_sb_cols" == *"|last_message|"* ]]; then
        _sb_msg="$(_sb_clean last_message)"
    else
        _sb_missing="${_sb_missing:+$_sb_missing, }last_message"
    fi
    [[ -z "$_sb_missing" ]] || echo "status-board: the sessions table has no column $_sb_missing; run orchestration/init/init-state-store.sh" >&2
    _sb_rows="$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" -separator "$_sb_us" "$_sb_db" \
        "SELECT $(_sb_clean agent_id), $(_sb_clean task_title), status, $_sb_ev, $_sb_at, $_sb_msg, $_sb_po FROM sessions WHERE status IN ('running','blocked','stalled') AND agent_id != 'dashboard' ORDER BY created_at, agent_id;")" \
        || { echo "Error: --status-board cannot list sessions from $_sb_db" >&2; exit 1; }
    # Live holds, one "label<US>epoch<US>op" line each. The directory is read only
    # if it exists: gate_hold_dir would create it.
    _sb_holds=""
    _sb_gate_dir="$PROJECT_ROOT/.claude/${GATE_HOLD_DIRNAME:-gate-holds}"
    if [[ -d "$_sb_gate_dir" ]] && declare -f gate_hold_live_ids &>/dev/null; then
        for _sb_id in $(gate_hold_live_ids "$_sb_gate_dir"); do
            _sb_h_label="$(gate_hold_pending_field "$_sb_gate_dir" "$_sb_id" label)" || continue
            _sb_h_epoch="$(gate_hold_pending_field "$_sb_gate_dir" "$_sb_id" epoch)" || continue
            _sb_h_op="$(gate_hold_pending_field "$_sb_gate_dir" "$_sb_id" op)" || continue
            _sb_h_op="${_sb_h_op//[$'\n\r\x1e\x1f']/ }"
            _sb_holds+="${_sb_h_label//[$'\x1e\x1f']/}$_sb_us$_sb_h_epoch$_sb_us$_sb_h_op"$'\n'
        done
    fi
    while IFS="$_sb_us" read -r _sb_label _sb_title _sb_status _sb_event _sb_time _sb_message _sb_pending; do
        [[ -n "$_sb_label" ]] || continue
        _sb_n=0 _sb_old_epoch="" _sb_old_op=""
        while IFS="$_sb_us" read -r _sb_hl _sb_he _sb_ho; do
            [[ "$_sb_hl" == "$_sb_label" ]] || continue
            _sb_n=$((_sb_n + 1))
            [[ "$_sb_he" =~ ^[0-9]+$ ]] || _sb_he=0
            if [[ -z "$_sb_old_epoch" ]] || (( _sb_he < _sb_old_epoch )); then
                _sb_old_epoch="$_sb_he" _sb_old_op="$_sb_ho"
            fi
        done <<< "$_sb_holds"
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1e' "$_sb_label" "$_sb_title" "$_sb_status" "$_sb_event" "$_sb_time" "$_sb_message" "$_sb_n" "$_sb_old_op" "$_sb_pending"
    done <<< "$_sb_rows"
    exit 0
fi
# --cache-ping MODEL [EFFORT]: one short headless turn that sends the exact tools and
# system prompt a worker of MODEL in this project sends, so the 1 h prompt cache stays
# warm (docs/orchestrator/prompt-cache-report-2026-11-24.md section 7). The command comes
# from _build_launch_cmd; two flags are added on top and nothing else is copied:
# --no-session-persistence (no transcript) and --settings disableAllHooks (no Terminus
# archive, no relay hooks). Runs in a fresh temp dir: no worktree, branch, state row or
# tmux window. The single prompt is the first message, so nothing asks the orchestrator.
# Appends one TSV line to ~/.claude/logs/cache-ping.log: time, project, model, input,
# cache read, cache create, create 1h, create 5m, output, cost in USD (turn-1 usage).
# Needs ORCH_PROJECT_ROOT or a cwd inside the project, like the other modes.
if [[ "${1:-}" == "--cache-ping" ]]; then
    _cp_model="${2:?--cache-ping needs a model}"
    _cp_effort="${3:-}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || true
    _cp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cache-ping.XXXXXX")"
    trap 'rm -rf "$_cp_tmp"' EXIT
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Reply with the single word ok."}}' > "$_cp_tmp/in.jsonl"
    : > "$_cp_tmp/out.jsonl"
    # cwd is the project root, not the temp dir: a worker sees the project's agents,
    # skills and settings in its tools and system blocks, so a ping from a bare temp dir
    # warms a shorter prefix (measured 47.6k against 56k tokens).
    _cp_cmd="$(_build_launch_cmd cache-ping "$PROJECT_ROOT" "$_cp_model" "$_cp_effort" "$_cp_tmp/in.jsonl" "$_cp_tmp/out.jsonl" "" "$(orch_session_name "$PROJECT_ROOT")")" || exit 1
    _cp_flags=" claude -p --no-session-persistence --settings '{\"disableAllHooks\":true}' "
    _cp_cmd="${_cp_cmd/ claude -p /$_cp_flags}"
    # no lean-ctx task named cache-ping in the project's own lean-ctx session
    _cp_cmd="${_cp_cmd/lean-ctx session task \'cache-ping\'/true}"
    # setsid gives the pipeline its own process group: its trailing `kill 0` must not reach this script
    # CLAUDE.md files sit in message 0, after the cached tools and system blocks: leaving them out
    # cuts the 5-minute tail the ping writes each time, and the 1 h part it must read is unchanged
    CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 perl -MPOSIX -e 'POSIX::setsid(); exec "bash", "-c", $ARGV[0]' "$_cp_cmd" >/dev/null 2>&1 &
    _cp_pid=$!
    for _cp_i in $(seq 1 240); do
        grep -q '"type":"result"' "$_cp_tmp/out.jsonl" 2>/dev/null && break
        sleep 0.5
    done
    kill -TERM -- "-$_cp_pid" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$_cp_pid" 2>/dev/null || true
    mkdir -p "$HOME/.claude/logs"
    _cp_row="$(grep -m1 '"type":"assistant"' "$_cp_tmp/out.jsonl" | jq -r '.message.usage | [.input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, (.cache_creation.ephemeral_1h_input_tokens // "-"), (.cache_creation.ephemeral_5m_input_tokens // "-"), .output_tokens] | @tsv' 2>/dev/null)" || _cp_row=""
    _cp_cost="$(grep -m1 '"type":"result"' "$_cp_tmp/out.jsonl" | jq -r '.total_cost_usd // "-"' 2>/dev/null)" || _cp_cost="-"
    _cp_row="$_cp_row	${_cp_cost:--}"
    IFS=$'\t' read -r _ _cp_rd _cp_cr _ <<< "$_cp_row"
    # an API error (spend limit) still yields a usage row, all zeros: count it as a failure
    if [[ -z "${_cp_row%%	*}" || "${_cp_rd:-0}${_cp_cr:-0}" == "00" ]]; then
        echo "dispatch-task.sh: cache ping got no reply for $_cp_model" >&2
        printf '%s\t%s\t%s\tFAILED\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$PROJECT_ROOT")" "$_cp_model" >> "$HOME/.claude/logs/cache-ping.log"
        exit 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$PROJECT_ROOT")" "$_cp_model" "$_cp_row" >> "$HOME/.claude/logs/cache-ping.log"
    echo "$_cp_row"
    exit 0
fi
# --cache-ping-all: ping every (live project, model). A live project is a tmux session
# with a window named dashboard whose pane sits in a Helm project. The off switch is the
# file ~/.claude/cache-ping.off. HELM_CACHE_PING_MODELS overrides the model list.
if [[ "${1:-}" == "--cache-ping-all" ]]; then
    if [[ -e "$HOME/.claude/cache-ping.off" ]]; then
        echo "cache ping is off ($HOME/.claude/cache-ping.off exists)"
        exit 0
    fi
    _cpa_rc=0
    _cpa_roots=""
    _cpa_panes="$(command tmux ${ORCH_TMUX_SOCKET:+-L "$ORCH_TMUX_SOCKET"} list-panes -a -F '#{window_name}|#{pane_current_path}' 2>/dev/null)" || _cpa_panes=""
    # "|" not a tab: tmux prints a tab as "_" when it has no terminal (under launchd)
    while IFS= read -r _cpa_line; do
        _cpa_win="${_cpa_line%%|*}" _cpa_path="${_cpa_line#*|}"
        [[ "$_cpa_win" == dashboard && -n "$_cpa_path" ]] || continue
        _cpa_root="$(cd "$_cpa_path" 2>/dev/null && cd "$(command git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)" || continue
        [[ -f "$_cpa_root/.claude/session-state.db" ]] && _cpa_roots+="$_cpa_root"$'\n'
    done <<< "$_cpa_panes"
    while IFS= read -r _cpa_root; do
        [[ -n "$_cpa_root" ]] || continue
        for _cpa_m in ${HELM_CACHE_PING_MODELS:-sonnet[1m] opus haiku}; do
            ORCH_PROJECT_ROOT="$_cpa_root" bash "${BASH_SOURCE[0]}" --cache-ping "$_cpa_m" || _cpa_rc=$?
        done
    done < <(printf '%s' "$_cpa_roots" | sort -u)
    exit "$_cpa_rc"
fi
if [[ "${1:-}" == "--blocked-sweep-all" ]]; then
    # No shared active-project pointer and launchd has no project: sweep every
    # project that owns a tmux pane (a worker pane's cwd is under .claude/worktrees/).
    _bsa_rc=0
    _bsa_roots=""
    _bsa_panes="$(command tmux ${ORCH_TMUX_SOCKET:+-L "$ORCH_TMUX_SOCKET"} list-panes -a -F '#{pane_current_path}' 2>/dev/null)" || _bsa_panes=""
    while IFS= read -r _bsa_path; do
        [[ -z "$_bsa_path" ]] && continue
        if [[ "$_bsa_path" == */.claude/worktrees/* ]]; then
            _bsa_root="${_bsa_path%%/.claude/worktrees/*}"
        elif _bsa_common="$(command git -C "$_bsa_path" rev-parse --git-common-dir 2>/dev/null)"; then
            _bsa_root="$(cd "$_bsa_path" && cd "$_bsa_common/.." && pwd)"
        else
            continue
        fi
        [[ -f "$_bsa_root/.claude/session-state.db" ]] && _bsa_roots+="$_bsa_root"$'\n'
    done <<< "$_bsa_panes"
    while IFS= read -r _bsa_root; do
        ORCH_PROJECT_ROOT="$_bsa_root" bash "${BASH_SOURCE[0]}" --blocked-sweep || _bsa_rc=$?
    done < <(printf '%s' "$_bsa_roots" | sort -u)
    exit "$_bsa_rc"
fi
if [[ "${1:-}" == "--blocked-sweep" ]]; then
    # Phase 4 (SWP-01): capture the sweep's stderr instead of letting it
    # vanish into launchd's shared log. fd 2 goes to a temp file; a DEBUG trap
    # (set -T so it reaches functions and $(...) subshells) appends each
    # "<base>:<window>\t<command>" to `trace`, and a MARK line the first time
    # it finds the stderr file non-empty. Pipeline stages run concurrently, so
    # the failing command is one of the few records just before MARK, not
    # always the very last; the log names those (up to 3). The EXIT trap logs
    # one line per stderr line, replays the stderr to the real fd 2, and
    # removes the temp dir. Stdout and the exit status are untouched; a clean
    # run writes no log line.
    _bs_log="${SWEEP_STDERR_LOG:-$HOME/.claude/logs/approval-sweep-stderr.log}"
    # SWEEP_QUIET=1: a UI poller runs this every few seconds. Read-only on the
    # DB (two mid-render NOMATCHes 6s apart would pass the 27-07 debounce and
    # clear a still-blocked worker; a status=blocked write would hide the
    # running->blocked transition from the launchd sweep, which owns all
    # reconciliation and the notification). No notification, no log lines, and
    # \x1f/\x1e records with a raw title and \x1e/\x1f stripped from fields (ops
    # can hold '|' and newlines) instead of '|' rows, plus a 5th op_seq field
    # (empty when unavailable). Stderr is still replayed.
    [[ "${SWEEP_QUIET:-}" == 1 ]] && _bs_log=/dev/null
    _bs_tmp="$(mktemp -d "${TMPDIR:-/tmp}/sweep-stderr.XXXXXX")"
    _bs_nl=$'\n'
    _bs_stderr_flush() {
        local rc=$? tgt cmd line ts rec c
        local -a recs=()
        set +e
        trap - DEBUG EXIT
        exec 2>&3 3>&-
        if [[ -s "$_bs_tmp/err" ]]; then
            while IFS= read -r rec; do
                [[ "$rec" == MARK ]] && break
                [[ "$rec" == *$'\t_bs_off=1' ]] && continue
                recs+=("$rec")
                (( ${#recs[@]} > 3 )) && recs=("${recs[@]:1}")
            done < "$_bs_tmp/trace"
            tgt="" cmd=""
            for rec in "${recs[@]}"; do
                tgt="${rec%%$'\t'*}"
                c="${rec#*$'\t'}"
                cmd="${cmd:+$cmd ; }$c"
            done
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            mkdir -p "$(dirname "$_bs_log")" 2>/dev/null
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" ]] && continue
                printf '%s trigger=%s target=%s cmd=%s stderr=%s\n' \
                    "$ts" "${SWEEP_TRIGGER:-manual}" "$tgt" "$cmd" "$line"
            done < "$_bs_tmp/err" >> "$_bs_log" 2>/dev/null
            cat "$_bs_tmp/err" >&2
        fi
        rm -rf "$_bs_tmp"
        return "$rc"
    }
    exec 3>&2 2>"$_bs_tmp/err"
    trap '_bs_off=1; _bs_stderr_flush' EXIT
    set -T
    trap '{ [[ -z "${_bs_off-}" ]] && { [[ -s "$_bs_tmp/err" && ! -e "$_bs_tmp/hit" ]] && { printf "MARK\n" >> "$_bs_tmp/trace"; : > "$_bs_tmp/hit"; }; printf "%s\t%s\n" "${_bs_base:-}:${_bs_window:-}" "${BASH_COMMAND//"$_bs_nl"/ }" >> "$_bs_tmp/trace"; }; } 2>/dev/null || :' DEBUG
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/orchestration/lib/notify.sh" 2>/dev/null || true
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    # The session DB is located from the cwd (session_state_db_path defaults
    # to "."), but the worker's hook records into the PROJECT's DB. Run from
    # any other repo (e.g. the orchestrator's own), every row lookup came back
    # empty: no title, no pending_operation. Anchor on the same project the
    # tmux base session is derived from. Only when that project has a session
    # DB, so a project without one keeps the caller's cwd behaviour.
    [[ -f "$PROJECT_ROOT/.claude/session-state.db" ]] && cd "$PROJECT_ROOT"
    _bs_base="$(tmux_base_session_name "$PROJECT_ROOT")"

    # Phase 1 gate holds: files only, no tmux. A live hold is a pending record
    # whose hook PID is alive; the worker's pane shows no dialog for it.
    source "$SCRIPT_DIR/orchestration/lib/gate-hold.sh" 2>/dev/null || true
    _bs_gate_dir="$(gate_hold_dir "$PROJECT_ROOT" 2>/dev/null)" || _bs_gate_dir=""
    _bs_gate_ids=""
    # Non-quiet only: the quiet sweep is read-only and a UI poller runs it.
    if [[ -n "$_bs_gate_dir" && "${SWEEP_QUIET:-}" != 1 ]]; then
        gate_hold_prune "$_bs_gate_dir"
    fi
    if [[ -n "$_bs_gate_dir" ]]; then
        _bs_gate_ids="$(gate_hold_live_ids "$_bs_gate_dir")"
    fi
    # Seconds a hold waits before it notifies (D-14); unset or not a number: 120.
    _bs_notify_after="${APPROVAL_NOTIFY_AFTER_SECS:-120}"
    [[ "$_bs_notify_after" =~ ^[0-9]+$ ]] || _bs_notify_after=120

    # One row per live gate hold, keyed by tool_use_id (D-08, D-09). Emission
    # reads only the hold files, so it runs with no tmux window at all. A
    # non-quiet sweep also marks each held worker blocked and notifies once per
    # hold: a second hold on a worker that is still blocked is a new request.
    for _bs_g_id in $_bs_gate_ids; do
        # A record may vanish mid-sweep (the gate exited): the reads then fail.
        _bs_g_label="$(gate_hold_pending_field "$_bs_gate_dir" "$_bs_g_id" label)" || continue
        _bs_g_hash="$(gate_hold_pending_field "$_bs_gate_dir" "$_bs_g_id" hash)" || continue
        _bs_g_op="$(gate_hold_pending_field "$_bs_gate_dir" "$_bs_g_id" op)" || continue
        # Not shaped like the gate's own record: no row.
        [[ -n "$_bs_g_label" && "$_bs_g_hash" =~ ^[0-9a-f]{64}$ ]] || continue
        if [[ "${SWEEP_QUIET:-}" != 1 ]]; then
            # Only a live worker flips: a done or dead row stays as it is. The
            # <id>.notified marker is removed with the pending record.
            _bs_g_st="$(session_state_read "$_bs_g_label" 2>/dev/null)"
            case "$_bs_g_st" in
                running|stalled|blocked)
                    [[ "$_bs_g_st" == blocked ]] || session_state_update_status "$_bs_g_label" blocked 2>/dev/null || true
                    # D-14: notify only once the hold has waited N seconds. A younger
                    # hold is picked up by a later sweep; one that ends first never
                    # notifies. A record with no readable epoch counts as old.
                    _bs_g_epoch="$(gate_hold_pending_field "$_bs_gate_dir" "$_bs_g_id" epoch)" || _bs_g_epoch=0
                    [[ "$_bs_g_epoch" =~ ^[0-9]+$ ]] || _bs_g_epoch=0
                    if [[ ! -e "$_bs_gate_dir/$_bs_g_id.notified" ]] && (( $(date +%s) - _bs_g_epoch >= _bs_notify_after )); then
                        : > "$_bs_gate_dir/$_bs_g_id.notified" 2>/dev/null || true
                        declare -f approval_notify &>/dev/null && \
                            approval_notify "Approval needed: $_bs_g_label" "$_bs_g_op" >/dev/null 2>&1
                    fi
                    ;;
            esac
        fi
        _bs_g_title="$(session_state_get_task_title "$_bs_g_label" 2>/dev/null)" || true
        if [[ "${SWEEP_QUIET:-}" == 1 ]]; then
            printf '%s\x1f%s\x1f%s\x1f\x1f\x1f1\x1f%s\x1f%s\x1e' "${_bs_g_label//[$'\x1e\x1f']/}" "${_bs_g_title//[$'\x1e\x1f']/}" "${_bs_g_op//[$'\x1e\x1f']/}" "$_bs_g_id" "$_bs_g_hash"
        else
            printf '%s|%s|%s|gate:%s\n' "$_bs_g_label" "${_bs_g_title:-<no task title recorded>}" "$_bs_g_op" "$_bs_g_id"
        fi
    done
    exit 0
fi

if [[ "${1:-}" == "--launch-sweep" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/orchestration/lib/gate-hold.sh" 2>/dev/null || true
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    [[ -f "$PROJECT_ROOT/.claude/session-state.db" ]] && cd "$PROJECT_ROOT"
    _ls_base="$(tmux_base_session_name "$PROJECT_ROOT")"
    _ls_us=$'\x1f'

    # D-13: re-verify pre-existing blocked rows at launch. No pane is read, so
    # a row stays blocked only while a live gate hold (same check as
    # --blocked-sweep: gate_hold_live_ids) still waits for it; the rest go
    # back to running. Never a blind wipe: a held worker keeps its hold card.
    _ls_gate_dir="$(gate_hold_dir "$PROJECT_ROOT" 2>/dev/null)" || _ls_gate_dir=""
    _ls_gate_labels=$'\n'
    if [[ -n "$_ls_gate_dir" ]]; then
        for _ls_g_id in $(gate_hold_live_ids "$_ls_gate_dir"); do
            _ls_g_label="$(gate_hold_pending_field "$_ls_gate_dir" "$_ls_g_id" label)" || continue
            _ls_gate_labels+="$_ls_g_label"$'\n'
        done
    fi
    _ls_blocked_rows="$(session_state_list_blocked 2>/dev/null)"
    if [[ -n "$_ls_blocked_rows" ]]; then
        while IFS="$_ls_us" read -r _ls_agent _ls_worktree _ls_title _ls_op _ls_updated; do
            [[ -z "$_ls_agent" ]] && continue
            [[ "$_ls_gate_labels" == *$'\n'"$_ls_agent"$'\n'* ]] && continue
            session_state_clear_pending_operation "$_ls_agent" 2>/dev/null || true
            session_state_update_status "$_ls_agent" running 2>/dev/null || true
        done <<< "$_ls_blocked_rows"
    fi

    # Orphan pass -- database-driven ONLY, deliberately. Do not
    # "improve" this into enumerating iTerm sessions: from outside, an
    # orphaned attach tab and a plain shell tab the human opened for their
    # own work are indistinguishable, and closing a tab is not undoable.
    # This only ever closes a tab a row proves the orchestrator created.
    # The tmux window (D-11) goes whether or not the row has a tab id: a
    # headless worker has none. _teardown_if_present acts only on a window or
    # grouped session that exists under exactly that name.
    _ls_all_rows="$(session_state_list 2>/dev/null)"
    if [[ -n "$_ls_all_rows" ]]; then
        while IFS='|' read -r _ls_d_agent _ls_d_status _ls_d_rest; do
            [[ -z "$_ls_d_agent" ]] && continue
            case "$_ls_d_status" in
                dead|merged)
                    _ls_d_sid="$(session_state_get_iterm_id "$_ls_d_agent" 2>/dev/null)"
                    if [[ -n "$_ls_d_sid" ]]; then
                        tmux_close_terminal_tab "$_ls_d_sid" >/dev/null 2>&1 || true
                    fi
                    _teardown_if_present "$_ls_base" "$_ls_d_agent"
                    ;;
            esac
        done <<< "$_ls_all_rows"
    fi

    exit 0
fi

# --teardown-project <absolute-folder>: stop one project's orchestrator (CONTEXT D-05,
# D-13, D-14). The folder alone names the project: no _resolve_project_root, so the
# caller's cwd and ORCH_PROJECT_ROOT are ignored. tmux sessions only -- the state
# database, worktrees and branches stay as they are, so a launch plus --resume
# brings the workers back.
if [[ "${1:-}" == "--teardown-project" ]]; then
    _tp_fail() { echo "Error: --teardown-project refused: $1" >&2; exit 1; }
    _tp_folder="${2-}"
    [[ "$_tp_folder" == /* && -d "$_tp_folder" ]] \
        || _tp_fail "needs an absolute path to an existing directory, got '$_tp_folder'"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || _tp_fail "the tmux-session library is missing"
    _tp_base="$(tmux_base_session_name "$_tp_folder")"
    [[ -n "$_tp_base" ]] || _tp_fail "no session name can be derived from '$_tp_folder'"
    tmux_kill_session_group "$_tp_base"
    # Closed on purpose: the next launch starts a new conversation. Same state-root
    # rule as launch-claude.sh (main checkout). Transcripts stay on disk.
    if _tp_common="$(command git -C "$_tp_folder" rev-parse --git-common-dir 2>/dev/null)"; then
        _tp_root="$(cd "$_tp_folder" && cd "$_tp_common/.." && pwd)"
        rm -f "$_tp_root/.claude/orchestrator-session-id"
        # D-03: keep every out log, empty every inbox (in place) so a later
        # --resume does not re-feed old lines through tail -n +1.
        for _tp_inbox in "$_tp_root"/.claude/sessions/*/inbox.jsonl; do
            [[ -f "$_tp_inbox" ]] && : > "$_tp_inbox"
        done
    fi
    exit 0
fi

# --write-notion-tasks [rows-file]: write <main repo>/.claude/notion-tasks.json for
# the GUI from the orchestrator's open Notion task rows (phase 3 D-01, D-02, D-05).
# Rows come from the file named (removed on every run, so the orchestrator's next
# file-tool Write never hits a stale file) or from stdin. Titles are untrusted:
# they only ever pass through jq as data. Any failure warns and leaves the file as it was.
if [[ "${1:-}" == "--write-notion-tasks" ]]; then
    _wnt_rows="${2-}"
    _wnt_tmp=""
    trap 'rm -f ${_wnt_rows:+"$_wnt_rows"} ${_wnt_tmp:+"$_wnt_tmp"}' EXIT
    _wnt_fail() { echo "dispatch-task.sh --write-notion-tasks: $1; notion-tasks.json left unchanged" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || _wnt_fail "jq is not on PATH"
    PROJECT_ROOT="$(_resolve_project_root)" || _wnt_fail "no target project"
    if [[ -n "$_wnt_rows" ]]; then
        _wnt_in="$(cat -- "$_wnt_rows" 2>/dev/null)" || _wnt_fail "cannot read the rows file"
    else
        _wnt_in="$(cat)"
    fi
    # One JSON value: an array of objects that each carry every D-02 key.
    _wnt_doc="$(printf '%s' "$_wnt_in" | jq -cs \
        --arg project "$(basename "$PROJECT_ROOT")" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        if length == 1 and (.[0] | type) == "array"
            and all(.[0][]; type == "object"
                and (["id","title","status","priority","tags","url","parent_id"] - keys) == [])
        then {schema: 1, project: $project, generated_at: $at, tasks: .[0]}
        else error("not one array of task rows") end' 2>/dev/null)" \
        || _wnt_fail "rows are not one JSON array of objects with id, title, status, priority, tags, url and parent_id"
    _wnt_dir="$PROJECT_ROOT/.claude"
    mkdir -p "$_wnt_dir" 2>/dev/null || _wnt_fail "cannot create $_wnt_dir"
    # Same-dir temp + rename (as _gate_hold_write_atomic): the app never reads a partial file.
    _wnt_tmp="$(mktemp "$_wnt_dir/.notion-tasks.XXXXXX" 2>/dev/null)" || _wnt_fail "cannot write in $_wnt_dir"
    if printf '%s\n' "$_wnt_doc" > "$_wnt_tmp" 2>/dev/null && mv -f "$_wnt_tmp" "$_wnt_dir/notion-tasks.json"; then
        _wnt_tmp=""
        exit 0
    fi
    _wnt_fail "writing $_wnt_dir/notion-tasks.json failed"
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: dispatch-task.sh _label" >&2
    exit 1
fi

if [[ "$1" == "--kill" ]]; then
    _kill_label="${2:?--kill needs a label}"
    # The label builds worktree and file paths below: refuse "..", "a/b" and the
    # like before any path exists.
    if ! [[ "$_kill_label" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || [[ "$_kill_label" == "." || "$_kill_label" == ".." ]]; then
        echo "Error: --kill refused: invalid session label '$_kill_label'" >&2
        exit 1
    fi
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || true
    _sid=$(session_state_get_iterm_id "$_kill_label" 2>/dev/null)
    if [[ -n "$_sid" ]]; then
        tmux_close_terminal_tab "$_sid" >/dev/null 2>&1 || true
    fi
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    if declare -f tmux_teardown_worker &>/dev/null; then
        tmux_teardown_worker "$(tmux_base_session_name "$PROJECT_ROOT")" "$_kill_label"
    fi
    _kill_worktree="$PROJECT_ROOT/.claude/worktrees/$_kill_label"
    _kill_branch="session/$_kill_label"
    source "$SCRIPT_DIR/orchestration/lib/branch-merged.sh" 2>/dev/null || true
    if branch_is_merged "$PROJECT_ROOT" HEAD "$_kill_branch" \
        && [[ -z "$(command git -C "$_kill_worktree" status --porcelain 2>/dev/null)" ]]; then
        # Merged into HEAD (incl. squash-merged PRs) with no uncommitted changes -- nothing to lose
        command git -C "$PROJECT_ROOT" worktree remove --force "$_kill_worktree" 2>/dev/null || true
        command git -C "$PROJECT_ROOT" branch -D "$_kill_branch" 2>/dev/null || true
        delete_remote_branch "$PROJECT_ROOT" "$_kill_branch"
    else
        # Unmerged commits and/or uncommitted changes -- preserve instead of destroying
        command git -C "$PROJECT_ROOT" branch -m "$_kill_branch" "session/${_kill_label}-orphaned-$(date +%s)" 2>/dev/null || true
    fi
    session_state_update_status "$_kill_label" dead 2>/dev/null || true
    # D-03: the session files go with the worker.
    session_files_delete "$PROJECT_ROOT" "$_kill_label" 2>/dev/null || true
    exit 0
fi

# --attach is retired (D-04): the app's view is how the user looks at a worker.
# Without this refusal the label "--attach" would be slugified and a worker started.
if [[ "$1" == "--attach" ]]; then
    echo "Error: --attach no longer exists; use the app's view to look at a worker" >&2
    exit 1
fi

# --resume (D-15, D-16): after a restart, start a tmux window for each worker
# that was live, in its own worktree, with `claude --resume <its session id>`
# and its stored model and effort. The effort comes from the row because a
# resume restores the model but not the effort (SPIKE C7). One project (the
# cwd's, or ORCH_PROJECT_ROOT); the base tmux session must exist already
# (launch-claude.sh makes it). Writes no row and makes no worktree. One line
# per row, `resumed <label>` or `skipped <label>: <reason>`; exit 0 even when
# rows were skipped, 1 only when it cannot run at all.
if [[ "$1" == "--resume" ]]; then
    _rs_fail() { echo "Error: --resume refused: $1" >&2; exit 1; }
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    for _rs_lib in session-state tmux-session branch-merged; do
        source "$SCRIPT_DIR/orchestration/lib/$_rs_lib.sh" 2>/dev/null || _rs_fail "the $_rs_lib library is missing"
    done
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    _rs_base="$(tmux_base_session_name "$PROJECT_ROOT")"
    tmux has-session -t "=$_rs_base" 2>/dev/null \
        || _rs_fail "the tmux session '$_rs_base' does not exist; run launch-claude.sh first"
    "$SCRIPT_DIR/orchestration/init/init-state-store.sh" "$PROJECT_ROOT" >/dev/null 2>&1 \
        || echo "Warning: could not initialise the session state store for '$PROJECT_ROOT'; continuing" >&2
    # The worker-relay hook is registered at the orchestrator root's path and
    # fails open when its library or prompt is missing there, so a resumed worker
    # would silently get no worker prompt. Name it here, where a human sees it.
    _rs_hook_warn=""
    _rs_orch="$(cat "$PROJECT_ROOT/.claude/orchestrator-root" 2>/dev/null || true)"
    if [[ -n "$_rs_orch" ]]; then
        for _rs_need in orchestration/lib/session-state.sh orchestration/prompts/worker-dependency-awareness.md; do
            [[ -r "$_rs_orch/$_rs_need" ]] || _rs_hook_warn="$_rs_hook_warn $_rs_orch/$_rs_need"
        done
    fi
    _rs_db="$PROJECT_ROOT/.claude/session-state.db"
    [[ -f "$_rs_db" ]] || { echo "nothing to resume: $_rs_db does not exist"; exit 0; }
    _rs_us=$'\x1f'
    _rs_rows="$(command sqlite3 -cmd ".timeout 5000" -separator "$_rs_us" "$_rs_db" \
        "SELECT agent_id, status, worktree_path, COALESCE(model,''), COALESCE(effort,''), COALESCE(claude_session_id,'') FROM sessions ORDER BY created_at, agent_id;")" \
        || _rs_fail "cannot read $_rs_db"
    while IFS="$_rs_us" read -r _rs_label _rs_status _rs_dir _rs_model _rs_effort _rs_sid; do
        [[ -n "$_rs_label" ]] || continue
        _rs_why=""
        case "$_rs_status" in
            running|blocked|stalled) ;;
            *) _rs_why="status is $_rs_status" ;;
        esac
        if [[ -z "$_rs_why" && "$_rs_label" == dashboard ]]; then
            _rs_why="the dashboard row is not a worker"
        fi
        if [[ -z "$_rs_why" && ! -d "$_rs_dir" ]]; then
            _rs_why="worktree directory is missing"
        fi
        # A branch with no commit of its own is an ancestor of HEAD too, but nothing
        # was merged: its tip is still the commit it was created from (oldest reflog
        # entry). Such a worker, killed before its first commit, must resume.
        if [[ -z "$_rs_why" ]] \
            && [[ "$(command git -C "$PROJECT_ROOT" rev-parse --verify -q "session/$_rs_label^{commit}" 2>/dev/null)" \
                != "$(command git -C "$PROJECT_ROOT" reflog show --format=%H "session/$_rs_label" 2>/dev/null | tail -n 1)" ]] \
            && branch_is_merged "$PROJECT_ROOT" HEAD "session/$_rs_label"; then
            _rs_why="branch is already merged"
        fi
        if [[ -z "$_rs_why" && -z "$_rs_sid" ]]; then
            _rs_why="no recorded Claude session ID"
        fi
        if [[ -z "$_rs_why" ]] && _tmux_window_exists "$_rs_base" "$_rs_label"; then
            _rs_why="a tmux window of that name exists"
        fi
        if [[ -z "$_rs_why" ]]; then
            _rs_inbox=""; _rs_out=""
            { read -r _rs_sfdir; read -r _rs_inbox; read -r _rs_out; } < <(session_files_paths "$PROJECT_ROOT" "$_rs_label" 2>/dev/null) || true
            if [[ -z "$_rs_inbox" ]]; then
                _rs_why="the label is not a valid session name"
            elif ! _rs_cmd="$(_build_launch_cmd "$_rs_label" "$_rs_dir" "${_rs_model:-sonnet[1m]}" "$_rs_effort" "$_rs_inbox" "$_rs_out" "$_rs_sid" "$(orch_session_name "$PROJECT_ROOT")" 2>/dev/null)"; then
                _rs_why="the recorded Claude session ID is not a plain token"
            elif ! { session_files_create "$PROJECT_ROOT" "$_rs_label" && session_files_empty_inbox "$PROJECT_ROOT" "$_rs_label"; } 2>/dev/null; then
                # D-09: empty inbox so tail -n +1 re-sends nothing; out log kept
                _rs_why="the session files could not be prepared"
            elif ! tmux_ensure_window "$_rs_base" "$_rs_label" "$_rs_cmd" 2>/dev/null; then
                _rs_why="the tmux window could not be created"
            else
                # rows started before this change hold no paths: UPDATE, no row write
                session_state_set_session_files "$_rs_label" "$_rs_inbox" "$_rs_out" >/dev/null 2>&1 || true
            fi
        fi
        if [[ -n "$_rs_why" ]]; then
            echo "skipped $_rs_label: $_rs_why"
        else
            echo "resumed $_rs_label"
            [[ -z "$_rs_hook_warn" ]] || echo "Warning: resumed worker '$_rs_label' gets no worker prompt: the worker-relay hook cannot read:$_rs_hook_warn" >&2
        fi
    done <<< "$_rs_rows"
    exit 0
fi

# --gate-decide <label> <tool_use_id> allow|deny <op_hash>: the band's answer to
# a git op the gate is holding (D-07). Writes the decision file and nothing
# else: no pane capture, no tmux. Exit 0 means "decision
# written"; the gate, not this mode, decides whether it is still waiting.
if [[ "$1" == "--gate-decide" ]]; then
    _gd_label="${2:-}"
    _gd_id="${3:-}"
    _gd_choice="${4:-}"
    _gd_hash="${5:-}"
    _gd_fail() { echo "Error: --gate-decide refused: $1" >&2; exit 1; }
    # Env markers (D-02): a Claude Code session carries these, the band and the app do not. env -u defeats this alone; the ancestry check below is the main check.
    [[ -z "${CLAUDECODE:-}" && -z "${CLAUDE_CODE_SESSION_ID:-}" ]] || _gd_fail "the caller is a Claude Code session, only the band may decide a hold"
    # Ancestry check: no caller-supplied value is the proof. Refuse when any ancestor
    # is a dispatched worker (launched with the worker prompt); otherwise require an
    # ancestor that is the orchestrator's Claude session (launched with the drafting
    # prompt) or the orchestrator-gui app. /bin/ps by absolute
    # path so a PATH stub cannot answer. Stops a worker deciding through this script,
    # not one that writes the .decision file itself (docs/approval-relay-setup.md).
    _gd_decider=""
    _gd_pid=$PPID
    while (( _gd_pid > 1 )); do
        read -r _gd_ppid _gd_comm < <(/bin/ps -o ppid=,comm= -p "$_gd_pid") || _gd_fail "could not read the caller's process tree"
        _gd_args=$(/bin/ps -o args= -p "$_gd_pid")
        [[ "$_gd_args" == *" --append-system-prompt-file "*/orchestration/prompts/worker-dependency-awareness.md* ]] \
            && _gd_fail "the caller runs inside a dispatched worker, only the orchestrator-gui app may decide a hold"
        [[ "${_gd_comm##*/}" == claude && "$_gd_args" == *" --append-system-prompt-file "*/orchestration/prompts/task-drafting-mode.md* ]] && _gd_decider=1
        [[ "$_gd_comm" == */Helm.app/Contents/MacOS/Helm ]] && _gd_decider=1
        _gd_pid=$_gd_ppid
    done
    [[ -n "$_gd_decider" ]] || _gd_fail "the caller is not the orchestrator-gui app"
    _gd_label_re='^[A-Za-z0-9._][A-Za-z0-9._-]*$'
    _gd_hash_re='^[0-9a-f]{64}$'
    [[ "$_gd_label" =~ $_gd_label_re ]] || _gd_fail "bad label"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    source "$SCRIPT_DIR/orchestration/lib/gate-hold.sh" 2>/dev/null || _gd_fail "gate-hold library missing"
    gate_hold_id_valid "$_gd_id" || _gd_fail "bad tool_use_id"
    [[ "$_gd_choice" == allow || "$_gd_choice" == deny ]] || _gd_fail "choice must be allow or deny"
    [[ "$_gd_hash" =~ $_gd_hash_re ]] || _gd_fail "bad op hash"
    PROJECT_ROOT="$(_resolve_project_root)" || exit 1
    _gd_dir="$(gate_hold_dir "$PROJECT_ROOT")" || _gd_fail "no hold directory for this project"
    [[ -f "$_gd_dir/$_gd_id.pending" ]] || _gd_fail "no pending hold for that tool_use_id"
    gate_hold_record_live "$_gd_dir" "$_gd_id" || _gd_fail "the hold is no longer waiting"
    [[ "$(gate_hold_pending_field "$_gd_dir" "$_gd_id" label)" == "$_gd_label" ]] || _gd_fail "that hold belongs to another worker"
    [[ "$(gate_hold_pending_field "$_gd_dir" "$_gd_id" hash)" == "$_gd_hash" ]] || _gd_fail "op hash does not match the held call"
    gate_hold_decision_write "$_gd_dir" "$_gd_id" "$_gd_choice" "$_gd_hash" || _gd_fail "could not write the decision"
    # The gate may have hit its deadline (or died) between the checks above and
    # the write. Liveness, then the decision file: the gate removes the decision
    # before its record, so a decision file that is gone after a failed liveness
    # check was taken (delivered), while one still on disk was never read. Take
    # it back so the band never shows a delivery nobody received.
    if ! gate_hold_record_live "$_gd_dir" "$_gd_id" && [[ -e "$_gd_dir/$_gd_id.decision" ]]; then
        rm -f "$_gd_dir/$_gd_id.decision"
        _gd_fail "the hold is no longer waiting"
    fi
    exit 0
fi

case "$1" in
    --help|-h)
        echo "Usage: dispatch-task.sh _label"
        exit 0
        ;;
    --*)
        echo "Usage: dispatch-task.sh _label" >&2
        exit 1
        ;;
esac

_label="$1"
_label="$(_slugify "$_label")"
# Optional second positional argument: the task title (D-15). Cannot be
# confused with the --flag subcommands above -- they all match and exit
# before this line is ever reached.
_title="${2:-}"
if [[ -z "${_title//[[:space:]]/}" ]]; then
    echo "Usage: dispatch-task.sh _label" >&2
    exit 1
fi

case "${DISPATCH_MODEL:-}" in
    ""|haiku|sonnet|opus) ;;
    *)
        echo "dispatch-task.sh: invalid DISPATCH_MODEL '${DISPATCH_MODEL}' (expected haiku, sonnet, or opus)" >&2
        exit 1
        ;;
esac
case "${DISPATCH_EFFORT:-}" in
    ""|low|medium|high|xhigh|max) ;;
    *)
        echo "dispatch-task.sh: invalid DISPATCH_EFFORT '${DISPATCH_EFFORT}' (expected low, medium, high, xhigh, or max)" >&2
        exit 1
        ;;
esac
if [[ "${DISPATCH_MODEL:-}" == "opus" && ( "${DISPATCH_EFFORT:-}" == "xhigh" || "${DISPATCH_EFFORT:-}" == "max" ) ]]; then
    echo "dispatch-task.sh: opus effort is capped at high (got '${DISPATCH_EFFORT}')" >&2
    exit 1
fi

# Set up paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Compute SESSION_DIR from label and ensure git worktree exists
PROJECT_ROOT="$(_resolve_project_root)" || exit 1

# Source tmux-session.sh for tmux window management (fail-safe if unavailable)
if [[ -f "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" ]]; then
    source "$SCRIPT_DIR/orchestration/lib/tmux-session.sh" 2>/dev/null || true
fi
TMUX_HELPER_ENABLED=false
declare -f tmux_ensure_window &>/dev/null && TMUX_HELPER_ENABLED=true
BASE_SESSION=""
if [[ "$TMUX_HELPER_ENABLED" == "true" ]]; then
    BASE_SESSION="$(tmux_base_session_name "$PROJECT_ROOT")"
fi

SESSION_DIR="$PROJECT_ROOT/.claude/worktrees/$_label"
mkdir -p "$PROJECT_ROOT/.claude/worktrees"

# Source session-state.sh for session_state_write (fail-safe if unavailable)
if [[ -f "$SCRIPT_DIR/orchestration/lib/session-state.sh" ]]; then
    source "$SCRIPT_DIR/orchestration/lib/session-state.sh" 2>/dev/null || true
fi

# Construct claude launch command (shared with resume, D-16)
{ read -r _sf_dir; read -r _sf_inbox; read -r _sf_out; } < <(session_files_paths "$PROJECT_ROOT" "$_label") || exit 1
_worker_cmd="$(_build_launch_cmd "$_label" "$SESSION_DIR" "${DISPATCH_MODEL:-sonnet[1m]}" "${DISPATCH_EFFORT:-}" "$_sf_inbox" "$_sf_out" "" "$(orch_session_name "$PROJECT_ROOT")")" || exit 1

# A window with this exact name is a live worker's: stop before anything below
# can write its row, remove its worktree or kill its window.
if [[ "$TMUX_HELPER_ENABLED" == "true" ]] && _tmux_window_exists "$BASE_SESSION" "$_label"; then
    echo "Error: tmux window '$_label' already exists in session '$BASE_SESSION'; end that worker first (dispatch-task.sh --kill $_label)" >&2
    exit 1
fi

# What this run created, so a failed dispatch undoes only that: a worktree or
# branch that existed before belongs to earlier work and is left alone.
_created_worktree=false
_created_branch=false
if [[ ! -d "$SESSION_DIR" ]]; then
    # Check if branch already exists (from prior partial failure)
    if command git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/session/$_label" 2>/dev/null; then
        # Branch exists, attach worktree to it (no -b)
        if ! worktree_err=$(command git -C "$PROJECT_ROOT" worktree add "$SESSION_DIR" "session/$_label" 2>&1); then
            echo "Error: failed to attach git worktree for session '$_label': $worktree_err" >&2
            exit 1
        fi
        _created_worktree=true
    else
        # Branch doesn't exist, create it with -b
        if ! worktree_err=$(command git -C "$PROJECT_ROOT" worktree add -b "session/$_label" "$SESSION_DIR" 2>&1); then
            echo "Error: failed to create git worktree for session '$_label': $worktree_err" >&2
            exit 1
        fi
        _created_worktree=true
        _created_branch=true
    fi
fi

# Undo a dispatch that never reached a running worker. The one cleanup for the
# window-failure path and the signal trap below, so the two cannot drift: window
# (only when one exists by exact name), worktree and branch (only what this run
# created), then the row goes dead.
_dispatch_undo() {
    _teardown_if_present "$BASE_SESSION" "$_label"
    if [[ "$_created_worktree" == true ]]; then
        command git -C "$PROJECT_ROOT" worktree remove --force "$SESSION_DIR" 2>/dev/null || true
    fi
    if [[ "$_created_branch" == true ]]; then
        command git -C "$PROJECT_ROOT" branch -D "session/$_label" 2>/dev/null || true
    fi
    session_state_update_status "$_label" dead 2>/dev/null || true
    # D-03: the session files go with an undone dispatch.
    session_files_delete "$PROJECT_ROOT" "$_label" 2>/dev/null || true
}
_dispatch_interrupted() {
    trap '' INT TERM HUP
    echo "dispatch-task.sh: interrupted before the worker window was created; dispatch undone" >&2
    _dispatch_undo
    exit 1
}

# Make sure this project's db has the relay columns before the row is written
# (idempotent). A failure only warns: the row write below stays fail-safe.
"$SCRIPT_DIR/orchestration/init/init-state-store.sh" "$PROJECT_ROOT" >/dev/null 2>&1 \
    || echo "Warning: could not initialise the session state store for '$PROJECT_ROOT'; continuing" >&2

# The row comes BEFORE the window so the worker's own SessionStart hook always
# finds it. The iTerm ID stays NULL: dispatch creates no tab (D-09).
if declare -f session_state_write_with_iterm_id &>/dev/null; then
    session_state_write_with_iterm_id "$_label" "$SESSION_DIR" "running" "$$" "" 2>/dev/null || true
fi
# From here until the window exists, an interrupt must not leave a running row
# with no worker behind it. SIGKILL cannot be trapped (PLAN-8's --resume skips
# a row with no session id). Not set earlier: before the row there is nothing
# to mark dead, and the early exits above already clean up.
trap _dispatch_interrupted INT TERM HUP

# Write the task title, when given (D-15) -- separate call, not folded into
# session_state_write_with_iterm_id above: that call is INSERT OR REPLACE,
# so folding the title in would mean a re-dispatch under the same label
# silently replaces the whole row. A title that fails to record must not
# fail a dispatch that otherwise succeeded, so this is wrapped fail-safe
# the same way the neighbouring state call above is.
if [[ -n "$_title" ]] && declare -f session_state_set_task_title &>/dev/null; then
    session_state_set_task_title "$_label" "$_title" 2>/dev/null || true
fi

# D-12: the model and effort this worker started with, for resume (D-16). A
# failure prints the helper's own stderr line and does not fail the dispatch.
if declare -f session_state_set_model_effort &>/dev/null; then
    session_state_set_model_effort "$_label" "${DISPATCH_MODEL:-sonnet[1m]}" "${DISPATCH_EFFORT:-}" || true
fi

# D-09: both session files exist before the window starts. The inbox is
# truncated even when an earlier session left lines in it, so tail -n +1 never
# re-feeds them; an existing out log is kept. The paths are stored after the
# row write above (INSERT OR REPLACE would wipe them). A failure only warns.
if session_files_create "$PROJECT_ROOT" "$_label" && session_files_empty_inbox "$PROJECT_ROOT" "$_label"; then
    session_state_set_session_files "$_label" "$_sf_inbox" "$_sf_out" || true
else
    echo "Warning: could not create the session files for '$_label'" >&2
fi

# The window is the only launch step (D-09); check its real exit code.
if [[ "$TMUX_HELPER_ENABLED" != "true" ]] || ! tmux_ensure_window "$BASE_SESSION" "$_label" "$_worker_cmd"; then
    trap '' INT TERM HUP
    echo "Error: failed to create tmux window for session '$_label'" >&2
    _dispatch_undo
    exit 1
fi
# The window exists: nothing after this point is undone by a signal.
trap - INT TERM HUP

# A peer message that reaches a worker before its SessionStart hooks finish is
# held (peer_message_hold, cause mode-unknown). Wait until every started hook
# has answered so the first SendMessage is not held. Bounded; on timeout, go on
# as before (the orchestrator prompt's Blocked Workers rule is the guard).
_ready_deadline=$((SECONDS + ${DISPATCH_READY_TIMEOUT:-30}))
while (( SECONDS < _ready_deadline )); do
    _hs="$(grep -c '"subtype":"hook_started"' "$_sf_out" 2>/dev/null || true)"
    _hr="$(grep -c '"subtype":"hook_response"' "$_sf_out" 2>/dev/null || true)"
    [[ "${_hs:-0}" -gt 0 && "${_hs:-0}" == "${_hr:-0}" ]] && break
    sleep 0.2
done

exit 0
