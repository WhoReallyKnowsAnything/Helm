#!/usr/bin/env bash
# question-stages.sh -- the one list of Cadence stages whose workers may use
# AskUserQuestion (the app shows the question as a card). A later phase adds a
# stage by adding one entry here.

QUESTION_STAGES=(context plan verify execute milestone)

# question_stage_allowed <agent_id>: succeeds only for a dispatch label of the form
# cad-<stage>-p<digits>[-<digits>] with <stage> in QUESTION_STAGES. Both ends are anchored.
question_stage_allowed() {
    local id="${1:-}" stage
    [[ -n "$id" ]] || return 1
    for stage in "${QUESTION_STAGES[@]}"; do
        [[ "$id" =~ ^cad-${stage}-p[0-9]+(-[0-9]+)?$ ]] && return 0
    done
    return 1
}

return 0 2>/dev/null || true
