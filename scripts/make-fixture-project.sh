#!/bin/bash
# Write a fixture <dir>/.claude/session-state.db for tests and manual checks.
# Usage: make-fixture-project.sh <dir> [old-schema]
#
# Schema copied from the orchestrator repo, orchestration/init/init-state-store.sh
# (WAL, sessions, dependencies, then the guarded ALTER columns). Not called from
# here, so tests need no other repo. /usr/bin/sqlite3 by absolute path: the first
# sqlite3 on PATH may be an Anaconda build whose WAL file handling differs from
# the system library the app links.
set -euo pipefail

DIR="${1:?usage: make-fixture-project.sh <dir> [old-schema]}"
VARIANT="${2:-}"
if [[ -n "$VARIANT" && "$VARIANT" != "old-schema" ]]; then
  echo "error: unknown variant '$VARIANT' (only 'old-schema')" >&2
  exit 1
fi

DB="$DIR/.claude/session-state.db"
if [[ -e "$DB" ]]; then
  echo "error: $DB already exists, refusing to touch it" >&2
  exit 1
fi
mkdir -p "$DIR/.claude"

if [[ "$VARIANT" == "old-schema" ]]; then
  SESSIONS_EXTRA=""
else
  SESSIONS_EXTRA=",
    pending_operation TEXT,
    task_title TEXT,
    last_event TEXT,
    last_message TEXT,
    claude_session_id TEXT,
    model TEXT,
    effort TEXT,
    inbox_path TEXT,
    out_path TEXT,
    nomatch_strikes INTEGER NOT NULL DEFAULT 0,
    op_seq INTEGER NOT NULL DEFAULT 0"
fi

if [[ "$VARIANT" == "old-schema" ]]; then
  ROWS="INSERT INTO sessions (agent_id, worktree_path, status, created_at) VALUES
    ('dashboard', '/fx/dashboard', 'running', '2026-01-01 10:00:00'),
    ('alpha',     '/fx/alpha',     'running', '2026-01-01 10:01:00'),
    ('bravo',     '/fx/bravo',     'blocked', '2026-01-01 10:02:00'),
    ('charlie',   '/fx/charlie',   'running', '2026-01-01 10:03:00'),
    ('delta',     '/fx/delta',     'merged',  '2026-01-01 10:04:00');"
else
  ROWS="INSERT INTO sessions (agent_id, worktree_path, status, created_at, task_title, last_event, inbox_path, out_path) VALUES
    ('dashboard', '/fx/dashboard', 'running', '2026-01-01 10:00:00', NULL,              NULL,   '/fx/sessions/dashboard.in.jsonl', '/fx/sessions/dashboard.out.jsonl'),
    ('alpha',     '/fx/alpha',     'running', '2026-01-01 10:01:00', 'Build the parser', NULL,   '/fx/sessions/alpha.in.jsonl',     '/fx/sessions/alpha.out.jsonl'),
    ('bravo',     '/fx/bravo',     'blocked', '2026-01-01 10:02:00', 'Wire the API',     NULL,   NULL, NULL),
    ('charlie',   '/fx/charlie',   'running', '2026-01-01 10:03:00', 'Write the docs',   'done', NULL, NULL),
    ('delta',     '/fx/delta',     'merged',  '2026-01-01 10:04:00', 'Old cleanup',      NULL,   NULL, NULL);"
fi

/usr/bin/sqlite3 "$DB" >/dev/null <<SQL
PRAGMA journal_mode = WAL;
CREATE TABLE sessions (
    agent_id TEXT PRIMARY KEY,
    worktree_path TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL CHECK(status IN ('running','blocked','done','merged','stalled','dead')),
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    pid INTEGER,
    last_activity_at DATETIME,
    iterm_session_id TEXT$SESSIONS_EXTRA
);
CREATE INDEX idx_status ON sessions(status);
CREATE INDEX idx_created ON sessions(created_at);
CREATE TABLE dependencies (
    dependent_agent_id TEXT NOT NULL,
    upstream_agent_id TEXT NOT NULL,
    artifact TEXT NOT NULL,
    notified_at DATETIME,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (dependent_agent_id, upstream_agent_id)
);
CREATE INDEX idx_dep_upstream ON dependencies(upstream_agent_id);
$ROWS
INSERT INTO dependencies (dependent_agent_id, upstream_agent_id, artifact) VALUES
    ('bravo', 'alpha', 'parser.swift'),
    ('alpha', 'delta', 'cleanup.swift');
-- Empties the -wal file, so a test can delete -wal and -shm without losing rows.
PRAGMA wal_checkpoint(TRUNCATE);
SQL
