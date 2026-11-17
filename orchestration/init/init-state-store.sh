#!/bin/bash
# orchestration/init/init-state-store.sh
# Initialize SQLite session state store with schema, PRAGMAs, and indexes.
# Idempotent: safe to run multiple times.

set -euo pipefail

# Parse arguments
TARGET_DIR="${1:-.}"

# Resolve to the MAIN repository root (--git-common-dir, not --show-toplevel:
# the latter returns the worktree itself when TARGET_DIR is a linked worktree)
if ! GIT_COMMON_DIR=$(git -C "$TARGET_DIR" rev-parse --git-common-dir 2>/dev/null); then
  echo "Error: not a git repository" >&2
  exit 1
fi

# Relative literal ".git" at the top of a plain checkout, absolute in a worktree
if [[ "$GIT_COMMON_DIR" != /* ]]; then
  GIT_COMMON_DIR="$(cd "$TARGET_DIR" && pwd)/$GIT_COMMON_DIR"
fi

PROJECT_ROOT="$(dirname "$GIT_COMMON_DIR")"

DB_PATH="$PROJECT_ROOT/.claude/session-state.db"

# Check if sqlite3 is available
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "Error: sqlite3 CLI not found" >&2
  exit 1
fi

# Create .claude directory
mkdir -p "$PROJECT_ROOT/.claude" 2>/dev/null || true

# Initialize database with PRAGMAs and schema
if ! sqlite3 "$DB_PATH" >/dev/null <<'SCHEMA_EOF'
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS sessions (
    agent_id TEXT PRIMARY KEY,
    worktree_path TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK(status IN ('running','blocked','done','merged','stalled','dead')),
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    pid INTEGER,
    last_activity_at DATETIME,
    iterm_session_id TEXT,
    pending_operation TEXT,
    task_title TEXT,
    nomatch_strikes INTEGER NOT NULL DEFAULT 0,
    op_seq INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_created ON sessions(created_at);

CREATE TABLE IF NOT EXISTS dependencies (
    dependent_agent_id TEXT NOT NULL,
    upstream_agent_id TEXT NOT NULL,
    artifact TEXT NOT NULL,
    notified_at DATETIME,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (dependent_agent_id, upstream_agent_id)
);

CREATE INDEX IF NOT EXISTS idx_dep_upstream ON dependencies(upstream_agent_id);
SCHEMA_EOF
then
  echo "Error: failed to create database schema" >&2
  exit 1
fi

# Guarded additive migration for pre-existing databases: CREATE TABLE IF NOT
# EXISTS above has no effect once the table already exists, so a database
# created before this change would otherwise never gain the new columns.
# SQLite's ALTER TABLE has no IF-NOT-EXISTS clause for ADD COLUMN (that syntax
# is a parse error), so PRAGMA table_info stands in as the idempotence guard.
# SQL passed as a sqlite3 argument, never a heredoc inside $(...) -- bash 3.2
# (/bin/bash on macOS) cannot parse that construct; see
# orchestration/lib/session-state.sh:130-132 for the incident that found it.
#
# last_event/last_message/claude_session_id/model/effort carry the worker relay
# (hooks write the first three, dispatch the last two). Two inits can race on
# the same db (dispatch + resume): the loser's ALTER fails "duplicate column",
# so a failed ALTER only counts as an error if the column is still missing.
for COLUMN in pending_operation task_title last_event last_message claude_session_id model effort inbox_path out_path; do
  if ! sqlite3 "$DB_PATH" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -qx "$COLUMN"; then
    if ! sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN $COLUMN TEXT;" &&
       ! sqlite3 "$DB_PATH" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -qx "$COLUMN"; then
      echo "Error: failed to add $COLUMN column to $DB_PATH" >&2
      exit 1
    fi
  fi
done

# nomatch_strikes is INTEGER NOT NULL DEFAULT 0, not TEXT -- kept out of the
# loop above so its ALTER TABLE statement can carry the right type/default.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -qx "nomatch_strikes"; then
  if ! sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN nomatch_strikes INTEGER NOT NULL DEFAULT 0;"; then
    echo "Error: failed to add nomatch_strikes column to $DB_PATH" >&2
    exit 1
  fi
fi

# op_seq counts pending_operation recordings per row (a per-dialog sequence
# number); same INTEGER NOT NULL DEFAULT 0 shape and guard as nomatch_strikes.
if ! sqlite3 "$DB_PATH" "PRAGMA table_info(sessions);" | cut -d'|' -f2 | grep -qx "op_seq"; then
  if ! sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN op_seq INTEGER NOT NULL DEFAULT 0;"; then
    echo "Error: failed to add op_seq column to $DB_PATH" >&2
    exit 1
  fi
fi

# Verify schema was created
TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null)
if ! echo "$TABLES" | grep -q "sessions"; then
  echo "Error: sessions table not found after creation" >&2
  exit 1
fi
if ! echo "$TABLES" | grep -q "dependencies"; then
  echo "Error: dependencies table not found after creation" >&2
  exit 1
fi

exit 0
