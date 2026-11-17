#!/bin/bash
# orchestration/lib/tmux-session.sh
# Shared tmux session-group helpers for phone/desktop dual-attach launch flows.
# Source this file to use the functions.

# With ORCH_TMUX_SOCKET set when this file is sourced, every tmux call of the
# script that sources it targets the private server `tmux -L $ORCH_TMUX_SOCKET`.
# Unset or empty: no function, nothing changes. The function makes `command -v
# tmux` print "tmux", so a path is read with `type -P tmux`.
if [[ -n "${ORCH_TMUX_SOCKET:-}" ]]; then
    tmux() { command tmux ${ORCH_TMUX_SOCKET:+-L "$ORCH_TMUX_SOCKET"} "$@"; }
fi

# tmux_base_session_name target_dir
# Returns a slugified base session name derived from target_dir's basename.
# A linked worktree is named after its MAIN repository (the git dir differs
# from the git common dir, the same signal session-state.sh uses), so a
# worktree and its main checkout share one orchestrator session. Any other
# path, git or not, is slugged exactly as given (no symlink resolution).
tmux_base_session_name() {
    local target_dir="$1" name git_dir common_dir
    name="$target_dir"
    if [[ -d "$target_dir" ]] \
        && git_dir="$(command git -C "$target_dir" rev-parse --absolute-git-dir 2>/dev/null)" \
        && common_dir="$(command git -C "$target_dir" rev-parse --git-common-dir 2>/dev/null)" \
        && common_dir="$(cd "$target_dir" && cd "$common_dir" && pwd -P)" \
        && [[ "$git_dir" != "$common_dir" ]]; then
        name="$(dirname "$common_dir")"
    fi
    basename "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# orch_session_name target_dir
# The orchestrator's Claude Code roster name (claude --name, what ListAgents and
# SendMessage use): "dashboard-<project slug>". The bare word "dashboard" is the
# state-store row id and the tmux window name, the same in every project; with
# 2+ projects open it made every orchestrator's roster name collide.
orch_session_name() {
    printf 'dashboard-%s' "$(tmux_base_session_name "$1")"
}

# env_file_records file
# Reads the GUI app's captured environment (KEY=VALUE records as `env` prints
# them) and writes each record to stdout as NAME=VALUE followed by a NUL byte,
# so embedded newlines survive (read it with `read -r -d ''`).
# A line that starts with a variable name (letter or underscore, then letters,
# digits or underscores) and `=` begins a record; the value is everything after
# that first `=`, byte for byte. Every other line continues the previous record,
# joined by one newline. Lines before the first record are dropped, a later
# record with a seen name replaces the earlier one in place, and a missing final
# newline is accepted. The file is untrusted: it is only read, never sourced,
# evaluated or word-split.
env_file_records() {
    local LC_ALL=C file="$1" line name n=0 i cur=-1
    local names=() values=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        name="${line%%=*}"
        if [[ "$line" == *=* && "$name" == [A-Za-z_]* && "$name" != *[!A-Za-z0-9_]* ]]; then
            cur=-1
            for ((i = 0; i < n; i++)); do
                [[ "${names[i]}" == "$name" ]] && cur=$i
            done
            if [[ "$cur" -lt 0 ]]; then
                cur=$n
                names[n]="$name"
                n=$((n + 1))
            fi
            values[cur]="${line#*=}"
        elif [[ "$cur" -ge 0 ]]; then
            values[cur]="${values[cur]}"$'\n'"$line"
        fi
    done <"$file"
    for ((i = 0; i < n; i++)); do
        printf '%s=%s\0' "${names[i]}" "${values[i]}"
    done
}

# env_file_value file name
# Prints the value of one variable from the env file (see env_file_records);
# returns 1 when the file does not hold it.
env_file_value() {
    local rec
    while IFS= read -r -d '' rec; do
        if [[ "${rec%%=*}" == "$2" ]]; then
            printf '%s' "${rec#*=}"
            return 0
        fi
    done < <(env_file_records "$1")
    return 1
}

# _tmux_dq value
# Writes value as one double-quoted word of tmux command syntax. Backslash,
# double quote, $ and the control characters tmux would otherwise eat (newline,
# tab, carriage return) are escaped, so the word round-trips byte for byte.
# Single quotes do not: tmux drops leading white space and `#` lines inside them.
_tmux_dq() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}

# _tmux_client tmux_bin env_file tmux_tmpdir_set tmux_tmpdir [socket]
# Runs `start-server ; source-file -` (command text on stdin) with exactly the
# env file's variables (plus TMUX_TMPDIR when set) as its environment. Arguments
# are read as $1..$5 so that no env file record can overwrite them. The socket
# name is an argument because the clear below drops ORCH_TMUX_SOCKET.
_tmux_client() {
    local _tmx_c_rec
    # clear what the caller had (readonly ones stay), then load the file
    for _tmx_c_rec in $(compgen -e); do unset "$_tmx_c_rec" 2>/dev/null; done
    if [[ -n "$2" ]]; then
        while IFS= read -r -d '' _tmx_c_rec; do
            export "${_tmx_c_rec%%=*}=${_tmx_c_rec#*=}" 2>/dev/null
        done < <(env_file_records "$2")
    fi
    [[ -n "$3" ]] && export TMUX_TMPDIR="$4"
    "$1" ${5:+-L "$5"} start-server \; source-file -
}

# _tmux_job_client tmux_bin env_file tmux_tmpdir_set tmux_tmpdir command_text [socket]
# macOS puts a tmux server in the process coalition of the app that started it,
# even after the server daemonizes, and "Stop running in background" or a force
# quit of that app kills every process in the coalition. A launchd job gets a
# coalition of its own. So this runs _tmux_client as a one-shot job in the
# gui/$UID domain and passes the command text through a FIFO: no value is in
# the plist, an argv or a file. Prints the client's exit status, `timeout` when
# the job started but sent no status in 30s, or nothing when no job ran (no
# launchctl, bootstrap failed, the job did not start in 5s). Once the job has
# started it owns the command text, so the caller never runs it a second time.
_tmux_job_client() {
    [[ -x /bin/launchctl ]] || return 0
    local dir label script arg args="" w="" i
    dir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-job.XXXXXX")" || return 0
    if ! mkfifo -m 600 "$dir/in"; then rm -rf "$dir"; return 0; fi
    label="io.github.whoreallyknowsanything.helm.tmux-client.$$.$RANDOM"
    script="$(declare -f env_file_records _tmux_client)"'
: >"$7"
exec <"$5"
_tmux_client "$1" "$2" "$3" "$4" "$8" 2>/dev/null
echo "$?" >"$6"'
    for arg in /bin/bash -c "$script" bash "$1" "$2" "$3" "$4" "$dir/in" "$dir/rc" "$dir/started" "${6-}"; do
        # sed, not ${arg//</&lt;}: bash 5.2 reads & in a replacement as the match
        args="$args<string>$(printf '%s' "$arg" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')</string>"
    done
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        "<plist version=\"1.0\"><dict><key>Label</key><string>$label</string>" \
        "<key>ProgramArguments</key><array>$args</array><key>RunAtLoad</key><true/>" \
        '<key>ProcessType</key><string>Interactive</string></dict></plist>' >"$dir/job.plist"
    # on Ctrl+C or kill: stop the writer, unload the job, remove the folder.
    # Callers run this in $(...), so the trap stays in that subshell.
    trap '[[ -n "$w" ]] && kill "$w" 2>/dev/null; /bin/launchctl bootout "gui/$UID/$label" &>/dev/null; rm -rf "$dir"; exit 130' INT TERM
    if ! /bin/launchctl bootstrap "gui/$UID" "$dir/job.plist" &>/dev/null; then
        trap - INT TERM; rm -rf "$dir"; return 0
    fi
    # opening the FIFO blocks until the job opens it, just after it creates "started"
    printf '%s\n' "$5" >"$dir/in" &
    w=$!
    for ((i = 0; i < 50; i++)); do [[ -e "$dir/started" ]] && break; /bin/sleep 0.1; done
    if [[ ! -e "$dir/started" ]]; then
        kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
        # checked again with the writer gone: a job that starts now finds no writer
        if [[ ! -e "$dir/started" ]]; then
            /bin/launchctl bootout "gui/$UID/$label" &>/dev/null; rm -rf "$dir"; trap - INT TERM; return 0
        fi
    fi
    for ((i = 0; i < 300; i++)); do [[ -s "$dir/rc" ]] && break; /bin/sleep 0.1; done
    kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    if [[ -s "$dir/rc" ]]; then printf '%s' "$(<"$dir/rc")"; else printf timeout; fi
    /bin/launchctl bootout "gui/$UID/$label" &>/dev/null
    rm -rf "$dir"
    trap - INT TERM
}

# tmux_ensure_base_session base first_window first_cmd [folder [env_file [NAME=VALUE...]]]
# Creates the base tmux session if it doesn't already exist.
# With only the first three arguments it is one plain `new-session`. With more,
# the session starts in folder with the env file's variables and then the
# NAME=VALUE arguments (which win) in its own environment, before the first pane
# process starts, so later windows inherit them. The command text goes to tmux on
# stdin and the client runs with exactly the env file's variables as its process
# environment (plus TMUX_TMPDIR, so it finds the launcher's server): no value is
# in any argv or temp file, none of the launcher's own variables reaches a
# server this call starts, and a server that already runs is left untouched.
# No ITERM_* variable (global env or env file) reaches the session's panes; the
# global env itself is not changed.
tmux_ensure_base_session() {
    local base="$1" first_window="$2" first_cmd="$3"
    type -P tmux &>/dev/null || { echo "Error: tmux is not installed" >&2; return 1; }
    if tmux has-session -t "=$base" 2>/dev/null; then
        return 0
    fi
    if [[ $# -gt 3 ]]; then
        # _tmx_ names: the subshell below unsets every exported variable, and a
        # launcher variable that shares a local's name must not unset the local
        local _tmx_dir="${4-}" _tmx_ef="${5-}" _tmx_n=$# _tmx_i _tmx_rec _tmx_text _tmx_bin _tmx_names _tmx_name _tmx_unset _tmx_post=""
        local _tmx_tt_set="${TMUX_TMPDIR+x}" _tmx_tt="${TMUX_TMPDIR-}"
        _tmx_bin="$(type -P tmux)"
        # -n and -c are format-expanded by tmux, so a literal # is written ##
        _tmx_text="new-session -d -s $(_tmux_dq "$base") -n $(_tmux_dq "${first_window//#/##}")"
        [[ -n "$_tmx_dir" ]] && _tmx_text="$_tmx_text -c $(_tmux_dq "${_tmx_dir//#/##}")"
        # ITERM_* names (never values) from the server's global env and the env file
        _tmx_names="$(tmux show-environment -g 2>/dev/null | sed -nE 's/^-?(ITERM_[A-Za-z0-9_]*)(=.*)?$/\1/p')"
        if [[ -n "$_tmx_ef" ]]; then
            while IFS= read -r -d '' _tmx_rec; do
                _tmx_text="$_tmx_text -e $(_tmux_dq "$_tmx_rec")"
                [[ "${_tmx_rec%%=*}" =~ ^ITERM_[A-Za-z0-9_]*$ ]] && _tmx_names="$_tmx_names"$'\n'"${_tmx_rec%%=*}"
            done < <(env_file_records "$_tmx_ef")
        fi
        for ((_tmx_i = 6; _tmx_i <= _tmx_n; _tmx_i++)); do
            _tmx_text="$_tmx_text -e $(_tmux_dq "${!_tmx_i}")"
        done
        _tmx_names="$(printf '%s\n' "$_tmx_names" | sort -u)"
        # env -u keeps them out of the first pane process, set-environment -r out of later windows
        _tmx_unset=""
        for _tmx_name in $_tmx_names; do
            _tmx_unset="$_tmx_unset -u $_tmx_name"
            _tmx_post="$_tmx_post"$'\n'"set-environment -t $(_tmux_dq "=$base") -r $_tmx_name"
        done
        [[ -n "$_tmx_unset" ]] && first_cmd="/usr/bin/env$_tmx_unset $first_cmd"
        _tmx_text="$_tmx_text $(_tmux_dq "$first_cmd")$_tmx_post"
        local _tmx_rc
        _tmx_rc="$(_tmux_job_client "$_tmx_bin" "$_tmx_ef" "$_tmx_tt_set" "$_tmx_tt" "$_tmx_text" "${ORCH_TMUX_SOCKET-}")"
        if [[ -z "$_tmx_rc" ]]; then # no launchd job ran: start the client here
            printf '%s\n' "$_tmx_text" | (_tmux_client "$_tmx_bin" "$_tmx_ef" "$_tmx_tt_set" "$_tmx_tt" "${ORCH_TMUX_SOCKET-}") 2>/dev/null
            _tmx_rc=$?
        fi
        # the job sent no status in time, but the session may exist all the same
        [[ "$_tmx_rc" == timeout ]] && tmux has-session -t "=$base" 2>/dev/null && _tmx_rc=0
        [[ "$_tmx_rc" == 0 ]] || { echo "Error: failed to create tmux session '$base'" >&2; return 1; }
        return 0
    fi
    tmux new-session -d -s "$base" -n "$first_window" "$first_cmd" 2>/dev/null \
        || { echo "Error: failed to create tmux session '$base'" >&2; return 1; }
}

# tmux_ensure_window base label cmd
# Creates a new window in base session, failing if label already exists (Pitfall 3)
tmux_ensure_window() {
    local base="$1" label="$2" cmd="$3"
    if tmux list-windows -t "=$base" -F '#{window_name}' 2>/dev/null | grep -qxF -- "$label"; then
        echo "Error: tmux window '$label' already exists in session '$base'" >&2
        return 1   # caller should reuse dispatch-task.sh's existing suffix-loop, not retry blindly
    fi
    tmux new-window -t "=$base:" -n "$label" "$cmd" 2>/dev/null \
        || { echo "Error: failed to create tmux window '$label'" >&2; return 1; }
}

# tmux_headless_cmd inbox out claude_cmd
# Prints the headless pipeline for a window command (workers and orchestrator):
#   tail -n +1 -f INBOX | { CLAUDE >> OUT; kill 0; }
# Window-end mechanism (D-08): a plain `tail | claude` leaves the window alive
# after claude dies, because the shell waits for tail, and macOS BSD tail has no
# --pid. tmux gives the window command its own session and process group, so
# `kill 0` after claude exits ends the shell and the tail with it, whatever
# claude's exit reason. Only POSIX syntax (brace group, kill 0), so it works
# when tmux's default shell is bash 3.2, zsh or sh. Both paths are quoted.
# shortcut: assumes a POSIX-style default-shell (not fish), switch to `sh -c` if needed.
tmux_headless_cmd() {
    local q_in q_out
    q_in="'$(printf '%s' "$1" | sed "s/'/'\\\\''/g")'"
    q_out="'$(printf '%s' "$2" | sed "s/'/'\\\\''/g")'"
    printf '%s' "tail -n +1 -f ${q_in} | { $3 >> ${q_out}; kill 0; }"
}

# tmux_client_attach_cmd base label
# Returns the command string to inject into an iTerm tab (or print in setup docs
# for phone SSH) -- the grouped-session attach that gives Pattern 1's independent focus.
tmux_client_attach_cmd() {
    local base="$1" label="$2" tmux_bin
    # absolute path: SSH forced commands run non-interactive with a bare PATH
    tmux_bin="$(type -P tmux)" || { echo "Error: tmux is not installed" >&2; return 1; }
    printf '%q%s new-session -A -t \\=%q -s %q \\; select-window -t \\=%q' "$tmux_bin" "${ORCH_TMUX_SOCKET:+ -L $(printf %q "$ORCH_TMUX_SOCKET")}" "$base" "${base}-${label}" "${base}-${label}:=${label}"
}

# tmux_teardown_worker base label
# Kills both the shared window and the grouped session that tmux_client_attach_cmd
# creates for iTerm's per-tab attach (tmux new-session -A -t base -s base-label).
# Killing only the window leaves that grouped session as a permanent zombie with
# zero attached clients -- nothing else in this codebase ever kills it.
tmux_teardown_worker() {
    local base="$1" label="$2"
    tmux kill-window -t "=${base}:=${label}" 2>/dev/null || true
    tmux kill-session -t "=${base}-${label}" 2>/dev/null || true
}

# tmux_kill_session_group base
# Kills the base session and every session whose #{session_group} equals base (the
# grouped client sessions, which carry the worker windows), by exact =name only.
# Never a prefix target and never a server-wide kill, so a sibling project whose name
# starts with base is untouched. Prints what it stopped, or that no session was found.
# An empty base is refused: every ungrouped session reports an empty #{session_group}.
# "No server running" counts as no session (status 0, safe under set -e).
tmux_kill_session_group() {
    local base="${1:-}" listing line name group killed=""
    local -a doomed=()
    if [[ -z "$base" ]]; then
        echo "Error: tmux_kill_session_group needs a base session name" >&2
        return 1
    fi
    # ':' cannot occur in a tmux session name or group name, so it separates the fields
    listing="$(tmux list-sessions -F '#{session_name}:#{session_group}' 2>/dev/null)" || listing=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%:*}"
        group="${line#*:}"
        if [[ "$name" == "$base" || "$group" == "$base" ]]; then
            doomed+=("$name")
        fi
    done <<< "$listing"
    if [[ ${#doomed[@]} -eq 0 ]]; then
        echo "no session found for '$base'"
        return 0
    fi
    for name in "${doomed[@]}"; do
        tmux kill-session -t "=$name" 2>/dev/null && killed="$killed $name"
    done
    echo "stopped:${killed:- (none, already gone)}"
    return 0
}

# _tmux_watchdog_scan
# Prints one line per live session: "M <name>" when the session's base (its
# #{session_group}, or its own name when ungrouped) is app-marked (CLAUDE_GUI=1 in the
# base session's environment), "U <name>" otherwise. A grouped client session does not
# carry the marker itself, and a group whose base session is gone reads as unmarked.
# The marker is read here, at call time. No server running prints nothing.
_tmux_watchdog_scan() {
    local listing line name group base kind
    # ':' cannot occur in a tmux session name or group name, so it separates the fields
    listing="$(tmux list-sessions -F '#{session_name}:#{session_group}' 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line%%:*}"
        group="${line#*:}"
        base="${group:-$name}"
        kind=U
        [[ "$(tmux show-environment -t "=$base" CLAUDE_GUI 2>/dev/null)" == "CLAUDE_GUI=1" ]] && kind=M
        printf '%s %s\n' "$kind" "$name"
    done <<< "$listing"
}

# tmux_watchdog_kill
# What the iTerm watchdog runs after iTerm2 quits. With no app-marked project it ends
# the tmux server (the v1.8 behavior, the only server-wide kill in this codebase). With one
# or more, it kills only the sessions of unmarked projects, each by exact =name, so
# projects the GUI app started survive. No server running is a quiet success.
# Known races, accepted: a marker set after the final check is not seen, and a session
# created after the list is not killed (documented in docs/approval-relay-setup.md).
tmux_watchdog_kill() {
    local scan line kind name
    scan="$(_tmux_watchdog_scan)"
    [[ -n "$scan" ]] || return 0
    if ! grep -q '^M ' <<<"$scan"; then
        # re-check right before the server-wide kill (review note R6); the check-to-kill
        # window that remains is accepted
        scan="$(_tmux_watchdog_scan)"
        [[ -n "$scan" ]] || return 0
        if ! grep -q '^M ' <<<"$scan"; then
            tmux kill-server 2>/dev/null
            return 0
        fi
    fi
    while IFS= read -r line; do
        kind="${line%% *}"
        name="${line#* }"
        [[ "$kind" == U ]] && tmux kill-session -t "=$name" 2>/dev/null
    done <<< "$scan"
    return 0
}

# tmux_close_terminal_tab iterm_session_id
# Closes the iTerm2 tab holding the session with the given id. Prints
# "closed", "not_found", or "error" on stdout -- never fails its caller.
# Extracted here because closing a tab by iTerm session id existed twice
# (merge-review.sh's close_iterm_tab_by_session_id, and an inline copy in
# dispatch-task.sh's --kill block) before this became the third call site
# (dispatch-task.sh --launch-sweep's orphan-tab pass) -- three copies of the
# same AppleScript is one too many.
tmux_close_terminal_tab() {
    local iterm_session_id="$1" procs

    # iTerm2 not running: no tab to close, and `tell app` would launch it (a sweep from the
    # GUI app must never start iTerm). ps, not pgrep: hardened runtime hides iTerm2 from
    # pgrep (see the watchdog in launch-claude.sh). The capture keeps a caller's pipefail
    # from reading a grep -q early exit as "not running".
    procs="$(ps -Ao comm= 2>/dev/null)"
    if ! grep -q '/iTerm2$' <<<"$procs"; then
        echo not_found
        return 0
    fi

    osascript <<APPLESCRIPT 2>/dev/null
tell app "iTerm2"
  try
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (id of s) is "$iterm_session_id" then
            close t
            return "closed"
          end if
        end repeat
      end repeat
    end repeat
    return "not_found"
  on error errMsg number errNum
    log "iTerm close error: " & errNum & " - " & errMsg
    return "error"
  end try
end tell
APPLESCRIPT
}

# Export functions for sourcing
return 0 2>/dev/null || true
