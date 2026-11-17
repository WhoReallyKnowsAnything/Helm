#!/bin/bash
# test/test-seed-mempalace.sh
# launch-claude.sh seed_mempalace: mines the project into its MemPalace wing with
# --daemon --background. The function is cut out of the launcher with sed and run
# under bash with a stub
# mempalace first on PATH. The stub rejects --background without --daemon, like the real
# CLI, and rejects every call while $SCRATCH/mempalace.fail exists. The real mempalace,
# the real projects folder and tmux are never touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/orchestration/launch-claude.sh"

FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS + 1)); }

SCRATCH="$(mktemp -d /tmp/smp.XXXXXX)" || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
STUB="$SCRATCH/stub"
CALLS="$SCRATCH/calls.log"
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"
PROJ="$SCRATCH/projects/seedproj"
PROBE="$SCRATCH/probe.sh"
mkdir -p "$STUB" "$PROJ"

# ---- stub ------------------------------------------------------------------
printf '#!/bin/bash\necho "$*" >>"%s"\n[[ -e "%s/mempalace.fail" ]] && exit 1\nif [[ " $* " == *" --background "* && " $* " != *" --daemon "* ]]; then\necho "mempalace: --background needs --daemon" >&2\nexit 1\nfi\nexit 0\n' "$CALLS" "$SCRATCH" >"$STUB/mempalace"
chmod +x "$STUB/mempalace"

if "$STUB/mempalace" mine "$PROJ" --wing seedproj --background >/dev/null 2>&1; then
    fail "stub rejects --background without --daemon"
else
    pass "stub rejects --background without --daemon"
fi
if "$STUB/mempalace" mine "$PROJ" --wing seedproj --daemon --background >/dev/null 2>&1; then
    pass "stub accepts --daemon --background"
else
    fail "stub accepts --daemon --background"
fi
rm -f "$CALLS"

# ---- the function, run alone -----------------------------------------------
{ echo '#!/bin/bash'; sed -n '/^seed_mempalace() {/,/^}/p' "$LAUNCHER"; echo 'seed_mempalace "$1"'; } >"$PROBE"

run_seed() {
    rm -f "$CALLS"
    (cd "$PROJ" && PATH="$STUB:$PATH" bash "$PROBE" seedproj >"$OUT" 2>"$ERR")
    RC=$?
}

# ---- success ---------------------------------------------------------------
run_seed
if [[ "$RC" -eq 0 ]] && grep -qF "MemPalace wing seeded" "$OUT" && grep -qxF "mine $PROJ --wing seedproj --daemon --background" "$CALLS"; then
    pass "success: wing seeded, mine called with --daemon --background"
else
    fail "success: rc=$RC out=$(head -c 200 "$OUT") err=$(head -c 200 "$ERR") calls=$(tr '\n' '|' <"$CALLS")"
fi

# ---- failure ---------------------------------------------------------------
touch "$SCRATCH/mempalace.fail"
run_seed
rm -f "$SCRATCH/mempalace.fail"
if [[ "$RC" -ne 0 ]] && ! grep -qF "MemPalace wing seeded" "$OUT" && grep -q 'Warning:' "$ERR"; then
    pass "failure: no seeded line, warning on stderr, non-zero return"
else
    fail "failure: rc=$RC out=$(head -c 200 "$OUT") err=$(head -c 200 "$ERR")"
fi

[[ "$FAILS" -eq 0 ]] && exit 0 || exit 1
