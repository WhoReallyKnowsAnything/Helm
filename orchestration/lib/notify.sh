#!/bin/bash
# orchestration/lib/notify.sh
# Away-from-desk notification shim (D-06): ntfy primary, local macOS
# notification secondary. Source this file to use approval_notify.
#
# approval_notify never blocks and never fails its caller -- it is called
# from the detection path, where a notification failure that propagated
# would stall the very thing it exists to report.

# _notify_conf_path [target_dir]
# Resolves .claude/approval-relay.conf at the main repo root -- same
# --git-common-dir algorithm as session_state_db_path (session-state.sh),
# not --show-toplevel, so a worker in a linked worktree finds the real
# (gitignored, .gitignore:1) config file rather than looking for one next
# to its own worktree.
_notify_conf_path() {
    local target_dir="${1:-.}"
    local git_common_dir

    git_common_dir=$(command git -C "$target_dir" rev-parse --git-common-dir 2>/dev/null) || return 1

    if [[ "$git_common_dir" != /* ]]; then
        git_common_dir="$(cd "$target_dir" && pwd)/$git_common_dir"
    fi

    printf '%s\n' "$(dirname "$git_common_dir")/.claude/approval-relay.conf"
}

# Sourced only if present. Never a default value, never a committed example
# carrying a real topic -- APPROVAL_NTFY_TOPIC_URL is a bearer secret.
_NOTIFY_CONF_PATH="$(_notify_conf_path 2>/dev/null)" || _NOTIFY_CONF_PATH=""
if [[ -n "$_NOTIFY_CONF_PATH" && -f "$_NOTIFY_CONF_PATH" ]]; then
    # shellcheck source=/dev/null
    source "$_NOTIFY_CONF_PATH" 2>/dev/null || true
fi

# _notify_as_escape text
# AppleScript string-literal escaping -- backslash first, then double
# quote, order load-bearing. Copied from dispatch-task.sh's _as_escape
# rather than sourced: dispatch-task.sh is a `set -euo pipefail` script
# that executes on source, so it cannot be sourced for this helper alone.
# This is NOT the shell's own quoting substitution -- that escapes for
# re-entering a shell, which is meaningless to AppleScript's grammar. Getting
# the escape order wrong here once already cost this repo every tab and
# every session record (see dispatch-task.sh's comment above _as_escape).
_notify_as_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# approval_notify title body
# Fires both channels. Always returns 0, on every path, including when
# both channels fail.
approval_notify() {
    local title="$1" body="$2"

    if [[ -n "${APPROVAL_NTFY_TOPIC_URL:-}" ]]; then
        # Backgrounded and output discarded: a slow or unreachable host must
        # never make this call wait. --max-time bounds the background job
        # itself, not this function's return.
        curl -fsS --max-time 5 -H "Title: $title" -d "$body" "$APPROVAL_NTFY_TOPIC_URL" \
            >/dev/null 2>&1 &
    fi

    local esc_title esc_body
    esc_title="$(_notify_as_escape "$title")"
    esc_body="$(_notify_as_escape "$body")"
    osascript -e "display notification \"$esc_body\" with title \"$esc_title\"" \
        >/dev/null 2>&1 || true

    return 0
}

# Export functions for sourcing
return 0 2>/dev/null || true
