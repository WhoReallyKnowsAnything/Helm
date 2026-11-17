#!/bin/bash
# test/test-cadence-stage-prompt.sh
# Pins the board stage-dispatch wording in ### Board Stage Dispatch of the
# drafting prompt. DRAFT=<copy> runs it against a scratch copy.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAFT="${DRAFT:-$SCRIPT_DIR/../orchestration/prompts/task-drafting-mode.md}"
PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
# has <text> <fixed string> <description>; hasE: same with an extended regex.
has() { if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3"; fi; }
hasE() { if printf '%s' "$1" | grep -qE -- "$2"; then pass "$3"; else fail "$3"; fi; }

SEC=$(awk '/^### Board Stage Dispatch/{p=1} /^### Worker Check-In/{p=0} p' "$DRAFT")
[ -n "$SEC" ] || { echo "FAIL: ### Board Stage Dispatch is missing in $DRAFT"; echo "Results: 0 passed, 1 failed"; exit 1; }

has "$SEC" 'Cadence stage: skill=' "exact prefix literal"
for s in context plan execute verify milestone audit health suggest coverage minimalism-review decision-review config land; do
    has "$SEC" "\`/cadence:cad-$s\`" "allowlist holds /cadence:cad-$s"
done
# nothing else: the section names exactly 13 distinct /cadence:cad-<word> skills (5 stage + 7 chip + cad-land)
N=$(printf '%s' "$SEC" | grep -oE '/cadence:cad-[a-z-]+' | sort -u | wc -l | tr -d ' ')
[ "$N" = 13 ] && pass "exactly 13 distinct skills named" || fail "exactly 13 distinct skills named (got $N)"
has "$SEC" '^[0-9]+(\.[0-9]+)?$' "phase regex"
has "$SEC" '`p1-1`' "p1-1 label example"
has "$SEC" 'cad-<stage>-p3`' "p3 label example"
has "$SEC" 'never `p3-0`' "p3-0 named as wrong"
has "$SEC" 'full text after `/cadence:cad-`' "<stage> is the full text after /cadence:cad-"
has "$SEC" 'phase=2 skill=/cadence:cad-milestone' "opaque reason example"
has "$SEC" 'Never parse it as fields' "reason is never parsed as fields"
has "$SEC" 'first occurrence of ` reason: `' "split at first reason marker"
has "$SEC" '--kill' "held label offers --kill"
has "$SEC" 'spawn nothing' "held label spawns nothing"
has "$SEC" 'dispatch nothing' "refusal dispatches nothing"
has "$SEC" 'Run no drafting round' "no drafting round"
hasE "$SEC" 'never into a shell command or argument' "reason only in SendMessage text"
hasE "$SEC" '`opus` with `xhigh` or `max` is refused' "opus xhigh and max refused"
hasE "$SEC" 'send it bare with no argument' "bare /cadence:cad-milestone"

# Phase 2: chip skills, optional fields, argument checks, send text
has "$SEC" 'optional ` phase=<N>`, optional ` arg=<text>`, then ` model=' "grammar: optional phase and arg, in order"
has "$SEC" 'the five stage skills' "field rule: stage skills"
has "$SEC" 'need `phase` and no `arg`' "field rule: stage skills need phase, no arg"
has "$SEC" '`cad-audit`, `cad-health` and `cad-suggest` take no `phase` and no `arg`' "field rule: audit health suggest"
has "$SEC" '`cad-config` takes no `phase` and one `arg`' "field rule: config"
has "$SEC" '`cad-coverage` and `cad-minimalism-review` take `phase` and no `arg`' "field rule: coverage and minimalism-review"
has "$SEC" '`cad-decision-review` takes `phase` and one `arg`' "field rule: decision-review"
has "$SEC" 'a field the skill does not take, is refused' "unwanted field refused"
for kv in 'workflow.plan_check` = `true' 'workflow.verifier` = `true' 'planning.code_map` = `true' \
          'review.triggers.plan.gate` = `advisory' 'review.triggers.diff.gate` = `off' \
          'review.triggers.risk_surface.gate` = `blocking' 'review.triggers.phase_diff.gate` = `off'; do
    has "$SEC" "$kv" "config key and its one value: $kv"
done
has "$SEC" 'A key outside this list is refused' "config: unknown key refused"
has "$SEC" 'A value other than the one shown for its key is refused' "config: other value refused"
has "$SEC" 'a pair outside this list is allowed only when a `trace suggest` run in the project now returns a `kind: suggest` entry' "config: priced pair needs a live trace suggest"
has "$SEC" 'whose `action` equals the pair'"'"'s key and whose `proposed` equals the pair'"'"'s value' "config: priced pair matches action and proposed"
has "$SEC" 'When no such entry exists, refuse the whole line with a reason that names the pair' "config: unpriced pair refused with a reason"
has "$SEC" 'never `route.mjs`' "config: priced check never runs route.mjs"
has "$SEC" 'any token starts with `--`' "config: any -- token refused"
has "$SEC" '`--global`' "config: --global named"
has "$SEC" 'Refuse the whole line, with a reason that names the bad pair' "config: one bad pair refuses the whole line"
has "$SEC" 'pair list is empty' "config: empty pair list refused"
has "$SEC" '`.planning/PROJECT.md`' "decision-review path: PROJECT.md"
has "$SEC" '`.planning/phases/<phase-text>/CONTEXT.md`' "decision-review path: phase CONTEXT.md"
has "$SEC" '`cad-<stage>-p<N>` for a line with a phase, and `cad-<stage>` for a line without one' "label forms with and without phase"
has "$SEC" 'the bare skill, no argument' "audit health suggest are sent bare"
has "$SEC" '`cad-decision-review`: `<skill> <arg>`. Never send it the phase' "decision-review send: skill and arg, never the phase"
has "$SEC" '`cad-coverage` and `cad-minimalism-review` chips: `<skill> <N>`' "coverage and minimalism-review send the phase"
has "$SEC" 'DISPATCH_MODEL' "spawn takes the line's model"
has "$SEC" 'DISPATCH_EFFORT' "spawn takes the line's effort"
has "$SEC" 'A chip line carries no reason' "no chip line carries a reason"
has "$SEC" 'never in a shell command' "arg reaches the worker only as SendMessage text"

# Phase 3: cad-land goes to the live milestone worker
has "$SEC" 'the live `cad-milestone-p<N>` worker' "cad-land goes to the live milestone worker"
has "$SEC" 'refuse with a reason' "cad-land with no live worker is refused with a reason"
has "$SEC" '`cad-land` takes `phase` and no `arg`' "cad-land field rule"
has "$SEC" 'A cad-land line carries no reason' "cad-land line carries no reason"

echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
