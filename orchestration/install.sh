#!/bin/bash
# orchestration/install.sh
# Non-interactive, safe to re-run. Writes the 2 hook wrappers and the blocked-sweep
# LaunchAgent for the orchestration folder this script sits in, and (below) registers
# the hooks in ~/.claude/settings.json. Never touches ~/.claude/CLAUDE.md.
set -eu
shopt -u patsub_replacement 2>/dev/null || true # bash 5.2+: keep "&" literal in ${x//a/b}

ORCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOKS_DIR="$HOME/.claude/hooks"
LOGS_DIR="$HOME/.claude/logs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="io.github.whoreallyknowsanything.helm.blocked-sweep.plist"

mkdir -p "$HOOKS_DIR" "$LOGS_DIR" "$AGENTS_DIR"

# Optional Notion setup: --notion-projects-ds ID / --notion-tasks-ds ID, or the env vars
# HELM_NOTION_PROJECTS_DS_ID / HELM_NOTION_TASKS_DS_ID. Written to notion.env in the Helm
# support folder, which launch-claude.sh reads. Nothing is written when neither is given.
while [ $# -gt 0 ]; do
  case "$1" in
    --notion-projects-ds) HELM_NOTION_PROJECTS_DS_ID="${2-}"; shift ;;
    --notion-tasks-ds) HELM_NOTION_TASKS_DS_ID="${2-}"; shift ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
NP="${HELM_NOTION_PROJECTS_DS_ID-}" NT="${HELM_NOTION_TASKS_DS_ID-}"
if [ -n "$NP$NT" ]; then
  uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  for v in "$NP" "$NT"; do
    [[ "$v" =~ $uuid_re ]] || { echo "install.sh: both Notion data source IDs must be UUIDs (lowercase, dashed): '$v'" >&2; exit 2; }
  done
  NOTION_DIR="${HELM_SUPPORT_DIR:-$HOME/Library/Application Support/Helm}"
  mkdir -p "$NOTION_DIR"
  printf 'HELM_NOTION_PROJECTS_DS_ID=%s\nHELM_NOTION_TASKS_DS_ID=%s\n' "$NP" "$NT" > "$NOTION_DIR/notion.env"
  chmod 600 "$NOTION_DIR/notion.env"
  echo "wrote $NOTION_DIR/notion.env"
fi

# $1 = template, $2 = output, $3 = mode, $4 = escaped orch dir, $5 = escaped home
render() {
  local body tmp
  body=$(cat "$1")
  body=${body//@ORCH_DIR@/$4}
  body=${body//@HOME@/$5}
  tmp=$(mktemp "$2.XXXXXX")
  printf '%s\n' "$body" > "$tmp"
  chmod "$3" "$tmp"
  mv -f "$tmp" "$2"
  echo "wrote $2"
}

# Wrappers hold the path inside double quotes: escape \ " $ and backtick.
sh_esc() { local v=$1; v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; printf '%s' "${v//\`/\\\`}"; }
# The plist is XML: escape & < >.
xml_esc() { local v=$1; v=${v//&/&amp;}; v=${v//</&lt;}; printf '%s' "${v//>/&gt;}"; }

for w in git-gate permission-hold; do
  render "$ORCH_DIR/templates/$w-wrapper.sh.in" "$HOOKS_DIR/$w-wrapper.sh" 755 "$(sh_esc "$ORCH_DIR")" ""
done

OLD_LABEL_PREFIX="com.claude-multi-session-orchestrator"
for j in blocked-sweep; do
  old="$OLD_LABEL_PREFIX.$j"
  if [ -f "$AGENTS_DIR/$old.plist" ] || launchctl print "gui/$(id -u)/$old" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$old" 2>/dev/null || true
    rm -f "$AGENTS_DIR/$old.plist"
  fi
done

PLIST="$AGENTS_DIR/$PLIST_NAME"
render "$ORCH_DIR/launchd/$PLIST_NAME" "$PLIST" 644 "$(xml_esc "$ORCH_DIR")" "$(xml_esc "$HOME")"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true # "not loaded" is fine
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# --- hooks in ~/.claude/settings.json ---
command -v node >/dev/null || { echo "install.sh: node is required to edit settings.json but was not found on PATH" >&2; exit 1; }
node - "$HOME/.claude/settings.json" "$ORCH_DIR" "$HOOKS_DIR" <<'JS'
const fs = require("fs");
const [file, orch, hooksDir] = process.argv.slice(2);
const die = (m) => { console.error("install.sh: " + m); process.exit(1); };

let raw = null, s = {};
if (fs.existsSync(file)) {
  raw = fs.readFileSync(file, "utf8");
  try { s = JSON.parse(raw); } catch (e) { die(file + " is not valid JSON, left unchanged: " + e.message); }
}
if (s === null || typeof s !== "object" || Array.isArray(s)) die(file + " is not a JSON object, left unchanged");
if (s.hooks === undefined) s.hooks = {};
if (s.hooks === null || typeof s.hooks !== "object" || Array.isArray(s.hooks)) die(file + ': "hooks" is not an object, left unchanged');

// The command path holds a space (the runtime folder), so every path is quoted.
const relay = { type: "command", command: `"${orch}/hooks/worker-relay.sh"`, timeout: 15 };
const wrap = (n) => ({ type: "command", command: `bash "${hooksDir}/${n}-wrapper.sh"`, timeout: 900, onFailure: "block" });
// Native Bash needs its own git gate (a machine without lean-ctx runs git through it). Skip it when
// settings.json or settings.local.json already gates a matcher that covers Bash, e.g. "Bash|bash".
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };
const localFile = require("path").join(require("path").dirname(file), "settings.local.json");
const gatesBash = (o) => !!o && !!o.hooks && Array.isArray(o.hooks.PreToolUse) && o.hooks.PreToolUse.some((g) =>
  g && typeof g.matcher === "string" && g.matcher.split("|").includes("Bash") && Array.isArray(g.hooks) &&
  g.hooks.some((h) => h && typeof h.command === "string" && /git-gate-wrapper\.sh|git-approval-gate\.sh/.test(h.command)));
const bashGated = gatesBash(s) || gatesBash(readJson(localFile));
const wanted = [
  ["PermissionRequest", undefined, wrap("permission-hold"), "permission-hold-wrapper.sh"],
  ["PreToolUse", "mcp__lean-ctx__ctx_shell", wrap("git-gate"), "git-gate-wrapper.sh"],
  ...(bashGated ? [] : [["PreToolUse", "Bash", wrap("git-gate"), "git-gate-wrapper.sh"]]),
  ["PostToolUse", "Bash|WebFetch|mcp__.*|Write|Edit|MultiEdit|NotebookEdit", relay, "worker-relay.sh"],
  ["PreToolUse", undefined, relay, "worker-relay.sh"],
  ["SessionStart", undefined, relay, "worker-relay.sh"],
  ["Stop", undefined, relay, "worker-relay.sh"],
  ["UserPromptSubmit", undefined, relay, "worker-relay.sh"],
];
const isManaged = (h, name) => h && typeof h.command === "string" && h.command.includes(name);

for (const [ev, matcher, hook, name] of wanted) {
  if (s.hooks[ev] === undefined) s.hooks[ev] = [];
  if (!Array.isArray(s.hooks[ev])) die(`hooks.${ev} is not an array, left unchanged`);
  const groups = s.hooks[ev];
  let placed = false;
  for (const g of groups) {
    if (!g || !Array.isArray(g.hooks)) continue;
    // A relay on PreToolUse and one on PostToolUse differ by matcher, so match the group's matcher too.
    if (g.matcher !== matcher) continue;
    g.hooks = g.hooks.flatMap((h) => {
      if (!isManaged(h, name)) return [h];
      if (placed) return [];
      placed = true;
      return [{ ...h, ...hook }];
    });
  }
  if (!placed) groups.push({ ...(matcher === undefined ? {} : { matcher }), hooks: [{ ...hook }] });
  s.hooks[ev] = groups.filter((g) => !(g && Array.isArray(g.hooks) && g.hooks.length === 0));
}

const out = JSON.stringify(s, null, 2) + "\n";
if (out === raw) { console.log("unchanged " + file); process.exit(0); }
fs.mkdirSync(require("path").dirname(file), { recursive: true });
const bak = file + ".bak-before-install";
if (raw !== null && !fs.existsSync(bak)) fs.writeFileSync(bak, raw);
const tmp = file + ".tmp-" + process.pid;
fs.writeFileSync(tmp, out);
fs.renameSync(tmp, file);
console.log("wrote " + file);
JS
