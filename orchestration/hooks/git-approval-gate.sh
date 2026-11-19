#!/bin/bash
# git-approval-gate.sh — PreToolUse hook: require in-session permission for git push and gh pr create
# Holds: git push, gh pr create (commits pass)
# Approval: a live dispatched worker's op is held for Helm and denied
# (with a notification) at the deadline; anyone else gets the native Claude Code
# permission prompt (yes/no). Yes runs the op, no stops it.

INPUT=$(cat)

CMD=$(echo "$INPUT" | node -e "
  let d='';
  process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try{ process.stdout.write(JSON.parse(d).tool_input?.command||'') }
    catch{ process.exit(1) }
  });
" 2>/dev/null)
NODE_EXIT=$?

# Fail-closed on a genuine parse failure: node couldn't read the payload at all.
if [[ $NODE_EXIT -ne 0 ]]; then
  printf '{"decision":"block","reason":"Could not parse tool input (node exit %d) — blocking git operation as precaution. Check node availability and hook health before retrying."}' "$NODE_EXIT"
  exit 2
fi

# Parsed fine but carries no command — ctx_shell job control (background_action +
# job_id) executes nothing, so there is nothing to gate. Anything else that somehow
# arrives without a command stays blocked.
if [[ -z "$CMD" ]]; then
  if echo "$INPUT" | grep -q '"background_action"'; then
    exit 0
  fi
  printf '{"decision":"block","reason":"Tool input had no command field — blocking git operation as precaution."}'
  exit 2
fi

# Block --no-verify outright: CLAUDE.md forbids it, and GSD's commit helper accepts
# it as a passthrough flag where the bare `git commit` pattern would not see it.
if echo "$CMD" | grep -qE '\-\-no-verify\b'; then
  printf '{"decision":"block","reason":"--no-verify is forbidden. Run the commit without it and let the hooks execute."}'
  exit 2
fi

# Load the hold libraries once, relative to this script. A failed load never blocks: the deny check below is skipped and git ops
# fall through to the plain ask.
GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/lib"
GATE_LIB_OK=""
source "$GATE_LIB_DIR/session-state.sh" 2>/dev/null \
  && source "$GATE_LIB_DIR/gate-hold.sh" 2>/dev/null \
  && GATE_LIB_OK=1

# json_field name: one top-level string field of the payload. One node call per
# field: a command can hold any byte, so no tab-joined read.
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

# live_worker_agent lives in session-state.sh (shared with worker-relay.sh). Both
# call sites below sit behind a GATE_LIB_OK check, so a failed library load never
# reaches an undefined function.

# Deny a live worker's command that names the hold directory: a worker could
# otherwise approve its own git op with a parallel tool call that writes the
# decision file (D-06). The bare word, since a relative path (`cd .claude &&
# ... gate-holds/x`, `.claude/./gate-holds/x`) never holds the full path; workers
# only, so a non-worker's commit message or grep that says "gate-holds" is
# untouched.
# Best-effort and knowingly dodgeable ($IFS, variable indirection); it does not
# cover file tools such as ctx_patch. Do not add parsing to chase those.
if [[ -n "$GATE_LIB_OK" && "$CMD" == *"$GATE_HOLD_DIRNAME"* ]] \
    && live_worker_agent "$(json_field cwd)" >/dev/null; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"This command names the approval decision directory (%s). Workers may not read or write approval decisions."}}' "$GATE_HOLD_DIRNAME"
  exit 0
fi

# Only gate git write operations. The gsd-tools patterns are here because GSD's
# commit helper reaches git via Node's spawnSync, invisible to PreToolUse hooks —
# the outer command is all we can match on.
#
# git_write_op prints "commit" or "push" when the command runs that git subcommand
# (the first non-option word after `git`), else nothing. One call feeds both the
# filter and the OP label below. A missing helper or a node failure prints "push",
# so the op is held, never passed.
git_write_op() {
  local out
  out=$(printf '%s' "$CMD" | node "$GATE_LIB_DIR/git-subcommand.js" 2>/dev/null) || out=push
  [[ -f "$GATE_LIB_DIR/git-subcommand.js" ]] || out=push
  printf '%s' "$out"
}
GIT_OP=$(git_write_op)

# Commits (git commit, the GSD commit helper) are not held. Only a push or
# `gh pr create` waits for approval.
if [[ "$GIT_OP" != push ]] && ! echo "$CMD" | grep -qE '\bgh\b[^;|&]*\bpr[[:space:]]+create\b'; then
  exit 0
fi

# Determine which op for the prompt label
if [[ "$GIT_OP" == push ]]; then
  OP="git push"
else
  OP="gh pr create"
fi

# gate_notify title body: one away-from-desk notification. approval_notify never
# blocks and never fails its caller; a missing notify.sh just means no
# notification, the deny below is already printed. The body is built from fixed
# strings and the label only, never from the command text, so a worker cannot
# put its own words in front of you.
gate_notify() {
  [[ -n "$GATE_LIB_OK" ]] || return 0
  source "$GATE_LIB_DIR/notify.sh" 2>/dev/null || return 0
  approval_notify "$(session_state_flatten_message "$1")" "$(session_state_flatten_message "$2")" >/dev/null 2>&1
  return 0
}

# hold_denied agent why: the hold for a live worker ended without a band decision
# (deadline) or could not be set up. D-05: nothing falls back to a native prompt,
# because a headless worker has nobody at its pane. Print the deny first, then
# notify, then exit; the EXIT trap (if the hold got that far) removes pending.
hold_denied() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
    "This $OP was denied: $2. Run it again to ask again."
  gate_notify "Worker $1: $OP denied" "$OP: $2"
  exit 0
}

# Hold a dispatched worker's git op until the band writes a decision for this
# exact tool call (keyed by tool_use_id and op hash). Returns 1 only when there is
# no live worker to hold for (libraries not loaded, no cwd, not a live worker), so
# the caller prints the plain ask for the human. From the moment the cwd resolves
# to a live worker every failure ends in hold_denied, which exits. This script
# must never crash or exit non-zero outside its block paths: the registration
# carries onFailure "block". Reads no pane, sends no keystroke, and never reads
# pending_operation/op_seq.
hold_for_band() {
  local tool_name stdin_cwd agent limit
  [[ -n "$GATE_LIB_OK" ]] || return 1

  stdin_cwd=$(json_field cwd) || return 1
  [[ -n "$stdin_cwd" ]] || return 1
  # Only a live dispatched worker waits (D-10).
  agent=$(live_worker_agent "$stdin_cwd") || return 1

  GATE_TOOL_ID=$(json_field tool_use_id) && gate_hold_id_valid "$GATE_TOOL_ID" \
    || hold_denied "$agent" "no usable tool_use_id, so no hold could be set up"
  tool_name=$(json_field tool_name) \
    || hold_denied "$agent" "the tool name could not be read, so no hold could be set up"
  GATE_HOLD_DIR_PATH=$(gate_hold_dir) \
    || hold_denied "$agent" "the hold directory could not be created"
  GATE_OP_HASH=$(gate_hold_op_hash "$tool_name" "$CMD")
  # A missing shasum or awk leaves the hash empty and no decision could ever match it.
  [[ "$GATE_OP_HASH" =~ ^[0-9a-f]{64}$ ]] \
    || hold_denied "$agent" "the op hash could not be computed (shasum or awk missing)"

  # The gate's own deadline sits below the 900 s hook registration timeout so this
  # script, not Claude Code's timeout, decides (D-03). Tests shorten it.
  limit="${APPROVAL_GATE_DEADLINE_SECS:-600}"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=600
  # The wait, its traps and its cleanup live in gate-hold.sh (shared with the
  # PermissionRequest hook). It runs in this shell, so the traps are this hook's.
  gate_hold_run "$GATE_HOLD_DIR_PATH" "$GATE_TOOL_ID" "$agent" "$GATE_OP_HASH" "$stdin_cwd" "$tool_name" "$CMD" "$limit" \
    || hold_denied "$agent" "the pending record could not be written"
  case "$GATE_HOLD_OUTCOME" in
    allow)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved from Helm."}}' ;;
    deny)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied from Helm."}}' ;;
    *)
      hold_denied "$agent" "the hold waited $limit seconds with no band decision" ;;
  esac
  exit 0
}

hold_for_band

# Surface a native yes/no permission prompt. Yes runs the op, no stops it.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Approve this %s?"}}' "$OP"
exit 0
