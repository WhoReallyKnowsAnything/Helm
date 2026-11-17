import Testing
@testable import OrchestratorGUI

private let phase1Context = #"""
# Phase 1: Workflow board - Context

Gathered: 2026-11-10
Feeds: /cad-plan 1

## Scope boundary

In: A workflow board panel per project that shows the Cadence milestone, every phase and each phase's stage (context, planned, executing, verify, done) from `planning.mjs status`; a next-step button that asks the project's orchestrator to dispatch the right `/cadence:cad-*` stage worker with its session model and effort; hard gates G1, G2 and G4 with an override that carries a reason to the worker; a running overlay that shows a live or finished-but-unmerged stage worker; and a prompt-only change in the orchestrator repo (`orchestrator`, `task-drafting-mode.md`) so the orchestrator accepts the board's dispatch line.
Out: Health strip, suggested-skill chips and config check (phase 2). Context, plan review and UAT screens (phases 3-5). Gate G3 on the merge button (phase 5). Any write to `.planning/` or to Cadence config by the app. Tuning Cadence subagent roles (stays with Cadence, `/cad-suggest`, phase 2 chip). Turning `workflow.plan_check` on (the user does that with `/cadence:cad-config`).
Deferred: None.
Plan shape: multiple plans - planning splits phase 1 into at least 3 plans: (1) board data, stage mapping and gates; (2) the dispatch line plus the orchestrator prompt change; (3) the running overlay with process liveness and Clear.

## Durable decisions

- D-04 (Running overlay and labels): The orchestrator names each stage worker with a fixed label `cad-<stage>-p<N>`. The board shows "context running", "plan running" or "executing" while that worker is live, and "waiting for merge" when it is done but not merged. The next-step button is off in both states. Liveness comes from the worker process, not from the orchestrator state row (on 2026-11-09 a worker died overnight while the state still said running). The board offers Clear for a dead stage worker (the equivalent of `dispatch-task.sh --kill <label>`) and then turns the button on again. A dispatch whose label is already held is refused with a clear reason and an offer to clear the old worker first; it never fails silently and never starts a second worker. `<N>` is the phase's exact text with the dot turned into a hyphen (`1.1` -> `cad-execute-p1-1`, `3` -> `cad-execute-p3`), taken exactly as `planning.mjs status` sends it (Cadence's canonical text), never re-formatted from a decoded floating-point value (Swift prints a decoded 3 as `3.0`). `status` sends `n` as a JSON number, so 1.10 arrives as 1.1; Cadence treats them as one phase and refuses the "1.10" spelling, so the app never sees both. Evidence: `cadence-core/bin/planning/status.mjs:227` (`n: p.n`), live run 2026-11-10 on a test roadmap with phases 1.1 and 1.10 returned `"n":1.1` for both, `cadence-core/bin/planning/core.mjs:44-56` (Cadence's own phase spelling rules), `Sources/OrchestratorGUI/MergeReview.swift:94-98` (`kill` already runs `dispatch-task.sh --kill <label>`), `Sources/OrchestratorGUI/GateHoldReader.swift:43-46` (process liveness by pid plus start time), `Sources/OrchestratorGUI/ProjectSession.swift:79` (`liveWindows`).
- D-07 (Dispatch line): The board sends one literal-prefix line through `InboxDelivery.deliver`, and the orchestrator recognises the prefix through a prompt-only change in the orchestrator repo (`task-drafting-mode.md`). The orchestrator then spawns the worker with skill, phase, model, effort and override reason, with no drafting round. The fixed fields come first; the free-text override reason comes last, after a reason marker. The orchestrator parses the fixed fields by order and pattern, and treats everything after the reason marker as opaque text that it never parses as fields (a reason that contains `phase=2` does not become a field). The line has a 2000-character cap and is refused over the cap, never cut. The override reason is untrusted text: newlines are flattened, it never reaches a shell command or argument (only native tool arguments such as SendMessage text and the `/cad-capture` message), and the app stores it nowhere. Evidence: `Sources/OrchestratorGUI/InboxDelivery.swift:7-8` (caps 200 and 2000), `:11-22` (`clean` flattens newline, CR and tab, strips control scalars), `:48` (refuses empty or control characters), `:55-56` (line carried as a JSON string), `Sources/OrchestratorGUI/DispatchModel.swift:36,46-48` (2000 cap, `refusesOverCap`), `:40` (`submit` is private, so a new entry point is needed), orchestrator `task-drafting-mode.md:116` (existing "App pick-up" prefix pattern).
- D-08 (Skill allowlist): The app builds the skill from a fixed table, stage -> `/cadence:cad-<stage> <N>` for context, plan, execute, verify and milestone, with the phase from the status JSON. No text from STATE.md goes into the line; the board may show `cursor.next` beside the button as a hint. The orchestrator checks the line against the same fixed allowlist and accepts the phase only if it matches `^[0-9]+(\.[0-9]+)?$`. Anything else is refused with a reason and not dispatched. Evidence: live `planning.mjs status` on 2026-11-10 returned `cursor.next` `/cad-context 1` (short form, written by workers into STATE.md); the skill list uses `/cadence:cad-*`. AMENDMENT (user-approved 2026-11-10): milestone is the one exception to `/cadence:cad-<stage> <N>`. `cad-milestone`'s argument-hint is `[version | next-milestone name]` (cadence 4.0.0 skills/cad-milestone/SKILL.md:4), so a phase number would be read as a version. The dispatch line keeps `phase=<N>` for the label only, and the orchestrator sends the worker a bare `/cadence:cad-milestone`. `<stage>` in the label is the full text after `/cadence:cad-`.
- D-12 (Routing, two layers): The stage session model is separate from the Cadence subagent roles. Context and milestone stage sessions run opus with effort high. Plan, execute and verify stage sessions name no model, so `dispatch-task.sh` applies its default `sonnet[1m]`. The session-model table lives in the app's own settings, not in `.planning/` and not in Cadence config. The board shows both layers: the stage session model and effort, and beneath it the Cadence subagent roles for that stage, read-only. Role retuning stays with Cadence. The app never calls `route.mjs resolve`, because it appends to `trace.jsonl`. Evidence: orchestrator `orchestration/lib/dispatch-task.sh` (`${DISPATCH_MODEL:-sonnet[1m]}` about line 818; `_build_launch_cmd` about line 34 adds `--effort` whenever effort is non-empty, independent of model), orchestrator `test/test-headless-dispatch.sh:133-134`, orchestrator `task-drafting-mode.md:19` (opus effort at most high), `Sources/OrchestratorGUI/AppSettingsView.swift:9,25` (`@AppStorage` settings pattern).

## Decisions

- D-01 (Locating Cadence): The board runs `node <installPath>/cadence-core/bin/planning.mjs status` with cwd set to the project. `installPath` comes from `plugins["cadence@cadence"]` in `~/.claude/plugins/installed_plugins.json` and is re-read on each refresh, never a hard-coded versioned cache path. `node` is found through a fixed search list (for example `/opt/homebrew/bin`, `/usr/local/bin`), because a Finder launch has no shell PATH. A missing node, plugin entry or `planning.mjs` shows a reason on the board. Evidence: `~/.claude/plugins/installed_plugins.json` (one user-scope entry, installPath ends in `4.0.0`), `Sources/OrchestratorGUI/OrchestratorPaths.swift` (`searchPath`, `tmuxPath()`, no node lookup today); only `/opt/homebrew/bin/node` exists on this machine (checked 2026-11-10).
- D-02 (Milestone name): `planning.mjs status` has no milestone field. The board reads the "Milestone vN: name" line from the ROADMAP.md Overview, with "Phase n of total" as the fallback. `cycle: none` shows "no open milestone". Evidence: `cadence-core/bin/planning/status.mjs:220-237`, `.planning/ROADMAP.md:5`.
- D-03 (Stage mapping): context = status `unplanned` and no `phases/<n>/CONTEXT.md`; planned = `unplanned` with CONTEXT.md (or `workflow.skip_discuss` on), or status `planned`; verify = `executed`; done = `complete`. "Executing" and the other running states come from the D-04 overlay, not from Cadence status. Evidence: `cadence-core/bin/planning/core.mjs:100-116` (`derivePhases`, 4 values), `cadence-core/bin/planning/status.mjs:87-91` (no executing value), `:226-234` (per-phase output fields), `cadence-core/bin/planning/criteria-coverage.mjs:63` (CONTEXT.md path).
- D-05 (Next legal stage): The app computes the next legal stage itself, from `current` (the first phase that is not complete) and the D-03 stage plus the gates. `cursor.next` is shown only as a hint. Evidence: `cadence-core/bin/planning/status.mjs:119-120`, `:168` ("the cursor is a hint, the derivation wins").
- D-06 (Refresh): An FSEvents watch on the project's `.planning/` (a new `ProjectWatcher` filter), coalesced the way `WorkerStore` coalesces reads, refreshes the board. It ignores `trace.jsonl` and `reads.jsonl` (Cadence appends to them on every tool call), and it also catches a `.planning/` folder created after the board opened. No polling timer. The board reads the project folder only, so a stage advances after its worker merges (the D-04 "waiting for merge" state covers the gap). Evidence: `Sources/OrchestratorGUI/ProjectWatcher.swift:6-7,13-29,45-48,72-97`, `Sources/OrchestratorGUI/WorkerStore.swift:21-23,51-60`, `cadence-core/bin/lib/trace.mjs:2,17`, `cadence-core/bin/lib/read-trace.mjs:2`.
- D-09 (Orchestrator liveness): The button is off, with a reason, when the project has no live orchestrator window. The board checks `ProjectSession.liveWindows` on each refresh, not only on press. Evidence: `Sources/OrchestratorGUI/InboxDelivery.swift:36-46` (`.failed("No orchestrator window to send to ...")` today only at deliver time), `Sources/OrchestratorGUI/ProjectSession.swift:79-92`.
- D-10 (Gates): G1 = `phases/<n>/CONTEXT.md` is present, waived when `workflow.skip_discuss` is on. G2 = a PLAN exists (derived status is not `unplanned`); Cadence runs the plan check inside the plan worker (`plan.md` check gate), the app never sends `--skip-check`, and the board shows "plan check: on/off". G4 = `planning.mjs audit` returns `counts.broken == 0`, milestone-wide. A blocked gate shows its reason and has an override that asks for a reason; the reason travels in the D-07 line for the worker's `/cad-capture`. Gates cover the app's buttons only; a typed command still runs. Evidence: `cadence-core/bin/planning/core.mjs:112`, `cadence-core/bin/planning/audit.mjs:96,137-141` (live run 2026-11-10: `{"total":12,"traced":0,"broken":12,"deferred":0}`), `.planning/config.json` (`workflow.skip_discuss: false`, `workflow.plan_check: false`).
- D-11 (Read-only on Cadence): The app reads config only through one batched `config.mjs get` call (`{ok, values, source, warnings?}`; warnings are ignored; one unknown key fails the whole call). The app writes no `.planning/` file and no Cadence config. `workflow.plan_check` on is the intended setting; the user turns it on with `/cadence:cad-config`, not this phase. Evidence: `cadence-core/bin/config.mjs:238-266`, live batched get on 2026-11-10.
- D-13 (Roles per stage): The board shows these Cadence roles per stage: context -> `cad-assumptions-analyzer`; plan -> `cad-planner` and `cad-plan-checker`; execute -> `cad-executor`; verify -> `cad-verifier`; milestone -> no subagent role row. Values come from `roles.<agent>.model` and `roles.<agent>.effort` through `config.mjs get`. Evidence: live `route.mjs resolve --role cad-assumptions-analyzer` on 2026-11-10 (`roles.cad-assumptions-analyzer.model` sonnet, effort xhigh), live `config.mjs get roles.cad-planner.*`.
- D-14 (Placement): The board is a panel at the top of the project's tree screen, above the worker tree and the dispatch bar. The phase 3-5 screens become new `Screen` cases that open from this panel. A project with no `.planning/` (or a status failure such as `no-roadmap` or `unparseable-roadmap`) shows the failure reason and no button. Evidence: `Sources/OrchestratorGUI/NavigationState.swift:6-12,72`, `Sources/OrchestratorGUI/ContentView.swift:345-367`, `cadence-core/bin/planning/status.mjs:94-113`.

## Acceptance criteria

- [ ] AC1: For a Cadence project, the board shows the milestone name, every phase and each phase's stage, and each stage equals the D-03 mapping of `planning.mjs status` run in that project. When `installPath` in `installed_plugins.json` points at another valid Cadence install, the next refresh runs that install's `planning.mjs`, with no app rebuild.
- [ ] AC2: A new or changed file under the project's `.planning/` updates the board within 5 seconds. An append to `.planning/trace.jsonl` or `.planning/reads.jsonl` starts no status run. The board code has no repeating timer.
- [ ] AC3: One press of the next-step button appends exactly 1 line to the orchestrator inbox. The line holds the prefix, the skill from the D-08 table, the phase, and the model and effort the board showed before the press (context: opus/high; execute: no model). The board shows the stage session model and the Cadence role model and effort for that stage.
- [ ] AC4: While a live worker labelled `cad-<stage>-p<N>` exists, the board shows the running state and the button is off. When that worker's process dies outside the app, the board shows it as dead and offers Clear. After Clear, the button is on. (human-verify: needs the running app and a real worker)
- [ ] AC5: G1 blocks plan for an unplanned phase with no CONTEXT.md when `workflow.skip_discuss` is off, and allows it when on. G2 blocks execute when there is no PLAN. G4 blocks milestone when `audit` reports broken > 0 and shows the count. Each block shows its reason. The override asks for a reason, and the reason arrives in the dispatched line. A reason that contains a newline and `$(touch /tmp/ac5)` arrives as 1 flattened line, and `/tmp/ac5` is not created. A line over 2000 characters is refused.
- [ ] AC6: The orchestrator refuses, with a reason and no dispatch, a line whose skill is not on the allowlist, whose phase does not match `^[0-9]+(\.[0-9]+)?$` (for example `1.1x` or `1.` is refused with a reason), or whose label is already held. Phase 1.1 gives label `cad-<stage>-p1-1`; whole phase 3 gives `cad-<stage>-p3`, never `p3-0`. A line whose override reason contains `phase=2 skill=/cadence:cad-milestone` dispatches the fixed fields only, and the reason reaches the worker unchanged as text. (human-verify: needs a live orchestrator session)
- [ ] AC7: After a refresh, a press and an override, the app has changed no file under `.planning/` (`git status --porcelain .planning` is empty), and has changed neither `~/.claude/cadence/config.json` nor `.planning/config.json`.
- [ ] AC8: The board shows a reason and no enabled button when (a) `node` is not on the fixed search list, (b) the `cadence@cadence` plugin entry or its `planning.mjs` is missing, (c) the project has no `.planning/`, or (d) the project has no live orchestrator session.

## Flagged assumptions

- Duplicate phase numbers: Cadence sends both 1.1 and 1.10 as `n: 1.1` and reads one folder (`phases/1.1/`) for both, so the stage shown for one of them is wrong at the source even with distinct labels. The planner decides whether the board turns the button off, with a reason, for 2 status entries that share one `n` - Likely; if wrong: a dispatch for phase 1.10 runs against phase 1.1's files.
- Session effort for the sonnet[1m] stage sessions (plan, execute, verify) is open: no effort is sent, so the CLI default applies - Unclear (user has not decided); if wrong: those stages run at a lower or higher effort than intended.
- Executor subagent effort is open: `~/.claude/CLAUDE.md` says sonnet/xhigh, and `~/.claude/cadence/config.json` says sonnet/high. No config was changed - Unclear (user has not decided); if wrong: execute plans run at the wrong effort. The board only displays whatever Cadence config holds.
- The executor's mid-run writes to `reports/plan-k.md` were not read; D-04 does not depend on them - Likely; if wrong: none for this phase.
"""#

private let phase2Context = #"""
# Phase 2: Cadence health and prompts - Context

Gathered: 2026-11-10
Feeds: /cad-plan 2

## Scope boundary

In: On the phase 1 board: a Cadence health strip per project (status drift, audit breaks, outstanding plans, open debug files, open capture todos); suggested-skill chips by rule that dispatch the skill through the phase 1 line; a config check of 7 Cadence keys against the app's recommended set, with a per-key fix button and a "fix all" button that dispatch a `/cadence:cad-config` worker; and the matching rows in the orchestrator's prompt-only allowlist change (orchestrator repo, `task-drafting-mode.md`).
Out: Any write by the app to `.planning/` or to Cadence config. Repairing drift (the health chip reports only). A separate map chip (D-06). Changing `~/.claude/cadence/config.json` from the board (D-09). Context, plan review and UAT screens (phases 3-5).
Deferred: None.
Plan shape: multiple plans - planning splits phase 2 into at least 2 plans: (1) the health strip and config-check reads; (2) the chips plus the dispatch table extension and the orchestrator prompt change.

## Durable decisions

- D-05 (Chip dispatch): Chip rows extend the phase 1 D-08 fixed skill table, all text built by the app: `/cadence:cad-audit`, `/cadence:cad-health`, `/cadence:cad-suggest`, `/cadence:cad-coverage <N>`, `/cadence:cad-minimalism-review <N>`, `/cadence:cad-decision-review <path>` with the path from a fixed list (`.planning/PROJECT.md` or `.planning/phases/<N>/CONTEXT.md`), and `/cadence:cad-config <key>=<value> ...` with keys and values from the D-07 table. The orchestrator allowlist gets the same rows. Labels are `cad-<skill>-p<N>` for a chip with a phase and `cad-<skill>` for one without; the phase 1 D-04 held-label refusal applies. One "utility" row in the app's session table (sonnet, no effort named) covers every chip and the config fix; the board shows the inner Cadence role beside it where one exists. Evidence: `.planning/phases/1/CONTEXT.md` D-04, D-07, D-08, D-12; `argument-hint` lines in `skills/cad-{audit,health,suggest,coverage,minimalism-review,decision-review,config}/SKILL.md` of the Cadence 4.0.0 plugin; `cadence-core/workflows/map.md:48` (only map names a role, `cad-mapper`); `cadence-core/workflows/minimalism-review.md:80-84` and `decision-review.md:58-59` (base `cad-reviewer` at the session default).
- D-09 (Orchestrator validation of chip lines): The orchestrator refuses, with a reason and no dispatch: a config line that carries `--global` or any flag that writes `~/.claude/cadence/config.json`; a config key not in the D-07 table; a value not allowed for that key; a decision-review path other than exactly `.planning/PROJECT.md` or `.planning/phases/<phase-rule>/CONTEXT.md` (phase rule from phase 1 D-08); and any skill not on the allowlist. A multi-pair config line is checked pair by pair and refused whole if any pair fails. Evidence: `skills/cad-config/SKILL.md:4` (`--roles [--global]`), user safety requirements given 2026-11-10.

## Decisions

- D-01 (Health values): The strip shows 5 values, each taken literally from its source: drift = number of entries in the `planning.mjs status` `drift` list (0 when the key is absent); outstanding plans = total plans across status `outstanding`; audit = D-02; open debug files = `.planning/debug/*.md` files whose `Status:` line is not `resolved` (a missing line counts as open, Cadence's own rule); open capture todos = the Todos `bullets` count from `planning.mjs capture-sections`. There is no health JSON command; `cad-health` is a prose checklist. Evidence: `cadence-core/bin/planning/status.mjs:122-200,213-223,236`; `cadence-core/workflows/debug.md:14,34-35`; `cadence-core/bin/planning/capture-check.mjs:36-60`; `skills/cad-health/SKILL.md:22-110`; `cadence-core/bin/planning.mjs:36-128` (no health command).
- D-02 (Audit display): The strip shows the literal audit value, `counts.broken/counts.total` with the break kinds beside it, in the warning colour whenever broken > 0. No stage-based or kind-based suppression. Evidence: `cadence-core/bin/planning/audit.mjs:96,137-141`; live run 2026-11-10: 12 of 12 broken, all `no-plan`.
- D-03 (Read-only refresh): A refresh runs only read-only commands: `planning.mjs status`, `audit`, `capture-sections`, `trace suggest`, and `config.mjs get`. The app never runs `route.mjs resolve`, `trace append`, `trace close`, or `trace ignore` without `--check`. The phase 1 D-06 watch drives the refresh, so the suggest chip updates on other `.planning/` events (D-06 ignores `trace.jsonl`). Evidence: live runs 2026-11-10 left the md5 of `.planning/trace.jsonl` and `git status` unchanged; `cadence-core/bin/route.mjs:468-476,807-811` (resolve appends trace events); `skills/cad-health/SKILL.md:35-41`.
- D-04 (Chip rules): Each chip shows the rule that raised it; app-made rules are labelled "board rule". Minimalism-review and coverage: for a phase while its stage is verify (derived `executed`). Suggest: when `planning.mjs trace suggest` returns an entry of kind `suggest` (`info` entries do not count; Cadence has no phase counter, so this replaces "every few phases"). Health: when status drift is non-empty; it reports and does not repair. Audit: when every phase is complete, before milestone. Decision-review: for a phase in the planned stage whose CONTEXT.md has 1 or more durable decisions; it stays until the phase leaves the planned stage, because `/cad-decision-review` writes no file or mark. Evidence: `cadence-core/workflows/milestone.md:19,281` (only audit and suggest are encoded by Cadence, inside the milestone worker); `cadence-core/bin/lib/trace-suggest.mjs:4-10,299-372`; `cadence-core/workflows/decision-review.md:54,190,221` (trace append only, "No file was edited").
- D-06 (No map chip): While `planning.code_map` is off, the code_map fix button is the map nudge; `/cad-map` exits at once with that key off. Evidence: `cadence-core/workflows/map.md:8-11`.
- D-07 (Recommended set): The config check compares 7 leaf keys with the app's recommended table: `workflow.plan_check` true, `workflow.verifier` true, `planning.code_map` true, `review.triggers.plan.gate` advisory, `review.triggers.diff.gate` off, `review.triggers.risk_surface.gate` blocking, `review.triggers.phase_diff.gate` off. Cadence ships no recommended profile, so the table is the app's; it is also the allowlist for the config line. One batched `config.mjs get` reads leaf keys only (a group key such as `review.triggers` fails with `unknown-key`). The board also shows `config.mjs` `warnings`. Evidence: live `config.mjs keys` and `get` 2026-11-10 (plan_check false, verifier true, code_map false, gates advisory/off/blocking/off); `cadence-core/bin/config.mjs:241-251`; `cadence-core/references/review-triggers.md:19-50`.
- D-08 (Fix button): A fix press dispatches a worker that runs `/cadence:cad-config <key>=<recommended value>`. It writes the project's `.planning/config.json` only (no `--global`). The new value shows on the board after that worker merges; the phase 1 "waiting for merge" state covers the gap. Evidence: `skills/cad-config/SKILL.md:4,36`; `cadence-core/workflows/config.md:177-190` (Direct set through `config.mjs set`).
- D-10 (Read-only on Cadence): The app writes no `.planning/` file and no Cadence config.
- D-11 (Fix all): `/cadence:cad-config` accepts several `<key>=<value>` pairs in one call and writes them atomically (nothing is written unless every pair is valid). So the config check has a "fix all" button that sends every flagged key in 1 line, 1 worker and 1 merge. The orchestrator validates each pair under D-09. Evidence: `cadence-core/workflows/config.md:31-32` (a value runs to the next `<key>=` token), `:183-190` (`config.mjs set <key=value>...`, atomic).

## Acceptance criteria

- [ ] AC1: The strip's 5 values each equal their D-01 source run at the same moment. The audit value shows broken/total and the break kinds, in the warning colour when broken > 0.
- [ ] AC2: After 10 board refreshes, the md5 of `.planning/trace.jsonl` and the output of `git status` are unchanged.
- [ ] AC3: Each chip shows its rule. Minimalism-review and coverage show for a phase only while it is in verify. Suggest shows only when `trace suggest` has a `suggest` entry. Health shows only when drift is non-empty. Decision-review shows for a planned phase with 1 or more durable decisions, and is still shown after a decision-review run, until the phase leaves planned.
- [ ] AC4: One chip press appends exactly 1 line with the skill from the fixed chip table, the label `cad-<skill>-p<N>` or `cad-<skill>`, and the utility model (sonnet, no effort). The board shows the inner Cadence role where one exists.
- [ ] AC5: The config check lists the 7 keys with the current value and the recommended value. On this repo today (`workflow.plan_check` is now true, `.planning/config.json:11`) it flags `planning.code_map` and shows the retired-key warning; the two-flagged case is covered by fixtures. A fix press dispatches `/cadence:cad-config <key>=<recommended value>`.
- [ ] AC6: The orchestrator refuses each D-09 case (for example `/cadence:cad-config --global workflow.plan_check=true`, `workflow.foo=true`, `workflow.verifier=maybe`, decision-review `../x.md`) with a reason and no dispatch. (human-verify: needs a live orchestrator session)
- [ ] AC7: After refreshes, chip presses and a config fix press, the app has changed no file under `.planning/` and has not changed `~/.claude/cadence/config.json`.
- [ ] AC8: With 2 keys flagged, one "fix all" press appends exactly 1 line `/cadence:cad-config <key1>=<value1> <key2>=<value2>`. A fix-all line with one invalid pair is refused whole by the orchestrator. (orchestrator part: human-verify: needs a live orchestrator session)

## Flagged assumptions

- Open capture todos use the `bullets` count from `capture-sections`; how it differs from `capture-check` `substantive` was not read (`lib/capture-health.mjs`) - Likely; if wrong: the strip's todo number differs from `/cad-health`.
- Open item (b), executor subagent effort, is still open: `~/.claude/CLAUDE.md` says sonnet/xhigh; the user-global `~/.claude/cadence/config.json` `roles.cad-executor` says sonnet/high and is the value in force. This repo's `.planning/config.json` also holds `model.effort.cad-executor: "high"`, a project-level executor override in the old key form, retired in Cadence 4.0.0 and ignored (routing reads only `roles.<agent>.effort`). The project has no `roles` block. No config was changed - Unclear (user has not decided); if wrong: execute plans run at the wrong effort.
- Open item (a), the effort for the sonnet[1m] stage sessions, is still open (no effort sent, CLI default) - Unclear (user has not decided).
- The orchestrator side (spawning a worker with a phase-less label, multi-pair config lines) was not read in the orchestrator repo - Likely; if wrong: the prompt change needs more than allowlist rows.
"""#

private let phase3Context = #"""
# Phase 3: Context screen - Context

Gathered: 2026-11-10
Feeds: /cad-plan 3

## Scope boundary

In: A context screen (a new `Screen` case opened from the phase 1 board) that shows a context-stage phase's question cards from its `cad-context-p<N>` worker and the locked decisions that constrain it; picks go back to the worker's AskUserQuestion through the v2 answer path, and Cadence writes CONTEXT.md. A shared file-open helper (FILE-01) for the phase 3, 4 and 5 screens. In the orchestrator repo (`orchestrator`): a change to `orchestration/hooks/permission-hold.sh` and the worker prompt that lifts the AskUserQuestion deny for stage workers whose questions have an app screen (phase 3: `cad-context-p<N>` only). This is not prompt-only: it edits a hook script.
Out: A code viewer or editor in the app. Plan review and UAT screens (phases 4 and 5) and their labels' allow entries. Any timer that answers or denies a question. Lifting the ExitPlanMode deny. Any app write to `.planning/`.
Deferred: None.
Plan shape: multiple plans - planning splits phase 3 into at least 3 plans: (1) the screen with question cards and decisions; (2) the FILE-01 helper; (3) the orchestrator hook and prompt change.

## Durable decisions

- D-01 (Question channel): The orchestrator lifts the AskUserQuestion deny for "stage workers whose questions have an app screen". Phase 3 enables `cad-context-p<N>`; phase 4 adds `cad-plan-p<N>`; phase 5 adds `cad-verify-p<N>`. Every other worker is still denied at once, and ExitPlanMode stays denied for all workers. The change edits `orchestration/hooks/permission-hold.sh` and the worker prompt (`orchestration/prompts/worker-dependency-awareness.md`), so it is not prompt-only. Cadence asks its normal structured questions; the screen shows them as native cards; picks go back through the v2 answer path. Origin of the deny: orchestrator commit 7a894b1 (2026-10-25, "deny AskUserQuestion and ExitPlanMode for live workers"), implementing orchestrator phase 2 decision D-04, written when a worker's question showed only on a terminal pane that nobody watched and the only answer path was pane keystrokes. The native cards remove that reason while the app shows them; D-02 and D-03 cover the rest. Evidence: `permission-hold.sh:101-109`; orchestrator `.planning/ARCHIVE.md:127`; `worker-dependency-awareness.md:17`; `Sources/OrchestratorGUI/RequestSessions.swift:16-17`, `RequestStore.swift:172-177,273`, `ControlAnswerWriter.swift:29-39`, `QuestionCards.swift:83`; `.planning/_archive-v2/4/CONTEXT.md` D-03 and AC4 (AskUserQuestion cards work for orchestrator sessions).
- D-01 amendment (user-approved 2026-11-10): the registered wrapper `~/.claude/hooks/permission-hold-wrapper.sh` turns an empty hook output for a live worker into a deny ("returned no decision"), so "the hook gives no output" does not lift the deny; flagged assumption 1 was wrong about the wrapper. The wrapper stays untouched and keeps its fail-closed rule. Instead `permission-hold.sh` prints an explicit decision for an allowed stage worker (`cad-context-p<N>` in phase 3): that decision is "ask", never "allow". Second amendment (2026-11-10, after the Claude Code hooks reference, "PreToolUse decision control" and "Tools that require user interaction": AskUserQuestion and ExitPlanMode need updatedInput paired with "allow", "allow" alone is not sufficient, and with "allow" the tool runs without prompting): "allow" is removed from the plan because a bare "allow" would run AskUserQuestion with no human answer; "ask" is primary, expected (an inference, not yet verified) to send the request on to the session's stdio permission prompt, the existing v2 card path. The hook never prints "allow" for AskUserQuestion for any label. Plan order: (1) the first orchestrator task is a test that settles whether an AskUserQuestion from `cad-context-p<N>` with the explicit decision still reaches the app as a question card and the pick returns to the worker (human-verify where it needs the live app); (2) conditional fallback, only if that test shows no card: change the wrapper in the orchestrator worktree, with its doc fence and `test/test-hook-wrapper.sh`; the deployed copy in `~/.claude/hooks` is NOT edited during execute and is recorded as a separate post-merge step the user approves, because that directory is live for every session; (3) every other worker's AskUserQuestion is still denied at once, and ExitPlanMode is denied for all workers. No 4th plan unless the fallback is needed; the fallback is described in the existing orchestrator-repo plan.
- D-05 (Worktree read exception): A narrow read-only exception to phase 1 D-06 ("the board reads the project folder only"): the context screen reads only `.planning/phases/<N>/CONTEXT.md` from the `cad-context-p<N>` worker's worktree while that worktree exists (running or waiting for merge), nothing else in that worktree, and falls back to the project folder when the worktree is gone. Evidence: `Sources/OrchestratorGUI/WorkerDatabase.swift:11` (`worktreePath`), `.planning/phases/1/CONTEXT.md` D-06.
- D-09 (File-open rule, FILE-01): Files with an extension on the code list open in VS Code by app name, never through the file's own default handler: .swift .ts .tsx .js .jsx .py .rb .go .rs .java .kt .c .h .m .cpp .cs .sh .bash .zsh .command .tool .json .yml .yaml .toml .xml .plist .md .txt .log .csv .html .css .sql (the planner may add other plain source types). Scripts are on the list on purpose, so they open as text and never in Terminal. Every other allowed file opens in its default app (for example .png, .jpg, .pdf in Preview). Refused with a reason: folders, bundles and packages (.app and any package directory); .terminal .workflow .action .pkg .mpkg .jar .webloc .inetloc .url .fileloc .dmg .mobileconfig; any file not on the code list that has the executable bit set; URL schemes; control characters. When VS Code is not installed, code-list files open in the default plain-text editor, never in their own handler. Opening goes through NSWorkspace with the app's location, never a shell string. Evidence: `Sources/OrchestratorGUI/TranscriptText.swift:57-59,616-620` (no file links today), `WorkerActionsView.swift:143` and `WorkerTreeView.swift:208` (only NSWorkspace uses), `PullRequest.swift:86-91` and `DroppedFiles.swift:23-25` (allowlist patterns).

## Decisions

- D-02 (Unanswered question): No deadline. The worker waits for the answer; the card comes back after an app restart, because pending cards come from the worker's out-log; the board shows the context stage as "question waiting"; the way out is the phase 1 Clear button. No timer decides for the user. Evidence: `Sources/OrchestratorGUI/RequestStore.swift:71` (`store.$pending` from the control log).
- D-03 (Dead worker card): The phase 1 liveness check applies to question cards. A card whose worker is not alive shows "worker ended", offers Clear and accepts no answer (a worker died overnight on 2026-11-09 while its state still said running). Evidence: `.planning/phases/1/CONTEXT.md` D-04.
- D-04 (Decisions shown): During the run, the screen shows the decisions of the 3 most recent earlier phases (the same CONTEXT.md files Cadence reads), from the project folder, labelled by phase ("Phase 1 D-05"), beside this phase's question cards (answered and waiting). `cad-context` writes CONTEXT.md only at its last step, so the phase under discussion has no D-NN during the run. After the worker writes it, the screen shows this phase's D-NN from the worktree marked "not merged yet" (D-05), then from the project folder after the merge. Evidence: Cadence `cadence-core/workflows/context.md:63,382,451`.
- D-06 (Screen entry): The screen opens from the board for a phase in the context stage in every state: before dispatch, context running, question waiting and waiting for merge. Answer controls show only on a pending card of a live worker. Evidence: `.planning/phases/1/CONTEXT.md` D-03, D-04, D-14; `Sources/OrchestratorGUI/NavigationState.swift:6-12`.
- D-07 (Worker lookup): The screen finds the worker by its label `cad-context-p<N>`, which is the worker row's `agentId`. Evidence: `Sources/OrchestratorGUI/ContentView.swift:409`, `RequestSessions.swift:16-17`.
- D-08 (D-NN parsing): Decision lines are read in the template's shape `- D-NN (area): ...` from both the "Durable decisions" and "Decisions" sections, keyed by phase, because D-NN numbers restart in each phase (phases 1 and 2 both have a D-05). Evidence: Cadence `cadence-core/templates/CONTEXT.md`; `.planning/phases/1/CONTEXT.md`, `.planning/phases/2/CONTEXT.md`.
- D-10 (Path checks): An openable path is an existing regular file whose real path (after symlinks) is inside the project folder or the stage worker's worktree. A relative path resolves in the worktree while it exists, else in the project folder, and the screen shows which one opened. One shared helper serves the phase 3, 4 and 5 screens. Evidence: `Sources/OrchestratorGUI/DroppedFiles.swift:23-25`.
- D-11 (Read-only): The app writes no `.planning/` file.

## Acceptance criteria

- [ ] AC1: The screen opens from the board for a context-stage phase and shows the 3 most recent earlier phases' D-NN, labelled by phase. After the worker writes this phase's CONTEXT.md, its D-NN show marked "not merged yet"; after the merge they show from the project folder.
- [ ] AC2: A `cad-context-p<N>` worker's AskUserQuestion shows on the screen as a card with its options; a pick reaches the worker, and the merged CONTEXT.md holds that answer as a decision. (human-verify: needs a live worker)
- [ ] AC3: In the orchestrator repo's hook test, AskUserQuestion from `cad-context-p<N>` is not denied; from any other worker label (for example `cad-execute-p1` or a normal task worker) it is denied at once; ExitPlanMode from `cad-context-p<N>` is denied.
- [ ] AC4: After the app quits and reopens, an unanswered card shows again and the board shows "question waiting". No answer is sent by any timer.
- [ ] AC5: With a `cad-context` worker killed while its question is pending, the reopened app shows the card as "worker ended", offers Clear, and shows no answer controls.
- [ ] AC6: A `.sh` or `.command` click opens VS Code and runs nothing; a `.png` opens in its default app; a `.app`, a folder, an extensionless executable file, a `.webloc` file and a path outside the project and worktree are each refused with a reason; with VS Code absent, a `.swift` opens in the default plain-text editor.
- [ ] AC7: A relative path opens the worktree copy while the worktree exists and the project copy after it is gone, and the screen shows which.
- [ ] AC8: After the screen is used, the app has changed no file under `.planning/`.

## Flagged assumptions

- A lifted AskUserQuestion reaches the session's stdio permission prompt (the app card) once the hook gives no output, and that prompt has no deadline - Likely; if wrong: the worker gets a timeout or deny instead of waiting, and D-02 needs a different mechanism. [Amended 2026-11-10: wrong about the wrapper, which denies an empty output; see D-01 amendment. The hook now prints an explicit decision instead.]
- Pending cards are rebuilt from the out-log on app launch - Likely (`RequestStore.swift:71`); if wrong: AC4 fails and the planner must add a rebuild.
- `NSWorkspace` opening by app location does not hand a `.command` or `.sh` file to Terminal when VS Code is the target - Likely; if wrong: AC6's "runs nothing" fails.
- Phase 1 is not built yet (no board, no `cad-<stage>-p<N>` labels); this phase depends on it - Confident.
"""#

@Suite struct ContextDecisionsTests {
    private func labels(_ d: [ContextDecision]) -> [String] { d.map(\.label) }

    @Test func phase1HasFourteenInFileOrder() {
        let d = ContextDecisions.parse(phase1Context, phase: "1")
        #expect(d.count == 14)
        #expect(labels(d) == ["D-04", "D-07", "D-08", "D-12", "D-01", "D-02", "D-03", "D-05", "D-06", "D-09", "D-10", "D-11", "D-13", "D-14"])
        #expect(Set(d.map(\.number)) == Set(1...14))
    }

    @Test func phase2HasElevenWithDurableFirst() {
        let d = ContextDecisions.parse(phase2Context, phase: "2")
        #expect(d.count == 11)
        #expect(labels(d).prefix(2) == ["D-05", "D-09"])
    }

    @Test func phasesStayApartByPhase() {
        let a = ContextDecisions.parse(phase1Context, phase: "1").first { $0.number == 5 }
        let b = ContextDecisions.parse(phase2Context, phase: "2").first { $0.number == 5 }
        #expect(a?.phase == "1" && b?.phase == "2")
        #expect(a?.text != b?.text)
    }

    @Test func phase3HasElevenOnceEachAndAmendmentYieldsNothing() {
        let d = ContextDecisions.parse(phase3Context, phase: "3")
        #expect(d.count == 11)
        #expect(d.map(\.number).sorted() == Array(1...11))
        #expect(!d.contains { $0.text.hasPrefix("the register") })
    }

    @Test func textIsNeverCut() {
        let d = ContextDecisions.parse("## Decisions\n\n- D-01 (area): one two three four\n", phase: "9")
        #expect(d == [ContextDecision(phase: "9", number: 1, area: "area", text: "one two three four")])
    }

    @Test func otherSectionsAreIgnored() {
        let text = "## Acceptance criteria\n- D-01 (x): no\n## Decisions\n- D-02 (y): yes\n## Flagged assumptions\n- D-03 (z): no\n"
        #expect(labels(ContextDecisions.parse(text, phase: "1")) == ["D-02"])
    }

    @Test func picksThreeNewestEarlierPhases() {
        let all = ["1", "2", "3", "4", "5"]
        #expect(ContextDecisions.earlierPhases(folders: all, current: "5") { _ in true } == ["4", "3", "2"])
    }

    @Test func skipsPhasesWithoutContextAndNumericOrder() {
        let all = ["2", "10", "9", "1.5"]
        #expect(ContextDecisions.earlierPhases(folders: all, current: "11") { $0 != "9" } == ["10", "2", "1.5"])
    }

    @Test func badFolderNamesAreSkipped() {
        let all = ["../x", "1.1x", "1", "2"]
        #expect(ContextDecisions.earlierPhases(folders: all, current: "3") { _ in true } == ["2", "1"])
        #expect(ContextDecisions.earlierPhases(folders: ["1"], current: "../x") { _ in true } == [])
    }
}
