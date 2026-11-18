#!/bin/bash
# orchestration/hooks/typed-command-gate.sh
# UserPromptSubmit hook (Phase 1, D-02, D-03): applies the board's stage gates
# G1, G2 and G4 to a typed /cadence:cad-plan, -execute or -milestone (and the
# /cad-* forms) in a Helm session. The judgement lives in
# lib/typed-command-gate.js; this script only decides if the session is Helm's.
#
# Helm session: CLAUDE_GUI=1 in the environment, or a live worker row for the
# payload cwd (live_worker_agent). Every other session passes with no output.
#
# Fails OPEN on its own errors (no node, bad payload, cwd outside a git
# checkout, helper crash): nothing on stdout, exit 0. Only the helper prints,
# and only a block or a "gate check could not run" context line.

_NODE_BIN="$(command -v node 2>/dev/null)"
[[ -n "$_NODE_BIN" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
# shellcheck source=../lib/session-state.sh
source "$SCRIPT_DIR/lib/session-state.sh" 2>/dev/null || exit 0

INPUT="$(cat)"

CWD="$(printf '%s' "$INPUT" | "$_NODE_BIN" -e "
  let d='';
  process.stdin.on('data',c=>d+=c);
  process.stdin.on('end',()=>{
    try{const v=JSON.parse(d).cwd;process.stdout.write(typeof v==='string'?v:'')}
    catch{process.exit(1)}
  });
" 2>/dev/null)" || exit 0
# An absolute path only: CWD goes to `cd` and `git -C`.
[[ "$CWD" == /* ]] || exit 0
cd "$CWD" 2>/dev/null || exit 0

# D-03: the checkout that holds the cwd, not the dispatching repo.
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$ROOT" ]] || exit 0

if [[ "${CLAUDE_GUI:-}" != 1 ]]; then
  AGENT="$(live_worker_agent "$CWD" 2>/dev/null)" || exit 0
  [[ -n "$AGENT" ]] || exit 0
fi

printf '%s' "$INPUT" | "$_NODE_BIN" "$SCRIPT_DIR/lib/typed-command-gate.js" "$ROOT" 2>/dev/null
exit 0
