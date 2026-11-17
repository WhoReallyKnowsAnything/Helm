#!/bin/bash
# test/test-git-approval-gate.sh
# Table test for the gate's op matching: which commands are held ("ask") and
# which pass straight through. Runs the real hook with a non-worker cwd, so a
# held op shows as the native "ask" decision. Plain bash, no framework.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../orchestration/hooks/git-approval-gate.sh"

PASS_COUNT=0
FAIL_COUNT=0

# run_hook command: prints the hook's stdout for a Bash PreToolUse payload.
run_hook() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_use_id:"toolu_test",cwd:"/tmp",tool_input:{command:process.argv[1]}}))' "$1" \
        | "$HOOK" 2>/dev/null
}

# expect held|pass command
expect() {
    local want=$1 cmd=$2 out got
    out=$(run_hook "$cmd")
    case "$out" in
        '')                  got=pass ;;
        *'"ask"'*)           got=held ;;
        *'--no-verify'*)     got=blocked ;;
        *)                   got="other:$out" ;;
    esac
    if [[ "$got" == "$want" ]]; then
        echo "PASS: $want <- $cmd"; PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: want $want, got $got <- $cmd"; FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Pass straight through: "push" or "commit" is not the git subcommand.
expect pass 'git stash push'
expect pass 'git stash push -m "x"'
expect pass 'git log --grep push'
expect pass 'git log --grep=commit'
expect pass 'git show HEAD:commit.txt'
expect pass 'git branch --contains abc123'
expect pass 'git -C "/path with space" status'
expect pass 'echo "git stash push"'
expect pass 'git status && git stash push -m wip'
expect pass 'ls'

# Held: a real commit, push or pr create.
expect held 'git push'
expect held 'git push origin main'
expect held 'git -C /some/dir push'
expect held 'git -C "/path with space" push'
expect held 'git -c key=val commit -m x'
expect held 'git --no-pager commit'
expect held 'git -P --git-dir=/x/.git push'
expect held 'git --git-dir /x/.git --work-tree /x commit'
expect held 'cd x && git push'
expect held 'git status; git push'
expect held 'git log | git push'
expect held 'git commit -am "fix push"'
expect held '/usr/bin/git push'
expect held 'bash -c "git push"'
expect held 'echo "$(git push)"'
expect held 'git $SUB'
expect held 'git -c alias.p=push p'
expect held 'gh pr create --title x'
expect held 'node gsd-tools.cjs query commit msg'

# --no-verify block is unchanged.
expect blocked 'git commit --no-verify -m x'

echo "---"
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[[ $FAIL_COUNT -eq 0 ]]
