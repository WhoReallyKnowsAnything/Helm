#!/bin/bash
set -euo pipefail

# orchestration/promote-session.sh
# Promotes an already-running solo Claude Code session into orchestration mode:
# initializes the state store, registers this session as "dashboard", and
# spawns the watcher + task queue UI. Mirrors the ORCHESTRATION_MODE tail of
# launch-claude.sh, minus relaunching the claude process (can't retrofit
# --model or --append-system-prompt-file onto a running process).
#
# Usage: promote-session.sh [target_dir]   (default: cwd)

TARGET_DIR="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! git -C "$TARGET_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Error: $TARGET_DIR is not a git repository (worktrees require it)" >&2
    exit 1
fi

if [[ -z "${TMUX:-}" && -z "${CLAUDE_IN_TMUX:-}" ]]; then
    echo "Error: this session is not running inside tmux -- cannot be made reachable from phone." >&2
    echo "Restart via launch-claude.sh instead of promoting a bare session." >&2
    exit 1
fi

source "$SCRIPT_DIR/lib/tmux-session.sh" 2>/dev/null || true

_orch_root="$(cd "$SCRIPT_DIR/.." && pwd)"
mkdir -p "$TARGET_DIR/.claude"
echo "$_orch_root" > "$TARGET_DIR/.claude/orchestrator-root"

if ! "$SCRIPT_DIR/init/init-state-store.sh" "$TARGET_DIR"; then
    echo "Error: could not initialize state store" >&2
    exit 1
fi
echo "  [state-store] Initialized"

source "$SCRIPT_DIR/lib/session-state.sh"
if ( cd "$TARGET_DIR" && session_state_write "dashboard" "$TARGET_DIR" "running" "$$" ); then
    echo "  [state-store] Registered this session as 'dashboard'"
else
    echo "  Warning: could not register this session in the state store" >&2
fi
( cd "$TARGET_DIR" && "$SCRIPT_DIR/lib/dispatch-task.sh" --launch-sweep ) >/dev/null 2>&1 || true

echo ""
echo "  Orchestration infra is up. This session is registered as 'dashboard'."
echo "  For full parity (Opus + task-drafting-mode prompt), run /model opus[1m]"
echo "  and see prompts/task-drafting-mode.md for the injected instructions."

tmux rename-window "dashboard" 2>/dev/null || true
