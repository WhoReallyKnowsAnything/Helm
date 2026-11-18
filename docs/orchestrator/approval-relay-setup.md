# Approval Relay -- Hook Setup

> `orchestration/install.sh` writes the wrappers, registers these hooks and installs the LaunchAgent. The manual steps below are for a reader who wants to do it by hand.

The worker relay hooks, the git gate and the permission hold are versioned in
this repo, but their *registration* lives in your global
`~/.claude/settings.json`, which is outside the repo entirely (worker
worktrees carry no `.claude/` at all -- `.gitignore:1`). A fresh clone of
this repo does nothing until you add the blocks below and restart the
Claude Code session that will host the worker -- hook registration is read
at session start, not live.
## Worker relay hooks (start, idle, commit)

A live worker's state row gets its start, idle and commit events and its Claude
session id from one script, `orchestration/hooks/worker-relay.sh`, registered
three times in global `~/.claude/settings.json`. No `SendMessage` is involved:
the hook writes the row directly. Add one entry to each of `hooks.SessionStart`,
`hooks.Stop` and `hooks.PostToolUse`, next to the entries already there (do not
remove or reorder any of them):

```json
{
  "hooks": [
    {
      "type": "command",
      "command": "\"$HOME/Library/Application Support/Helm/orchestration/hooks/worker-relay.sh\"",
      "timeout": 15
    }
  ]
}
```

That entry goes in `hooks.SessionStart` and in `hooks.Stop` as it is. In
`hooks.PostToolUse` the same entry needs a matcher. It must cover `Bash`,
`WebFetch` and `mcp__.*`, because the hook puts a blocked row back to running
when the call completes. It must also cover every tool that
the permission hold covers, because the hook ends the hold of a call that a human
answered at the native dialog (see "A pane answer ends the hold"). A narrower matcher
leaves a WebFetch or MCP call showing as blocked, and leaves the hold of a Write or
Edit that was answered at the native dialog until its
deadline:

```json
{
  "matcher": "Bash|WebFetch|mcp__.*|Write|Edit|MultiEdit|NotebookEdit",
  "hooks": [
    {
      "type": "command",
      "command": "\"$HOME/Library/Application Support/Helm/orchestration/hooks/worker-relay.sh\"",
      "timeout": 15
    }
  ]
}
```

The `busy` event (a worker working again after a Stop) comes from two more
registrations of the same script, with the same entry and no matcher: one in
`hooks.UserPromptSubmit` and one in `hooks.PreToolUse`. The hook writes `busy`
only when the row's last_event is `idle`, so it is one DB write per resume, not
one per tool call, and it never replaces `done`. UserPromptSubmit covers a typed
prompt. PreToolUse covers a cross-session message, which may not fire
UserPromptSubmit (unverified): the worker's first tool call after the message
flips the row.

- The hooks are global. They run for every session and exit at once, writing
  nothing and printing nothing, unless the session's cwd is inside a live
  worker's worktree (a `running`, `blocked` or `stalled` row that is not
  `dashboard`). For a live worker, the hook prints one thing: on a SessionStart
  with `source` `resume` it prints one JSON context block, the worker prompt (see
  "Come back after a reboot" below). It printed nothing on SessionStart before
  Plan 8. For every other event and `source` it still prints nothing.
- `"timeout": 15` is this guide's own choice: the spike verdict only records
  900 for the hold hook. The relay is an observer that fails open, so it has no
  `onFailure` line. The hook always exits 0, and a missing script only means no
  event is recorded.
- Registration is read at session start, so a running session needs a restart
  before the hooks fire. Already-dispatched workers are not covered.

What each event means:

- `start`: SessionStart fired (any `source`: startup, resume, clear, compact).
  The hook also stores the Claude session id for a later `--resume`.
- `commit`: a shell tool ran a command containing `git commit`. The message is
  the subject of `HEAD`.
- `idle`: Stop fired. A turn ended and the worker waits. It does NOT mean the
  task is finished, because Stop fires at the end of every turn. Two cases
  also block the Stop once. With the tree clean and the event not `done`, a
  worker branch with commits ahead of the base gets a nudge to run
  `--mark-done`. A branch with no commits ahead gets a start nudge: the launch
  system prompt is the user's go, so the worker must not wait for one.
- `done`: written only by the worker's final step, `dispatch-task.sh --mark-done
  <label> [message]`, after it ran `/om-wrap-up`. A Stop alone never shows a
  worker as done, and a Stop after `done` leaves it `done`. A later `start` or
  `commit` replaces `done`.
- `blocked` comes with the hold (`gate-hold.sh`), not from this script.

Prove it fires: restart the session that will host the worker, dispatch a
worker, let it run one turn, then read its row:

```bash
sqlite3 .claude/session-state.db "select agent_id, last_event, claude_session_id from sessions"
```

`last_event` stays empty when the hooks are not registered, and every column in
the command above must exist: run `orchestration/init/init-state-store.sh` once
for a project whose database was created before these columns.

## ntfy topic (26-05)

The away-from-desk notification (D-06) has two channels. The local macOS
notification works with no setup at all -- it is what covers the
at-the-machine case. The ntfy channel needs one thing from you: a topic.

### Picking a topic

Pick an unguessable topic name (a random slug, not `approvals` or your
username) at [ntfy.sh](https://ntfy.sh) or a self-hosted ntfy instance.
Subscribe your phone to it in the ntfy app. There is nothing to register or
create in advance -- posting to a topic that has no subscribers yet is a
harmless no-op, and subscribing is instant.

### Wiring it in

Write the full topic URL into `.claude/approval-relay.conf` at this repo's
root, in the shape `orchestration/lib/notify.sh` expects:

```
APPROVAL_NTFY_TOPIC_URL="https://ntfy.sh/YOUR-TOPIC-HERE"
```

That path is already gitignored (`.gitignore:1` ignores `.claude/` entirely)
-- no gitignore change is needed, and nothing here adds one. The file is
sourced only if it exists; with no file and no topic configured, the ntfy
channel is silently skipped and the local macOS notification still fires.

### The topic URL is a bearer secret

Anyone holding the topic URL can read every notification body posted to it,
and that body carries blocked-operation text -- command lines and worktree
paths. Treat the URL exactly like a credential: never commit it, never put a
real topic in an example file or a chat message, and pick something
unguessable rather than a short, memorable slug.

## Out-of-band notification (Gap 4)

`--blocked-sweep` only runs when something invokes it. The launchd LaunchAgent in
`orchestration/launchd/io.github.whoreallyknowsanything.helm.blocked-sweep.plist`
runs `dispatch-task.sh --blocked-sweep-all` on a timer, outside any Claude Code
session. That finds each project through tmux pane paths (`list-panes`, no pane
content is read) and runs `--blocked-sweep` for it. The sweep prunes dead gate
hold records and sends the "Approval needed" notification for a hold that has
waited 120 s (`APPROVAL_NOTIFY_AFTER_SECS`).

### What it does

`StartInterval 60` runs the sweep every 60 seconds, unconditionally, whether
or not an orchestrator session is open. An explicit `EnvironmentVariables.PATH` is set
to `/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` because launchd's
default minimal PATH does not include `/opt/homebrew/bin`, where `tmux` and
`node` resolve on this machine -- without it, the job loads and exits 0 every
time while every tmux call inside `--blocked-sweep` silently no-ops (this
repo's pervasive `2>/dev/null || true` fail-open pattern swallows the "tmux:
command not found" error too, so `launchctl list`'s exit status alone proves
nothing -- check the log's content).

A second, related gotcha surfaced during live verification: launchd's
default working directory is `/`, not the repo. `session_state_db_path`
(used internally by the sweep) resolves the state DB via `git -C .
rev-parse --git-common-dir` when called with no argument -- CWD-relative,
not `PROJECT_ROOT`-relative. Under `/`, that git call fails ("not a git
repository"), `set -euo pipefail` kills the whole sweep before it prints
anything, and the stray `2>/dev/null` on that call swallows the one error
message that would have explained why. The plist sets `WorkingDirectory` to
the repo root to fix this -- the same silent-failure shape as Pitfall 4,
one directory-resolution layer up from `PATH`.

A third gotcha, more severe than either of the above, also surfaced live:
setting `WorkingDirectory` to the repo root (needed for the fix above) puts
the job's cwd inside `~/Documents`, a TCC-protected macOS folder. `tmux`'s
own client startup calls `getcwd()` unconditionally on every invocation
(`find_cwd()`, confirmed via `sample` on the hung process) -- and under
launchd, without Full Disk Access, that `getcwd()` call **hangs
indefinitely** inside the kernel rather than failing fast, because there is
no GUI session for `tccd` to resolve a permission prompt against. This is
not a `2>/dev/null`-swallowed error like the two gotchas above -- it is a
real hang, confirmed by `sample`'s call stack (`main -> find_cwd ->
__getcwd -> open$NOCANCEL`, stuck) and by a disposable probe LaunchAgent
that completed instantly with `WorkingDirectory=/tmp` and hung indefinitely
with `WorkingDirectory=` the repo root. The plist wraps the sweep in `timeout
25` so a still-ungranted machine fails fast with a clear log line instead of
accumulating hung `tmux`/`bash` processes every 60 seconds forever.

**Required one-time step on this machine:** grant Full Disk Access to
`/bin/bash` in System Settings -> Privacy & Security -> Full Disk Access
(the `+` button, then navigate to `/bin/bash` -- not visible in Applications,
use Cmd+Shift+G to type the path). This is a GUI-only step; nothing in this
repo can grant it. Until it is granted, `~/.claude/logs/approval-sweep-launchd.log`
will show the `timed out after 25s` line above instead of a swept result --
that line, appearing after a real block, is exactly the signal that this
step is still outstanding.

### Installing it

The plist lives outside the repo the same way `~/.claude/settings.json`
does (worker worktrees carry no `.claude/` at all) -- installing it is a
one-time per-machine step, not something a fresh clone gets automatically:

```bash
cp orchestration/launchd/io.github.whoreallyknowsanything.helm.blocked-sweep.plist \
   ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/io.github.whoreallyknowsanything.helm.blocked-sweep.plist
```

### Forcing an immediate run for testing

Don't wait a full 60s interval -- kick it off directly, then check the log:

```bash
launchctl kickstart -k gui/$(id -u)/io.github.whoreallyknowsanything.helm.blocked-sweep
tail -n 20 ~/.claude/logs/approval-sweep-launchd.log
```

A `timed out after 25s` line means Full Disk Access (above) is still
missing -- grant it, then kickstart again. A blank log after a forced run
with no worker currently blocked is the expected quiet-case output (the
sweep found nothing to report and printed nothing, matching interactive
`--blocked-sweep` behavior).

## The git gate (hold until the band decides)

`orchestration/hooks/git-approval-gate.sh` is a PreToolUse hook that holds a
dispatched worker's git write op until Helm answers it, instead
of a keystroke into the worker's pane. It holds `git commit`,
`git push`, `gh pr create` and the GSD commit helper (`gsd-tools query commit`).
It holds only dispatched workers: a session with no live worker row (your own
sessions) gets the immediate native yes/no prompt, as before. The GitHub MCP
writes (`push_files`, `create_pull_request`, `issue_write`) are not this hook's.
Every non-git prompt (ExitPlanMode, WebFetch, Write/Edit, MCP dialogs, and
AskUserQuestion from an unlisted worker) is held or denied by the PermissionRequest
hook in "The permission hold" below. AskUserQuestion from a listed stage worker
(`orchestration/lib/question-stages.sh`) goes on to the app as a card.

**Channel.** The gate writes a pending record per `tool_use_id` under the
project's `.claude/gate-holds/` and polls for a sibling decision file; the band
writes that decision (`allow` or `deny` plus the op hash it showed you) through
`dispatch-task.sh --gate-decide`. The gate acts only when the id and op hash
match its own op, so a stale or mismatched decision is never an allow.

**Registration.** Point both entries at the in-repo gate by absolute path. The
`command` below is the bare path. It works, but the fail-closed wrapper under
"Fail-closed registration" further down replaces it; that wrapper is the form
to apply. In `~/.claude/settings.json`,
the `mcp__lean-ctx__ctx_shell` entry:

```json
{
  "matcher": "mcp__lean-ctx__ctx_shell",
  "hooks": [
    {
      "type": "command",
      "command": "\"$HOME/Library/Application Support/Helm/orchestration/hooks/git-approval-gate.sh\"",
      "timeout": 900,
      "onFailure": "block"
    }
  ]
}
```

In `~/.claude/settings.local.json`, the same hook object replaces the existing
`git-approval-gate.sh` command inside the `Bash|bash` entry (its other four
hooks stay as they are):

```json
{
  "type": "command",
  "command": "\"$HOME/Library/Application Support/Helm/orchestration/hooks/git-approval-gate.sh\"",
  "timeout": 900,
  "onFailure": "block"
}
```

`"timeout": 900` and `"onFailure": "block"` are both needed: a hook that times
out fails open by default (the command would run unapproved), so `block` makes
it fail closed. The gate's own deadline is 600 s (set `APPROVAL_GATE_DEADLINE_SECS`
to change it) and it ends in a deny, below the 900 s registration timeout, so
the script decides rather than Claude Code's timeout. Registration is read at
session start, so restart any session that should use it.

With the bare path above, `onFailure: "block"` blocks every `Bash` or `ctx_shell`
call when the registered script is missing, so the registered path must exist at
all times. Repoint the registration before removing a worktree or checkout that
holds the script. The wrapper under "Fail-closed registration" avoids this for
you. The gate needs `node`, `sqlite3` and `shasum` on `PATH`.

**Deadline and failures (no fallback).** A live worker's git op never falls back
to the native prompt. There is no fallback, because a headless worker has nobody
at its pane (D-05). Past its deadline (600 s by default,
`APPROVAL_GATE_DEADLINE_SECS` to change it) the gate denies the call and sends
one notification that names the worker. The deny reason says the hold waited N
seconds with no band decision, so the worker can run the command again to ask
again. A live worker whose hold cannot be set up is denied the same way, at
once: no usable `tool_use_id`, no op hash (`shasum` or `awk` missing), or no
pending record. The gate decides who is a live worker with `live_worker_agent`:
only a row with status `running`, `blocked` or `stalled` counts, and the
`dashboard` row never does. A human in a finished worktree, in a checkout that
is not a worker, or in the `dashboard` session still gets the plain yes/no
prompt, within 1 s.

**Fail-closed registration (a missing gate script).** `onFailure: "block"`
covers a gate that crashes or hangs. A script that is missing is different: it
blocks every call, yours as well as a worker's. The object below is the `command`
wrapper for the same hook object, with `timeout` 900 and `onFailure: "block"`
kept from above. The human applies it in PLAN-8; this guide only documents it.

- Script present and executable: the wrapper runs it with `exec`, so the payload
  reaches the gate on stdin untouched.
- Script missing: it reads the payload once and takes the payload's `cwd` with a
  real JSON parse (a text match could be fooled by words inside the command). It
  sources `session-state.sh` from `../lib/` next to the gate path and asks
  `live_worker_agent` about that cwd. For a live worker it prints the same
  PreToolUse `deny` the gate prints at its deadline, with a reason that says the
  gate script is missing, and exits 0. For anything else it prints nothing and
  exits 0: not a worker, the `dashboard` row, a `done` row's worktree, an empty or
  unparseable cwd, garbage input. Your own git ops then follow your normal
  permission rules.
- `session-state.sh` missing as well: last resort. The wrapper denies when the
  cwd contains `/.claude/worktrees/` and prints nothing otherwise. This rule is
  only for a checkout that is gone. It is not the main rule, because it would
  deny a human working in a finished worktree.

The wrapper holds the gate's absolute path in exactly one place (`G=`). It needs
`bash` and `node` on `PATH`; without `node` it cannot read the cwd and prints
nothing. It guards a missing script only. The output-checking wrapper in
`.planning/spikes/permission-request-hold/SPIKE.md` (v3) cannot guard this hook,
because the gate prints nothing for every command that is not a git op.
`test/test-hook-wrapper.sh` runs this exact text with the script absent.

In `~/.claude/settings.json` this object replaces the hook object inside the
`hooks` array of the `mcp__lean-ctx__ctx_shell` entry. In
`~/.claude/settings.local.json` it replaces the gate hook object inside the
`Bash|bash` entry the same way:

```json wrapper-git-gate
{
  "type": "command",
  "command": "bash -c 'G=\"$HOME/Library/Application Support/Helm/orchestration/hooks/git-approval-gate.sh\"; [ -x \"$G\" ] && exec \"$G\"; C=$(node -e \"(async()=>{let d=[];for await(let c of process.stdin)d.push(c);try{process.stdout.write(String(JSON.parse(Buffer.concat(d)).cwd||[]))}catch{}})()\" 2>/dev/null); [ -n \"$C\" ] || { printf \"{\\042hookSpecificOutput\\042:{\\042hookEventName\\042:\\042PreToolUse\\042,\\042permissionDecision\\042:\\042ask\\042,\\042permissionDecisionReason\\042:\\042The approval gate script is missing and the hook could not read the working folder (node missing or bad input), so this call needs your approval.\\042}}\"; exit 0; }; if . \"${G%/*}/../lib/session-state.sh\" 2>/dev/null; then cd \"$C\" 2>/dev/null; live_worker_agent \"$C\" >/dev/null 2>&1 || exit 0; else case \"$C\" in */.claude/worktrees/*) ;; *) exit 0;; esac; fi; printf \"{\\042hookSpecificOutput\\042:{\\042hookEventName\\042:\\042PreToolUse\\042,\\042permissionDecision\\042:\\042deny\\042,\\042permissionDecisionReason\\042:\\042The approval gate script is missing, so this call from a live worker is denied. Restore orchestration/hooks/git-approval-gate.sh and retry.\\042}}\"; exit 0'",
  "timeout": 900,
  "onFailure": "block"
}
```

**Self-approval limits.** A worker runs as your uid and can write the
`.claude/gate-holds/` directory, so it could write its own decision. The gate
denies any command from a live worker whose text names that directory, and the
same applies to a dev session on this repo that is registered as a worker. That
check is best-effort and dodgeable (`$IFS` splitting, variable indirection),
and it does not cover file tools such as `ctx_patch`. This is parity with a
worker's existing ability to `tmux send-keys` into its own pane, not an
improvement on it. Real isolation (a decision store the worker cannot write: a
separate uid, an ACL, or a signing key it cannot read) is a deferred phase.

**Caller check on `--gate-decide`.** `dispatch-task.sh --gate-decide` makes two
checks before it writes a decision. Both must pass.

1. Environment markers. It refuses a caller whose env carries `CLAUDECODE` or
   `CLAUDE_CODE_SESSION_ID`. The band was measured to carry neither marker
   (`.planning/phases/1/MEASUREMENT.md`). Do not launch the GUI app from a
   Claude Code shell, because the app would inherit a marker and be refused.
   `env -u` removes the markers, so this check alone does not stop a worker.
2. Process ancestry. It reads the caller's parent processes with `/bin/ps`, up
   to `launchd`. No environment variable or argument from the caller counts.
   It refuses the call if any parent has
   `--append-system-prompt-file .../orchestration/prompts/worker-dependency-awareness.md`
   in its arguments. `dispatch-task.sh` launches every worker, fresh or resumed,
   with that flag. Otherwise it needs one parent that is a decider:
   - the orchestrator's Claude session: a process named `claude` with
     `--append-system-prompt-file .../orchestration/prompts/task-drafting-mode.md`
     in its arguments (`launch-claude.sh` in Orchestration mode). The band runs
     inside this process.
   - the orchestrator-gui app: an executable at a path that ends in
     `Helm.app/Contents/MacOS/Helm`, installed or a dev build. During the
     change-over from the old executable name,
     `Helm.app/Contents/MacOS/OrchestratorGUI` also passes. The app passes
     nothing new.

What the check guarantees: a worker that runs `--gate-decide` from its own
shell tool is refused, with or without `env -u`, and the hold stays pending.
This is true for git holds and for held permission prompts. A band shown
inside a worker's own session is refused too, because it runs in that worker's
process tree. Answer holds from the orchestrator's band or from the app. An
orchestrator session started without the drafting prompt (plain `claude`, or
Root Dir Mode) is not a decider, so its band is refused.

What the check does not guarantee: it stops accidental or casual
self-approval through the script. It is not a security boundary against a
worker that tries to get around it, because a worker runs as your uid. These
routes stay open:

- The worker writes `<id>.decision` directly with a file tool. The gate reads
  any file shaped `allow <sha256>` with the matching hash, and it cannot know
  who wrote the file. The gate's text deny on the directory name covers shell
  commands only. This applies to held permission prompts too.
- The worker starts a process outside its own process tree, for example with
  `tmux new-window`, `launchctl submit` or `osascript`. That process has no
  worker parent. It passes if it also has a decider-shaped parent, for example
  a new `claude` started with the drafting prompt, or any binary copied to a
  path that ends in `Helm.app/Contents/MacOS/Helm` or
  `Helm.app/Contents/MacOS/OrchestratorGUI`.
- The worker edits `dispatch-task.sh`, `gate-hold.sh`, the hook scripts or
  `~/.claude/settings*.json`. The same user owns them.
- A second `--gate-decide` on a hold that the gate has not read yet replaces
  the first, so the last writer wins.

Real isolation needs a decision store that the worker cannot write: a separate
uid, or an OS sandbox around the worker. That is a deferred phase.

## The permission hold (every other prompt)

`orchestration/hooks/permission-hold.sh` is a PermissionRequest hook. It holds the
permission prompt of a live dispatched worker for Helm, for every
tool. The git gate above covers git ops. This hook covers everything else:
WebFetch, Write and Edit, MCP tools and the rest. The `--answer` path, which typed
a choice into the worker's pane, was removed. Helm now answers only through
the decision files, and no code reads pane text or sends a keystroke to answer a
prompt.

- **Who is held.** Only a live worker. The hook uses the same test as the git gate
  (`live_worker_agent`: a row with status `running`, `blocked` or `stalled`, never
  the `dashboard` row). It asks from the payload `cwd` and from each parent folder
  that has a `.git` entry, so a worker in a sub-folder, or inside a nested git
  repo in its worktree, is still found. The folder where Claude Code starts the
  hook does not matter. For any other `cwd` the hook prints nothing, so your own
  sessions keep the native prompt.
- **The hold key.** A PermissionRequest has no `tool_use_id`. The hold id is the
  session id, the tool name, the first 12 characters of the op hash and a nonce
  that is new for each hook run. Two identical requests get two holds.
- **The op text.** The tool name, then `: `, then the `command` of the tool input,
  else its `url`, else the whole input as compact JSON. The band reads it as it
  reads a git op.
- **The answer.** The band's Approve and Deny buttons run `--gate-decide`, as for
  a git hold. The hook prints the allow or deny shape of the spike verdict.
- **The deadline.** After 600 s with no decision (`APPROVAL_GATE_DEADLINE_SECS`
  changes it) the hook prints a deny and sends one notification that names the
  worker. A live worker whose hold cannot be set up is denied at once, in the same
  way. If `orchestration/lib` is missing or partly deployed, the hook cannot
  find the worker, so it denies a `cwd` under `/.claude/worktrees/` and prints
  nothing for any other `cwd`.
- **Questions.** `ExitPlanMode` is denied at once for every worker, with no hold.
  `AskUserQuestion` is denied at once too, except for a worker whose label is
  listed in `orchestration/lib/question-stages.sh` (the app shows its question as
  a card). For that worker the hook prints nothing, never "allow" (a bare allow
  would run the tool with no human answer), and the wrapper below passes that one
  empty output through. Claude Code 2.1.322 accepts only allow and deny from a
  PermissionRequest hook, so "ask" is not used. Every other empty output is still
  a deny. The deny message tells the worker to send the question or the plan to
  the orchestrator with `SendMessage` and wait.
- **A pane answer ends the hold.** A human can answer the native dialog at the
  worker's pane while the hold waits. After a Yes, the call runs and its
  PostToolUse reaches `worker-relay.sh`. The relay finds the hold of that exact
  call (worker label, session id, tool name and the full op hash) and signals its
  hook. The hook exits through its normal cleanup, so the band row goes within about
  1 s. No decision is written and no notification is sent. If the relay matches the
  wrong hold, that hook prints nothing and the wrapper below turns it into a
  deny, never an allow. Of several identical holds only the oldest ends. After a
  No, Claude Code itself stopped the hook before the deadline (live probe, Claude
  Code 2.1.310, one trial, Bash): no PostToolUse, PostToolUseFailure or
  PermissionDenied fired, so the relay has nothing to act on and does not need to.
  This works only for tools whose PostToolUse reaches the relay (the PostToolUse
  matcher in "Worker relay"). A held tool outside that matcher keeps its hold after
  a Yes at the pane until the deadline. The realistic case is a Read that prompts
  for a path outside the worktree.
- **A limit that stays.** A tool that never fires PermissionRequest (for example a
  call that auto mode allows) is not held. If a native dialog still shows at a
  worker's pane, the band lists a pane row for it. That row cannot be answered.
  This is a gap in the hook event. It is not a failure of the hook.

**Registration.** In `~/.claude/settings.json`, under `hooks`, add a
`PermissionRequest` entry with no matcher. Use the wrapper below as the hook
object, not the bare script path:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [ "<the wrapper hook object below>" ]
      }
    ]
  }
}
```

**Fail-closed wrapper.** A bare registration is not enough. A crash with exit 2, a
hook that prints invalid JSON and a missing script leave the native dialog at the
worker pane. The spike (`.planning/spikes/permission-request-hold/SPIKE.md`, wrapper
v3) tested this and found that `onFailure: "block"` does not apply to those
cases. The hook object below has `timeout` 900 and `onFailure: "block"`. Its
`command` is a `bash -c` wrapper with these properties:

- It holds the script's absolute path in exactly one place (`G=`). The alarm bound
  is `${APPROVAL_HOOK_ALARM_SECS:-660}`. The three numbers stay in this order: the
  hook's own deadline (600), the wrapper bound (660), the registration `timeout`
  (900).
- It reads stdin once. When the script is executable, it runs the script with the
  payload under `perl -e 'alarm shift; exec @ARGV'` and the bound, and keeps the
  output and the exit status.
- Exit status 0 and an output that parses as JSON with a
  `hookSpecificOutput.decision.behavior` is printed unchanged. Any other result is
  a failure: a non-zero exit, a timeout, output that is not a decision, and a
  missing script. A `{}` output counts as a failure, because it leaves the dialog.
- On failure it sources `session-state.sh` from `../lib/` next to the script path
  and asks `live_worker_agent` about the payload `cwd` and each parent folder that
  has a `.git` entry. For a live worker it prints the PermissionRequest deny
  shape, with a message that says what failed (missing, crashed, timed out). For
  any other `cwd` it prints nothing.
- An empty output with exit status 0 passes only when the `cwd` is not a live
  worker. The hook always prints a decision for a live worker, so for a live
  worker an empty output is a failure.
- If `session-state.sh` cannot be sourced, the wrapper denies a `cwd` under
  `/.claude/worktrees/` and prints nothing for any other `cwd`.
- It exits 0 in every case. It needs `bash`, `perl`, `node` and `mktemp` on `PATH`.
  Without `node` it cannot read the `cwd` and prints nothing.

The human applies this registration in PLAN-8. Registration is read at session
start, so restart any session that should use it.
`test/test-hook-wrapper.sh` runs this exact text with stub hook scripts.

```json wrapper-permission-hold
{
  "type": "command",
  "command": "bash -c 'G=\"$HOME/Library/Application Support/Helm/orchestration/hooks/permission-hold.sh\"; B=${APPROVAL_HOOK_ALARM_SECS:-660}; IN=$(cat); T=$(mktemp); W=; if [ -x \"$G\" ]; then printf %s \"$IN\" | perl -e \"alarm shift; exec @ARGV\" \"$B\" \"$G\" >\"$T\" 2>/dev/null; rc=$?; if [ $rc -eq 0 ]; then if [ -s \"$T\" ]; then node -e \"(async()=>{let d=[];for await(let c of process.stdin)d.push(c);try{let b=JSON.parse(Buffer.concat(d)).hookSpecificOutput.decision.behavior;process.exit(String(b)===b&&b?0:1)}catch{process.exit(1)}})()\" <\"$T\" 2>/dev/null && { cat \"$T\"; rm -f \"$T\"; exit 0; }; W=crashed; else W=empty; fi; elif [ $rc -eq 142 ]; then W=timed; else W=crashed; fi; else W=missing; fi; rm -f \"$T\"; C=$(printf %s \"$IN\" | node -e \"(async()=>{let d=[];for await(let c of process.stdin)d.push(c);try{process.stdout.write(String(JSON.parse(Buffer.concat(d)).cwd||[]))}catch{}})()\" 2>/dev/null); case \"$C\" in /*) ;; *) exit 0;; esac; if . \"${G%/*}/../lib/session-state.sh\" 2>/dev/null; then L=; d=$C; while :; do if [ -e \"$d/.git\" ] && A=$(cd \"$d\" && live_worker_agent \"$d\" 2>/dev/null); then L=1; break; fi; [ \"$d\" = / ] && break; d=${d%/*}; d=${d:-/}; done; [ -n \"$L\" ] || exit 0; else case \"$C\" in */.claude/worktrees/*) ;; *) exit 0;; esac; fi; if [ \"$W\" = empty ] && [ -n \"$L\" ] && . \"${G%/*}/../lib/question-stages.sh\" 2>/dev/null && question_stage_allowed \"$A\" && [ \"$(printf %s \"$IN\" | node -e \"(async()=>{let d=[];for await(let c of process.stdin)d.push(c);try{process.stdout.write(String(JSON.parse(Buffer.concat(d)).tool_name||[]))}catch{}})()\" 2>/dev/null)\" = AskUserQuestion ]; then exit 0; fi; case $W in missing) M=\"script is missing\";; timed) M=\"timed out\";; empty) M=\"returned no decision\";; *) M=\"crashed or returned no valid decision\";; esac; printf \"{\\042hookSpecificOutput\\042:{\\042hookEventName\\042:\\042PermissionRequest\\042,\\042decision\\042:{\\042behavior\\042:\\042deny\\042,\\042message\\042:\\042The approval hold hook $M, so this call from a live worker is denied. Restore orchestration/hooks/permission-hold.sh and try again.\\042}}}\"; exit 0'",
  "timeout": 900,
  "onFailure": "block"
}
```

## Headless workers

`dispatch-task.sh <label>` starts a worker in a tmux window and opens no iTerm2
tab. Nobody needs to watch the worker, because the Helm hold cards
show what it needs.

The app's view is how you look at a worker. `--kill <label>` ends the worker
and closes any tab an old row still holds.

## Worker status board

`dispatch-task.sh --status-board` prints one line per live worker. It only reads
the state store. Each line shows the worker's last event:

- `start`: the worker's session started (the relay hook on SessionStart).
- `blocked`: the worker waits for a decision on a held approval.
- `commit`: the worker ran `git commit`.
- `idle`: Stop fired. The worker finished a turn and waits. It is not finished.
- `done`: the worker ran `dispatch-task.sh --mark-done <label> [message]` as its
  last step, after `/om-wrap-up`. Only this step writes `done`. A Stop never does.

## Away notifications

A hold that nobody decides sends a notification after it has waited
`APPROVAL_NOTIFY_AFTER_SECS` seconds. The default is 120. The notice is sent
once for each hold, through the channels in "ntfy topic" above.
The text names the request of that hold. A hold that someone decides before the
delay ends sends nothing. The native dialog that a held worker also shows on its
pane sends nothing. A prompt with no hold on it still notifies as soon as the
sweep sees it.

The launchd sweep sends it (see "Out-of-band notification"). The sweep runs every
60 seconds, so a notice arrives up to about 60 seconds after the delay ends. To
change the delay, set `APPROVAL_NOTIFY_AFTER_SECS` in the sweep's environment (for
the launchd job, under `EnvironmentVariables` in the plist). A value that is not
a number means 120.

## Come back after a reboot

When iTerm2 quits, the watchdog that `launch-claude.sh` starts ends the tmux
server (D-07) only if no base session carries `CLAUDE_GUI`. If one does (a
project the GUI app started with `--gui-folder`), the watchdog ends only the
sessions outside the app-marked projects, so app-started projects survive. An
iTerm-started session that a `--gui-folder` launch reuses gets the marker too.
It reads the marker when iTerm2 quits. A marker set between its last check and its
kill is not seen, and a session created after its list is not ended. Every
worker's tmux window in an ended session ends with it. Each worker's
worktree, branch and state row stay on disk.

To start the live workers again, do these steps for one project at a time:

1. Run `orchestration/launch-claude.sh` in the project. It makes the base tmux
   session that `--resume` needs.
2. Run `orchestration/lib/dispatch-task.sh --resume` from the project folder (or
   set `ORCH_PROJECT_ROOT`). It prints `resumed <label>` or
   `skipped <label>: <reason>` for each row and exits 0 even when it skipped rows.

`--resume` starts `claude --resume <session id>` in a new tmux window for each
worker that was live. It skips merged rows, rows whose worktree is gone, the
`dashboard` row, rows with no stored session id, and workers whose window already
exists. It writes no row and makes no worktree.

What a resume restores, and what it does not:

- `claude --resume` keeps the session id and the model. It does NOT keep the
  effort. `--resume` passes `--effort` again from the effort stored in the row.
- `claude --resume` accepts `--append-system-prompt-file` and ignores it, so the
  worker prompt (`orchestration/prompts/worker-dependency-awareness.md`) does not
  come back through that flag. The relay hook brings it back (next paragraph).

**The relay hook now prints on a resume.** Before Plan 8, `worker-relay.sh`
printed nothing on SessionStart. Now, when the payload `source` is `resume` and
the session belongs to a live worker, it prints one JSON block on stdout:
`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<the worker prompt>"}}`.
Claude Code adds that text to the resumed session as context. For every other
`source` (`startup`, `clear`, `compact`) and for every other session, the hook
prints nothing. The SessionStart entry in "Worker relay hooks" must have no
`matcher`, or the `resume` source never reaches it. If the prompt file cannot be
read, the hook prints a line on stderr and no context, and the worker still
resumes.

The live probe is `.planning/spikes/permission-request-hold/RESUME-CONTEXT.md`.
It sent 9988 bytes (the prompt, 9957 bytes at probe time, plus a marker line). The
last line reached a resumed session, in `-p` mode and in an interactive tmux
window, and a control with a silent hook got no marker. If the prompt grows past
9988 bytes, repeat that probe before you trust the larger size. The probe shows
the text arrives. It does not show that a resumed worker follows it as strictly
as a system prompt. The live check (Plan 8 Task 4) covers that.

## Every hook the setup needs

`orchestration/install.sh` registers these hooks for you. Use the table below only for a manual setup.

| Hook | Event and matcher | Script | If the script fails | Exact entry |
|---|---|---|---|---|
| Git gate | PreToolUse, `mcp__lean-ctx__ctx_shell` in `settings.json` and `Bash` in `settings.local.json` | `git-approval-gate.sh`, through its wrapper | closes | "The git gate", block `wrapper-git-gate` |
| Worker relay (events) | SessionStart (no matcher), Stop, PostToolUse (`Bash\|WebFetch\|mcp__.*\|Write\|Edit\|MultiEdit\|NotebookEdit`) | `worker-relay.sh` | opens (observer) | "Worker relay hooks" |
| Worker prompt on resume | the same SessionStart entry, only when `source` is `resume` | `worker-relay.sh` | opens (observer) | "Come back after a reboot" |
| Permission hold | PermissionRequest, no matcher | `permission-hold.sh`, through its wrapper | closes | "The permission hold", block `wrapper-permission-hold` |

The hold and gate wrappers fail closed: if the script is missing, the call is
denied. Their hook registrations in `~/.claude/settings.json` and
`~/.claude/settings.local.json` are applied by hand (Plan 8 Task 3), after this
branch is merged on `main`. Before the merge, `permission-hold.sh` is not on
`main`, so a wrapper that points at the `main` checkout would deny every call.
Do not register the wrappers until the merge is done.

## Limitations

Recorded honestly, per D-09, rather than designed around. The band answers
through decision files only. No code path reads pane text or sends a keystroke
to answer a prompt (the `--answer` path was removed).

- **The standing-grant row is refused outright, unconditionally, regardless
  of what the human chose.** Its failure mode -- landing on `Yes, and don't
  ask again for ...` -- is both silent and permanent: it converts one
  human "yes" into a standing allow rule for that tool class in that
  worktree, with nothing telling anyone it happened. There is no guard
  cheap enough to make that row safe to select, so it is never selected.
- **Warning signs (from RESEARCH.md Pitfall 1) that this has gone wrong
  anyway:** a worker that stops prompting for operations it used to prompt
  for, or a settings file (`~/.claude/settings.json`, a project's own
  settings) gaining allow rules nobody added by hand. Either one means a
  standing-grant row was selected somewhere outside this relay's guards --
  investigate immediately, do not assume it is benign.
- **A deny reason and the denial are unlinked from the worker's point of
  view.** D-14 routes the human's reason out-of-band via the orchestrator's
  own `SendMessage` call rather than typing it into the pane, because the
  denial mechanism the worker sees carries no reason field at all -- it is
  generic boilerplate ("The user doesn't want to proceed with this tool
  use... STOP what you are doing and wait for the user to tell you how to
  proceed"). That design is correct given the constraint (T-26-35 forbids
  typing human text into the pane), but it means nothing ties the relayed
  reason to the specific denial the worker actually saw. A worker receiving
  a reason with no attached evidence it corresponds to its own most recent
  denial is right to treat it with skepticism rather than as verified fact
  -- confirmed live during Phase 26 Task 3, check 2. D-14's guarantee is
  therefore weaker in practice than "the denial carries the reason": the
  reason is delivered, but not provably attached.
- **The sweep logs its own stderr.** Each stderr line of `--blocked-sweep` is
  appended to `~/.claude/logs/approval-sweep-stderr.log` (override with
  `SWEEP_STDERR_LOG`) as `ISO-ts trigger=<t> target=<base:window> cmd=<last
  commands> stderr=<line>`. `<t>` comes from `SWEEP_TRIGGER`: `launchd` (set in
  the plist) or `manual` (unset). A clean sweep writes nothing.

