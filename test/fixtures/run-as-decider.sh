#!/bin/bash
# test/fixtures/run-as-decider.sh band|app|worker|none cmd [args...]
# Runs cmd detached (launchd adopts it) under a fake parent process whose ps
# comm and args look like the band's Claude session, the orchestrator-gui app,
# a worker under the band, or a plain shell. Waits for cmd, prints its stdout,
# prints its stderr to stderr, exits with its status (98 after 30 s).
# APP_BUNDLE (default Helm) and APP_EXEC (default Helm) name the app kind's process:
# <APP_BUNDLE>.app/Contents/MacOS/<APP_EXEC>.
# Absolute tool paths: callers put stub mv etc. first on PATH.

kind=$1; shift
d=$(/usr/bin/mktemp -d) || exit 97
app="$d/${APP_BUNDLE:-Helm}.app/Contents/MacOS"
exe=${APP_EXEC:-Helm}
/bin/mkdir -p "$d/bin" "$app"
/bin/ln -s /bin/bash "$d/bin/claude"
/bin/ln -s /bin/bash "$app/$exe"
printf '%q ' "$@" > "$d/cmd"
printf ". '%s/cmd' >'%s/out' 2>'%s/err'; echo \$? >'%s/rc.tmp'; /bin/mv '%s/rc.tmp' '%s/rc'\n" "$d" "$d" "$d" "$d" "$d" "$d" > "$d/step"
run=". '$d/step'; true"
band_prompt=/orch/orchestration/prompts/task-drafting-mode.md
worker_prompt=/orch/orchestration/prompts/worker-dependency-awareness.md

case "$kind" in
    band) ( "$d/bin/claude" -c "$run" claude --append-system-prompt-file "$band_prompt" </dev/null >/dev/null 2>&1 & ) ;;
    app) ( "$app/$exe" -c "$run" </dev/null >/dev/null 2>&1 & ) ;;
    worker)
        printf '%s\n' "'$d/bin/claude' -c \"$run\" claude --append-system-prompt-file $worker_prompt" > "$d/worker"
        ( "$d/bin/claude" -c ". '$d/worker'; true" claude --append-system-prompt-file "$band_prompt" </dev/null >/dev/null 2>&1 & ) ;;
    none) ( /bin/bash -c "$run" </dev/null >/dev/null 2>&1 & ) ;;
    *) echo "run-as-decider.sh: unknown kind '$kind'" >&2; /bin/rm -rf "$d"; exit 99 ;;
esac

i=0
while [ ! -e "$d/rc" ]; do
    i=$((i + 1))
    if [ "$i" -gt 300 ]; then /bin/rm -rf "$d"; exit 98; fi
    /bin/sleep 0.1
done
/bin/cat "$d/out"
/bin/cat "$d/err" >&2
rc=$(/bin/cat "$d/rc")
/bin/rm -rf "$d"
exit "$rc"
