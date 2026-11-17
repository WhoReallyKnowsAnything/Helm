#!/bin/bash
# permission-hold.sh — PermissionRequest hook: hold a live worker's permission
# prompt for Helm instead of showing it on the worker's pane.
# Covers every tool (the git gate covers git ops by PreToolUse). A live
# dispatched worker's prompt is held until the band writes a decision, and it is
# denied (with a notification) at the deadline or when the hold cannot be set up.
# Anyone else gets no output from this hook, so the native prompt shows.
# Reads no pane, sends no keystroke, never calls tmux. Always exits 0: the
# registration wrapper (docs/approval-relay-setup.md) covers the hook failing.

INPUT=$(cat)

# json_field name: one top-level string field of the payload. One node call per
# field: a value can hold any byte, so no tab-joined read.
json_field() {
  printf '%s' "$INPUT" | node -e "
    let d='';
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try{ process.stdout.write(String(JSON.parse(d)[process.argv[1]]||'')) }
      catch{ process.exit(1) }
    });
  " "$1" 2>/dev/null
}

# json_op: the operation text of the payload (gate_hold_json_op, shared with
# worker-relay.sh so a PostToolUse hashes the same text as this request).
json_op() { gate_hold_json_op "$INPUT"; }

# permission_deny message: the PermissionRequest deny shape. The message is fixed
# text chosen here, never payload text, so it needs no JSON escaping.
permission_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"%s"}}}' "$1"
}

cwd=$(json_field cwd) || exit 0
[[ "$cwd" == /* ]] || exit 0

# Load the hold libraries relative to this script. A failed load must not hand a
# live worker the native prompt: with the libraries gone the worker lookup is
# gone too, so fall back to the path rule the registration wrapper uses (a cwd
# under /.claude/worktrees/ is denied, any other prints nothing).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/lib"
LIB_OK=""
source "$LIB_DIR/session-state.sh" 2>/dev/null \
  && source "$LIB_DIR/gate-hold.sh" 2>/dev/null \
  && declare -F live_worker_agent gate_hold_run gate_hold_permission_id gate_hold_json_op >/dev/null \
  && LIB_OK=1
if [[ -z "$LIB_OK" ]]; then
  case "$cwd" in
    */.claude/worktrees/*)
      permission_deny "The approval hold libraries could not be loaded, so this call from a live worker is denied. Restore orchestration/lib and retry." ;;
  esac
  exit 0
fi

# find_live_worker cwd: sets agent and WORKER_ROOT (the worktree that holds the
# cwd). Not run in a subshell, so both survive. live_worker_agent reads the state
# db of the process's own cwd and resolves the nearest git root, so it is asked
# from each ancestor that has a .git entry in turn. A worker whose cwd sits in a
# nested git repo (nearest root = the nested repo, which has no state db) is still
# found at its own worktree, and the lookup does not depend on the directory
# Claude Code started this hook in.
find_live_worker() {
  local d="$1"
  while :; do
    if [[ -e "$d/.git" ]] && agent=$(cd "$d" 2>/dev/null && live_worker_agent "$d"); then
      WORKER_ROOT="$d"
      return 0
    fi
    [[ "$d" == / || -z "$d" ]] && return 1
    d="${d%/*}"; d="${d:-/}"
  done
}

agent=""; WORKER_ROOT=""
find_live_worker "$cwd" || exit 0
# The hold dir, the pending record and the blocked event all resolve the state
# store from the process cwd: make that the worker's own worktree.
cd "$WORKER_ROOT" 2>/dev/null || exit 0

# gate_notify title body: one away-from-desk notification, never blocking and
# never failing the hook. The body is fixed text plus the worker label, never
# payload text, so a worker cannot put its own words in front of you.
gate_notify() {
  source "$LIB_DIR/notify.sh" 2>/dev/null || return 0
  approval_notify "$(session_state_flatten_message "$1")" "$(session_state_flatten_message "$2")" >/dev/null 2>&1
  return 0
}

# hold_denied why: the hold ended without a band decision (deadline) or could not
# be set up. A headless worker has nobody at its pane, so nothing falls back to a
# native prompt. Deny first, then notify; the EXIT trap removes the pending record.
hold_denied() {
  permission_deny "This request was denied: $1. Try again to ask again."
  gate_notify "Worker $agent: permission request denied" "A permission request was denied: $1"
  exit 0
}

tool_name=$(json_field tool_name) && [[ -n "$tool_name" ]] \
  || hold_denied "the tool name could not be read, so no hold could be set up"
# D-04: a worker cannot ask the user or leave plan mode on its own, and nobody
# watches its pane. Deny at once, with no hold and no wait; the message is what the
# model reads, so it says what to do instead.
# Lifted for AskUserQuestion only, and only for a listed stage worker (see
# lib/question-stages.sh): the app shows its question as a card. The hook prints
# NOTHING there, never "allow" (that would run the tool with no human answer), so the
# request reaches the session's stdio prompt. Claude Code 2.1.322 accepts only allow
# and deny from a PermissionRequest hook, so "ask" is not available. The
# registration wrapper passes this one empty output through (docs/approval-relay-setup.md).
# The library is sourced outside LIB_OK: if it is missing the question stays denied.
source "$LIB_DIR/question-stages.sh" 2>/dev/null
case "$tool_name" in
  AskUserQuestion)
    if declare -F question_stage_allowed >/dev/null && question_stage_allowed "$agent"; then
      exit 0
    fi
    permission_deny "Workers cannot use $tool_name. Send the question or the plan to the orchestrator with SendMessage, and wait for the answer."
    exit 0 ;;
  ExitPlanMode)
    permission_deny "Workers cannot use $tool_name. Send the question or the plan to the orchestrator with SendMessage, and wait for the answer."
    exit 0 ;;
esac
session_id=$(json_field session_id)
op=$(json_op) || hold_denied "the tool input could not be read, so no hold could be set up"
hold_dir=$(gate_hold_dir) || hold_denied "the hold directory could not be created"
op_hash=$(gate_hold_op_hash "$tool_name" "$op")
# A missing shasum or awk leaves the hash empty and no decision could ever match it.
[[ "$op_hash" =~ ^[0-9a-f]{64}$ ]] \
  || hold_denied "the op hash could not be computed (shasum or awk missing)"
# The request has no tool_use_id: the id is session + tool + hash prefix + a nonce
# unique to this hook run, so two identical requests never share a key.
hold_id=$(gate_hold_permission_id "$session_id" "$tool_name" "$op_hash" "$$-$RANDOM-$(date +%s)") \
  && gate_hold_id_valid "$hold_id" \
  || hold_denied "no usable hold id could be built"

# The deadline sits below the 900 s registration timeout so this script, not
# Claude Code's timeout, decides. Tests shorten it. Same knob as the git gate.
limit="${APPROVAL_GATE_DEADLINE_SECS:-600}"
[[ "$limit" =~ ^[0-9]+$ ]] || limit=600
# The wait, its traps and its cleanup live in gate-hold.sh (shared with the git
# gate). It runs in this shell, so the traps are this hook's.
gate_hold_run "$hold_dir" "$hold_id" "$agent" "$op_hash" "$cwd" "$tool_name" "$op" "$limit" \
  || hold_denied "the pending record could not be written"
case "$GATE_HOLD_OUTCOME" in
  allow)
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
  deny)
    permission_deny "Denied from Helm." ;;
  *)
    hold_denied "the hold waited $limit seconds with no band decision" ;;
esac
exit 0
