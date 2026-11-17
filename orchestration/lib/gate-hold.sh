#!/bin/bash
# orchestration/lib/gate-hold.sh
# Sourced library: the single owner of the gate-hold channel. The git approval
# gate (orchestration/hooks/git-approval-gate.sh) holds a worker's git op until
# the band writes a decision file keyed by tool_use_id AND op hash; this file
# defines where those files live and what a valid one looks like.
#
# Per tool_use_id, up to three files under <project root>/.claude/gate-holds/:
#   <id>.pending   written by the gate: label, op hash, hook PID, epoch, cwd, hook start time, op text
#   <id>.decision  written by the band: exactly "allow <sha256>" or "deny <sha256>"
#   <id>.notified  written by the sweep once it has notified for this hold; goes with the pending record
#
# No `set -e` and no output on source: a hook that sources this must not die.
# No tmux and no pane code, ever: the channel is files only.

source "$(dirname "${BASH_SOURCE[0]}")/session-state.sh" 2>/dev/null

# The hold directory's name; the gate denies commands that contain it (D-06).
GATE_HOLD_DIRNAME="gate-holds"

# gate_hold_dir [target_dir]
# Prints (and creates) <project root>/.claude/gate-holds. The root is the parent
# of git-common-dir, resolved by session_state_db_path, so a linked worktree and
# the main checkout share one directory.
gate_hold_dir() {
    local db_path dir
    db_path=$(session_state_db_path "${1:-.}" 2>/dev/null) || return 1
    dir="$(dirname "$db_path")/$GATE_HOLD_DIRNAME"
    mkdir -p "$dir" || return 1
    echo "$dir"
}

# gate_hold_id_valid id
# 1 to 128 of letters, digits, underscore, hyphen: the id becomes a filename.
gate_hold_id_valid() {
    local LC_ALL=C re='^[A-Za-z0-9_-]{1,128}$'
    [[ "$1" =~ $re ]]
}

# gate_hold_op_hash tool_name command
# Lowercase hex SHA-256 of "<tool_name>: <command>". Holds and worker-relay.sh
# depend on this exact shape. Piped from printf so no byte of the command is trimmed.
gate_hold_op_hash() {
    printf '%s: %s' "$1" "$2" | shasum -a 256 | awk '{print $1}'
}

# gate_hold_permission_id session_id tool_name op_hash nonce
# The hold id of a PermissionRequest hold, which carries no tool_use_id: "perm-",
# the session id, the tool name, a short prefix of the op hash and the nonce, with
# every character outside [A-Za-z0-9_-] replaced by "_" (the payload is untrusted
# and the id becomes a filename). At most 116 characters, so it passes
# gate_hold_id_valid. Two identical requests differ by the nonce alone: the caller
# must make it unique per hook run, and an empty nonce is refused.
gate_hold_permission_id() {
    local LC_ALL=C s t n h
    s="${1//[^A-Za-z0-9_-]/_}"; t="${2//[^A-Za-z0-9_-]/_}"
    h="${3//[^0-9a-f]/}"; n="${4//[^A-Za-z0-9_-]/_}"
    [[ -n "$n" ]] || return 1
    printf 'perm-%s-%s-%s-%s' "${s:0:36}" "${t:0:30}" "${h:0:12}" "${n:0:30}"
}

# _gate_hold_write_atomic dir file  (content on stdin)
# Temp file in the same dir, then rename: a reader never sees a partial record.
_gate_hold_write_atomic() {
    local tmp
    tmp=$(mktemp "$1/.tmp.XXXXXX") || return 1
    if cat > "$tmp" && mv -f "$tmp" "$1/$2"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# _gate_hold_start_time pid
# The process start time, whitespace-normalised; empty when the process is gone.
# Pinned to LC_ALL=C TZ=UTC: the hook and the band read it from different environments.
_gate_hold_start_time() {
    LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | awk '{$1=$1; print}'
}

# gate_hold_pending_write dir id label op_hash cwd tool_name command
# Lines: label, op hash, hook PID ($$), epoch seconds, cwd, the hook's process
# start time, then the op text as the remainder (it may span lines). Newlines
# are stripped from label and cwd. No start time, no record: readers could never
# call such a record live, so the caller takes the plain ask instead.
gate_hold_pending_write() {
    local dir="$1" id="$2" label="${3//$'\n'/}" cwd="${5//$'\n'/}" start
    start=$(_gate_hold_start_time "$$")
    [[ -n "$start" ]] || return 1
    {
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$label" "$4" "$$" "$(date +%s)" "$cwd" "$start"
        printf '%s: %s' "$6" "$7"
    } | _gate_hold_write_atomic "$dir" "$id.pending"
}

# gate_hold_pending_field dir id label|hash|pid|epoch|cwd|start|op
# Prints one field of a pending record; `op` is everything after line 6, raw.
gate_hold_pending_field() {
    local f="$1/$2.pending"
    [[ -f "$f" ]] || return 1
    case "$3" in
        label) sed -n '1p' "$f" ;;
        hash)  sed -n '2p' "$f" ;;
        pid)   sed -n '3p' "$f" ;;
        epoch) sed -n '4p' "$f" ;;
        cwd)   sed -n '5p' "$f" ;;
        start) sed -n '6p' "$f" ;;
        op)    tail -n +7 "$f" ;;
        *)     return 1 ;;
    esac
}

# gate_hold_decision_read dir id expected_hash
# Prints "allow" or "deny" and returns 0 only for a file that is exactly
# "<allow|deny> <expected_hash>" with at most one trailing LF. Any other shape
# (wrong hash, other verdict, extra tokens, short hash, empty, CR) is "no
# decision": return 1, print nothing, never allow (D-01).
gate_hold_decision_read() {
    local LC_ALL=C f="$1/$2.decision" content re='^(allow|deny) ([0-9a-f]{64})$'
    [[ -f "$f" ]] || return 1
    content=$(cat "$f" 2>/dev/null; printf x) || return 1
    content="${content%x}"
    content="${content%$'\n'}"
    [[ "$content" =~ $re ]] || return 1
    [[ "${BASH_REMATCH[2]}" == "$3" ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# gate_hold_decision_write dir id allow|deny op_hash
# The band's write, by temp file and rename. The hash is the one the human was
# shown; the gate accepts the file only if it equals the hash it computed.
gate_hold_decision_write() {
    printf '%s %s\n' "$3" "$4" | _gate_hold_write_atomic "$1" "$2.decision"
}

# gate_hold_cleanup dir id
# Removes this call's decision, notified and pending files, pending last: a
# reader that still sees a decision then still sees its record (--gate-decide's
# post-write check relies on it).
gate_hold_cleanup() {
    rm -f "$1/$2.decision" "$1/$2.notified" "$1/$2.pending"
}

# gate_hold_run dir id label op_hash cwd tool_name op_text deadline_secs
# The wait half of a hold, shared by every hook that holds a worker's call. It
# runs in the CALLER's shell, never a subshell: the traps below must belong to
# the hook process, and $$ in the pending record must be the hook's PID.
# Sets GATE_HOLD_OUTCOME to allow, deny or deadline and returns 0. Returns 1 when
# the pending record could not be written; the caller decides what that ends in.
# The caller formats the hook output. Reads no pane, sends no keystroke.
gate_hold_run() {
    local verdict end
    _GATE_HOLD_RUN_DIR="$1" _GATE_HOLD_RUN_ID="$2"
    GATE_HOLD_OUTCOME=""
    # Every exit after this point goes through the same cleanup: allow, deny and
    # deadline fall to the EXIT trap directly; Esc and the hook timeout send
    # SIGTERM (INT and HUP likewise), which exit and so reach it. Installed before
    # the pending write so no signal can land between the record and its cleanup.
    trap 'gate_hold_cleanup "$_GATE_HOLD_RUN_DIR" "$_GATE_HOLD_RUN_ID"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    gate_hold_pending_write "$1" "$2" "$3" "$4" "$5" "$6" "$7" || return 1
    # D-02: the status board reads the worker's state from its row. Once per hold,
    # here and never in the loop below. A failed write must not change the hold, so
    # its status is ignored and its own stderr line is let through.
    session_state_record_event "$3" blocked "$6: $7" || true

    # The caller's deadline sits below the 900 s hook registration timeout so this
    # script, not Claude Code's timeout, decides (D-03). Tests shorten it.
    end=$((SECONDS + $8))
    until verdict=$(gate_hold_decision_read "$1" "$2" "$4"); do
        if (( SECONDS >= end )); then
            GATE_HOLD_OUTCOME=deadline
            return 0
        fi
        sleep 0.5
    done
    GATE_HOLD_OUTCOME="$verdict"
    return 0
}

# gate_hold_pid_alive pid
# A real signalable process: pid 0 would signal the caller's own process group
# and pid 1 is never a gate.
gate_hold_pid_alive() {
    [[ "$1" =~ ^[1-9][0-9]*$ && "$1" != 1 ]] && kill -0 "$1" 2>/dev/null
}

# gate_hold_record_live dir id
# Whether a pending record's hook is still the process that wrote it: its pid is
# alive AND that pid's start time equals the one recorded, so a recycled pid is
# not a live gate. A record with no start time (an older layout, or none) never
# matches and reads as dead.
gate_hold_record_live() {
    local pid start
    pid=$(gate_hold_pending_field "$1" "$2" pid) || return 1
    start=$(gate_hold_pending_field "$1" "$2" start) || return 1
    gate_hold_pid_alive "$pid" && [[ -n "$start" && "$(_gate_hold_start_time "$pid")" == "$start" ]]
}

# gate_hold_live_ids dir
# One id per line for every pending record whose hook is alive. A dead-hook
# record is a crashed gate's leftover, never a hold the band can answer.
gate_hold_live_ids() {
    local f id
    for f in "$1"/*.pending; do
        [[ -e "$f" ]] || continue
        id=$(basename "$f" .pending)
        if gate_hold_record_live "$1" "$id"; then echo "$id"; fi
    done
    return 0
}

# gate_hold_prune dir
# Removes every pending record whose hook is dead (a SIGKILLed gate cannot trap,
# D-11) together with its decision and notified files, and every decision or
# notified file with no pending record beside it: a --gate-decide that passed its
# checks just before the gate's deadline cleanup leaves the first, a sweep that
# notified just after it the second.
gate_hold_prune() {
    local f id
    for f in "$1"/*.pending; do
        [[ -e "$f" ]] || continue
        id=$(basename "$f" .pending)
        gate_hold_record_live "$1" "$id" || rm -f "$f" "$1/$id.decision" "$1/$id.notified"
    done
    for f in "$1"/*.decision "$1"/*.notified; do
        [[ -e "$f" ]] || continue
        [[ -e "${f%.*}.pending" ]] || rm -f "$f"
    done
    return 0
}

# gate_hold_json_op payload
# The operation text of a hook payload: tool_input.command, then .url, then the
# whole tool_input as compact JSON. Shared by
# permission-hold.sh (hashing a request) and worker-relay.sh (matching its
# PostToolUse), so both hash the same text. Exit 1 when the payload is not JSON.
gate_hold_json_op() {
    printf '%s' "$1" | node -e "
      let d='';
      process.stdin.on('data',c=>d+=c);
      process.stdin.on('end',()=>{
        try{
          let ti=JSON.parse(d).tool_input;
          if(ti===null||typeof ti!=='object') ti={};
          process.stdout.write(ti.command!==undefined ? String(ti.command)
            : ti.url!==undefined ? String(ti.url) : JSON.stringify(ti));
        }catch{ process.exit(1) }
      });
    " 2>/dev/null
}

# gate_hold_end_answered dir label session_id tool_name op_hash
# A call answered at the native dialog fires PostToolUse while its PermissionRequest
# hold still waits. End that hold: signal its hook, whose TERM trap runs the normal
# cleanup. Writes NO decision. The hook then prints nothing and exits 143, which the
# registration wrapper turns into a deny for a live worker, so a wrong match fails
# closed, never allow. The match is the exact call's key: label, session, tool and
# the full op hash. Of several identical holds only the oldest ends. Prints the
# ended id; returns 1 when no live hold matched.
gate_hold_end_answered() {
    local dir="$1" label="$2" prefix id best="" best_epoch epoch pid
    prefix=$(gate_hold_permission_id "$3" "$4" "$5" N) || return 1
    prefix="${prefix%N}"
    for id in $(gate_hold_live_ids "$dir"); do
        [[ "$id" == "$prefix"* ]] || continue
        [[ "$(gate_hold_pending_field "$dir" "$id" label)" == "$label" ]] || continue
        [[ "$(gate_hold_pending_field "$dir" "$id" hash)" == "$5" ]] || continue
        epoch=$(gate_hold_pending_field "$dir" "$id" epoch)
        if [[ -z "$best" ]] || (( epoch < best_epoch )); then best="$id"; best_epoch="$epoch"; fi
    done
    [[ -n "$best" ]] || return 1
    pid=$(gate_hold_pending_field "$dir" "$best" pid)
    gate_hold_record_live "$dir" "$best" && kill -TERM "$pid" 2>/dev/null || return 1
    echo "$best"
}

return 0 2>/dev/null || true
