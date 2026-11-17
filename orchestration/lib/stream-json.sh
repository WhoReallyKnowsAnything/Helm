#!/bin/bash
# orchestration/lib/stream-json.sh
# Builds the one-line stdin message a headless `claude -p --input-format
# stream-json` session reads from its inbox file.
#
# Line shape (Claude Code SDK user message; Plan 3 copies it into the app):
#   {"type":"user","message":{"role":"user","content":"<text>"}}
# CONFIRMED 2026-11-05: a real `claude -p --input-format stream-json
# --output-format stream-json --verbose --model haiku` fed this line through
# `tail -n +1 -f <inbox>` answered with a `result` event
# (test-stream-json-line.sh, ORCH_REAL_CLAUDE=1).

# stream_json_user_line text
# Prints one JSON line plus one newline. The text is passed to jq as data, so
# quotes, newlines, backslashes and control characters stay data.
stream_json_user_line() {
    command -v jq >/dev/null 2>&1 || { echo "Error: jq is required to build a stream-json line" >&2; return 1; }
    [[ -n "${1-}" ]] || { echo "Error: stream_json_user_line needs non-empty text" >&2; return 1; }
    jq -cn --arg text "$1" '{type: "user", message: {role: "user", content: $text}}'
}
