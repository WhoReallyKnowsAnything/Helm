# Worker prompt-cache report (2026-11-24)

Question: why does each worker write a new prompt cache instead of reading an earlier worker's cache?

## 1. Baseline: turn 1 of real workers

Source: first `assistant` event `usage` in every `.claude/sessions/*/out.jsonl` (orchestrator `dashboard` logs excluded). Tokens, medians.

| Model | Workers | Cold (read = 0) | Warm | Warm create / read | Warm read share |
|---|---|---|---|---|---|
| sonnet | 133 | 23 | 110 | 62,657 / 55,724 | 47% |
| opus | 11 | 10 | 1 | 72,389 / 48,563 | 40% |
| haiku | 5 | 5 | 0 | none warm (about 120,000 / 0) | 0% |

Examples (create / read): sonnet `cad-plan-p10` 63,178 / 56,416. sonnet `cad-execute-p10` 62,804 / 56,416. opus `port-whoreallyknowsanything…` 120,802 / 0. haiku `commit-often` 120,368 / 0.

A warm worker always reads the same 56,4xx tokens. Everything after that point is written again.

## 2. Where two same-model request prefixes first differ

Evidence: request bodies captured with a local forwarding proxy (`ANTHROPIC_BASE_URL` set per process through `--settings`), plus the `api-request-blob` entries in two real worker transcripts one minute apart.

Request order: tools, system (3 blocks), message 0 (user), message 1 (hook and environment reminders).

- Tools and system blocks are byte-identical between workers of the same project, including the appended worker prompt and the orchestrator-name line. The shared prefix is about 56,4xx tokens. This is what a warm worker reads.
- The first difference is **message 0**. Message 0 holds `[global CLAUDE.md block (identical), git status block with "Current branch: session/<label>", the dispatched task text]`. The task text and the branch name differ per worker.
- The API reads this cache at message boundaries here. Block 0 of message 0 is identical in both workers, yet it is not read, because message 0 as a whole differs.
- Message 1 (about 97,000 characters: hook output, `Primary working directory`, skill list, agent list, deferred tool list) comes after the task, so it is never shared. It also differs by cwd and by the Terminus hook lines (`last session ... on branch`, `N sessions and M turns`).
- Test with identical task text and different worktrees: read rose to about 77,000 and the first difference moved to message 1, at the Terminus line (`It last answered`, session count). So the task text in message 0 costs about 20,000 read tokens.

## 3. Classification

| Cause | Class | Source |
|---|---|---|
| Task text inside message 0, ahead of about 60,000 tokens of static content | Outside dispatch: Claude Code orders the first user message | request dump |
| `Current branch: session/<label>` in the git status block | Needs a unique branch per worker. Outside dispatch | dispatch-task.sh branch naming |
| `Primary working directory` line before the skill, agent and tool lists | Claude Code env block, per worktree | request dump |
| Terminus SessionStart lines (counts, last answer) inside message 1 | User hook, outside dispatch | `terminus` hook output |
| Cold start: no same-model request in the last hour (1 h TTL on the system blocks) | TTL, per model. Haiku and opus are used rarely, so 15 of 16 of their workers were cold | usage table |
| `cc_version=2.1.331.ed6` is the first system block. `claude update` at launch (`dispatch-task.sh:55`) can change it | Dispatch, but small: a release bump costs the system part (about 9,000 tokens) once, tools still hit | request dump |
| Appended prompt order/content (`dispatch-task.sh:53`, `:49`) | Checked: identical per project, not a cause | request dump |
| `--exclude-dynamic-system-prompt-sections` | Tested on haiku, no gain (read 56,071 vs 56,884 baseline) | probes E0, E1 |

## 4. Fixes applied

None. No dispatch-controlled cause moves the read share. The shared prefix already stops where per-worker data (task, branch, cwd) starts, and Claude Code puts that data before the large static blocks.

## 5. Options that need the user's decision

1. Move the static global rules out of message 0 into `--append-system-prompt-file` (generated from CLAUDE.md, with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`). Gain: about 20,000 more read tokens (to about 65%). Risk: rules lose user-message weight, and project CLAUDE.md files need handling.
2. Keep-warm ping per model every 50 minutes. Gain: removes cold starts for haiku and opus. Cost: one cheap read per model per 50 minutes, and a background job.
3. Ask Terminus to print its volatile lines last, or to skip headless workers. Gain: small once the cwd line is the first difference.

Step 5 of the task (2 workers per model, before/after) was not run: there is no fix to compare. Baseline probes, haiku, 2 workers, distinct tasks, different worktrees: worker 2 turn 1 create 63,639 / read 56,884.

## 6. Option 1 applied: rules in the system prompt (2026-11-24)

Change: `orchestration/lib/worker-rules.sh` builds the rules text at launch. `_build_launch_cmd` passes it as `--append-system-prompt "$(cat <file>)"` and sets `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`.

Checks (request captures through a forwarding proxy in front of the headroom proxy, worker-style `stream-json` launch with the real `_build_launch_cmd` output):

- `CLAUDE_CODE_DISABLE_CLAUDE_MDS` exists in `2.1.331`. It removes the whole `Codebase and user instructions` block (49,822 chars) from message 0: CLAUDE.md, `@` imports, `~/.claude/rules`, `~/.claude/AGENTS.md` and the auto-memory `MEMORY.md` index. The `# Memory` instructions in the system prompt stay.
- Only the last `--append-system-prompt-file` and the last `--append-system-prompt` are used. So the second file flag is not possible. The worker prompt file flag stays unchanged (the gate match still fires). The orchestrator-name line moves into the rules file, because it was the one inline flag.
- Rules with `paths:` frontmatter (swift, typescript, testing) load lazily in the old setup. They are now always in the system prompt, with their frontmatter. Cost: about 6,000 more cached tokens. Project files are read from the main checkout, not the worktree.
- Request capture: every `Contents of` block appears exactly once, in system block 2. Message 0 holds only the email context and the task. System block 2 of two workers with different tasks is byte-identical (md5 `6ec356ee`). The `x-anthropic-billing-header` block 0 changes with the task text, and does not stop the cache read.

Turn 1, worker 2 (worker 1 dispatched first, same model, within the TTL):

| Model | Baseline read | After read | Gain | After create |
|---|---|---|---|---|
| haiku | 56,884 | 85,398 | +28,514 | 40,926 |
| sonnet | 55,724 | 84,393 | +28,669 | 40,774 |

Opus was not run. Worker 1 of each pair wrote about 77,000 tokens (the rules text is new in the system prefix once).

Rule check (sonnet, task "run `pwd`"): before and after behave the same. The reply starts with the user's name (the canary rule). The worker first tries native `Bash` (blocked by the hook), then uses `mcp__lean-ctx__ctx_shell`. The git approval gate rules were not exercised.

### 6.1 Launch order fix (c74ed5b) and live proof

Cause: `_build_launch_cmd` ran before `git worktree add`, so its `git -C "$session_dir"` lookup failed and every fresh dispatch fell back to the old launch silently. Fix: use `PROJECT_ROOT` first (set on dispatch, resume and ping), git lookup only when it is unset, and one stderr line when the rules file is not built. Test: `test/test-worker-rules.sh` (3 of its 4 new checks fail on the old script, 17 of 17 pass now).

Live runs, haiku, worktree copy of the script, `ps` of the worker:
- Process env holds `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`. The inline `--append-system-prompt` is about 78 KB of rules text (before: the short orchestrator line only).
- Turn 1 cache read: worker A (cold) 48,677. Worker B (dispatched after A) 85,983, create 40,478. Worker C 85,983.
- One `--cache-ping haiku` by hand: read 47,568, create 66,340. Probe C ran right after it, but worker B had already warmed the cache, so C does not prove the ping prefix alone. Not isolated.
- All probes ended with `--kill`. The launchd ping job was not touched.
