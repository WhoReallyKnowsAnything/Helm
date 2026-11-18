#!/bin/bash
# test/test-install.sh
# Runs orchestration/install.sh against a scratch HOME with a stub launchctl on PATH.
# The orchestration folder is copied to a path with a space, so quoting is exercised.
# Plain bash, no framework. Never touches the real ~/.claude or ~/Library.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

SCRATCH=$(mktemp -d) || { echo "FAIL: no scratch dir"; exit 1; }
SCRATCH=$(cd "$SCRATCH" && pwd -P)
cleanup() { cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

export HOME="$SCRATCH/home"
mkdir -p "$HOME" "$SCRATCH/bin" "$SCRATCH/Helm Support"
[ "$HOME" = "$SCRATCH/home" ] && [ -d "$SCRATCH" ] || { echo "FAIL: HOME is not the scratch folder; refusing to run"; exit 1; }

ORCH="$SCRATCH/Helm Support/orchestration"
cp -R "$REPO_ROOT/orchestration" "$ORCH"
# A copy of the real file, so a test that deletes the duplicate check edits only this one.
INSTALL="${INSTALL_SH:-$ORCH/install.sh}"

LOG="$SCRATCH/launchctl.log"
printf '#!/bin/bash\n[ "$1" = print ] && exit 1\necho "$@" >> "%s"\n' "$LOG" > "$SCRATCH/bin/launchctl"
chmod +x "$SCRATCH/bin/launchctl"
export PATH="$SCRATCH/bin:$PATH"

S="$HOME/.claude/settings.json"
W1="$HOME/.claude/hooks/git-gate-wrapper.sh"
W2="$HOME/.claude/hooks/permission-hold-wrapper.sh"
PL="$HOME/Library/LaunchAgents/io.github.whoreallyknowsanything.helm.blocked-sweep.plist"
hashes() { shasum "$W1" "$W2" "$PL" 2>/dev/null; }

echo "test-install"

# CLAUDE.md sentinel and a settings file with unrelated content and an old-root relay entry
mkdir -p "$HOME/.claude"
echo "my rules" > "$HOME/.claude/CLAUDE.md"
CLAUDE_SUM=$(shasum "$HOME/.claude/CLAUDE.md")
cat > "$S" <<'EOF'
{
  "model": "keep-me",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo unrelated", "timeout": 5}]},
      {"hooks": [{"type": "command", "command": "/old/root/orchestration/hooks/worker-relay.sh", "timeout": 15}]},
      {"matcher": "Skill", "hooks": [{"type": "command", "command": "/old/root/orchestration/hooks/typed-command-gate.sh", "timeout": 90}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/old/root/orchestration/hooks/typed-command-gate.sh", "timeout": 90}]}
    ],
    "Notification": [{"hooks": [{"type": "command", "command": "echo note"}]}]
  }
}
EOF
cp "$S" "$SCRATCH/settings.orig.json"

bash "$INSTALL" >"$SCRATCH/run1.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "first run exits 0" || { fail "first run exit $rc: $(cat "$SCRATCH/run1.out")"; }

# --- wrappers and plist ---
for w in "$W1" "$W2"; do
  [ -x "$w" ] && pass "$(basename "$w") is executable" || fail "$(basename "$w") missing or not executable"
  grep -qF "$ORCH/hooks/" "$w" && pass "$(basename "$w") holds the scratch orchestration path" || fail "$(basename "$w") lacks the scratch path"
  grep -q "/Users/\|@ORCH_DIR@" "$w" && fail "$(basename "$w") holds an owner path or a token" || pass "$(basename "$w") holds no owner path or token"
done
plutil -lint "$PL" >/dev/null 2>&1 && pass "plist passes plutil -lint" || fail "plist fails plutil -lint"
{ grep -qF "$ORCH/lib/dispatch-task.sh" "$PL" && grep -qF "$HOME/.claude/logs/approval-sweep-launchd.log" "$PL" \
  && ! grep -q "/Users/\|@ORCH_DIR@\|@HOME@" "$PL"; } && pass "plist holds the scratch paths only" || fail "plist paths wrong"

# --- re-run changes nothing ---
H1=$(hashes); S1=$(shasum "$S")
bash "$INSTALL" >/dev/null 2>&1
[ "$(hashes)" = "$H1" ] && pass "second run leaves wrappers and plist byte-identical" || fail "second run changed wrappers or plist"
[ "$(shasum "$S")" = "$S1" ] && pass "second run leaves settings byte-identical" || fail "second run changed settings"
LINES=$(grep -c . "$LOG")
{ [ "$LINES" -eq 4 ] && sed -n '1p;3p' "$LOG" | grep -q "^bootout gui/[0-9]* $PL\$" && sed -n '2p;4p' "$LOG" | grep -q "^bootstrap gui/[0-9]* $PL\$"; } \
  && pass "launchctl got bootout then bootstrap with the plist path" || fail "launchctl log wrong: $(cat "$LOG")"

# --- settings content ---
cat > "$SCRATCH/check.js" <<'EOF'
const fs = require("fs"), assert = require("assert");
const [file, origFile, orch] = process.argv.slice(2);
const s = JSON.parse(fs.readFileSync(file, "utf8")), o = JSON.parse(fs.readFileSync(origFile, "utf8"));
assert.strictEqual(s.model, o.model);
assert.deepStrictEqual(s.hooks.Notification, o.hooks.Notification);
assert.deepStrictEqual(s.hooks.PreToolUse[0], o.hooks.PreToolUse[0]);
const count = (ev, name) => (s.hooks[ev] || []).flatMap((g) => g.hooks).filter((h) => h.command.includes(name)).length;
for (const ev of ["PostToolUse", "PreToolUse", "SessionStart", "Stop", "UserPromptSubmit"]) assert.strictEqual(count(ev, "worker-relay.sh"), 1, ev);
assert.strictEqual(count("PermissionRequest", "permission-hold-wrapper.sh"), 1);
// one entry per matcher: lean-ctx's shell and native Bash
assert.strictEqual(count("PreToolUse", "git-gate-wrapper.sh"), 2);
// typed-command gate: one entry on UserPromptSubmit, one on PreToolUse in a Skill group, 90 s timeout
assert.strictEqual(count("UserPromptSubmit", "typed-command-gate.sh"), 1);
assert.strictEqual(count("PreToolUse", "typed-command-gate.sh"), 1);
const skillGate = s.hooks.PreToolUse.filter((g) => g.matcher === "Skill").flatMap((g) => g.hooks).filter((h) => h.command.includes("typed-command-gate.sh"));
assert.strictEqual(skillGate.length, 1);
assert.strictEqual(skillGate[0].timeout, 90);
const all = JSON.stringify(s);
assert(!all.includes("/old/root"), "old root still present");
assert(all.includes(orch), "scratch root missing");
const pre = s.hooks.PermissionRequest[0].hooks[0];
assert.strictEqual(pre.onFailure, "block");
EOF
node "$SCRATCH/check.js" "$S" "$SCRATCH/settings.orig.json" "$ORCH" 2>"$SCRATCH/check.err" \
  && pass "unrelated entries equal, each managed event has 1 entry on the scratch root, old root moved" \
  || fail "settings check: $(cat "$SCRATCH/check.err")"
[ -f "$S.bak-before-install" ] && cmp -s "$S.bak-before-install" "$SCRATCH/settings.orig.json" && pass "backup holds the original file" || fail "backup missing or wrong"

# --- registered command strings run with a space in the root ---
CMD=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$S")
OUT=$(bash -c "$CMD" </dev/null 2>&1)
case "$OUT" in *"No such file"*) fail "registered relay command fails on the spaced root: $OUT";; *) pass "registered relay command finds its script on a spaced root";; esac

# --- CLAUDE.md untouched ---
[ "$(shasum "$HOME/.claude/CLAUDE.md")" = "$CLAUDE_SUM" ] && pass "CLAUDE.md untouched" || fail "CLAUDE.md changed"

# --- old-label migration ---
OLDPL="$HOME/Library/LaunchAgents/com.claude-multi-session-orchestrator.blocked-sweep.plist"
: > "$LOG"
echo old > "$OLDPL"
bash "$INSTALL" >/dev/null 2>&1
{ [ ! -e "$OLDPL" ] && grep -q "^bootout gui/[0-9]*/com.claude-multi-session-orchestrator.blocked-sweep\$" "$LOG" \
  && [ "$(grep -n 'orchestrator.blocked-sweep' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^bootstrap' "$LOG" | head -1 | cut -d: -f1)" ]; } \
  && pass "old-label plist booted out and removed before the new load" || fail "old-label migration wrong: $(cat "$LOG")"
: > "$LOG"
bash "$INSTALL" >/dev/null 2>&1
grep -q "claude-multi-session-orchestrator" "$LOG" && fail "migration not silent when the old label is absent" || pass "no old-label calls when the old label is absent"

# --- malformed settings ---
echo '{ not json' > "$S"
BAD=$(shasum "$S")
bash "$INSTALL" >"$SCRATCH/bad.out" 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && [ "$(shasum "$S")" = "$BAD" ]; } && pass "malformed settings: exit $rc, file unchanged" || fail "malformed settings: exit $rc or file changed"

# --- native Bash git gate (no lean-ctx needed) ---
cat > "$SCRATCH/gates.js" <<'EOF'
// Prints "<n>" git-gate entries on matchers that match native Bash, over the given settings files.
const fs = require("fs");
let n = 0;
for (const f of process.argv.slice(2)) {
  if (!fs.existsSync(f)) continue;
  const s = JSON.parse(fs.readFileSync(f, "utf8"));
  for (const g of (s.hooks && s.hooks.PreToolUse) || [])
    if (typeof g.matcher === "string" && g.matcher.split("|").includes("Bash"))
      n += (g.hooks || []).filter((h) => /git-gate-wrapper\.sh|git-approval-gate\.sh/.test(h.command)).length;
}
console.log(n);
EOF
bashgates() { node "$SCRATCH/gates.js" "$@"; }

# fresh home: nothing but the installer's own files, no lean-ctx anywhere
FH="$SCRATCH/fresh"; mkdir -p "$FH"
HOME="$FH" bash "$INSTALL" >/dev/null 2>&1
[ "$(bashgates "$FH/.claude/settings.json")" = 1 ] && pass "fresh home: one native Bash git-gate entry" || fail "fresh home: Bash git-gate entries = $(bashgates "$FH/.claude/settings.json")"
HOME="$FH" bash "$INSTALL" >/dev/null 2>&1
[ "$(bashgates "$FH/.claude/settings.json")" = 1 ] && pass "fresh home: re-run adds no second Bash entry" || fail "fresh home re-run: entries = $(bashgates "$FH/.claude/settings.json")"

# owner-shaped home: the Bash|bash git gate sits in settings.local.json, other hooks around it
OH="$SCRATCH/owner"; mkdir -p "$OH/.claude"
cat > "$OH/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash|bash", "hooks": [
        {"type": "command", "command": "bash ~/.claude/hooks/enforce-ctx-shell.sh"},
        {"type": "command", "command": "bash ~/.claude/hooks/git-gate-wrapper.sh", "timeout": 900, "onFailure": "block"},
        {"type": "command", "command": "bash ~/.claude/hooks/blocks-raw-file-read.sh"}]},
      {"matcher": "Read", "hooks": [{"type": "command", "command": "echo r"}]}
    ]
  }
}
EOF
cat > "$OH/.claude/settings.json" <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "mcp__lean-ctx__ctx_shell", "hooks": [{"type": "command", "command": "echo mine"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo bash-mine"}]}
]}}
EOF
LOC_SUM=$(shasum "$OH/.claude/settings.local.json"); cp "$OH/.claude/settings.json" "$SCRATCH/owner-settings.orig.json"
HOME="$OH" bash "$INSTALL" >/dev/null 2>&1
[ "$(shasum "$OH/.claude/settings.local.json")" = "$LOC_SUM" ] && pass "owner home: settings.local.json untouched" || fail "owner home: settings.local.json changed"
[ "$(bashgates "$OH/.claude/settings.json" "$OH/.claude/settings.local.json")" = 1 ] \
  && pass "owner home: still one Bash git-gate entry across both files" || fail "owner home: Bash git-gate entries = $(bashgates "$OH/.claude/settings.json" "$OH/.claude/settings.local.json")"
node -e '
const a=require("assert"),fs=require("fs");
const s=JSON.parse(fs.readFileSync(process.argv[1])),o=JSON.parse(fs.readFileSync(process.argv[2]));
a.deepStrictEqual(s.hooks.PreToolUse.slice(0,2),o.hooks.PreToolUse);
' "$OH/.claude/settings.json" "$SCRATCH/owner-settings.orig.json" 2>"$SCRATCH/own.err" \
  && pass "owner home: existing hooks kept, same order" || fail "owner home: hooks changed: $(cat "$SCRATCH/own.err")"

# an existing Bash|bash git gate in settings.json itself is left as it is
BH="$SCRATCH/bashbar"; mkdir -p "$BH/.claude"
echo '{"hooks":{"PreToolUse":[{"matcher":"Bash|bash","hooks":[{"type":"command","command":"bash ~/.claude/hooks/git-gate-wrapper.sh"}]}]}}' > "$BH/.claude/settings.json"
HOME="$BH" bash "$INSTALL" >/dev/null 2>&1
[ "$(bashgates "$BH/.claude/settings.json")" = 1 ] && pass "Bash|bash entry in settings.json: no second entry" || fail "Bash|bash in settings.json: entries = $(bashgates "$BH/.claude/settings.json")"

# the installed wrapper on a native Bash payload: silent for non-git, ask for git, never allow
GP() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_use_id:"toolu_i",cwd:"/tmp",tool_input:{command:process.argv[1]}}))' "$1" | HOME="$FH" bash "$FH/.claude/hooks/git-gate-wrapper.sh" 2>/dev/null; }
[ -z "$(GP 'ls -la')" ] && pass "gate wrapper: non-git Bash command gets no output" || fail "gate wrapper: output for ls: $(GP 'ls -la')"
for c in 'git commit -m x' 'git push origin main' 'gh pr create --title x'; do
  O=$(GP "$c")
  case "$O" in *'"allow"'*) fail "gate wrapper: '$c' got allow";; *'"permissionDecision":"ask"'*) pass "gate wrapper: '$c' gets ask";; *) fail "gate wrapper: '$c' got [$O]";; esac
done


echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
