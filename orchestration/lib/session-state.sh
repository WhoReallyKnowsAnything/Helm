#!/bin/bash
# orchestration/lib/session-state.sh
# Bash helper library for session state store CRUD operations.
# Source this file to use the functions.

# session_state_db_path [target_dir]
# Returns absolute path to session state database
# Uses --git-common-dir, not --show-toplevel: from inside a linked worktree the
# latter returns the worktree, so workers would silently read an empty db.
session_state_db_path() {
    local target_dir="${1:-.}"
    local git_common_dir

    if ! git_common_dir=$(command git -C "$target_dir" rev-parse --git-common-dir); then
        echo "Error: not a git repository" >&2
        return 1
    fi

    # Absolute in a linked worktree, the relative literal ".git" at the top of a
    # plain checkout -- dirname on the relative form yields "." and reintroduces
    # the bug, so normalize before taking the parent.
    if [[ "$git_common_dir" != /* ]]; then
        git_common_dir="$(cd "$target_dir" && pwd)/$git_common_dir"
    fi

    echo "$(dirname "$git_common_dir")/.claude/session-state.db"
}

# session_state_write agent_id worktree_path status [pid]
# Inserts or replaces a session record
# Returns 0 on success, 1 on error
session_state_write() {
    local agent_id="$1"
    local worktree_path="$2"
    local status="$3"
    local pid="${4:-}"
    
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id esc_worktree_path esc_status
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    esc_worktree_path=$(printf '%s' "$worktree_path" | sed "s/'/''/g")
    esc_status=$(printf '%s' "$status" | sed "s/'/''/g")
    
    local pid_value
    if [ -n "$pid" ]; then
        pid_value="$pid"
    else
        pid_value="NULL"
    fi
    
    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO sessions (agent_id, worktree_path, status, pid, updated_at)
VALUES ('$esc_agent_id', '$esc_worktree_path', '$esc_status', $pid_value, CURRENT_TIMESTAMP);
COMMIT;
EOF
    then
        echo "Error: failed to write session record for $agent_id to $db_path" >&2
        return 1
    fi
    
    return 0
}

# session_state_read agent_id
# Returns the status for the given agent_id
# Returns empty string if not found
# Returns 0 on success, 1 on error
session_state_read() {
    local agent_id="$1"
    local db_path
    
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    
    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT status FROM sessions WHERE agent_id = '$esc_agent_id';") ; then
        echo "Error: failed to read session status for $agent_id from $db_path" >&2
        return 1
    fi
    
    echo "$result"
    return 0
}

# session_state_list
# Lists all sessions pipe-separated: agent_id, status, worktree_path, pid, created_at, retry_count, updated_at
# Returns 0 on success, 1 on error
session_state_list() {
    local db_path
    db_path=$(session_state_db_path) || return 1
    
    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT agent_id, status, worktree_path, pid, created_at, retry_count, updated_at FROM sessions ORDER BY agent_id;"; then
        echo "Error: failed to list sessions from $db_path" >&2
        return 1
    fi
    
    return 0
}

# session_state_update_status agent_id new_status
# Updates the status field for a session, touches updated_at
# Returns 0 on success, 1 on error (or if invalid status)
session_state_update_status() {
    local agent_id="$1"
    local new_status="$2"
    
    # Validate status enum
    case "$new_status" in
        running|blocked|done|merged|stalled|dead)
            ;;
        *)
            echo "Error: invalid status value '$new_status'; must be one of: running, blocked, done, merged, stalled, dead" >&2
            return 1
            ;;
    esac
    
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_new_status esc_agent_id guard=""
    esc_new_status=$(printf '%s' "$new_status" | sed "s/'/''/g")
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    case "$new_status" in running|blocked) guard="AND status NOT IN ('merged','dead')" ;; esac
    
    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET status = '$esc_new_status', updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id' $guard;
COMMIT;
EOF
    then
        echo "Error: failed to update status for $agent_id in $db_path" >&2
        return 1
    fi

    if [ "$new_status" = "dead" ]; then
        local dep_result
        # SQL passed as an argument, not a heredoc: bash 3.2 (/bin/bash on macOS,
        # the shebang every dispatch script uses) cannot parse a heredoc nested
        # inside $(...) and fails to source this whole file.
        if ! dep_result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "
BEGIN IMMEDIATE;
DELETE FROM dependencies WHERE upstream_agent_id = '$esc_agent_id';
SELECT changes();
COMMIT;"
        ); then
            echo "Error: failed to tear down dependencies for dead session $agent_id in $db_path" >&2
            return 1
        fi
        local torn_down
        torn_down=$(echo "$dep_result" | tail -n1)
        if [ -n "$torn_down" ] && [ "$torn_down" != "0" ]; then
            echo "Torn down $torn_down pending dependency edge(s) for dead session $agent_id" >&2
        fi
    fi
    
    return 0
}
# session_state_mark_stalled agent_id
# Marks a session as stalled (convenience wrapper for session_state_update_status)
# Returns 0 on success, 1 on error
session_state_mark_stalled() {
    local agent_id="$1"
    session_state_update_status "$agent_id" "stalled"
}

# session_state_get_pid agent_id
# Returns the PID for the given agent_id
# Returns empty string if not found or NULL in DB
# Returns 0 on success, 1 on error
session_state_get_pid() {
    local agent_id="$1"
    local db_path
    
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    
    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT pid FROM sessions WHERE agent_id = '$esc_agent_id';") ; then
        echo "Error: failed to read PID for $agent_id from $db_path" >&2
        return 1
    fi
    
    # sqlite3 returns empty string for NULL, which is what we want
    echo "$result"
    return 0
}

# session_state_increment_retry agent_id
# Increments retry_count by 1 for the given session
# Returns 0 on success, 1 on error
session_state_increment_retry() {
    local agent_id="$1"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET retry_count = retry_count + 1, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to increment retry_count for $agent_id in $db_path" >&2
        return 1
    fi
    return 0
}

# session_state_reset_retry agent_id
# Resets retry_count to 0 for the given session
# Returns 0 on success, 1 on error
session_state_reset_retry() {
    local agent_id="$1"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET retry_count = 0, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to reset retry_count for $agent_id in $db_path" >&2
        return 1
    fi
    return 0
}

# session_state_write_with_iterm_id agent_id worktree_path status [pid] [iterm_session_id]
# Inserts or replaces a session record with iTerm session ID
# Returns 0 on success, 1 on error
session_state_write_with_iterm_id() {
    local agent_id="$1"
    local worktree_path="$2"
    local status="$3"
    local pid="${4:-}"
    local iterm_session_id="${5:-}"

    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id esc_worktree_path esc_status esc_iterm_session_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    esc_worktree_path=$(printf '%s' "$worktree_path" | sed "s/'/''/g")
    esc_status=$(printf '%s' "$status" | sed "s/'/''/g")
    esc_iterm_session_id=$(printf '%s' "$iterm_session_id" | sed "s/'/''/g")

    local pid_value iterm_value
    if [ -n "$pid" ]; then
        pid_value="$pid"
    else
        pid_value="NULL"
    fi

    if [ -n "$iterm_session_id" ]; then
        iterm_value="'$esc_iterm_session_id'" 
    else
        iterm_value="NULL"
    fi

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO sessions 
  (agent_id, worktree_path, status, pid, iterm_session_id, updated_at)
VALUES ('$esc_agent_id', '$esc_worktree_path', '$esc_status', $pid_value, $iterm_value, CURRENT_TIMESTAMP);
COMMIT;
EOF
    then
        echo "Error: failed to write session record with iTerm ID for $agent_id" >&2
        return 1
    fi
    return 0
}

# session_state_get_iterm_id agent_id
# Returns the iTerm session ID for the given agent_id
# Returns empty string if not found or NULL in DB
# Returns 0 on success, 1 on error
session_state_get_iterm_id() {
    local agent_id="$1"
    local db_path

    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT iterm_session_id FROM sessions WHERE agent_id = '$esc_agent_id' LIMIT 1;") ; then
        return 1
    fi

    echo "$result"
    return 0
}

# session_state_set_iterm_id agent_id iterm_session_id
# Stores the iTerm tab id of a live row (running, blocked or stalled) with an
# UPDATE that touches nothing else, not even updated_at. Not
# session_state_write_with_iterm_id: that one is INSERT OR REPLACE and would
# erase the event, session-id, model and effort columns. Returns 1 when no row
# was changed (unknown agent, or the row is no longer live) or sqlite failed.
session_state_set_iterm_id() {
    local db_path esc_agent_id esc_id changed
    db_path=$(session_state_db_path) || return 1
    esc_agent_id=$(session_state_sql_escape "$1")
    esc_id=$(session_state_sql_escape "$2")

    if ! changed=$(command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET iterm_session_id = '$esc_id' WHERE agent_id = '$esc_agent_id' AND status IN ('running','blocked','stalled'); SELECT changes();"); then
        echo "Error: failed to set iterm_session_id for $1 in $db_path" >&2
        return 1
    fi
    [[ "$changed" == 1 ]]
}

# session_state_add_dependency dependent_agent_id upstream_agent_id artifact
# Records that dependent_agent_id depends on an artifact from upstream_agent_id.
# Refuses self-dependencies and direct/transitive cycles; no row written on refusal.
# On success, echoes upstream's current status (empty is normal, forward-reference case)
# Returns 0 on success, 1 on error/refusal
session_state_add_dependency() {
    local dependent_agent_id="$1"
    local upstream_agent_id="$2"
    local artifact="$3"

    if [ "$dependent_agent_id" = "$upstream_agent_id" ]; then
        echo "Error: cannot add self-dependency for $dependent_agent_id" >&2
        return 1
    fi

    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_upstream_agent_id esc_dependent_agent_id esc_artifact
    esc_upstream_agent_id=$(printf '%s' "$upstream_agent_id" | sed "s/'/''/g")
    esc_dependent_agent_id=$(printf '%s' "$dependent_agent_id" | sed "s/'/''/g")
    esc_artifact=$(printf '%s' "$artifact" | sed "s/'/''/g")

    local cycle_check
    if ! cycle_check=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "
WITH RECURSIVE ancestors(id) AS (
    SELECT upstream_agent_id FROM dependencies WHERE dependent_agent_id = '$esc_upstream_agent_id'
    UNION
    SELECT d.upstream_agent_id FROM dependencies d JOIN ancestors a ON d.dependent_agent_id = a.id
)
SELECT 1 FROM ancestors WHERE id = '$esc_dependent_agent_id' LIMIT 1;"); then
        echo "Error: failed to check for dependency cycle between $dependent_agent_id and $upstream_agent_id" >&2
        return 1
    fi

    if [ -n "$cycle_check" ]; then
        echo "Error: adding dependency $dependent_agent_id -> $upstream_agent_id would create a cycle" >&2
        return 1
    fi

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
INSERT OR REPLACE INTO dependencies (dependent_agent_id, upstream_agent_id, artifact)
VALUES ('$esc_dependent_agent_id', '$esc_upstream_agent_id', '$esc_artifact');
COMMIT;
EOF
    then
        echo "Error: failed to add dependency $dependent_agent_id -> $upstream_agent_id in $db_path" >&2
        return 1
    fi

    session_state_read "$upstream_agent_id"
    return 0
}

# session_state_list_pending_dependents upstream_agent_id
# Lists pipe-separated dependent_agent_id|artifact rows still awaiting notification
# Returns 0 on success, 1 on error
session_state_list_pending_dependents() {
    local upstream_agent_id="$1"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_upstream_agent_id
    esc_upstream_agent_id=$(printf '%s' "$upstream_agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT dependent_agent_id, artifact FROM dependencies WHERE upstream_agent_id = '$esc_upstream_agent_id' AND notified_at IS NULL;"; then
        echo "Error: failed to list pending dependents for $upstream_agent_id from $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_mark_dependency_notified dependent_agent_id upstream_agent_id
# Marks a dependency edge as notified (sets notified_at)
# Returns 0 on success, 1 on error
session_state_mark_dependency_notified() {
    local dependent_agent_id="$1"
    local upstream_agent_id="$2"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_dependent_agent_id esc_upstream_agent_id
    esc_dependent_agent_id=$(printf '%s' "$dependent_agent_id" | sed "s/'/''/g")
    esc_upstream_agent_id=$(printf '%s' "$upstream_agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE dependencies SET notified_at = CURRENT_TIMESTAMP
WHERE dependent_agent_id = '$esc_dependent_agent_id' AND upstream_agent_id = '$esc_upstream_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to mark dependency notified for $dependent_agent_id -> $upstream_agent_id in $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_set_pending_operation agent_id operation
# Sets the pending_operation column for a session, touches updated_at.
# Does not touch status - session_state_update_status already owns that
# field, and this split keeps a detection hook able to record an operation
# without asserting a status it cannot actually observe.
# Also resets nomatch_strikes to 0: a new operation starts a fresh debounce
# streak. --blocked-sweep bumps strikes for every running worker with no
# prompt up, so a lone strike is usually standing when the next tool call
# records; left in place, one transient no-prompt sweep before the popup
# draws would reach the clear threshold and wipe the operation just recorded.
# Returns 0 on success, 1 on error
session_state_set_pending_operation() {
    local agent_id="$1"
    local operation="$2"

    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_operation esc_agent_id
    esc_operation=$(printf '%s' "$operation" | sed "s/'/''/g")
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET pending_operation = '$esc_operation', nomatch_strikes = 0, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to set pending_operation for $agent_id in $db_path" >&2
        return 1
    fi

    # op_seq numbers each recording so a stale press cannot approve an identical
    # retried dialog. Separate statement, failure ignored: on a database not yet
    # migrated (init only runs at launch) the column is absent and the
    # operation recorded above must stand.
    command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET op_seq = op_seq + 1 WHERE agent_id = '$esc_agent_id';" >/dev/null 2>&1 || true

    return 0
}

# session_state_get_op_seq agent_id
# Prints the row's op_seq; empty when the column is missing (unmigrated
# database) or there is no row. Always returns 0.
session_state_get_op_seq() {
    local agent_id="$1"
    local db_path

    db_path=$(session_state_db_path) || return 0

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    command sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT op_seq FROM sessions WHERE agent_id = '$esc_agent_id';" 2>/dev/null || true
    return 0
}

# session_state_get_pending_operation agent_id
# Returns the pending_operation for the given agent_id
# Returns empty string if not found or NULL in DB
# Returns 0 on success, 1 on error
session_state_get_pending_operation() {
    local agent_id="$1"
    local db_path

    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT pending_operation FROM sessions WHERE agent_id = '$esc_agent_id';") ; then
        echo "Error: failed to read pending_operation for $agent_id from $db_path" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# session_state_get_task_title agent_id
# Returns the task_title for the given agent_id, independent of whether the
# row currently carries a pending_operation -- session_state_list_pending_
# confirmation only returns rows with one, so --blocked-sweep's title lookup
# came back empty whenever the operation was NULL even though the title was
# recorded.
# Returns empty string if not found or NULL in DB
# Returns 0 on success, 1 on error
session_state_get_task_title() {
    local agent_id="$1"
    local db_path

    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT task_title FROM sessions WHERE agent_id = '$esc_agent_id';") ; then
        echo "Error: failed to read task_title for $agent_id from $db_path" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# session_state_clear_pending_operation agent_id
# Sets pending_operation to a literal NULL (not an empty string), so "never
# had one" and "had one and it was cleared" read identically to consumers.
# Also resets nomatch_strikes to 0 -- every caller that reaches a real clear
# (window gone, debounce threshold hit, or a resolved --answer) means the
# prior streak is settled either way, so the next detection starts fresh.
# Returns 0 on success, 1 on error
session_state_clear_pending_operation() {
    local agent_id="$1"

    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET pending_operation = NULL, nomatch_strikes = 0, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to clear pending_operation for $agent_id in $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_bump_nomatch_strikes agent_id
# Increments nomatch_strikes by 1 and echoes the new count. Debounce state
# for the pane-first sweep (--blocked-sweep): the PreToolUse hook that
# writes pending_operation fires once, before any popup renders, and never
# again -- so a single transient NOMATCH (a pane captured mid-render) must
# not clear a genuinely still-blocked row. Only a SECOND consecutive NOMATCH,
# which spans a separate --blocked-sweep invocation ~StartInterval apart
# (see orchestration/launchd/*.blocked-sweep.plist), should trigger the real
# clear -- see session_state_reset_nomatch_strikes for the counterpart.
# Returns 0 on success, 1 on error
session_state_bump_nomatch_strikes() {
    local agent_id="$1"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET nomatch_strikes = nomatch_strikes + 1, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
SELECT nomatch_strikes FROM sessions WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    ); then
        echo "Error: failed to bump nomatch_strikes for $agent_id in $db_path" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# session_state_reset_nomatch_strikes agent_id
# Resets nomatch_strikes to 0 -- called whenever a pane match is confirmed,
# so an earlier lone strike never carries forward into an unrelated later one.
# Returns 0 on success, 1 on error
session_state_reset_nomatch_strikes() {
    local agent_id="$1"
    local db_path
    db_path=$(session_state_db_path) || return 1

    local esc_agent_id
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET nomatch_strikes = 0, updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to reset nomatch_strikes for $agent_id in $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_set_task_title agent_id title
# Sets the task_title column for a session, touches updated_at. Called after
# dispatch's INSERT OR REPLACE rather than folded into it, so
# session_state_write_with_iterm_id's signature stays unchanged (D-15)
# Returns 0 on success, 1 on error
session_state_set_task_title() {
    local agent_id="$1"
    local title="$2"

    local db_path
    db_path=$(session_state_db_path) || return 1

    # SQL-escaped via sed, not the ${var//\'/\'\'} idiom the rest of this
    # file used to rely on: verified live that bash 3.2 (/bin/bash on macOS, the
    # shebang every dispatch script uses) mis-substitutes that pattern --
    # it leaves a literal backslash in front of each doubled quote
    # (`O\'\'Brien` instead of `O''Brien`), corrupting the SQL literal and
    # silently dropping the title. sed's behaviour is identical across
    # bash 3.2 and bash 5 (verified both). Task titles are the first
    # untrusted text routinely containing an apostrophe to reach this file.
    local esc_agent_id esc_title
    esc_agent_id=$(printf '%s' "$agent_id" | sed "s/'/''/g")
    esc_title=$(printf '%s' "$title" | sed "s/'/''/g")

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" <<EOF
BEGIN IMMEDIATE;
UPDATE sessions SET task_title = '$esc_title', updated_at = CURRENT_TIMESTAMP
WHERE agent_id = '$esc_agent_id';
COMMIT;
EOF
    then
        echo "Error: failed to set task_title for $agent_id in $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_list_blocked
# Lists agent_id, worktree_path, task_title, pending_operation, updated_at
# (five fields per row, ASCII unit separator \x1f between fields) for every
# session whose status is blocked, ordered by updated_at.
# pending_operation and task_title are untrusted free text (shell command
# text, Notion task titles) that routinely contain literal '|' characters,
# so '|' cannot be used as the field separator -- \x1f is used instead since
# it cannot appear in either field.
# Returns 0 on success, 1 on error
session_state_list_blocked() {
    local db_path
    db_path=$(session_state_db_path) || return 1

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" -separator $'\x1f' "$db_path" "SELECT agent_id, worktree_path, task_title, pending_operation, updated_at FROM sessions WHERE status = 'blocked' ORDER BY updated_at;"; then
        echo "Error: failed to list blocked sessions from $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_list_pending_confirmation
# Lists agent_id, worktree_path, task_title, pending_operation, updated_at
# (five fields per row, \x1f-separated, same shape as session_state_list_blocked)
# for every session with a non-NULL pending_operation, regardless of its
# current status. This is --blocked-sweep's candidate set: the detection
# hook records pending_operation on every matching tool call without ever
# setting status='blocked' itself (it fires before the permission decision
# is made and cannot know whether a popup will actually be drawn) --
# confirmation, not the hook, is what promotes a row to blocked.
# session_state_list_blocked cannot serve this role: it filters on
# status='blocked', which is exactly the value nothing sets until after
# confirmation.
# Returns 0 on success, 1 on error
session_state_list_pending_confirmation() {
    local db_path
    db_path=$(session_state_db_path) || return 1

    if ! command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" -separator $'\x1f' "$db_path" "SELECT agent_id, worktree_path, task_title, pending_operation, updated_at FROM sessions WHERE pending_operation IS NOT NULL ORDER BY updated_at;"; then
        echo "Error: failed to list pending-confirmation sessions from $db_path" >&2
        return 1
    fi

    return 0
}

# session_state_agent_id_for_worktree worktree_path
# Returns the agent_id for the given worktree_path
# worktree_path is UNIQUE, so this is single-valued by schema; LIMIT 1 anyway,
# matching session_state_get_iterm_id
# Returns empty string if not found
# Returns 0 on success, 1 on error
session_state_agent_id_for_worktree() {
    local worktree_path="$1"
    local db_path

    db_path=$(session_state_db_path) || return 1

    local esc_worktree_path
    esc_worktree_path=$(printf '%s' "$worktree_path" | sed "s/'/''/g")

    local result
    if ! result=$(command sqlite3 -cmd ".timeout 5000" -cmd "PRAGMA synchronous = NORMAL;" "$db_path" "SELECT agent_id FROM sessions WHERE worktree_path = '$esc_worktree_path' LIMIT 1;") ; then
        echo "Error: failed to read agent_id for worktree $worktree_path from $db_path" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# --- Worker relay columns (last_event, last_message, claude_session_id, model,
# effort). Each helper is one UPDATE that touches only its own columns: never
# status, never updated_at (the sweeps read updated_at). SQL goes in as an
# argument, never a heredoc nested in $(...) (bash 3.2 cannot parse that). A
# missing column (db not yet re-initialised) is the usual Error: line and
# return 1; the caller decides whether to ignore it. An unknown agent id
# updates no row and still returns 0.

# session_state_sql_escape text: prints text with single quotes doubled (sed,
# not ${var//\'/\'\'}, which bash 3.2 mis-substitutes; see set_task_title).
session_state_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# session_state_flatten_message text: prints text on one line, control bytes
# (ESC and the rest) dropped, cut to 200 characters. The text is untrusted
# model output that the board later draws in a terminal, so no escape sequence
# may survive.
# shortcut: 200 characters, raise the cap when the board needs more.
session_state_flatten_message() {
    local flat
    flat=$(printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
    printf '%s' "${flat:0:200}"
}

# session_state_record_event agent_id event [message] [keep-done]
# Sets last_event, last_message and last_activity_at. event is one of start,
# blocked, commit, idle, busy, done. With keep-done as the 4th argument a row
# whose current event is already done is left exactly as it is (the Stop hook
# and the busy writers ask: the worker's final step writes done and its turn
# then ends, and a later prompt or tool call must not undo it); every
# other writer replaces done, because a new start, commit or blocked means the
# worker is working again.
session_state_record_event() {
    local agent_id="$1" event="$2" message="${3:-}" keep_done="${4:-}"
    local db_path esc_agent_id esc_message guard=""

    case "$event" in
        start|blocked|commit|idle|busy|done) ;;
        *) echo "Error: unknown relay event '$event'" >&2; return 1 ;;
    esac
    db_path=$(session_state_db_path) || return 1
    esc_agent_id=$(session_state_sql_escape "$agent_id")
    esc_message=$(session_state_sql_escape "$(session_state_flatten_message "$message")")
    [[ "$keep_done" == keep-done ]] && guard=" AND COALESCE(last_event, '') != 'done'"

    if ! command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET last_event = '$event', last_message = '$esc_message', last_activity_at = CURRENT_TIMESTAMP WHERE agent_id = '$esc_agent_id'$guard;"; then
        echo "Error: failed to record event $event for $agent_id in $db_path" >&2
        return 1
    fi
    return 0
}

# session_state_set_claude_session_id agent_id session_id
session_state_set_claude_session_id() {
    local db_path esc_agent_id esc_id
    db_path=$(session_state_db_path) || return 1
    esc_agent_id=$(session_state_sql_escape "$1")
    esc_id=$(session_state_sql_escape "$2")

    if ! command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET claude_session_id = '$esc_id' WHERE agent_id = '$esc_agent_id';"; then
        echo "Error: failed to set claude_session_id for $1 in $db_path" >&2
        return 1
    fi
    return 0
}

# session_state_set_model_effort agent_id model effort
session_state_set_model_effort() {
    local db_path esc_agent_id esc_model esc_effort
    db_path=$(session_state_db_path) || return 1
    esc_agent_id=$(session_state_sql_escape "$1")
    esc_model=$(session_state_sql_escape "$2")
    esc_effort=$(session_state_sql_escape "$3")

    if ! command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET model = '$esc_model', effort = '$esc_effort' WHERE agent_id = '$esc_agent_id';"; then
        echo "Error: failed to set model/effort for $1 in $db_path" >&2
        return 1
    fi
    return 0
}

# session_state_set_session_files agent_id inbox_path out_path
# Touches only inbox_path and out_path (never status or updated_at).
session_state_set_session_files() {
    local db_path esc_agent_id esc_inbox esc_out
    db_path=$(session_state_db_path) || return 1
    esc_agent_id=$(session_state_sql_escape "$1")
    esc_inbox=$(session_state_sql_escape "$2")
    esc_out=$(session_state_sql_escape "$3")

    if ! command sqlite3 -cmd ".timeout 5000" "$db_path" "UPDATE sessions SET inbox_path = '$esc_inbox', out_path = '$esc_out' WHERE agent_id = '$esc_agent_id';"; then
        echo "Error: failed to set session files for $1 in $db_path" >&2
        return 1
    fi
    return 0
}

# Session files (D-02): <root>/.claude/sessions/<label>/{inbox,out}.jsonl.
# root is the main checkout. The label is checked before any path is built:
# --kill takes it from the command line, so "..", "a/b" or "" must not escape.
_session_files_label_ok() {
    [[ "$1" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] && [[ "$1" != "." && "$1" != ".." ]] && return 0
    echo "Error: invalid session label '$1'" >&2
    return 1
}

# session_files_paths root label: prints dir, inbox path, out path (3 lines)
session_files_paths() {
    _session_files_label_ok "$2" || return 1
    printf '%s\n%s\n%s\n' "$1/.claude/sessions/$2" "$1/.claude/sessions/$2/inbox.jsonl" "$1/.claude/sessions/$2/out.jsonl"
}

# session_files_create root label: both files if absent; never truncates out
session_files_create() {
    _session_files_label_ok "$2" || return 1
    local dir="$1/.claude/sessions/$2"
    mkdir -p "$dir" && touch "$dir/inbox.jsonl" "$dir/out.jsonl"
}

# session_files_empty_inbox root label: truncate in place so a running tail -f
# keeps its file; the out log is untouched
session_files_empty_inbox() {
    _session_files_label_ok "$2" || return 1
    : > "$1/.claude/sessions/$2/inbox.jsonl"
}

# session_files_delete root label: removes the two files by name, then rmdir
# (never rm -rf); the directory stays when something else is in it
session_files_delete() {
    _session_files_label_ok "$2" || return 1
    local dir="$1/.claude/sessions/$2"
    rm -f "$dir/inbox.jsonl" "$dir/out.jsonl"
    rmdir "$dir" 2>/dev/null || true
    return 0
}

# live_worker_agent cwd: prints the agent id of a dispatched worker that is still
# live and whose worktree holds cwd, else returns 1. Only a live worker waits or
# is denied (D-10): a finished, merged or dead worker's row persists, and the user
# reviewing in that worktree must get the plain ask. The "dashboard" row is the
# user's own orchestrator session in the main checkout, never a worker. cwd is
# resolved to its worktree root first so a worker in a subdirectory still matches;
# a cwd git cannot resolve is not a worker. The state db must already exist: the
# lookup would otherwise create an empty file in every repo the user commits in.
# Shared by git-approval-gate.sh and worker-relay.sh.
live_worker_agent() {
  local db root agent status
  [[ -n "$1" ]] || return 1
  db=$(session_state_db_path 2>/dev/null) && [[ -s "$db" ]] || return 1
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  # root is symlink-resolved; the row may hold the path as dispatched, so try cwd too.
  agent=$(session_state_agent_id_for_worktree "$root" 2>/dev/null) || return 1
  [[ -n "$agent" ]] || agent=$(session_state_agent_id_for_worktree "$1" 2>/dev/null) || return 1
  [[ -n "$agent" && "$agent" != dashboard ]] || return 1
  status=$(session_state_read "$agent" 2>/dev/null) || return 1
  case "$status" in
    running|blocked|stalled) echo "$agent" ;;
    *) return 1 ;;
  esac
}

# Export functions for sourcing
return 0 2>/dev/null || true
