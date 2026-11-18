#!/bin/bash
# test/test-cycle-open.sh
# Pins the dispatch-task.sh --cycle-open exit contract: 0 cycle open, 1 none,
# 2 script error. Runs without Cadence installed: a fixture HOME points at a
# stub planning.mjs whose output and exit status come from per-case files.
# DISPATCH=<script> runs it against another script.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="${DISPATCH:-$SCRIPT_DIR/../orchestration/lib/dispatch-task.sh}"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"
FHOME="$TMP/home"
CAD="$TMP/cadence"
mkdir -p "$PROJ" "$FHOME/.claude/plugins" "$CAD/cadence-core/bin"
git -C "$PROJ" init -q -b main
cat > "$CAD/cadence-core/bin/planning.mjs" <<'EOF'
import fs from 'node:fs';
const d = new URL('../../', import.meta.url).pathname;
fs.writeFileSync(d + 'ran', '');
fs.appendFileSync(d + 'argv', process.argv.slice(2).join('\n') + '\n');
process.stdout.write(fs.readFileSync(d + 'out', 'utf8'));
process.exit(Number(fs.readFileSync(d + 'rc', 'utf8')));
EOF
cat > "$FHOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins":{"cadence@cadence":[{"installPath":"$CAD"}]}}
EOF

# run_case <stub stdout> <stub rc> -> exit status of --cycle-open; clears stub records
run_case() {
    printf '%s' "$1" > "$CAD/out"
    printf '%s' "$2" > "$CAD/rc"
    rm -f "$CAD/ran" "$CAD/argv"
    HOME="$FHOME" ORCH_PROJECT_ROOT="$PROJ" bash "$DISPATCH" --cycle-open >/dev/null 2>&1
}
expect() { # <description> <want> <got>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (want $2, got $3)"; fi
}

mkdir -p "$PROJ/.planning"
run_case '{"ok":true,"total":2}' 0; expect "(a) 2 phases: exit 0" 0 $?
run_case '{"ok":true,"total":0}' 0; expect "(b) 0 phases: exit 1" 1 $?

# (g) argv is exactly: status --dir <project>/.planning
run_case '{"ok":true,"total":2}' 0
if [ "$(cat "$CAD/argv" 2>/dev/null)" = "$(printf 'status\n--dir\n%s' "$PROJ/.planning")" ]; then
    pass "(g) stub argv is status --dir <project>/.planning"
else
    fail "(g) stub argv is status --dir <project>/.planning"
fi
# (g) an extra argument is never run and never reaches the stub
MARK="$TMP/injected"
rm -f "$CAD/argv"
HOME="$FHOME" ORCH_PROJECT_ROOT="$PROJ" bash "$DISPATCH" --cycle-open "x; touch $MARK" >/dev/null 2>&1
if [ ! -e "$MARK" ] && ! grep -q 'touch' "$CAD/argv" 2>/dev/null; then
    pass "(g) extra argument is not executed and not passed on"
else
    fail "(g) extra argument is not executed and not passed on"
fi

run_case '{"ok":false,"reason":"internal"}' 1; expect "(e) ok:false, node exit 1: exit 2" 2 $?
run_case 'not json at all' 0; expect "(f) non-JSON output: exit 2" 2 $?

# (c) no .planning: exit 1 and the stub never runs
rm -rf "$PROJ/.planning"
run_case '{"ok":true,"total":2}' 0; expect "(c) no .planning: exit 1" 1 $?
[ ! -e "$CAD/ran" ] && pass "(c) stub not run without .planning" || fail "(c) stub not run without .planning"

# (d) no plugins file: exit 2
mkdir -p "$PROJ/.planning"
mv "$FHOME/.claude/plugins/installed_plugins.json" "$TMP/plugins.bak"
run_case '{"ok":true,"total":2}' 0; expect "(d) no plugins file: exit 2" 2 $?
mv "$TMP/plugins.bak" "$FHOME/.claude/plugins/installed_plugins.json"

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
