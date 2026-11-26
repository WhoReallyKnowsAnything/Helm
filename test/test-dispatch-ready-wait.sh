#!/bin/bash
# test/test-dispatch-ready-wait.sh
# dispatch-task.sh waits (bounded) until every SessionStart hook in the new
# worker's out.jsonl has answered, so the first SendMessage is not held
# (peer_message_hold, cause mode-unknown). tmux is stubbed; the stub plays a
# worker that logs its hooks over about 1 second.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DISPATCH="$REPO_DIR/orchestration/lib/dispatch-task.sh"
FAILS=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

TMP_MAIN=$(mktemp -d); STUB_BIN=$(mktemp -d)
trap 'rm -rf "$TMP_MAIN" "$STUB_BIN"' EXIT
git -C "$TMP_MAIN" init -q -b main
git -C "$TMP_MAIN" config user.email t@example.com
git -C "$TMP_MAIN" config user.name Test
echo r > "$TMP_MAIN/README.md"
git -C "$TMP_MAIN" add README.md
git -C "$TMP_MAIN" -c commit.gpgsign=false commit -q -m init
"$REPO_DIR/orchestration/init/init-state-store.sh" "$TMP_MAIN" >/dev/null 2>&1
export ORCH_PROJECT_ROOT="$TMP_MAIN"

# new-window: $5 is the label. With STUB_HOOKS set, a background "worker" logs
# 2 hook_started now and 2 hook_response after 1 s.
cat > "$STUB_BIN/tmux" <<'STUB'
#!/bin/bash
case "$1" in
    new-window)
        if [ -n "${STUB_HOOKS:-}" ]; then
            out="$ORCH_PROJECT_ROOT/.claude/sessions/$5/out.jsonl"
            mkdir -p "$(dirname "$out")"
            ( printf '{"type":"system","subtype":"hook_started"}\n{"type":"system","subtype":"hook_started"}\n' >> "$out"
              sleep 1
              printf '{"type":"system","subtype":"hook_response"}\n{"type":"system","subtype":"hook_response"}\n' >> "$out" ) >/dev/null 2>&1 &
        fi
        exit 0 ;;
    list-windows) exit 0 ;;
    has-session) exit 1 ;;
    *) exit 0 ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/osascript"
chmod +x "$STUB_BIN/"*
run() { (cd "$TMP_MAIN" && env "$@" PATH="$STUB_BIN:$PATH" "$DISPATCH" "$LABEL" "Ready wait task" >/dev/null 2>&1); }

LABEL=rw-ready; t0=$SECONDS
run STUB_HOOKS=1 DISPATCH_READY_TIMEOUT=20; rc=$?; dt=$((SECONDS - t0))
resp=$(grep -c hook_response "$TMP_MAIN/.claude/sessions/$LABEL/out.jsonl" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "${resp:-0}" -eq 2 ] && [ "$dt" -lt 15 ]; then ok "dispatch returns once all hooks answered (${dt}s)"; else bad "ready case: rc=$rc responses=$resp dt=$dt"; fi

LABEL=rw-timeout; t0=$SECONDS
run DISPATCH_READY_TIMEOUT=2; rc=$?; dt=$((SECONDS - t0))
if [ "$rc" -eq 0 ] && [ "$dt" -ge 2 ] && [ "$dt" -lt 15 ]; then ok "no worker log: dispatch gives up after the timeout and exits 0 (${dt}s)"; else bad "timeout case: rc=$rc dt=$dt"; fi

echo "Results: $FAILS failed"; [ "$FAILS" -eq 0 ]
