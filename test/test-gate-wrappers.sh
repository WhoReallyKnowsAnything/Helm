#!/usr/bin/env bash
# test/test-gate-wrappers.sh
# Renders orchestration/templates/{git-gate,permission-hold}-wrapper.sh.in into a scratch folder and runs them
# with no `node` on PATH. The git-gate wrapper must never stay silent when it cannot read the working folder
# (silent = the call goes ungated); the permission-hold wrapper must never emit an allow without node.
# Plain bash, no framework. Never touches ~/.claude or the default tmux server.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${WRAPPER_TEMPLATES:-$HERE/../orchestration/templates}"  # override: check the test against old templates
PASS=0 FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
ORCH="$T/orch"; mkdir -p "$ORCH/hooks" "$T/bin" "$T/proj/.claude/worktrees/w1"
for tool in cat mktemp perl rm env sh bash sleep; do ln -s "$(command -v "$tool")" "$T/bin/$tool"; done
for w in git-gate permission-hold; do sed "s|@ORCH_DIR@|$ORCH|g" "$TPL/$w-wrapper.sh.in" > "$T/$w.sh"; done
WORKER_IN="{\"cwd\":\"$T/proj/.claude/worktrees/w1\",\"tool_name\":\"Bash\"}"

# run_nonode WRAPPER INPUT: run with a PATH that has no node; sets OUT.
run_nonode() { OUT="$(printf '%s' "$2" | env -i HOME="$T" PATH="$T/bin" /bin/bash "$T/$1.sh" 2>/dev/null)"; }

# Gate script absent, node absent: a live worker's call is denied or asked, never silent.
run_nonode git-gate "$WORKER_IN"
[[ "$OUT" =~ \"permissionDecision\":\"(ask|deny)\" ]] && pass "git-gate: no node, gate missing, worker input -> ask or deny" || fail "git-gate no node worker: out=[$OUT]"
run_nonode git-gate "not json"
[[ "$OUT" =~ \"permissionDecision\":\"(ask|deny)\" ]] && pass "git-gate: no node, unparseable input -> ask or deny" || fail "git-gate no node bad input: out=[$OUT]"

# Gate script present: the wrapper hands the call to it, node or not.
printf '#!/bin/sh\necho GATE-RAN\n' > "$ORCH/hooks/git-approval-gate.sh"; chmod +x "$ORCH/hooks/git-approval-gate.sh"
run_nonode git-gate "$WORKER_IN"
[[ "$OUT" == GATE-RAN ]] && pass "git-gate: gate present, call goes through the gate" || fail "git-gate gate present: out=[$OUT]"
rm -f "$ORCH/hooks/git-approval-gate.sh"

# With node, a gate-less call outside any worker stays silent (native flow unchanged).
if command -v node >/dev/null 2>&1; then
  OUT="$(printf '{"cwd":"/tmp"}' | env -i HOME="$T" PATH="$PATH" /bin/bash "$T/git-gate.sh" 2>/dev/null)"
  [[ -z "$OUT" ]] && pass "git-gate: node present, non-worker cwd stays silent" || fail "git-gate node non-worker: out=[$OUT]"
  OUT="$(printf '%s' "$WORKER_IN" | env -i HOME="$T" PATH="$PATH" /bin/bash "$T/git-gate.sh" 2>/dev/null)"
  [[ "$OUT" == *'"permissionDecision":"deny"'* ]] && pass "git-gate: node present, gate missing, worker cwd denied" || fail "git-gate node worker: out=[$OUT]"
fi

# permission-hold: without node it can not check the hold hook's answer, so it must never emit an allow.
printf '#!/bin/sh\ncat >/dev/null\necho "{\\"hookSpecificOutput\\":{\\"hookEventName\\":\\"PermissionRequest\\",\\"decision\\":{\\"behavior\\":\\"allow\\"}}}"\n' > "$ORCH/hooks/permission-hold.sh"; chmod +x "$ORCH/hooks/permission-hold.sh"
run_nonode permission-hold "$WORKER_IN"
[[ "$OUT" != *'"allow"'* ]] && pass "permission-hold: no node never emits allow" || fail "permission-hold no node: out=[$OUT]"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
