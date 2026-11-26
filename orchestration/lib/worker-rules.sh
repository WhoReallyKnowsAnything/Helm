#!/usr/bin/env bash
# worker-rules.sh -- builds the rules text a worker gets in its SYSTEM prompt.
#
# Why: Claude Code puts CLAUDE.md, ~/.claude/rules and the auto-memory index in
# user message 0, next to the per-worker task text. The prompt cache reads only
# up to the first byte that differs, so those ~15,000 tokens were written again
# for every worker. The same text in the system prompt is identical for every
# worker of a project, so it is read from the cache (docs/orchestrator/
# prompt-cache-report-2026-11-24.md). CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 stops
# Claude Code from adding the same files to message 0 (so each rule appears once).
#
# Sources, in Claude Code's own order: user CLAUDE.md plus its @imports,
# ~/.claude/rules/**/*.md (sorted), ~/.claude/AGENTS.md, then the project's
# CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, .claude/rules/**/*.md, and the
# project's auto-memory MEMORY.md (first 200 lines, as Claude Code loads it).
# No path inside the text depends on the worker (project root only, never the
# worktree), so two workers of one project get identical bytes.
# shortcut: project files are read from the main checkout, not the worker's
# worktree; a branch that edits CLAUDE.md is not seen until it merges.

# _wr_block path description: prints one "Contents of" block, nothing when the
# file is missing or empty. Same wording as Claude Code's own block.
_wr_block() {
    [[ -s "$1" ]] || return 0
    printf 'Contents of %s (%s):\n\n' "$1" "$2"
    cat "$1"
    printf '\n\n'
}
# _wr_with_imports path description: the file, then each "@file" import line.
_wr_with_imports() {
    local f="$1" desc="$2" line imp
    _wr_block "$f" "$desc"
    [[ -r "$f" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^@([^[:space:]]+)$ ]] || continue
        imp="${BASH_REMATCH[1]}"
        [[ "$imp" == "~/"* ]] && imp="$HOME/${imp#\~/}"
        [[ "$imp" == /* ]] || imp="$(dirname "$f")/$imp"
        _wr_block "$imp" "$desc"
    done < "$f"
}
# _wr_dir_rules dir description: every *.md under dir, sorted by path.
_wr_dir_rules() {
    local f
    [[ -d "$1" ]] || return 0
    while IFS= read -r f; do _wr_block "$f" "$2"; done < <(find "$1" -type f -name '*.md' | LC_ALL=C sort)
}
# build_worker_rules_text project_root orch_name: prints the full text.
build_worker_rules_text() {
    local root="$1" orch="$2" home="${HOME:?}" slug mem
    if [[ -n "$orch" ]]; then
        printf 'Your orchestrator session name in the peer roster is: %s. Use exactly this name as the SendMessage target for the orchestrator. Never use the bare name dashboard.\n\n' "$orch"
    fi
    printf 'Codebase and user instructions are shown below. Be sure to adhere to these instructions. IMPORTANT: These instructions OVERRIDE any default behavior and you MUST follow them exactly as written.\n\n'
    _wr_with_imports "$home/.claude/CLAUDE.md" "user's private global instructions for all projects"
    _wr_dir_rules "$home/.claude/rules" "user's private global instructions for all projects"
    _wr_block "$home/.claude/AGENTS.md" "project instructions, checked into the codebase"
    _wr_with_imports "$root/CLAUDE.md" "project instructions, checked into the codebase"
    _wr_with_imports "$root/.claude/CLAUDE.md" "project instructions, checked into the codebase"
    _wr_with_imports "$root/CLAUDE.local.md" "user's private project instructions, not checked in"
    _wr_dir_rules "$root/.claude/rules" "project instructions, checked into the codebase"
    slug="$(printf '%s' "$root" | sed 's/[^A-Za-z0-9]/-/g')"
    mem="$home/.claude/projects/$slug/memory/MEMORY.md"
    if [[ -s "$mem" ]]; then
        printf "Contents of %s (user's auto-memory, persists across conversations):\n\n" "$mem"
        head -n 200 "$mem"
        printf '\n'
    fi
}
# worker_rules_file project_root orch_name: writes the text to
# <project_root>/.claude/worker-rules.md (only when the bytes changed, via an
# atomic rename, so concurrent dispatches never see a half-written file) and
# prints that path. Fails when the file cannot be written: the caller then
# launches the old way (rules in message 0).
worker_rules_file() {
    local root="$1" orch="$2" out tmp
    out="$root/.claude/worker-rules.md"
    mkdir -p "$root/.claude" 2>/dev/null || return 1
    tmp="$(mktemp "$root/.claude/worker-rules.XXXXXX")" || return 1
    if ! build_worker_rules_text "$root" "$orch" > "$tmp" || ! [[ -s "$tmp" ]]; then
        rm -f "$tmp"; return 1
    fi
    if cmp -s "$tmp" "$out" 2>/dev/null; then rm -f "$tmp"; else mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }; fi
    printf '%s' "$out"
}
