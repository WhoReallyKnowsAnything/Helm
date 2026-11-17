#!/usr/bin/env bash
set +o posix
# launch-claude.sh
# Claude Session
#   Ask: Root Dir Mode  OR  Project Mode
#     Project Mode: New Project | Existing Project
#       New Project: create dir, optionally auto-run /cadence:cad-new-project
#       Existing: pick from /Documents/Projects list
#   Conversation: new / resume
#
# Non-interactive start (the orchestrator-gui app):
#   launch-claude.sh --gui-folder <absolute-folder> [--resume <id>] --env-file <file>
#   launch-claude.sh --gui-root [--resume <id>] --env-file <file>
#   launch-claude.sh --gui-new <name> --github private|public|skip --env-file <file>
# --gui-root is interactive option 1 (Root Dir Mode): a plain solo session in ~
# with no orchestration, no git check and the user's default model. It takes no
# --gui-folder. The exit codes, stdout line and env file rules below are the same.
# --gui-new is interactive New Project without the prompts. It creates
# $PROJECTS_DIR/<name> (<name> matches ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$), then
# goes on as --gui-folder on it. All three flags are required, each with a value;
# --gui-new, --gui-folder and --gui-root exclude each other. The steps: git init;
# scaffold (.gitignore, .claudeignore, README.md, .env.example, .claude/settings.json);
# MemPalace wing (skipped when NO_MEMPALACE=1); one commit; gh repo create for
# private or public (git and gh must be on the env file's PATH, gh not for skip);
# Notion Projects row (skipped when NO_NOTION=1). Exit 1 is any validation failure
# (nothing is created). Exit 4: $PROJECTS_DIR/<name> already exists (file or
# directory). Exit 5: git init, the scaffold or the commit failed; stderr names the
# step and the folder, and the folder stays. MemPalace, GitHub and Notion failures
# only print `warning: <step>: <reason>` on stderr. Before the last line, stdout holds
# `folder=<absolute path>` and `repo=<url or none>`. PROJECTS_DIR comes from the env
# file, else the environment, else ~/Documents/Projects.
# --resume <id> (with --gui-root or --gui-folder only) starts the dashboard on a past
# conversation. <id> matches ^[0-9a-f-]{36}$ and its transcript
# ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug>/<id>.jsonl is not empty (<slug>: the
# folder's pwd -P, every non-alphanumeric character replaced by -), else exit 1.
# --gui-folder stores the id in .claude/orchestrator-session-id, so later starts
# resume it too. The out log and the inbox are emptied in place, then the out log
# gets the conversation's user and assistant records (stream-json shape) and one
# result line. A running base session is not reused: only its dashboard pane
# restarts (exit 0), and its other windows keep running.
# The flags above are the only trigger (never an environment variable). No
# prompt, no stdin, no tty, no iTerm attach, no watchdog. The folder is an
# existing git repository top level or a linked worktree of one; a linked
# worktree starts the session of its main repository.
#   Exit 0  started a new base session
#   Exit 3  the base session already existed and was reused
#   Exit 1  failed, the reason is on stderr, no session was created
# On exit 0 and 3 the LAST stdout line is the base session name.
# The base session carries CLAUDE_GUI=1 (set before the dashboard pane starts;
# it never enters the tmux global environment).
# The env file holds the app's captured environment as KEY=VALUE records, as
# `env` prints them. It is untrusted text: only read, never sourced or
# evaluated, and no value reaches an argv or a temp file. A line that starts
# with NAME= (a letter or underscore, then letters, digits or underscores)
# begins a record; every other line continues the previous record, joined by
# one newline. Known limit: a continuation line that itself looks like NAME=...
# is read as a new record, and a record whose name has other characters (an
# exported bash function) is read as a continuation; a zsh `env` holds neither.
# Its PATH replaces this script's PATH (--gui-new also reads PROJECTS_DIR from
# it). Its variables are set in the new base session only; when this start
# creates the tmux server they also become that server's global environment
# (the user's own environment), and a server that already runs is left
# untouched. An existing base session is not given them.

PYTHON_CMD="/opt/anaconda3/bin/python3"
if [[ ! -x "$PYTHON_CMD" ]]; then
    PYTHON_CMD=$(which python3 2>/dev/null || echo "python3")
fi

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Documents/Projects}"

# Task dispatch functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MemPalace hub: start it before any session so it takes the writer lease before a stdio
# mempalace-mcp does. Never blocks the launch; warns on stderr when the hub is still down.
if [[ -f "$SCRIPT_DIR/lib/mempalace-hub-check.sh" ]]; then
    source "$SCRIPT_DIR/lib/mempalace-hub-check.sh" 2>/dev/null && { mempalace_hub_ensure || mempalace_hub_warning >&2; }
fi

list_projects() {
    project_dirs=()
    if [[ -d "$PROJECTS_DIR" ]]; then
        while IFS= read -r d; do
            [[ -d "$d" ]] && project_dirs+=("$(basename "$d")")
        done < <(find "$PROJECTS_DIR" -maxdepth 1 -mindepth 1 -type d | sort)
    fi
}

pick_project() {
    # Populates PICKED_DIR
    list_projects
    if [[ ${#project_dirs[@]} -eq 0 ]]; then
        echo "  No projects found in $PROJECTS_DIR."
        PICKED_DIR="$HOME"
        return
    fi
    echo ""
    for idx in "${!project_dirs[@]}"; do
        printf "  %2d) %s\n" "$((idx+1))" "${project_dirs[$idx]}"
    done
    read -rp "Select project (1-${#project_dirs[@]}): " pidx
    if [[ "$pidx" -ge 1 && "$pidx" -le ${#project_dirs[@]} ]] 2>/dev/null; then
        PICKED_DIR="$PROJECTS_DIR/${project_dirs[$((pidx-1))]}"
    else
        echo "  Invalid – using first project."
        PICKED_DIR="$PROJECTS_DIR/${project_dirs[0]}"
    fi
}

# Shared by the interactive New Project path and --gui-new. Each runs inside the new git repository.
scaffold_project() {
    local proj_name="$1"
    # .gitignore
    if [[ -f "$HOME/.claude/templates/gitignore" ]]; then
        cp "$HOME/.claude/templates/gitignore" .gitignore
    else
        cat > .gitignore <<'GITIGNORE'
.env
.env.local
node_modules/
__pycache__/
*.pyc
.DS_Store
dist/
build/
.venv/
GITIGNORE
    fi
    echo ".symdex/" >> .gitignore
    echo "  .gitignore created"

    # .claudeignore
    if [[ -f "$HOME/.claude/templates/claudeignore" ]]; then
        cp "$HOME/.claude/templates/claudeignore" .claudeignore
        echo "  .claudeignore added"
    fi

    # README.md
    echo "# $proj_name" > README.md
    echo "  README.md created"

    # .env.example
    echo "# Environment variables — copy to .env and fill in values" > .env.example
    echo "  .env.example created"

    # .claude/settings.json (project-level)
    mkdir -p .claude
    cat > .claude/settings.json <<'CLAUDEJSON'
{
  "permissions": {
    "allow": [],
    "deny": []
  }
}
CLAUDEJSON
    echo "  .claude/settings.json created"
}

seed_mempalace() {
    local proj_name="$1" rc=0
    if command -v mempalace >/dev/null; then
        mempalace mine "$PWD" --wing "$proj_name" --daemon --background >/dev/null 2>&1 || rc=$?
        if (( rc == 0 )); then
            echo "  MemPalace wing seeded"
        else
            echo "  Warning: MemPalace mine failed, wing not seeded" >&2
        fi
    fi
    return $rc
}

commit_initial_scaffold() {
    git add -A
    git commit -q -m "chore: initial project scaffold"
    echo "  Initial commit"
}

# create_github_repo name private|public: sets gh_repo_url
create_github_repo() {
    local proj_name="$1" visibility="$2"
    if gh repo create "$proj_name" --"$visibility" --source=. --remote=origin --push >/dev/null 2>&1; then
        echo "  GitHub: $visibility repo created"
        gh_repo_url=$(git config --get remote.origin.url 2>/dev/null | tr -d '\n')
    else
        echo "  GitHub: failed (check: gh auth status)"
        return 1
    fi
}

# load_notion_config: the Notion data source IDs belong to the user's own workspace, so they are
# never in this repo. Env vars win; else notion.env in the Helm support folder (KEY=VALUE lines,
# read with sed, never sourced). A value that is not a UUID counts as unset. Unset = Notion off.
load_notion_config() {
    local f="${HELM_SUPPORT_DIR:-$HOME/Library/Application Support/Helm}/notion.env" k v
    local id_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    for k in HELM_NOTION_PROJECTS_DS_ID HELM_NOTION_TASKS_DS_ID; do
        v="${!k:-}"
        if [[ -z "$v" && -r "$f" ]]; then v="$(sed -n "s/^$k=//p" "$f" | tail -1 | tr -d "\"' \r")"; fi
        if [[ "$v" =~ $id_re ]]; then printf -v "$k" '%s' "$v"; else printf -v "$k" '%s' ""; fi
    done
}

# create_notion_project_row name [repo_url]: returns 1 when no row was created or found
create_notion_project_row() {
    local proj_name="$1" gh_repo_url="${2-}"
    load_notion_config
    _notion_token=$(jq -r '.mcpServers.notionApi.env.NOTION_TOKEN // empty' "$HOME/.claude.json" 2>/dev/null)
    if [[ -z "$HELM_NOTION_PROJECTS_DS_ID" ]]; then
        echo "  Notion: skipped (HELM_NOTION_PROJECTS_DS_ID not configured)"
        return 1
    elif [[ -z "$_notion_token" ]]; then
        echo "  Notion: skipped (NOTION_TOKEN not configured)"
        return 1
    else
        _notion_ds_id="$HELM_NOTION_PROJECTS_DS_ID"
        _notion_ver="2025-09-03"
        
        # Check if project already exists
        _query_payload=$(jq -n --arg proj "$proj_name" '{filter: {property: "Project name", title: {equals: $proj}}}')
        _query_resp=$(NOTION_API_TOKEN="$_notion_token" ntn api "v1/data_sources/$_notion_ds_id/query" -d "$_query_payload" --notion-version "$_notion_ver" 2>/dev/null)
        
        _existing=$(echo "$_query_resp" | jq -r '.results[0].id // empty' 2>/dev/null)
        
        if [[ -n "$_existing" ]]; then
            echo "  Notion: project row already exists"
        else
            # Build properties with optional Repo URL
            _props="{\"Project name\": {\"title\": [{\"text\": {\"content\": \"$proj_name\"}}]}}"
            if [[ -n "$gh_repo_url" ]]; then
                _props=$(echo "$_props" | jq --arg url "$gh_repo_url" '."Repo URL" = {"url": $url}')
            fi
            
            # Create page
            _create_payload=$(jq -n --arg ds "$_notion_ds_id" --argjson p "$_props" '{
                parent: {type: "data_source_id", data_source_id: $ds},
                icon: {type: "emoji", emoji: "🏗️"},
                properties: $p
            }')
            
            _create_resp=$(NOTION_API_TOKEN="$_notion_token" ntn api v1/pages -d "$_create_payload" --notion-version "$_notion_ver" 2>/dev/null)
            
            if echo "$_create_resp" | jq -e '.id' >/dev/null 2>&1; then
                echo "  Notion: project row created"
            else
                echo "  Notion: failed (check NOTION_TOKEN / network)"
                return 1
            fi
        fi
    fi
}


# NON-INTERACTIVE MODE: parse and validate before any tmux or state side effect
GUI_MODE=false
_gui_folder="" _gui_env="" _gui_folder_set=false _gui_env_set=false _gui_root=false
_gui_new="" _gui_github="" _gui_new_set=false _gui_resume="" _gui_resume_set=false _resume_id=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gui-root) _gui_root=true ;;
        --gui-folder) _gui_folder_set=true; _gui_folder="${2-}"; [[ $# -gt 1 ]] && shift ;;
        --gui-new) _gui_new_set=true; _gui_new="${2-}"; [[ $# -gt 1 ]] && shift ;;
        --github) _gui_github="${2-}"; [[ $# -gt 1 ]] && shift ;;
        --env-file) _gui_env_set=true; _gui_env="${2-}"; [[ $# -gt 1 ]] && shift ;;
        --resume) _gui_resume_set=true; _gui_resume="${2-}"; [[ $# -gt 1 ]] && shift ;;
    esac
    shift
done
if [[ "$_gui_folder_set" == true || "$_gui_env_set" == true || "$_gui_root" == true || "$_gui_new_set" == true || "$_gui_resume_set" == true ]]; then
    GUI_MODE=true
    _gui_fail() { echo "Error: $1" >&2; exit 1; }
    if [[ "$_gui_new_set" == true ]]; then
        [[ "$_gui_folder_set" == false && "$_gui_root" == false ]] \
            || _gui_fail "--gui-new, --gui-folder and --gui-root exclude each other"
        [[ -n "$_gui_new" && -n "$_gui_github" && -n "$_gui_env" ]] \
            || _gui_fail "--gui-new, --github and --env-file are required together, each with a value"
        _gui_name_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
        [[ "$_gui_new" =~ $_gui_name_re ]] \
            || _gui_fail "--gui-new must match $_gui_name_re: $_gui_new"
        [[ "$_gui_github" == private || "$_gui_github" == public || "$_gui_github" == skip ]] \
            || _gui_fail "--github must be private, public or skip: $_gui_github"
    elif [[ "$_gui_root" == true ]]; then
        [[ "$_gui_folder_set" == false && -n "$_gui_env" ]] \
            || _gui_fail "--gui-root takes --env-file with a value and no --gui-folder"
        _gui_folder="$HOME"
    else
        [[ -n "$_gui_folder" && -n "$_gui_env" ]] \
            || _gui_fail "--gui-folder and --env-file are required together, each with a value"
    fi
    [[ "$_gui_new_set" == true || ( "$_gui_folder" == /* && -d "$_gui_folder" ) ]] \
        || _gui_fail "--gui-folder must be an absolute path to an existing directory: $_gui_folder"
    if [[ "$_gui_resume_set" == true ]]; then
        [[ "$_gui_new_set" == false ]] || _gui_fail "--resume is valid with --gui-root or --gui-folder only"
        [[ "$_gui_resume" =~ ^[0-9a-f-]{36}$ ]] || _gui_fail "--resume must match ^[0-9a-f-]{36}\$: $_gui_resume"
        _resume_slug="$(cd "$_gui_folder" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
        _resume_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$_resume_slug/$_gui_resume.jsonl"
        [[ -s "$_resume_file" ]] || _gui_fail "--resume $_gui_resume has no transcript: $_resume_file"
        _resume_id="$_gui_resume"
    fi
    [[ -f "$_gui_env" && -r "$_gui_env" ]] \
        || _gui_fail "--env-file is not a readable file: $_gui_env"
    source "$SCRIPT_DIR/lib/tmux-session.sh" 2>/dev/null \
        || _gui_fail "cannot load $SCRIPT_DIR/lib/tmux-session.sh"
    # the env file's PATH is the only value this process takes from the file
    if _gui_path="$(env_file_value "$_gui_env" PATH)"; then
        PATH="$_gui_path"
        hash -r
    fi
    type -P tmux >/dev/null 2>&1 || _gui_fail "tmux not found on the env file's PATH"
    [[ -z "$_resume_id" ]] || type -P jq >/dev/null 2>&1 || _gui_fail "jq not found on the env file's PATH (needed for --resume)"
    # --resume history for the out log (jq keeps text as data), built before any state write
    if [[ -n "$_resume_id" ]]; then
        _resume_seed="$(jq -cn --arg sid "$_resume_id" '
            [inputs] as $r
            | ([$r[] | select(.cwd) | .cwd] | first) as $cwd
            | ({type: "system", subtype: "init", session_id: $sid} + (if $cwd then {cwd: $cwd} else {} end)),
            ($r[] | select((.type == "user" and (.isMeta | not) and (.isSidechain | not))
                          or (.type == "assistant" and (.isSidechain | not)))
             | if .type == "user" then {type: "user", isReplay: true, session_id: $sid, message: .message}
               else {type: "assistant", session_id: $sid, message: .message} end),
            {type: "result", subtype: "success", session_id: $sid}' "$_resume_file" 2>&1)" \
            || _gui_fail "cannot read the transcript $_resume_file: ${_resume_seed:0:200}"
    fi
    if [[ "$_gui_new_set" == true ]]; then
        type -P git >/dev/null 2>&1 || _gui_fail "git not found on the env file's PATH"
        [[ "$_gui_github" == skip ]] || type -P gh >/dev/null 2>&1 \
            || _gui_fail "gh not found on the env file's PATH (needed unless --github skip)"
        if _gui_projects="$(env_file_value "$_gui_env" PROJECTS_DIR)"; then
            PROJECTS_DIR="$_gui_projects"
        fi
        [[ "$PROJECTS_DIR" == /* ]] || _gui_fail "PROJECTS_DIR must be an absolute path: $PROJECTS_DIR"
        _gui_folder="$PROJECTS_DIR/$_gui_new"
    elif [[ "$_gui_root" != true ]]; then
        _gui_top="$(command git -C "$_gui_folder" rev-parse --show-toplevel 2>/dev/null)" \
            || _gui_fail "cannot read git information for $_gui_folder (git missing or not a repository)"
        [[ "$(cd "$_gui_top" && pwd -P)" == "$(cd "$_gui_folder" && pwd -P)" ]] \
            || _gui_fail "the folder is not the top level of a git repository or linked worktree: $_gui_folder"
    fi
    [[ -n "$(tmux_base_session_name "$_gui_folder")" ]] \
        || _gui_fail "no session name can be made from the folder name: $_gui_folder"
    if [[ "$_gui_new_set" == true && ( -e "$_gui_folder" || -L "$_gui_folder" ) ]]; then
        echo "Error: $_gui_folder already exists" >&2
        exit 4
    fi
fi

# --gui-new: create the project (steps 1-6), then go on as --gui-folder on it.
# Steps 1, 2 and 4 must work (exit 5, the folder stays); 3, 5 and 6 only warn.
if [[ "$_gui_new_set" == true ]]; then
    _gui_new_fail() { echo "Error: step $1 failed in $_gui_folder" >&2; exit 5; }
    _gui_warn() { echo "warning: $1: $2" >&2; }
    exec </dev/null
    gh_repo_url=""
    mkdir -p "$_gui_folder" && git -C "$_gui_folder" init -q || _gui_new_fail "1 (git init)"
    pushd "$_gui_folder" >/dev/null || _gui_new_fail "1 (git init)"
    ( set -e; scaffold_project "$_gui_new" ) >/dev/null
    (( $? == 0 )) || _gui_new_fail "2 (scaffold)"
    if [[ "${NO_MEMPALACE:-}" != 1 ]]; then
        seed_mempalace "$_gui_new" >/dev/null || _gui_warn mempalace "mempalace mine failed"
    fi
    ( set -e; commit_initial_scaffold ) >/dev/null
    (( $? == 0 )) || _gui_new_fail "4 (commit)"
    if [[ "$_gui_github" != skip ]]; then
        create_github_repo "$_gui_new" "$_gui_github" >/dev/null \
            || _gui_warn github "gh repo create failed (check: gh auth status)"
    fi
    if [[ "${NO_NOTION:-}" != 1 ]]; then
        create_notion_project_row "$_gui_new" "$gh_repo_url" >/dev/null \
            || _gui_warn notion "project row not created (NOTION_TOKEN not configured, or the request failed)"
    fi
    popd >/dev/null
    printf 'folder=%s\nrepo=%s\n' "$_gui_folder" "${gh_repo_url:-none}"
fi

# CLAUDE SESSION

if [[ "$GUI_MODE" != true ]]; then
echo ""
echo "│           CLAUDE SESSION                │"
echo ""
echo "Mode:"
echo "  1) Root Dir Mode  (~)"
echo "  2) Project Mode"
read -rp "Enter 1-2: " claude_mode

TARGET_DIR="$HOME"
AUTO_CADENCE=false
ROOT_MODE=false

case "$claude_mode" in
    2)
        echo ""
        echo "Project:"
        echo "  1) New Project"
        echo "  2) Existing Project"
        read -rp "Enter 1-2: " project_mode

        case "$project_mode" in
            1)
                read -rp "Project name: " proj_name
                if [[ -n "$proj_name" ]]; then
                    TARGET_DIR="$PROJECTS_DIR/$proj_name"
                    mkdir -p "$TARGET_DIR"
                    cd "$TARGET_DIR"

                    # git
                    git init -q
                    echo "  git init"

                    scaffold_project "$proj_name"

                    seed_mempalace "$proj_name"

                    commit_initial_scaffold

                    # GitHub repo
                    echo ""
                    echo "  Create GitHub repo?"
                    echo "    1) Private"
                    echo "    2) Public"
                    echo "    3) Skip"
                    read -rp "  Enter 1-3: " gh_choice
                    gh_repo_url=""
                    case "$gh_choice" in
                        1)
                            create_github_repo "$proj_name" private
                            ;;
                        2)
                            create_github_repo "$proj_name" public
                            ;;
                        *)
                            echo "  GitHub: skipped"
                            ;;
                    esac

                    create_notion_project_row "$proj_name" "$gh_repo_url"

                    # Index with SymDex
                    SYMDEX_STATE_DIR=.symdex symdex index . --repo "$proj_name" >/dev/null 2>&1
                    echo "  Indexed with SymDex"

                    echo ""
                    echo "  Created: $TARGET_DIR"
                    AUTO_CADENCE=true
                else
                    echo "  No name given – using home."
                fi
                ;;
            2)
                echo ""
                echo "Projects in $PROJECTS_DIR:"
                pick_project
                TARGET_DIR="$PICKED_DIR"
                ;;
            *)
                echo "  Invalid – using home."
                ROOT_MODE=true
                ;;
        esac
        ;;
    *)
        TARGET_DIR="$HOME"
        ROOT_MODE=true
        ;;
esac

echo ""
echo "  Claude session dir: $TARGET_DIR"

# Orchestration or solo mode selection (D-01) -- skipped in Root Dir Mode,
# which is always a plain solo session
if [[ "$ROOT_MODE" == true ]]; then
    ORCHESTRATION_MODE=false
else
    read -rp "Orchestration or solo session? (1=Orchestration, 2=Solo, default Orchestration): " session_mode_choice
    case "$session_mode_choice" in
        2) ORCHESTRATION_MODE=false ;;
        *) ORCHESTRATION_MODE=true ;;
    esac
fi
else
    # Non-interactive mode: no prompt, no auto-cadence. --gui-folder: orchestration.
    # --gui-root: the plain solo session in ~ (interactive option 1).
    TARGET_DIR="$_gui_folder"
    AUTO_CADENCE=false
    ROOT_MODE="$_gui_root"
    ORCHESTRATION_MODE=true
    [[ "$_gui_root" == true ]] && ORCHESTRATION_MODE=false
fi

# Where project state lives: the folder itself, except in non-interactive mode,
# where a linked worktree holds no state of its own and the main repository does
# (found through --git-common-dir, as session-state.sh and init-state-store.sh do).
_state_root="$TARGET_DIR"
if [[ "$GUI_MODE" == true ]] && _gui_common="$(command git -C "$TARGET_DIR" rev-parse --git-common-dir 2>/dev/null)"; then
    _state_root="$(cd "$TARGET_DIR" && cd "$_gui_common/.." && pwd)"
fi

# Initialize state store once per invocation (D-02/D-03 guarded by ORCHESTRATION_MODE)
if [[ "$ORCHESTRATION_MODE" == true ]]; then
    if [[ -d "$_state_root/.git" ]]; then
        _orch_root="$(cd "$SCRIPT_DIR/.." && pwd)"
        mkdir -p "$_state_root/.claude"
        echo "$_orch_root" > "$_state_root/.claude/orchestrator-root"
        if ! "$SCRIPT_DIR/init/init-state-store.sh" "$_state_root" 2>/dev/null; then
            echo "  [state-store] Warning: Could not initialize state store" >&2
        else
            echo "  [state-store] Initialized"
        fi
        
        # Source helper library (fail-safe: skip writes if unavailable)
        if ! source "$SCRIPT_DIR/lib/session-state.sh" 2>/dev/null; then
            echo "  [state-store] Warning: Could not source helper library, session state writes disabled" >&2
            STATE_STORE_ENABLED=false
        else
            STATE_STORE_ENABLED=true
        fi
    else
        STATE_STORE_ENABLED=false
    fi
else
    # Solo mode: zero-footprint gate (D-03)
    STATE_STORE_ENABLED=false
fi

# tmux helper library (unconditional -- applies to every launch, both
# Orchestration and Solo mode, per D-01/D-02; NOT nested in the block above)
if ! source "$SCRIPT_DIR/lib/tmux-session.sh" 2>/dev/null; then
    echo "  [tmux] Warning: Could not source tmux helper library" >&2
    TMUX_HELPER_ENABLED=false
else
    TMUX_HELPER_ENABLED=true
    BASE_SESSION="$(tmux_base_session_name "$TARGET_DIR")"
fi

# Multi-session prompt for project sessions (D-02 guarded by ORCHESTRATION_MODE)
EXTRA_SESSION_LABELS=()

# Conversation selection. Orchestration seeds Session 1 with the Notion task-list
# prompt (D-03, NOTION-01) and pins the conversation to a stored id, so a relaunch
# resumes it. Not `--continue`: that picks the newest conversation in the directory,
# which may belong to another session. A stored id with no transcript starts new.
CONV_ARG=""
SEED_PROMPT=""   # headless (D-07): sent as the first inbox line, not as an argument
NOTION_CFG_ARG=""   # the Notion IDs reach the prompt here, never from the repo
if [[ "$ORCHESTRATION_MODE" == true ]]; then
    load_notion_config
    if [[ -n "$HELM_NOTION_PROJECTS_DS_ID" && -n "$HELM_NOTION_TASKS_DS_ID" ]]; then
        SEED_PROMPT="Show my open Notion tasks for this project."
        NOTION_CFG_ARG=" --append-system-prompt $(printf '%q' "Helm Notion config. Projects data source ID: $HELM_NOTION_PROJECTS_DS_ID. Tasks data source ID: $HELM_NOTION_TASKS_DS_ID.")"
    fi
    if [[ -d "$_state_root/.git" ]]; then
        _sid_file="$_state_root/.claude/orchestrator-session-id"
        # --resume (checked above): store the picked id, so the check below resumes it
        if [[ -n "$_resume_id" ]]; then
            mkdir -p "$_state_root/.claude" && echo "$_resume_id" > "$_sid_file" \
                || { echo "Error: could not write $_sid_file" >&2; exit 1; }
        fi
        _sid="$(cat "$_sid_file" 2>/dev/null)"
        _slug="$(cd "$TARGET_DIR" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
        if [[ "$_sid" =~ ^[0-9a-f-]{36}$ && -s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$_slug/$_sid.jsonl" ]]; then
            CONV_ARG="--resume $_sid"
            SEED_PROMPT=""
        else
            _sid="$(uuidgen | tr 'A-Z' 'a-z')"
            mkdir -p "$_state_root/.claude" && echo "$_sid" > "$_sid_file"
            CONV_ARG="--session-id $_sid"
        fi
    fi
fi
[[ "$ROOT_MODE" == true && -n "$_resume_id" ]] && CONV_ARG="--resume $_resume_id"

# Conditional model flag (D-05/D-06): Opus for Orchestration mode only;
# Root Dir Mode uses the user's configured default model (no --model flag)
HEADLESS_FLAGS="-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --replay-user-messages"
ORCH_NAME="$(orch_session_name "$TARGET_DIR")"
if [[ "$ROOT_MODE" == true ]]; then
    CLAUDE_CMD="claude $HEADLESS_FLAGS"
    [[ " $CLAUDE_CMD " == *" -p "* ]] && CLAUDE_CMD="$CLAUDE_CMD --permission-prompt-tool stdio"
elif [[ "$ORCHESTRATION_MODE" == true ]]; then
    CLAUDE_CMD="claude $HEADLESS_FLAGS --name $ORCH_NAME --model opus[1m]"
    # --permission-prompt-tool is only valid with -p (Phase 4 D-01, D-12)
    [[ " $CLAUDE_CMD " == *" -p "* ]] && CLAUDE_CMD="$CLAUDE_CMD --permission-prompt-tool stdio"
    # Phase 12: Append task-drafting-mode system prompt
    CLAUDE_CMD="$CLAUDE_CMD --append-system-prompt-file $(printf '%q' "$SCRIPT_DIR/prompts/task-drafting-mode.md")$NOTION_CFG_ARG"
    # /clear hook, registered for Session 1 only; a missing script exits 0 (never blocks)
    _clear_hook="$SCRIPT_DIR/hooks/orchestrator-clear.sh"
    CLAUDE_CMD="$CLAUDE_CMD --settings '{\"hooks\":{\"SessionStart\":[{\"matcher\":\"clear\",\"hooks\":[{\"type\":\"command\",\"command\":\"[ -x \\\"$_clear_hook\\\" ] && \\\"$_clear_hook\\\" || true\",\"timeout\":10}]}]}}'"
else
    CLAUDE_CMD="claude $HEADLESS_FLAGS --model sonnet[1m]"
fi

# Headroom proxy
HEADROOM_ENV_PREFIX=""
HEADROOM_PROXY_ARGS="--port 8787"
if command -v headroom &>/dev/null; then
    HEADROOM_ENV_PREFIX="ANTHROPIC_BASE_URL=http://localhost:4444"
fi

# Build main command
main_cmd="$CLAUDE_CMD $CONV_ARG"
# CLAUDE_IN_TMUX: breadcrumb for promote-session.sh, since TMUX itself is
# stripped below -- Claude Code drops to 256-colour output when it sees TMUX
env_part="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_IN_TMUX=1"
# Marks Orchestration Session 1 for orchestrator-clear.sh (never set for Solo/Root)
[[ "$ORCHESTRATION_MODE" == true ]] && env_part="$env_part ORCH_SESSION1=1"

CLAUDE_TITLE="Main Session - Claude Code"
$AUTO_CADENCE && CLAUDE_TITLE="$CLAUDE_TITLE [new project – /cadence:cad-new-project]"

# LAUNCH

echo ""
echo "Launching session..."

# ---- Repowire daemon ----
if command -v repowire &>/dev/null; then
    if ! repowire status &>/dev/null; then
        echo "  Starting repowire daemon..."
        repowire setup --daemon &>/dev/null &
        sleep 0.5
    fi
fi

# ---- Claude session ----
if [[ "$TMUX_HELPER_ENABLED" != true ]]; then
    echo "Error: tmux helper library unavailable -- cannot launch a phone-reachable session." >&2
    exit 1
fi

_gui_reused=false _gui_restarted=false
# The dashboard pane's start script (a new base session and a --resume restart)
_write_tmp_claude() {
    HEADLESS_PIPE="$(tmux_headless_cmd "$_sf_inbox" "$_sf_out" "env -u TMUX TERM=xterm-256color $env_part $HEADROOM_ENV_PREFIX $main_cmd")"
    TMP_CLAUDE=$(mktemp -t claude-session)
    chmod +x "$TMP_CLAUDE"

    cat > "$TMP_CLAUDE" <<SCRIPT
#!/bin/bash
printf '\033]0;${CLAUDE_TITLE}\007'
$(if [[ -n "$HEADROOM_ENV_PREFIX" ]]; then
    printf '%s\n' "headroom proxy $HEADROOM_PROXY_ARGS &>/dev/null &"
    printf '%s\n' 'HEADROOM_PID=$!'
    printf '%s\n' 'trap "kill $HEADROOM_PID 2>/dev/null" EXIT'
    printf '%s\n' 'sleep 0.5'
fi)
claude update >/dev/null 2>&1 || true
rm -- "\$0"
cd $(printf '%q' "$TARGET_DIR") && ${HEADLESS_PIPE}
SCRIPT
}
# --resume: empty the out log and the inbox in place (a running tail -f keeps its
# file), then write the picked conversation's history into the out log
_resume_reset() {
    : > "$_sf_out" && : > "$_sf_inbox" && printf '%s\n' "$_resume_seed" >> "$_sf_out" \
        || { echo "Error: could not reset the session files in $_sf_dir" >&2; exit 1; }
}
# --resume on a running base session: restart only its dashboard pane. A placeholder
# replaces the old pipeline first, so the old claude is gone before the reset, and
# the new tail starts after it. Other windows keep running.
_resume_restart_dashboard() {
    local pane="=$BASE_SESSION:=dashboard" old i rec text
    old="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
    [[ "$old" =~ ^[0-9]+$ ]] || _gui_fail "tmux session '$BASE_SESSION' has no dashboard window"
    tmux respawn-pane -k -t "$pane" 'exec sleep 2147483647' 2>/dev/null \
        || _gui_fail "could not stop the dashboard pane of '$BASE_SESSION'"
    # the pane process leads its own process group, and the pipeline shares it
    for ((i = 0; i < 100; i++)); do kill -0 -- "-$old" 2>/dev/null || break; sleep 0.1; done
    kill -0 -- "-$old" 2>/dev/null && _gui_fail "the old dashboard claude did not stop (process group $old)"
    session_files_create "$_state_root" dashboard \
        || _gui_fail "could not create session files in $_sf_dir"
    _resume_reset
    _write_tmp_claude
    # same folder, env file records and marker as a new base session; the env file
    # values go through tmux command text on stdin, never an argv
    text="respawn-pane -k -t $(_tmux_dq "$pane") -c $(_tmux_dq "${TARGET_DIR//#/##}")"
    while IFS= read -r -d '' rec; do
        [[ "${rec%%=*}" =~ ^ITERM_[A-Za-z0-9_]*$ ]] || text="$text -e $(_tmux_dq "$rec")"
    done < <(env_file_records "$_gui_env")
    text="$text -e CLAUDE_GUI=1 $(_tmux_dq "bash '$TMP_CLAUDE'")"
    printf '%s\n' "$text" | (_tmux_client "$(type -P tmux)" "$_gui_env" "${TMUX_TMPDIR+x}" "${TMUX_TMPDIR-}" "${ORCH_TMUX_SOCKET-}") 2>/dev/null \
        || { rm -f "$TMP_CLAUDE"; _gui_fail "could not restart the dashboard pane of '$BASE_SESSION'"; }
    echo "  Restarted the dashboard of tmux session '$BASE_SESSION' on conversation $_resume_id"
    _gui_restarted=true
}
# Headless session files (D-02) for the orchestrator window, under the state root.
# session-state.sh holds the file helpers; solo and root launches need them too.
declare -F session_files_paths >/dev/null || source "$SCRIPT_DIR/lib/session-state.sh" 2>/dev/null \
    || { echo "Error: session file helpers unavailable (lib/session-state.sh)" >&2; exit 1; }
{ read -r _sf_dir; read -r _sf_inbox; read -r _sf_out; } < <(session_files_paths "$_state_root" dashboard) \
    || { echo "Error: could not resolve session file paths" >&2; exit 1; }
if tmux has-session -t "=$BASE_SESSION" 2>/dev/null; then
    if [[ -n "$_resume_id" ]]; then
        _resume_restart_dashboard
    else
        echo "  Reusing existing tmux session '$BASE_SESSION'"
        _gui_reused=true
    fi
else
    # New base session: claude is not running, so the inbox can be emptied (D-09)
    session_files_create "$_state_root" dashboard && session_files_empty_inbox "$_state_root" dashboard \
        || { echo "Error: could not create session files in $_sf_dir" >&2; exit 1; }
    [[ -n "$_resume_id" ]] && _resume_reset
    # Seed (D-07): first inbox line of a new conversation only; --resume leaves SEED_PROMPT empty
    if [[ -n "$SEED_PROMPT" ]]; then
        source "$SCRIPT_DIR/lib/stream-json.sh" \
            && stream_json_user_line "$SEED_PROMPT" >> "$_sf_inbox" \
            || { echo "Error: could not write the seed prompt to $_sf_inbox" >&2; exit 1; }
    fi
    _write_tmp_claude

    # Non-interactive mode: pane folder, env file and the session marker
    _ensure_extra=()
    [[ "$GUI_MODE" == true ]] && _ensure_extra=("$TARGET_DIR" "$_gui_env" CLAUDE_GUI=1)
    if ! tmux_ensure_base_session "$BASE_SESSION" "dashboard" "bash '$TMP_CLAUDE'" "${_ensure_extra[@]}"; then
        rm -f "$TMP_CLAUDE"
        # Non-interactive mode: a concurrent start may have created the session
        # first. Take the reuse path instead of failing.
        if [[ "$GUI_MODE" == true ]] && tmux has-session -t "=$BASE_SESSION" 2>/dev/null; then
            echo "  Reusing existing tmux session '$BASE_SESSION'"
            _gui_reused=true
        else
            echo "Error: failed to create tmux session for phone-reachable launch." >&2
            exit 1
        fi
    fi
fi

# Non-interactive mode, reused session: mark it as app-started. Panes and
# windows that already exist keep the environment they were started with.
if [[ "$GUI_MODE" == true && ( "$_gui_reused" == true || "$_gui_restarted" == true ) ]]; then
    tmux set-environment -t "=$BASE_SESSION" CLAUDE_GUI 1 2>/dev/null \
        || { echo "Error: tmux session '$BASE_SESSION' went away while it was being marked" >&2; exit 1; }
fi

# Write session record for Tab 1 (main/dashboard)
if [[ "$STATE_STORE_ENABLED" == true ]]; then
    if ! ( cd "$TARGET_DIR" && session_state_write "dashboard" "$TARGET_DIR" "running" "$$" ) 2>/dev/null; then
        echo "  [state-store] Warning: Could not write session record for dashboard tab" >&2
    # session_state_write is INSERT OR REPLACE and wipes the path columns: store them after it
    elif ! ( cd "$TARGET_DIR" && session_state_set_session_files "dashboard" "$_sf_inbox" "$_sf_out" ) 2>/dev/null; then
        echo "  [state-store] Warning: Could not store session file paths for dashboard tab" >&2
    fi
fi

# D-13: re-verify pre-existing blocked rows and sweep orphaned tabs at
# launch. Guarded so a sweep failure can never fail the launch itself.
if [[ "$STATE_STORE_ENABLED" == true ]]; then
    ( cd "$TARGET_DIR" && "$SCRIPT_DIR/lib/dispatch-task.sh" --launch-sweep ) >/dev/null 2>&1 || true
fi

# Non-interactive mode ends here: the base name is the last stdout line and
# nothing attaches, watches iTerm or reads stdin.
if [[ "$GUI_MODE" == true ]]; then
    printf '%s\n' "$BASE_SESSION"
    [[ "$_gui_reused" == true ]] && exit 3
    exit 0
fi

# Attach current terminal to the base session as a tmux client (Pattern 1) --
# the grouped-session attach gives independent focus while sharing windows.
_attach_cmd="$(tmux_client_attach_cmd "$BASE_SESSION" dashboard)"
# iTerm quit -> tmux_watchdog_kill: end the tmux server, or only the sessions of projects
# the GUI app did not start when one is marked CLAUDE_GUI. Detach closes the tab too, and
# with QuitWhenAllWindowsClosed that also ends the server -- accepted.
# Detached process on purpose: anything inside the tab dies with the tab.
# ps not pgrep: hardened runtime hides iTerm2 from pgrep entirely, so pgrep
# reported it dead on the first tick and killed the server at launch.
if ! pgrep -f 'orchestrator-iterm-watchdog' >/dev/null 2>&1; then
    nohup bash -c ': orchestrator-iterm-watchdog; while ps -Ao comm= | grep -q "/iTerm2$"; do sleep 5; done; source "$1" && tmux_watchdog_kill' orchestrator-iterm-watchdog "$SCRIPT_DIR/lib/tmux-session.sh" >/dev/null 2>&1 &
    disown
fi

# Title escape from inside the tmux temp script (L353) is swallowed by tmux --
# only one printed here, in the real terminal right before exec, reaches iTerm.
if [[ "$ORCHESTRATION_MODE" == true ]]; then
    printf '\033]0;Orchestrator\007'
else
    printf '\033]0;%s\007' "$(basename "$TARGET_DIR")"
fi
exec bash -c "$_attach_cmd"
