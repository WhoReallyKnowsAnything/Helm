#!/bin/bash
# orchestration/hooks/worker-relay.sh
# SessionStart, Stop, PostToolUse, UserPromptSubmit and PreToolUse hook (D-02,
# D-06): writes a live worker's start, idle, busy and commit events and its Claude session id into its state row,
# so the orchestrator never depends on the model calling SendMessage. The fourth
# event, done, is NOT written here: only the worker's final
# `dispatch-task.sh --mark-done` step writes it, because Stop fires at the end
# of every turn, not at the end of the task. A Stop never overwrites done.
# The blocked event comes with the hold (PLAN-5).
#
# Registered from the user's GLOBAL ~/.claude/settings.json (see
# docs/approval-relay-setup.md), so it runs for EVERY session and exits early
# unless live_worker_agent finds a live worker row for the payload cwd.
#
# An observer: it fails OPEN. Exit 0 on every path,
# nothing on stdout except three cases. A `resume` SessionStart for a live worker
# prints the worker prompt (a SessionStart hook's stdout becomes model context),
# see the SessionStart branch. A Stop for a worker with committed work, a clean
# tree and no done event prints one {"decision":"block"} nudge to run
# --mark-done, once. A Stop for an idle worker with a clean tree and no commits
# prints one {"decision":"block"} nudge to start the task without a "go", once
# (see the Stop branch). Helper errors go to stderr only. No `set -e`: a
# hook that dies partway through is a hook
# whose write silently did not happen, and the exit-0 contract has to hold on
# every path.
#
# Payload fields (SPIKE.md C6 for SessionStart and Stop; the PostToolUse shape
# was captured live on Claude Code 2.1.310): hook_event_name, cwd, session_id;
# Stop: last_assistant_message; PostToolUse: tool_name, tool_input.command.

_NODE_BIN="$(command -v node 2>/dev/null)"
[[ -n "$_NODE_BIN" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
# shellcheck source=../lib/session-state.sh
source "$SCRIPT_DIR/lib/session-state.sh" 2>/dev/null || exit 0

INPUT="$(cat)"

# json_field dotted.path: one string field of the payload, empty for anything
# that is not a string. One node call per field: a command or message can hold
# any byte, so no tab-joined read. Exit 1 only when the payload is not JSON.
json_field() {
  printf '%s' "$INPUT" | "$_NODE_BIN" -e "
    let d='';
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try{
        const v=process.argv[1].split('.').reduce((o,k)=>o==null?undefined:o[k],JSON.parse(d));
        process.stdout.write(typeof v==='string'?v:'');
      }catch{ process.exit(1) }
    });
  " "$1" 2>/dev/null
}

CWD="$(json_field cwd)" || exit 0
# An absolute path only: CWD goes to `git -C` below, and a relative or
# dash-leading value must never be read as an option.
[[ "$CWD" == /* ]] || exit 0
# The session-state helpers find the db from the process cwd, so work from the
# payload cwd, not from wherever the hook runner started.
cd "$CWD" 2>/dev/null || exit 0

# live_worker_agent reads the state db of the process cwd and resolves the
# nearest git root, so a worker whose cwd sits in a nested git repo would be
# missed. Ask from each ancestor that has a .git entry in turn, as
# permission-hold.sh does, and work from the worker's own worktree.
AGENT=""
WORKER_ROOT="$CWD"
while :; do
  if [[ -e "$WORKER_ROOT/.git" ]] \
    && AGENT="$(cd "$WORKER_ROOT" 2>/dev/null && live_worker_agent "$WORKER_ROOT" 2>/dev/null)" \
    && [[ -n "$AGENT" ]]; then
    break
  fi
  [[ "$WORKER_ROOT" == / || -z "$WORKER_ROOT" ]] && exit 0
  WORKER_ROOT="${WORKER_ROOT%/*}"; WORKER_ROOT="${WORKER_ROOT:-/}"
done
cd "$WORKER_ROOT" 2>/dev/null || exit 0

case "$(json_field hook_event_name)" in
  SessionStart)
    session_state_record_event "$AGENT" start "" >/dev/null
    # The id later reaches `claude --resume <id>` on a command line, so only a
    # plain token is stored; anything else is dropped, not escaped.
    SID="$(json_field session_id)"
    if [[ "$SID" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
      session_state_set_claude_session_id "$AGENT" "$SID" >/dev/null
    fi
    # `claude --resume` accepts --append-system-prompt-file and does not apply
    # it (SPIKE C7), so a resumed worker gets the worker prompt here instead, as
    # SessionStart session context (RESUME-CONTEXT.md: delivered). The only case
    # where this hook prints. Startup, clear and compact run in a process that
    # already got the flag. A prompt file that cannot be read prints nothing.
    if [[ "$(json_field source)" == resume ]]; then
      PROMPT_FILE="$SCRIPT_DIR/prompts/worker-dependency-awareness.md"
      if CONTEXT_JSON="$("$_NODE_BIN" -e '
        process.stdout.write(JSON.stringify({hookSpecificOutput:{
          hookEventName:"SessionStart",
          additionalContext:require("fs").readFileSync(process.argv[1],"utf8")}}));
      ' "$PROMPT_FILE" 2>/dev/null)" && [[ -n "$CONTEXT_JSON" ]]; then
        printf '%s' "$CONTEXT_JSON"
      else
        echo "worker-relay: cannot read $PROMPT_FILE; the resumed worker '$AGENT' gets no worker prompt" >&2
      fi
    fi
    ;;
  UserPromptSubmit|PreToolUse)
    # A worker that resumes after a Stop (a typed prompt, or a cross-session
    # message that may not fire UserPromptSubmit and so shows up as its first
    # tool call) is working again: idle -> busy. Only from idle, so this is one
    # DB write per resume, not one per tool call. keep-done guards done.
    BUSY_DB="$(session_state_db_path 2>/dev/null)" \
      && [[ "$(command sqlite3 -cmd ".timeout 5000" "$BUSY_DB" \
            "SELECT COALESCE(last_event, '') FROM sessions WHERE agent_id = '$(session_state_sql_escape "$AGENT")';" 2>/dev/null)" == idle ]] \
      && session_state_record_event "$AGENT" busy "" keep-done >/dev/null
    ;;
  Stop)
    session_state_record_event "$AGENT" idle "$(json_field last_assistant_message)" keep-done >/dev/null
    # Two blocking cases share one probe chain: an idle worker with a clean tree.
    # With commits ahead of base and no done event it probably skipped its
    # --mark-done step. With none ahead it probably waits for a "go" that its
    # launch system prompt already gave. stop_hook_active is set on the Stop that
    # follows a block, so this never blocks twice in a row. Every probe that
    # fails leaves its variable empty and the chain falls through.
    # The base is the branch checked out in the main checkout, as merge-review.sh
    # resolves it.
    if [[ "$(printf '%s' "$INPUT" | "$_NODE_BIN" -e '
          let d="";
          process.stdin.on("data",c=>d+=c);
          process.stdin.on("end",()=>{ try{ if(JSON.parse(d).stop_hook_active!==true) process.stdout.write("go") }catch{} });
        ' 2>/dev/null)" == go ]] \
      && STOP_DB="$(session_state_db_path 2>/dev/null)" \
      && [[ "$(command sqlite3 -cmd ".timeout 5000" "$STOP_DB" \
            "SELECT COALESCE(last_event, '') FROM sessions WHERE agent_id = '$(session_state_sql_escape "$AGENT")';" 2>/dev/null)" == idle ]] \
      && STOP_PORCELAIN="$(git -C "$WORKER_ROOT" status --porcelain 2>/dev/null)" \
      && [[ -z "$STOP_PORCELAIN" ]] \
      && STOP_COMMON="$(git -C "$WORKER_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      && STOP_BASE="$(git --git-dir="$STOP_COMMON" symbolic-ref --short HEAD 2>/dev/null)" \
      && [[ -n "$STOP_BASE" ]] \
      && STOP_AHEAD="$(git -C "$WORKER_ROOT" rev-list --count "$STOP_BASE..HEAD" 2>/dev/null)" \
      && [[ "$STOP_AHEAD" =~ ^[0-9]+$ ]] \
      && BLOCK_JSON="$("$_NODE_BIN" -e '
          const [script,label,ahead]=process.argv.slice(1);
          process.stdout.write(JSON.stringify({decision:"block",reason:ahead==="0"?
            "Your launch system prompt is the user\u0027s go for this task, so do not wait for a \"go\". Start the task now. If you need an answer, send it to the orchestrator with SendMessage and stop.":
            "Your branch has committed work and a clean tree, but the task is not marked done. If the task is finished, run: \""+script+"\" --mark-done "+label+". Then stop. If you are waiting on the user or the task is not finished, say so in one line and stop."}));
        ' "$SCRIPT_DIR/lib/dispatch-task.sh" "$AGENT" "$STOP_AHEAD" 2>/dev/null)" \
      && [[ -n "$BLOCK_JSON" ]]; then
      printf '%s' "$BLOCK_JSON"
    fi
    ;;
  PostToolUse)
    # The call finished, so it is no longer waiting for approval: put a blocked
    # row back to running.
    # A worker with a live gate hold is still waiting on another call (parallel
    # tool calls), so leave it blocked, as the sweep does (dispatch-task.sh).
    HELD=""
    if source "$SCRIPT_DIR/lib/gate-hold.sh" 2>/dev/null; then
      HOLD_DIR="$(gate_hold_dir "$WORKER_ROOT" 2>/dev/null)" || HOLD_DIR=""
      # This call ran, so a human may have answered it at the native dialog while
      # its PermissionRequest hold still waits. End that one hold (no decision is
      # written; the hook exits and its wrapper denies, which Claude Code drops
      # for an answered call). A hold of any other call stays and keeps the row
      # blocked. The ended hook needs a moment to remove its record, so skip it below.
      ENDED=""
      if [[ -n "$HOLD_DIR" ]]; then
        HOLD_OP="$(gate_hold_json_op "$INPUT")" && ENDED="$(gate_hold_end_answered "$HOLD_DIR" "$AGENT" \
          "$(json_field session_id)" "$(json_field tool_name)" \
          "$(gate_hold_op_hash "$(json_field tool_name)" "$HOLD_OP")")"
      fi
      for HOLD_ID in $([[ -n "$HOLD_DIR" ]] && gate_hold_live_ids "$HOLD_DIR"); do
        [[ "$HOLD_ID" == "$ENDED" ]] && continue
        [[ "$(gate_hold_pending_field "$HOLD_DIR" "$HOLD_ID" label)" == "$AGENT" ]] && HELD=1
      done
    fi
    if [[ -z "$HELD" ]]; then
      [[ "$(session_state_read "$AGENT" 2>/dev/null)" == blocked ]] \
        && session_state_update_status "$AGENT" running >/dev/null
    fi
    case "$(json_field tool_name)" in
      Bash|mcp__lean-ctx__ctx_shell)
        # Same pattern as git-approval-gate.sh. A false positive (a git log that
        # mentions "commit") only records the latest subject again.
        if printf '%s' "$(json_field tool_input.command)" | grep -qE -- '\bgit\b[^;|&]*\bcommit\b'; then
          session_state_record_event "$AGENT" commit "$(git -C "$CWD" log -1 --format=%s 2>/dev/null)" >/dev/null
        fi
        ;;
    esac
    ;;
esac

exit 0
