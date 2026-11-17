#!/bin/bash
# SessionStart hook: after /clear in an orchestrator Session 1, store the new
# conversation id so a relaunch resumes it. Only launch-claude.sh sets
# ORCH_SESSION1=1, and only for that session. Always exits 0.
[[ "${ORCH_SESSION1:-}" == 1 ]] || exit 0
_in="$(cat)"
_src="$(printf '%s' "$_in" | jq -r '.source // empty' 2>/dev/null)"
[[ "$_src" == clear ]] || exit 0
_sid="$(printf '%s' "$_in" | jq -r '.session_id // empty' 2>/dev/null)"
[[ "$_sid" =~ ^[0-9a-f-]{36}$ ]] || exit 0
_common="$(command git rev-parse --git-common-dir 2>/dev/null)" || exit 0
_root="$(cd "$_common/.." 2>/dev/null && pwd)" || exit 0
[[ -d "$_root/.claude" ]] && echo "$_sid" > "$_root/.claude/orchestrator-session-id"
exit 0
