#!/bin/bash
# test/test-mempalace-hub-check.sh
# mempalace_hub_warning warns (never blocks) when the MemPalace hub is down or
# read-only, and stays silent when the hub answers and holds the writer lease.
# The two probes are stubbed; no real hub or network is used. Also checks that
# dispatch-task.sh sources the check and that the worker prompt names the MCP tools.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
source "$ROOT/orchestration/lib/mempalace-hub-check.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WRITER_STATUS='{"writer": {"read_only": false, "peer_writer_read_only": false, "peer_writer_lock_failed": false}}'

# 0. No mempalace on this machine: a down hub is expected, so no warning.
mempalace_hub_healthz() { return 1; }
mempalace_hub_status() { echo ""; }
NOMP=$(mktemp -d); NOMP=$(cd "$NOMP" && pwd -P)
OUT=$(HOME="$NOMP" PATH="/usr/bin:/bin" mempalace_hub_warning); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "no mempalace installed: hub down gives no warning" || fail "no mempalace: rc=$RC out=$OUT"

# 1. Hub down (mempalace installed, stubbed on PATH): one warning naming the launchctl step, rc 0.
mkdir -p "$NOMP/bin"; printf '#!/bin/sh\n' > "$NOMP/bin/mempalace"; chmod +x "$NOMP/bin/mempalace"
OUT=$(HOME="$NOMP" PATH="$NOMP/bin:/usr/bin:/bin" mempalace_hub_warning); RC=$?
rm -rf "$NOMP"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"not answering"* && "$OUT" == *"launch-claude.sh starts the hub"* ]]; then
    pass "hub down warns and returns 0"
else
    fail "hub down: rc=$RC out=$OUT"
fi

# 2. Hub up + writer: silent.
mempalace_hub_healthz() { return 0; }
mempalace_hub_status() { echo "$WRITER_STATUS" | tr -d ' \n'; }
OUT=$(mempalace_hub_warning); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    pass "hub up with writer lease is silent"
else
    fail "hub up + writer: rc=$RC out=$OUT"
fi

# 3. Hub up + read-only (each of the three flags): warns, rc 0.
for flag in read_only peer_writer_read_only peer_writer_lock_failed; do
    mempalace_hub_status() { echo "$WRITER_STATUS" | sed "s/\"$flag\": false/\"$flag\": true/" | tr -d ' \n'; }
    OUT=$(mempalace_hub_warning); RC=$?
    if [ "$RC" -eq 0 ] && [[ "$OUT" == *"read-only"* ]]; then
        pass "hub up with $flag=true warns"
    else
        fail "hub read-only ($flag): rc=$RC out=$OUT"
    fi
done

# 4. Hub up but statusz unreadable (token set, or old hub): no false alarm.
mempalace_hub_status() { echo ""; }
OUT=$(mempalace_hub_warning)
[ -z "$OUT" ] && pass "unreadable statusz is silent" || fail "unreadable statusz warned: $OUT"

# 5. mempalace_hub_ensure with launchctl and the healthz probe stubbed.
# A sandboxed HOME holds a fake hub binary; the real $HOME is never touched.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
export HOME="$SCRATCH/home"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\n' >"$HOME/.local/bin/mempalace"
chmod +x "$HOME/.local/bin/mempalace"
export MEMPALACE_HUB_WAIT_TICKS=3
BOOTSTRAPS="$SCRATCH/bootstraps"
PLIST_SEEN="$SCRATCH/plist-seen"

reset_ensure() { : >"$BOOTSTRAPS"; : >"$PLIST_SEEN"; }
bootstrap_count() { wc -l <"$BOOTSTRAPS" | tr -d ' '; }

# launchctl stub: LOADED=1 makes `print` succeed; BOOTSTRAP_RC is bootstrap's status;
# a successful bootstrap brings the (stubbed) hub up.
mempalace_hub_launchctl() {
    case "$1" in
        print) [ "${LOADED:-0}" = 1 ] ;;
        bootstrap)
            echo "$2" >>"$BOOTSTRAPS"
            cp "$3" "$PLIST_SEEN"
            [ "${BOOTSTRAP_RC:-0}" -eq 0 ] && HUB_UP=1
            return "${BOOTSTRAP_RC:-0}"
            ;;
    esac
}
mempalace_hub_healthz() { [ "${HUB_UP:-0}" = 1 ]; }
mempalace_hub_status() { echo "$WRITER_STATUS" | tr -d ' \n'; }

# 5a. Already up: no bootstrap.
reset_ensure; HUB_UP=1 LOADED=0 BOOTSTRAP_RC=0
mempalace_hub_ensure; RC=$?
[ "$RC" -eq 0 ] && [ "$(bootstrap_count)" -eq 0 ] \
    && pass "hub already up: no bootstrap" || fail "hub up: rc=$RC bootstraps=$(bootstrap_count)"

# 5b. Down and not loaded: one bootstrap of a temp copy with the real binary path; hub comes up.
reset_ensure; HUB_UP=0 LOADED=0 BOOTSTRAP_RC=0
mempalace_hub_ensure; RC=$?
if [ "$RC" -eq 0 ] && [ "$(bootstrap_count)" -eq 1 ] \
   && grep -q "$HOME/.local/bin/mempalace" "$PLIST_SEEN" && ! grep -q __MEMPALACE_BIN__ "$PLIST_SEEN" \
   && [ "$(mempalace_hub_warning)" = "" ]; then
    pass "hub down and not loaded: bootstraps once with the binary filled in, then no warning"
else
    fail "not loaded: rc=$RC bootstraps=$(bootstrap_count)"
fi

# 5c. Down but job already loaded: no second bootstrap.
reset_ensure; HUB_UP=0 LOADED=1 BOOTSTRAP_RC=0
mempalace_hub_ensure; RC=$?
[ "$RC" -eq 1 ] && [ "$(bootstrap_count)" -eq 0 ] \
    && pass "job already loaded but hub down: no bootstrap, returns 1 so the caller warns" || fail "loaded: rc=$RC bootstraps=$(bootstrap_count)"

# 5d. Bootstrap fails: ensure returns 1 (no hang), the warning fires, and the caller's `||` carries on.
reset_ensure; HUB_UP=0 LOADED=0 BOOTSTRAP_RC=1
OUT=$(mempalace_hub_ensure || mempalace_hub_warning); RC=$?
mempalace_hub_ensure; ENSURE_RC=$?
if [ "$RC" -eq 0 ] && [ "$ENSURE_RC" -eq 1 ] && [ "$(bootstrap_count)" -eq 2 ] && [[ "$OUT" == *"not answering"* ]]; then
    pass "bootstrap fails: ensure returns 1, warning fires, launch continues"
else
    fail "bootstrap fails: rc=$RC bootstraps=$(bootstrap_count) out=$OUT"
fi

# 5e. No hub binary: nothing is bootstrapped.
reset_ensure; HUB_UP=0 LOADED=0 BOOTSTRAP_RC=0
rm "$HOME/.local/bin/mempalace"
mempalace_hub_ensure; RC=$?
[ "$RC" -eq 0 ] && [ "$(bootstrap_count)" -eq 0 ] \
    && pass "no mempalace binary: no bootstrap" || fail "no binary: rc=$RC bootstraps=$(bootstrap_count)"

# 6. Wiring: dispatch-task.sh and launch-claude.sh source the check; worker prompt names the MCP tools.
grep -q 'mempalace_hub_ensure' "$ROOT/orchestration/launch-claude.sh" \
    && pass "launch-claude.sh starts the hub" || fail "launch-claude.sh does not call mempalace_hub_ensure"
plutil -lint "$ROOT/orchestration/launchd/io.github.whoreallyknowsanything.helm.mempalace-hub.plist" >/dev/null \
    && pass "hub plist template lints" || fail "hub plist template does not lint"
grep -q 'mempalace-hub-check.sh' "$ROOT/orchestration/lib/dispatch-task.sh" \
    && pass "dispatch-task.sh sources the hub check" || fail "dispatch-task.sh does not source the hub check"
grep -q 'mempalace_add_drawer' "$ROOT/orchestration/prompts/worker-dependency-awareness.md" \
    && pass "worker prompt names the MemPalace MCP tools" || fail "worker prompt lacks the MemPalace MCP line"

echo "Passed: $PASS_COUNT, Failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
