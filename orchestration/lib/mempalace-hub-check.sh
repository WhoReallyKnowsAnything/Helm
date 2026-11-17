#!/bin/bash
# orchestration/lib/mempalace-hub-check.sh
# Warn-only probe of the MemPalace hub (`mempalace serve`). Source this file,
# then call mempalace_hub_warning: it prints one warning line, or nothing, and
# always returns 0 -- a dispatch is never blocked by a missing hub.
#
# MemPalace allows one writer per palace. Without a hub, the first session's
# MCP server takes the lease and every later session is read-only, so a
# worker's wrap-up save fails. With a hub, every session's mempalace-mcp
# proxies to it and all of them can write.
#
# The hub takes the writer lease at startup and does not answer /healthz while
# it waits for it, so an answering hub holds the lease unless it was started
# read-only. /statusz reports that in writer.read_only (a --read-only hub) and
# writer.peer_writer_read_only / peer_writer_lock_failed (a lost lease).
# MEMPALACE_HUB_URL overrides the default address.

mempalace_hub_url() {
    printf '%s' "${MEMPALACE_HUB_URL:-http://127.0.0.1:8765}"
}

# Probes are separate functions so tests can stub them.
mempalace_hub_healthz() {
    curl -fsS -m 2 "$(mempalace_hub_url)/healthz" >/dev/null 2>&1
}

mempalace_hub_status() {
    curl -fsS -m 2 "$(mempalace_hub_url)/statusz" 2>/dev/null | tr -d ' \n'
}

mempalace_hub_warning() {
    local url status
    url="$(mempalace_hub_url)"
    # No MemPalace on this machine means no hub is expected, so nothing to warn about.
    [[ -x "$HOME/.local/bin/mempalace" ]] || command -v mempalace >/dev/null 2>&1 || mempalace_hub_healthz || return 0
    if ! mempalace_hub_healthz; then
        echo "warning: MemPalace hub not answering at $url -- worker sessions share one writer lease, so most workers cannot save to MemPalace. launch-claude.sh starts the hub on the next app launch (log: /tmp/mempalace-hub.log)."
        return 0
    fi
    status="$(mempalace_hub_status)"
    if [[ "$status" == *'"read_only":true'* \
       || "$status" == *'"peer_writer_read_only":true'* \
       || "$status" == *'"peer_writer_lock_failed":true'* ]]; then
        echo "warning: MemPalace hub at $url is read-only (it does not hold the writer lease) -- no session can save to MemPalace. Stop the other mempalace-mcp holders or restart the hub."
    fi
    return 0
}

# Start the hub as a launchd job when it is down. Never blocks the launch: it waits
# at most MEMPALACE_HUB_WAIT_TICKS x 0.1s, and only right after a bootstrap.
# Returns 0 when the hub answers or nothing could be tried (no launchctl, binary or
# plist), and 1 when it tried (or the job is loaded) and the hub still does not
# answer; the caller then runs mempalace_hub_warning.
# Idempotent: a hub that answers, or a job that is already loaded, is left alone.
# The plist stays in the repo; bootstrap runs on a temp copy with the binary path
# filled in, so nothing is installed outside the repo. The job lives until logout.
# Only $HOME/.local/bin/mempalace (the uv tool path) is used; a sandboxed HOME,
# as the tests use, therefore never starts a real hub.
MEMPALACE_HUB_LABEL=io.github.whoreallyknowsanything.helm.mempalace-hub
_MEMPALACE_HUB_PLIST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../launchd" && pwd)/$MEMPALACE_HUB_LABEL.plist"

mempalace_hub_launchctl() { /bin/launchctl "$@"; }

mempalace_hub_ensure() {
    local bin="$HOME/.local/bin/mempalace" dir i
    mempalace_hub_healthz && return 0
    [[ -x /bin/launchctl && -x "$bin" && -f "$_MEMPALACE_HUB_PLIST" ]] || return 0
    # loaded but not answering: the hub is still waiting for the writer lease
    mempalace_hub_launchctl print "gui/$UID/$MEMPALACE_HUB_LABEL" &>/dev/null && return 1
    dir="$(mktemp -d "${TMPDIR:-/tmp}/mempalace-hub.XXXXXX")" || return 0
    sed "s|__MEMPALACE_BIN__|$bin|" "$_MEMPALACE_HUB_PLIST" >"$dir/job.plist"
    mempalace_hub_launchctl bootstrap "gui/$UID" "$dir/job.plist" &>/dev/null
    rm -rf "$dir"
    for ((i = 0; i < ${MEMPALACE_HUB_WAIT_TICKS:-80}; i++)); do
        mempalace_hub_healthz && return 0
        /bin/sleep 0.1
    done
    return 1
}
