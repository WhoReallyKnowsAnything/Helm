# Claude Multi-Session Orchestrator

Run several [Claude Code](https://claude.com/claude-code) sessions in parallel on one project, each isolated in its own git worktree, coordinated by an orchestrator session and a shared state store -- without adopting a multi-agent framework or giving up control over merges.

Built for people who want AI-assisted parallel development but aren't comfortable handing an autonomous agent swarm full control. **You still decide what work exists and you still approve every merge.** Nothing auto-merges, nothing auto-resolves conflicts.

## What it does

- **Orchestration mode** -- `launch-claude.sh` starts Session 1 as an orchestrator (Opus) that drafts task prompts with you and dispatches each one to a worker. Solo mode launches a plain session instead; `promote-session.sh` turns an already-running session into an orchestrator.
- **Isolation** -- each worker runs in its own git worktree on a `session/<label>` branch, in its own tmux window (headless: dispatch opens no iTerm2 tab, and the app's view is how you look at a worker), so two workers can never clobber each other's files.
- **Shared state** -- a local SQLite store (`.claude/session-state.db`) tracks every session's status, retry count, task title and worktree path, plus declared dependencies between sessions.
- **Notion pick-up** -- the orchestrator shows the project's open Notion tasks at launch; naming one flips its Status to `In progress` and drafts the worker prompt from it.
- **`SendMessage` handoff** -- every drafted prompt carries an escalation channel: the worker uses `SendMessage` to tell the orchestrator when it finishes or is unsure about scope.
- **Dependency messaging** -- a task can declare `Depends on: <session label>, needs: <artifact>`. When the upstream session produces the artifact, the dependent worker is notified.
- **Approval relay** -- when a worker blocks on a permission dialog, a hook holds it and Helm shows it as a hold card, and you press Approve or Deny (nothing is typed into the worker's pane). See [docs/approval-relay-setup.md](docs/approval-relay-setup.md).
- **Manual, confirmed merges** -- `merge-review.sh` shows a diff and commit log per session; merging requires an explicit flag and a yes/no confirmation, always.

## Prerequisites

- macOS + [iTerm2](https://iterm2.com/) (AppleScript automation targets iTerm2 specifically)
- `tmux` -- every worker runs in a tmux window
- [`claude` CLI](https://claude.com/claude-code)
- `git` (worktrees), `sqlite3` (bundled with macOS), `node` (approval relay)
- Optional: `jq` and an authenticated [`gh` CLI](https://cli.github.com/) for the New Project flow (creates a GitHub repo and a Notion project row)
- Target project must be a git repository

## Setup

The orchestrator ships inside the Helm repo (`orchestration/`). Follow "Build and install" in the [root README](../../README.md). It ends with `install.sh`, which registers the hooks and installs the LaunchAgent.

The state store initializes itself the first time you launch in Orchestration mode against a git-repo target. To use the approval relay, register its hook as described in [docs/approval-relay-setup.md](docs/approval-relay-setup.md).

## Usage

### Launch

```bash
./orchestration/launch-claude.sh
```

Interactive: pick root-dir or project mode, an existing or new project, then Orchestration or Solo (default Orchestration). In Orchestration mode Session 1 starts as the orchestrator; describe work in plain language and it drafts one prompt per task and dispatches workers on your go-ahead.

Promote a session that is already running:

```bash
./orchestration/promote-session.sh [target_dir]    # default: cwd
```

### Launch without iTerm (GUI app)

```bash
./orchestration/launch-claude.sh --gui-folder <absolute-folder> --env-file <file>
```

This mode starts the orchestrator for one project with no prompts, no stdin, no terminal, no iTerm tab and no iTerm watchdog.

- `--gui-folder` and `--env-file` are required together. No environment variable starts this mode.
- The `--gui-folder` value is an absolute path to an existing directory. It must be the top level of a git repository or linked worktree. A linked worktree shares the session and the state of its main repository.
- Exit code 0 means the launch started a new base session. Exit code 3 means the base session already ran and the launch reused it. Exit code 1 means the launch failed. The reason is on stderr.
- On 0 and 3 the last stdout line is the base session name.
- The base session environment holds the marker `CLAUDE_GUI=1`. A reused session gets the marker but not the env file.
- The launcher takes `PATH` from the env file to find `tmux`. It reads the file and never sources it.

Env file format: `KEY=VALUE` lines as `env` prints them. A line that starts with a name (a letter or underscore, then letters, digits or underscores) and `=` starts a record. The value is everything after the first `=`. Any other line continues the previous record, joined by one newline. A later record with the same name replaces the earlier one. Lines before the first record are dropped.

Known limits of the env file:

- A continuation line of a multi-line value that itself looks like `NAME=...` starts a new variable.
- A value that is not valid UTF-8 makes tmux reject the new session, and the launch exits 1.
- The writer puts each value in double quotes and writes `#` as `##` in the folder and window name (tmux expands `#` in those two values).
- A server that this launch starts gets the file's variables as its global environment. The launcher's own `TMUX_TMPDIR`, when set, is part of that environment. A server that already runs keeps its global environment unchanged.

### Create a project and launch it (GUI app)

```bash
./orchestration/launch-claude.sh --gui-new <name> --github private|public|skip --env-file <file>
```

This mode does what New Project does in the interactive menu, without prompts. It then continues as `--gui-folder` on the new folder.

- All three flags are required, each with a value. `--gui-new`, `--gui-folder` and `--gui-root` exclude each other.
- `<name>` matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. The folder is `$PROJECTS_DIR/<name>`. `PROJECTS_DIR` comes from the env file, else the environment, else `~/Documents/Projects`.
- Steps: `git init`, scaffold (`.gitignore`, `.claudeignore` when the template exists, `README.md`, `.env.example`, `.claude/settings.json`), MemPalace wing (skipped when `NO_MEMPALACE=1`), one commit `chore: initial project scaffold`, `gh repo create` for `private` or `public`, Notion Projects row (skipped when `NO_NOTION=1`).
- `tmux` and `git` must be on the env file `PATH`. `gh` must be too, unless `--github skip`.
- Exit code 1 means a validation failure. Nothing is created. Exit code 4 means `$PROJECTS_DIR/<name>` already exists (file or directory). Exit code 5 means `git init`, the scaffold or the commit failed. The folder stays and stderr names the step and the folder. Exit codes 0 and 3 are the same as for `--gui-folder`.
- A MemPalace, GitHub or Notion failure prints `warning: <step>: <reason>` on stderr and the launch goes on.
- Before the last line, stdout holds `folder=<absolute path>` and `repo=<url or none>`. The last line is the base session name.

### Stop one project

```bash
./orchestration/lib/dispatch-task.sh --teardown-project <absolute-folder>
```

This stops the orchestrator of one project. It kills that project's tmux sessions (the base session and its grouped client sessions) by exact name. It never ends the tmux server and never touches another project. Worktrees, branches and the state database stay. To bring the workers back, launch the project again and run `orchestration/lib/dispatch-task.sh --resume`.

- Exit code 0 means the command ran, including when it found no session. Exit code 1 means it refused the folder (not absolute, or not an existing directory).
- The folder is not checked against a real project. Any absolute existing folder whose name gives the same session name stops that project.
- Known races: the command exits 0 even if one kill failed (the failed session is missing from the printed list), and a session that appears after the list is not stopped.

### Notion-sourced tasks

Session 1 in Orchestration mode shows the project's open Notion tasks (Status `Not started`/`In progress`) at launch. Naming a task in plain language flips its Status to `In progress`, so it drops off other sessions' lists, then hands it off using the same drafted-prompt shape as ad-hoc tasks. With zero open tasks it falls back to drafting mode. See [orchestration/prompts/task-drafting-mode.md](orchestration/prompts/task-drafting-mode.md).

### Monitoring

Query state directly anytime:

```bash
sqlite3 .claude/session-state.db "SELECT agent_id, status, retry_count FROM sessions;"
```

Status values: `running`, `blocked`, `done`, `merged`, `stalled`, `dead`.

Stop a worker: `./orchestration/lib/dispatch-task.sh --kill <label>`.

### Merging finished work

```bash
./orchestration/merge-review.sh                          # list sessions with status
./orchestration/merge-review.sh <label>                  # diff summary + commits for session/<label>
./orchestration/merge-review.sh <label> --merge          # conflict check + confirmation, then merge
./orchestration/merge-review.sh <label> --merge --yes    # same, non-interactive (used by orchestrated dispatch)
```

`--merge` exits `0` on a clean merge+cleanup, `2` when the merge succeeded but wrap-up cleanup (worktree/branch removal) was deferred, and `1` on failure -- check `$?` directly. Piping the invocation (e.g. `... --yes | tail -25`) silently discards that exit code, since `tail`'s own status wins the pipeline. Run `set -o pipefail` first, check `${PIPESTATUS[0]}`, or verify end state with `git worktree list` + `git branch --list`.

### Tests

```bash
bash test/test-merge-review.sh    # likewise the other test/test-*.sh
```

## Architecture

```
launch-claude.sh / promote-session.sh
        |
        v
orchestrator session (Session 1) --drafts prompt--> dispatch-task.sh <label> <title>
        ^                                                  |
        | SendMessage                                      +-> git worktree + session/<label> branch
        |                                                  +-> tmux window, no tab (Claude Code worker)
        |                                                  +-> writes session-state.db
worker sessions --------------------------------------------+
        ^
        +-- dispatch-task.sh --blocked-sweep (launchd) prunes dead gate holds, notifies;
        +-- Helm (orchestrator-gui) shows them as hold cards, answers on a press
```

`dispatch-task.sh` is the one place worker-launch logic lives; its other modes (`--kill`, `--status-board`, `--resume`, `--blocked-sweep`, `--add-dependency`, `--pending-dependents`, ...) serve the orchestrator and the approval relay. Dispatch creates a tmux window and no tab. The app's view is how you look at a worker. `--status-board` feeds the `/workers` board, and `--resume` restarts the live workers after a reboot (see [docs/approval-relay-setup.md](docs/approval-relay-setup.md)). Shared state helpers live in `orchestration/lib/session-state.sh`.

## Design philosophy

- No third-party multi-agent framework -- everything is scripted against `git worktree`, `tmux`, the `claude` CLI and native macOS automation
- Automation fails safe: on any uncertainty, log loudly and leave things alone rather than guess
- Conflicts, merges, and anything hard to reverse always surface to you -- never auto-resolved

## License

MIT -- see [LICENSE](LICENSE).
